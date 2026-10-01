import AVFoundation
import Darwin
import Foundation

struct AudioEngineDiagnostic: Sendable {
    let event: String
    let status: String
    let errorDomain: String?
    let errorCode: Int?
}

enum AudioEngineRuntimeFailure: Equatable, Sendable { case captureStalled, captureConversion, playbackConversion, configurationChanged }

struct PCMSignalMetrics: Equatable, Sendable {
    let frameCount: Int
    let rms: Double
    let peak: Double
    let nonzeroCount: Int

    var hasNonzeroSignal: Bool { nonzeroCount > 0 }
}

enum AudioFlowFailureStage: String, Equatable, Sendable {
    case noMicCallback = "no_mic_callback"
    case conversionFailure = "conversion_failure"
    case sendFailure = "send_failure"
    case receiveAbsent = "receive_absent"
    case playbackScheduleFailure = "playback_schedule_failure"
    case renderFailure = "render_failure"
}

struct AudioProgressCounters: Equatable, Sendable {
    var sent: UInt64 = 0
    var received: UInt64 = 0
    var rendered: UInt64 = 0

    func stalledStage(since baseline: Self) -> AudioFlowFailureStage? {
        if sent == baseline.sent { return .sendFailure }
        if received == baseline.received { return .receiveAbsent }
        if rendered == baseline.rendered { return .renderFailure }
        return nil
    }
}

struct AudioFlowMilestones: Equatable, Sendable {
    var micCallback = false
    var networkPCMGenerated = false
    var networkFrameSent = false
    var remoteFrameReceived = false
    var playbackScheduled = false
    var playbackRendered = false

    var failureStage: AudioFlowFailureStage? {
        if !micCallback { return .noMicCallback }
        if !networkPCMGenerated { return .conversionFailure }
        if !networkFrameSent { return .sendFailure }
        if !remoteFrameReceived { return .receiveAbsent }
        if !playbackScheduled { return .playbackScheduleFailure }
        if !playbackRendered { return .renderFailure }
        return nil
    }

    func isOperational(transportActive: Bool) -> Bool {
        transportActive && micCallback && networkPCMGenerated && networkFrameSent &&
            remoteFrameReceived && playbackRendered
    }
}

enum AudioWatchdogAction: Equatable, Sendable { case recover, terminate }

enum AudioWatchdogPolicy {
    static func action(for stage: AudioFlowFailureStage, recoveryAvailable: Bool) -> AudioWatchdogAction {
        let structural = stage == .noMicCallback || stage == .conversionFailure ||
            stage == .playbackScheduleFailure || stage == .renderFailure
        return structural && recoveryAvailable ? .recover : .terminate
    }
}

struct AudioRecoveryBudget: Equatable, Sendable {
    private(set) var used = false
    mutating func claim() -> Bool {
        guard !used else { return false }
        used = true
        return true
    }
}

protocol AudioEngineHandling: AnyObject {
    var onFrame: (@Sendable (Data) -> Void)? { get set }
    var onDiagnostic: (@Sendable (AudioEngineDiagnostic) -> Void)? { get set }
    var onFailure: (@Sendable (AudioEngineRuntimeFailure) -> Void)? { get set }
    var onMuteChanged: (@Sendable (Bool) -> Void)? { get set }
    func ensureRecordPermission() async -> Bool
    func configureSession() throws
    func start(muted: Bool) throws
    func stop()
    func setMuted(_ value: Bool) throws
    func play(_ payload: Data)
}

struct CaptureSourceLifecycle {
    private(set) var isInstalled = false
    mutating func install(installSource: () -> Void, startEngine: () throws -> Void, removeSource: () -> Void) throws {
        guard !isInstalled else { throw CallFailure.audioFailed }
        installSource(); isInstalled = true
        do { try startEngine() } catch { removeSource(); isInstalled = false; throw error }
    }
    mutating func remove(_ removeSource: () -> Void) { guard isInstalled else { return }; removeSource(); isInstalled = false }
}

/// A bounded SPSC ring. The realtime callback only copies into preallocated AVAudioPCMBuffer storage.
private final class RealtimeCaptureRing: @unchecked Sendable {
    private let slots: [AVAudioPCMBuffer]
    private let capacity: Int
    private let writeSequence = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let readSequence = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let callbacks = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let drops = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let frameLengths: UnsafeMutablePointer<AVAudioFrameCount>

    var callbackCount: UInt64 { UInt64(max(0, OSAtomicAdd64Barrier(0, callbacks))) }
    var droppedCount: UInt64 { UInt64(max(0, OSAtomicAdd64Barrier(0, drops))) }

    init?(format: AVAudioFormat, slots: Int = 12, maximumFrames: AVAudioFrameCount = 4096) {
        var buffers: [AVAudioPCMBuffer] = []
        for _ in 0..<slots { guard let value = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else { return nil }; buffers.append(value) }
        self.slots = buffers; self.capacity = slots
        self.frameLengths = .allocate(capacity: slots)
        writeSequence.initialize(to: 0); readSequence.initialize(to: 0)
        callbacks.initialize(to: 0); drops.initialize(to: 0)
        frameLengths.initialize(repeating: 0, count: slots)
    }

    deinit {
        writeSequence.deinitialize(count: 1); writeSequence.deallocate()
        readSequence.deinitialize(count: 1); readSequence.deallocate()
        callbacks.deinitialize(count: 1); callbacks.deallocate()
        drops.deinitialize(count: 1); drops.deallocate()
        frameLengths.deinitialize(count: capacity); frameLengths.deallocate()
    }

    func write(frameCount: AVAudioFrameCount, inputData: UnsafePointer<AudioBufferList>) {
        OSAtomicIncrement64Barrier(callbacks)
        let write = OSAtomicAdd64Barrier(0, writeSequence)
        let read = OSAtomicAdd64Barrier(0, readSequence)
        guard write - read < Int64(capacity) else { OSAtomicIncrement64Barrier(drops); return }
        let slotIndex = Int(write % Int64(capacity))
        let target = slots[slotIndex]
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let destination = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        guard source.count == destination.count else { OSAtomicIncrement64Barrier(drops); return }
        var validFrames = min(frameCount, target.frameCapacity)
        for index in source.indices {
            guard let sourceData = source[index].mData, let destinationData = destination[index].mData else { OSAtomicIncrement64Barrier(drops); return }
            let bytesPerFrame = max(1, Int(target.format.streamDescription.pointee.mBytesPerFrame))
            let destinationCapacity = Int(target.frameCapacity) * bytesPerFrame
            let byteCount = min(Int(source[index].mDataByteSize), destinationCapacity)
            guard byteCount > 0 else { OSAtomicIncrement64Barrier(drops); return }
            memcpy(destinationData, sourceData, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
            validFrames = min(validFrames, AVAudioFrameCount(byteCount / bytesPerFrame))
        }
        guard validFrames > 0 else { OSAtomicIncrement64Barrier(drops); return }
        frameLengths[slotIndex] = validFrames
        OSAtomicIncrement64Barrier(writeSequence)
    }

    func consume(_ body: (AVAudioPCMBuffer) -> Void) -> Bool {
        let read = OSAtomicAdd64Barrier(0, readSequence)
        guard read < OSAtomicAdd64Barrier(0, writeSequence) else { return false }
        let slotIndex = Int(read % Int64(capacity))
        let value = slots[slotIndex]
        value.frameLength = frameLengths[slotIndex]
        body(value)
        OSAtomicIncrement64Barrier(readSequence)
        return true
    }
}

private struct PCMByteRing {
    private var storage = [UInt8](repeating: 0, count: 16_384)
    private var readIndex = 0
    private var count = 0

    mutating func append(_ data: Data) {
        data.withUnsafeBytes { bytes in
            guard let source = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            for offset in 0..<bytes.count {
                if count == storage.count { readIndex = (readIndex + 1) % storage.count; count -= 1 }
                storage[(readIndex + count) % storage.count] = source[offset]; count += 1
            }
        }
    }

    mutating func popFrame() -> Data? {
        guard count >= AudioEngine.bytesPerFrame else { return nil }
        var output = Data(count: AudioEngine.bytesPerFrame)
        output.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            for offset in 0..<AudioEngine.bytesPerFrame { destination[offset] = storage[(readIndex + offset) % storage.count] }
        }
        readIndex = (readIndex + AudioEngine.bytesPerFrame) % storage.count; count -= AudioEngine.bytesPerFrame
        return output
    }

    mutating func reset() { readIndex = 0; count = 0 }
}

final class AudioEngine: AudioEngineHandling, @unchecked Sendable {
    static let networkSampleRate: Double = 16_000
    static let samplesPerFrame: AVAudioFrameCount = 320
    static let bytesPerFrame = 640

    var onFrame: (@Sendable (Data) -> Void)?
    var onDiagnostic: (@Sendable (AudioEngineDiagnostic) -> Void)?
    var onFailure: (@Sendable (AudioEngineRuntimeFailure) -> Void)?
    var onMuteChanged: (@Sendable (Bool) -> Void)?

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let controlQueue = DispatchQueue(label: "com.vkapps.wifisecurecall.audio.control", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "com.vkapps.wifisecurecall.audio.capture", qos: .userInteractive)
    private let playbackQueue = DispatchQueue(label: "com.vkapps.wifisecurecall.audio.playback", qos: .userInteractive)
    private var inputConverter: AVAudioConverter?
    private var outputConverter: AVAudioConverter?
    private var networkFormat: AVAudioFormat?
    private var captureSink: AVAudioSinkNode?
    private var captureRing: RealtimeCaptureRing?
    private var pcmRing = PCMByteRing()
    private var captureTimer: DispatchSourceTimer?
    private var watchdog: DispatchWorkItem?
    private var watchdogGeneration: UInt64 = 0
    private var renderedBufferCount: UInt64 = 0
    // Access only on playbackQueue; callbacks from an earlier graph must not mark a new graph rendered.
    private var playbackGeneration: UInt64 = 0
    private var captureLifecycle = CaptureSourceLifecycle()
    private var starting = false
    private var scheduledBuffers = 0
    private let maximumScheduledBuffers = 8
    private var firstMicBufferReported = false
    private var firstMicNonzeroReported = false
    private var firstNetworkFrameReported = false
    private var firstNetworkNonzeroReported = false
    private var firstCaptureFailureReported = false
    private var firstPlaybackScheduledReported = false
    private var firstPlaybackNonzeroReported = false
    private var firstPlaybackRenderedReported = false
    private var firstPlaybackFailureReported = false
    private var playbackOverflowReported = false
    private var peakScheduledBuffers = 0
    private var observers: [NSObjectProtocol] = []
    private let transmitMute = TransmitMuteGate()

    init() { engine.attach(player); installObservers() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func ensureRecordPermission() async -> Bool {
        if #available(iOS 17.0, watchOS 10.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: emit("microphone_permission", "granted"); return true
            case .denied: emit("microphone_permission", "denied"); return false
            case .undetermined:
                let granted = await withCheckedContinuation { continuation in AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) } }
                emit("microphone_permission", granted ? "requested_granted" : "requested_denied"); return granted
            @unknown default: emit("microphone_permission", "unknown"); return false
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: emit("microphone_permission", "granted"); return true
        case .denied: emit("microphone_permission", "denied"); return false
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
            emit("microphone_permission", granted ? "requested_granted" : "requested_denied"); return granted
        @unknown default: return false
        }
    }

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        #if os(watchOS)
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        #else
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        #endif
        emit("audio_session_configured", "success")
    }

    func setMuted(_ value: Bool) throws {
        controlQueue.sync {
            applyMute(value)
            emit("audio_input_mute", value ? "muted" : "unmuted")
        }
    }

    func start(muted: Bool) throws { try controlQueue.sync { try startOnControlQueue(muted: muted) } }

    private func startOnControlQueue(muted: Bool) throws {
        guard !engine.isRunning, !starting else { throw CallFailure.audioFailed }
        starting = true; emit("audio_engine_start_attempt", "started")
        do {
            cleanupGraph(); resetFirstFlags()
            let input = engine.inputNode, output = engine.outputNode
            try input.setVoiceProcessingEnabled(true)
            guard input.isVoiceProcessingEnabled, output.isVoiceProcessingEnabled else { throw NSError(domain: "WiFiSecureCall.AudioEngine", code: 20) }
            emit("voice_processing_enabled", "input=YES output=YES")
            applyMute(muted)

            let session = AVAudioSession.sharedInstance()
            emit("audio_route", "inputAvailable=\(session.isInputAvailable) inputs=\(session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")) outputs=\(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","))")
            let inputFormat = input.outputFormat(forBus: 0)
            let hardwareInput = input.inputFormat(forBus: 0)
            let outputFormat = output.inputFormat(forBus: 0)
            try validate(inputFormat); try validate(hardwareInput); try validate(outputFormat)
            emit("input_format", "client \(formatDescription(inputFormat)) hardware \(formatDescription(hardwareInput))")
            emit("output_format", "hardware \(formatDescription(outputFormat))")

            guard let network = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.networkSampleRate, channels: 1, interleaved: true),
                  let captureConverter = AVAudioConverter(from: inputFormat, to: network),
                  let playbackConverter = AVAudioConverter(from: network, to: outputFormat),
                  let ring = RealtimeCaptureRing(format: inputFormat)
            else { throw CallFailure.audioFailed }
            captureConverter.primeMethod = .none; playbackConverter.primeMethod = .none
            networkFormat = network; inputConverter = captureConverter; outputConverter = playbackConverter; captureRing = ring
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            player.volume = 1; engine.mainMixerNode.outputVolume = 1

            let sink = AVAudioSinkNode { [weak ring] _, frameCount, data in ring?.write(frameCount: frameCount, inputData: data); return noErr }
            captureSink = sink
            try captureLifecycle.install(
                installSource: { [engine] in engine.attach(sink); engine.connect(input, to: sink, format: inputFormat) },
                startEngine: { [engine] in engine.prepare(); try engine.start() },
                removeSource: { [engine] in engine.disconnectNodeInput(sink); engine.detach(sink) }
            )
            player.play(); startCaptureWorker(); startCaptureWatchdog(ring)
            starting = false; emit("capture_source_connected", "av_audio_sink_node"); emit("audio_engine_start_success", "success")
        } catch {
            cleanupGraph(); starting = false
            let value = error as NSError; emit("audio_engine_start_failure", "failed", error: value)
            throw CallFailure.audioFailed
        }
    }

    func stop() { controlQueue.sync { cleanupGraph() } }

    func play(_ payload: Data) {
        guard payload.count == Self.bytesPerFrame else { reportPlaybackFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 30)); return }
        playbackQueue.async { [weak self] in self?.convertAndSchedule(payload) }
    }

    static func convertToNetworkPCM(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> Data? {
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * networkSampleRate / buffer.format.sampleRate)) + 16
        guard let destination = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false, error: NSError?
        let status = converter.convert(to: destination, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, destination.frameLength > 0 else { return nil }
        return pcmData(from: destination, requireCanonicalFrame: false)
    }

    static func isCanonicalNetworkFormat(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatInt16 && format.sampleRate == networkSampleRate &&
            format.channelCount == 1 && format.isInterleaved
    }

    static func pcmData(from buffer: AVAudioPCMBuffer, requireCanonicalFrame: Bool = true) -> Data? {
        guard isCanonicalNetworkFormat(buffer.format), buffer.frameLength > 0 else { return nil }
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        if requireCanonicalFrame && (buffer.frameLength != samplesPerFrame || byteCount != bytesPerFrame) { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard buffers.count == 1, let base = buffers[0].mData, Int(buffers[0].mDataByteSize) >= byteCount else { return nil }
        return Data(bytes: base, count: byteCount)
    }

    static func canonicalBuffer(from payload: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard payload.count == bytesPerFrame, isCanonicalNetworkFormat(format),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: samplesPerFrame) else { return nil }
        buffer.frameLength = samplesPerFrame
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard buffers.count == 1, let destination = buffers[0].mData,
              Int(buffers[0].mDataByteSize) >= payload.count else { return nil }
        payload.withUnsafeBytes { bytes in if let source = bytes.baseAddress { memcpy(destination, source, payload.count) } }
        buffers[0].mDataByteSize = UInt32(payload.count)
        return buffer
    }

    static func signalMetrics(forCanonicalPCM data: Data) -> PCMSignalMetrics? {
        guard data.count == bytesPerFrame else { return nil }
        var sum = 0.0, peak = 0.0, nonzero = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                let sample = Double(Int16(bitPattern: bits)) / Double(Int16.max)
                let magnitude = abs(sample)
                sum += sample * sample; peak = max(peak, magnitude)
                if bits != 0 { nonzero += 1 }
            }
        }
        return PCMSignalMetrics(frameCount: Int(samplesPerFrame), rms: sqrt(sum / Double(samplesPerFrame)), peak: peak, nonzeroCount: nonzero)
    }

    static func signalMetrics(for buffer: AVAudioPCMBuffer) -> PCMSignalMetrics? {
        guard buffer.frameLength > 0 else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var sum = 0.0, peak = 0.0, nonzero = 0, sampleCount = 0
        for audioBuffer in list {
            guard let data = audioBuffer.mData else { continue }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let count = min(Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size, Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1))
                let values = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count { let sample = Double(values[index]); let magnitude = abs(sample); sum += sample * sample; peak = max(peak, magnitude); if values[index] != 0 { nonzero += 1 } }
                sampleCount += count
            case .pcmFormatInt16:
                let count = min(Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size, Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1))
                let values = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<count { let sample = Double(values[index]) / Double(Int16.max); let magnitude = abs(sample); sum += sample * sample; peak = max(peak, magnitude); if values[index] != 0 { nonzero += 1 } }
                sampleCount += count
            case .pcmFormatInt32:
                let count = min(Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size, Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1))
                let values = data.bindMemory(to: Int32.self, capacity: count)
                for index in 0..<count { let sample = Double(values[index]) / Double(Int32.max); let magnitude = abs(sample); sum += sample * sample; peak = max(peak, magnitude); if values[index] != 0 { nonzero += 1 } }
                sampleCount += count
            default: return nil
            }
        }
        guard sampleCount > 0 else { return nil }
        return PCMSignalMetrics(frameCount: Int(buffer.frameLength), rms: sqrt(sum / Double(sampleCount)), peak: peak, nonzeroCount: nonzero)
    }

    private func startCaptureWorker() {
        captureTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drainCaptureRing() }
        captureTimer = timer; timer.resume()
    }

    private func drainCaptureRing() {
        guard let ring = captureRing, let converter = inputConverter else { return }
        while ring.consume({ [self] buffer in
            if let metrics = Self.signalMetrics(for: buffer) {
                if !firstMicBufferReported {
                    firstMicBufferReported = true
                    emit("first_mic_callback", metricsDescription(metrics))
                    emit("first_mic_buffer", "frameLength=\(buffer.frameLength) sampleRate=\(buffer.format.sampleRate) channelCount=\(buffer.format.channelCount)")
                }
                if metrics.hasNonzeroSignal, !firstMicNonzeroReported {
                    firstMicNonzeroReported = true
                    emit("first_mic_nonzero_signal", metricsDescription(metrics))
                }
            }
            guard let converted = Self.convertToNetworkPCM(buffer, converter: converter) else { reportCaptureFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 31)); return }
            pcmRing.append(converted)
            while let frame = pcmRing.popFrame() {
                guard let metrics = Self.signalMetrics(forCanonicalPCM: frame) else { reportCaptureFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 36)); continue }
                if !firstNetworkFrameReported {
                    firstNetworkFrameReported = true
                    emit("first_network_pcm_generated", "bytes=\(frame.count) \(metricsDescription(metrics))")
                    emit("first_network_audio_frame_generated", "bytes=\(frame.count)")
                }
                if metrics.hasNonzeroSignal, !firstNetworkNonzeroReported {
                    firstNetworkNonzeroReported = true
                    emit("first_network_pcm_nonzero", metricsDescription(metrics))
                }
                onFrame?(transmitMute.outgoingFrame(frame))
            }
        }) {}
    }

    private func startCaptureWatchdog(_ ring: RealtimeCaptureRing) {
        watchdog?.cancel()
        watchdogGeneration &+= 1
        scheduleCaptureWatchdog(ring, baseline: ring.callbackCount, generation: watchdogGeneration)
    }

    private func scheduleCaptureWatchdog(_ ring: RealtimeCaptureRing, baseline: UInt64, generation: UInt64) {
        let item = DispatchWorkItem { [weak self, weak ring] in
            guard let self, let ring, self.engine.isRunning, self.watchdogGeneration == generation else { return }
            let current = ring.callbackCount
            if current == baseline {
                self.emit("capture_watchdog_failed", "callbacks_stalled")
                self.onFailure?(.captureStalled)
                return
            }
            self.scheduleCaptureWatchdog(ring, baseline: current, generation: generation)
        }
        watchdog = item; controlQueue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func convertAndSchedule(_ payload: Data) {
        guard engine.isRunning, let networkFormat, let converter = outputConverter,
              let source = Self.canonicalBuffer(from: payload, format: networkFormat) else {
            let error = NSError(domain: "WiFiSecureCall.AudioEngine", code: 32)
            reportPlaybackFailure(error); return
        }
        guard scheduledBuffers < maximumScheduledBuffers else {
            if !playbackOverflowReported { playbackOverflowReported = true; emit("playback_overflow", "dropped depth=\(scheduledBuffers)") }
            return
        }
        if let metrics = Self.signalMetrics(forCanonicalPCM: payload), metrics.hasNonzeroSignal, !firstPlaybackNonzeroReported {
            firstPlaybackNonzeroReported = true
            emit("first_playback_nonzero_input", metricsDescription(metrics))
        }
        let capacity = AVAudioFrameCount(ceil(Double(Self.samplesPerFrame) * converter.outputFormat.sampleRate / networkFormat.sampleRate)) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { reportPlaybackFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 34)); return }
        var supplied = false, error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, status in if supplied { status.pointee = .noDataNow; return nil }; supplied = true; status.pointee = .haveData; return source }
        guard status != .error, error == nil, converted.frameLength > 0 else { reportPlaybackFailure(error ?? NSError(domain: "WiFiSecureCall.AudioEngine", code: 35)); return }
        if !player.isPlaying { player.play() }
        scheduledBuffers += 1
        peakScheduledBuffers = max(peakScheduledBuffers, scheduledBuffers)
        let generation = playbackGeneration
        player.scheduleBuffer(converted, completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.playbackQueue.async {
                guard self.playbackGeneration == generation else { return }
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                if !self.firstPlaybackRenderedReported { self.firstPlaybackRenderedReported = true; self.emit("first_playback_buffer_rendered", "rendered") }
                self.renderedBufferCount &+= 1
                if self.renderedBufferCount.isMultiple(of: 50) { self.emit("playback_render_progress", "frames=50") }
            }
        }
        if !firstPlaybackScheduledReported { firstPlaybackScheduledReported = true; emit("first_playback_buffer_scheduled", "frameLength=\(converted.frameLength) depth=\(scheduledBuffers) peak=\(peakScheduledBuffers)") }
    }

    private func cleanupGraph() {
        watchdogGeneration &+= 1; watchdog?.cancel(); watchdog = nil; captureTimer?.cancel(); captureTimer = nil
        playbackQueue.sync { playbackGeneration &+= 1; scheduledBuffers = 0 }
        player.stop(); if engine.isRunning { engine.stop() }
        captureQueue.sync {}
        let sink = captureSink
        captureLifecycle.remove { [engine] in guard let sink else { return }; engine.disconnectNodeInput(sink); engine.detach(sink) }
        captureSink = nil; captureRing = nil; engine.disconnectNodeOutput(player); engine.reset()
        inputConverter = nil; outputConverter = nil; networkFormat = nil; pcmRing.reset(); scheduledBuffers = 0
        transmitMute.reset()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in self?.onFailure?(.configurationChanged) })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in self?.emit("audio_interruption", "\(note.userInfo?[AVAudioSessionInterruptionTypeKey] ?? "unknown")") })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in self?.emit("audio_route_changed", "changed") })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in self?.onFailure?(.configurationChanged) })
    }

    private func validate(_ format: AVAudioFormat) throws { guard format.sampleRate > 0, format.channelCount > 0 else { throw CallFailure.audioFailed } }
    private func applyMute(_ value: Bool) {
        _ = transmitMute.setMuted(value)
        emit("transmit_pcm_muted", value ? "YES" : "NO")
        onMuteChanged?(value)
    }
    private func formatDescription(_ format: AVAudioFormat) -> String { "sampleRate=\(format.sampleRate) channelCount=\(format.channelCount) commonFormat=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved)" }
    private func metricsDescription(_ metrics: PCMSignalMetrics) -> String { "frames=\(metrics.frameCount) rms=\(metrics.rms) peak=\(metrics.peak) nonzero=\(metrics.nonzeroCount)" }
    private func resetFirstFlags() { firstMicBufferReported = false; firstMicNonzeroReported = false; firstNetworkFrameReported = false; firstNetworkNonzeroReported = false; firstCaptureFailureReported = false; firstPlaybackScheduledReported = false; firstPlaybackNonzeroReported = false; firstPlaybackRenderedReported = false; firstPlaybackFailureReported = false; playbackOverflowReported = false; peakScheduledBuffers = 0; renderedBufferCount = 0 }
    private func reportCaptureFailure(_ error: NSError) { guard !firstCaptureFailureReported else { return }; firstCaptureFailureReported = true; emit("first_capture_conversion_failure", "failed", error: error); onFailure?(.captureConversion) }
    private func reportPlaybackFailure(_ error: NSError) { guard !firstPlaybackFailureReported else { return }; firstPlaybackFailureReported = true; emit("first_playback_failure", "failed", error: error); onFailure?(.playbackConversion) }
    private func emit(_ event: String, _ status: String, error: NSError? = nil) { onDiagnostic?(.init(event: event, status: status, errorDomain: error?.domain, errorCode: error?.code)) }
}
