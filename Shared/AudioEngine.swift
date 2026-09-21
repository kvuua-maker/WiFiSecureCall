import AVFoundation
import Foundation

struct AudioEngineDiagnostic: Sendable {
    let event: String
    let status: String
    let errorDomain: String?
    let errorCode: Int?
}

enum AudioEngineRuntimeFailure: Equatable, Sendable { case captureStalled, captureConversion, playbackConversion, configurationChanged }

protocol AudioEngineHandling: AnyObject {
    var onFrame: (@Sendable (Data) -> Void)? { get set }
    var onDiagnostic: (@Sendable (AudioEngineDiagnostic) -> Void)? { get set }
    var onFailure: (@Sendable (AudioEngineRuntimeFailure) -> Void)? { get set }
    var onMuteChanged: (@Sendable (Bool) -> Void)? { get set }
    func ensureRecordPermission() async -> Bool
    func configureSession() throws
    func start() throws
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
    private var writeIndex = 0
    private var readIndex = 0
    private(set) var callbackCount: UInt64 = 0
    private(set) var droppedCount: UInt64 = 0

    init?(format: AVAudioFormat, slots: Int = 12, maximumFrames: AVAudioFrameCount = 4096) {
        var buffers: [AVAudioPCMBuffer] = []
        for _ in 0..<slots { guard let value = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else { return nil }; buffers.append(value) }
        self.slots = buffers; self.capacity = slots
    }

    func write(frameCount: AVAudioFrameCount, inputData: UnsafePointer<AudioBufferList>) {
        callbackCount &+= 1
        let next = (writeIndex + 1) % capacity
        guard next != readIndex else { droppedCount &+= 1; return }
        let target = slots[writeIndex]
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let destination = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        guard source.count == destination.count else { droppedCount &+= 1; return }
        var validFrames = min(frameCount, target.frameCapacity)
        for index in source.indices {
            guard let sourceData = source[index].mData, let destinationData = destination[index].mData else { droppedCount &+= 1; return }
            let byteCount = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            guard byteCount > 0 else { droppedCount &+= 1; return }
            memcpy(destinationData, sourceData, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
            let bytesPerFrame = max(1, Int(target.format.streamDescription.pointee.mBytesPerFrame))
            validFrames = min(validFrames, AVAudioFrameCount(byteCount / bytesPerFrame))
        }
        guard validFrames > 0 else { droppedCount &+= 1; return }
        target.frameLength = validFrames
        writeIndex = next
    }

    func read() -> AVAudioPCMBuffer? {
        guard readIndex != writeIndex else { return nil }
        let value = slots[readIndex]
        readIndex = (readIndex + 1) % capacity
        return value
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
    private var captureLifecycle = CaptureSourceLifecycle()
    private var starting = false
    private var scheduledBuffers = 0
    private let maximumScheduledBuffers = 8
    private var firstMicBufferReported = false
    private var firstNetworkFrameReported = false
    private var firstCaptureFailureReported = false
    private var firstPlaybackScheduledReported = false
    private var firstPlaybackRenderedReported = false
    private var firstPlaybackFailureReported = false
    private var observers: [NSObjectProtocol] = []

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
        if #available(iOS 17.0, watchOS 10.0, *) { try AVAudioApplication.shared.setInputMuted(value) }
        engine.inputNode.isVoiceProcessingInputMuted = value
        onMuteChanged?(value)
        emit("audio_input_mute", value ? "muted" : "unmuted")
    }

    func start() throws { try controlQueue.sync { try startOnControlQueue() } }

    private func startOnControlQueue() throws {
        guard !engine.isRunning, !starting else { throw CallFailure.audioFailed }
        starting = true; emit("audio_engine_start_attempt", "started")
        do {
            cleanupGraph(); resetFirstFlags()
            let input = engine.inputNode, output = engine.outputNode
            try input.setVoiceProcessingEnabled(true)
            guard input.isVoiceProcessingEnabled, output.isVoiceProcessingEnabled else { throw NSError(domain: "WiFiSecureCall.AudioEngine", code: 20) }
            emit("voice_processing_enabled", "input=YES output=YES")
            let muted: Bool
            if #available(iOS 17.0, watchOS 10.0, *) { muted = AVAudioApplication.shared.isInputMuted }
            else { muted = input.isVoiceProcessingInputMuted }
            onMuteChanged?(muted)

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
        guard status != .error, error == nil, destination.frameLength > 0, let channel = destination.int16ChannelData?[0] else { return nil }
        return Data(bytes: channel, count: Int(destination.frameLength) * MemoryLayout<Int16>.size)
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
        while let buffer = ring.read() {
            if !firstMicBufferReported { firstMicBufferReported = true; emit("first_mic_buffer", "frameLength=\(buffer.frameLength) sampleRate=\(buffer.format.sampleRate) channelCount=\(buffer.format.channelCount)") }
            guard let converted = Self.convertToNetworkPCM(buffer, converter: converter) else { reportCaptureFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 31)); continue }
            pcmRing.append(converted)
            while let frame = pcmRing.popFrame() {
                if !firstNetworkFrameReported { firstNetworkFrameReported = true; emit("first_network_audio_frame_generated", "bytes=\(frame.count)") }
                onFrame?(frame)
            }
        }
    }

    private func startCaptureWatchdog(_ ring: RealtimeCaptureRing) {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self, weak ring] in
            guard let self, self.engine.isRunning, (ring?.callbackCount ?? 0) == 0 else { return }
            self.emit("capture_watchdog_failed", "no_callbacks")
            self.onFailure?(.captureStalled)
        }
        watchdog = item; controlQueue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func convertAndSchedule(_ payload: Data) {
        guard engine.isRunning, let networkFormat, let converter = outputConverter,
              let source = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: Self.samplesPerFrame) else {
            let error = NSError(domain: "WiFiSecureCall.AudioEngine", code: 32)
            reportPlaybackFailure(error); onFailure?(.playbackConversion); return
        }
        guard scheduledBuffers < maximumScheduledBuffers else { emit("playback_overflow", "dropped"); return }
        source.frameLength = Self.samplesPerFrame
        let copied = payload.withUnsafeBytes { bytes -> Bool in guard let base = bytes.baseAddress, let channel = source.int16ChannelData?[0] else { return false }; memcpy(channel, base, payload.count); return true }
        guard copied else { reportPlaybackFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 33)); return }
        let capacity = AVAudioFrameCount(ceil(Double(Self.samplesPerFrame) * converter.outputFormat.sampleRate / networkFormat.sampleRate)) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { reportPlaybackFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 34)); return }
        var supplied = false, error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, status in if supplied { status.pointee = .noDataNow; return nil }; supplied = true; status.pointee = .haveData; return source }
        guard status != .error, error == nil, converted.frameLength > 0 else { reportPlaybackFailure(error ?? NSError(domain: "WiFiSecureCall.AudioEngine", code: 35)); onFailure?(.playbackConversion); return }
        if !player.isPlaying { player.play() }
        scheduledBuffers += 1
        player.scheduleBuffer(converted, completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.playbackQueue.async {
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                if !self.firstPlaybackRenderedReported { self.firstPlaybackRenderedReported = true; self.emit("first_playback_buffer_rendered", "rendered") }
            }
        }
        if !firstPlaybackScheduledReported { firstPlaybackScheduledReported = true; emit("first_playback_buffer_scheduled", "frameLength=\(converted.frameLength)") }
    }

    private func cleanupGraph() {
        watchdog?.cancel(); watchdog = nil; captureTimer?.cancel(); captureTimer = nil
        player.stop(); if engine.isRunning { engine.stop() }
        let sink = captureSink
        captureLifecycle.remove { [engine] in guard let sink else { return }; engine.disconnectNodeInput(sink); engine.detach(sink) }
        captureSink = nil; captureRing = nil; engine.disconnectNodeOutput(player); engine.reset()
        inputConverter = nil; outputConverter = nil; networkFormat = nil; pcmRing.reset(); scheduledBuffers = 0
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in self?.onFailure?(.configurationChanged) })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in self?.emit("audio_interruption", "\(note.userInfo?[AVAudioSessionInterruptionTypeKey] ?? "unknown")") })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in self?.emit("audio_route_changed", "changed") })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in self?.onFailure?(.configurationChanged) })
        if #available(iOS 17.0, watchOS 10.0, *) { observers.append(center.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: nil) { [weak self] _ in guard let self else { return }; let muted = AVAudioApplication.shared.isInputMuted; self.emit("audio_input_mute", muted ? "system=muted" : "system=unmuted"); self.onMuteChanged?(muted) }) }
    }

    private func validate(_ format: AVAudioFormat) throws { guard format.sampleRate > 0, format.channelCount > 0 else { throw CallFailure.audioFailed } }
    private func formatDescription(_ format: AVAudioFormat) -> String { "sampleRate=\(format.sampleRate) channelCount=\(format.channelCount) commonFormat=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved)" }
    private func resetFirstFlags() { firstMicBufferReported = false; firstNetworkFrameReported = false; firstCaptureFailureReported = false; firstPlaybackScheduledReported = false; firstPlaybackRenderedReported = false; firstPlaybackFailureReported = false }
    private func reportCaptureFailure(_ error: NSError) { guard !firstCaptureFailureReported else { return }; firstCaptureFailureReported = true; emit("first_capture_conversion_failure", "failed", error: error); onFailure?(.captureConversion) }
    private func reportPlaybackFailure(_ error: NSError) { guard !firstPlaybackFailureReported else { return }; firstPlaybackFailureReported = true; emit("first_playback_failure", "failed", error: error) }
    private func emit(_ event: String, _ status: String, error: NSError? = nil) { onDiagnostic?(.init(event: event, status: status, errorDomain: error?.domain, errorCode: error?.code)) }
}
