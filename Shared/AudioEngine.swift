import AVFoundation
import Foundation

struct AudioEngineDiagnostic: Sendable {
    let event: String
    let status: String
    let errorDomain: String?
    let errorCode: Int?
}

protocol AudioEngineHandling: AnyObject {
    var onFrame: (@Sendable (Data) -> Void)? { get set }
    var onDiagnostic: (@Sendable (AudioEngineDiagnostic) -> Void)? { get set }
    func ensureRecordPermission() async -> Bool
    func configureSession() throws
    func start() throws
    func stop()
    func setMuted(_ value: Bool)
    func play(_ payload: Data)
}

struct CaptureSourceLifecycle {
    private(set) var isInstalled = false

    mutating func install(
        installSource: () -> Void,
        startEngine: () throws -> Void,
        removeSource: () -> Void
    ) throws {
        guard !isInstalled else { throw CallFailure.audioFailed }
        installSource()
        isInstalled = true
        do {
            try startEngine()
        } catch {
            removeSource()
            isInstalled = false
            throw error
        }
    }

    mutating func remove(_ removeSource: () -> Void) {
        guard isInstalled else { return }
        removeSource()
        isInstalled = false
    }
}

final class AudioEngine: AudioEngineHandling, @unchecked Sendable {
    static let networkSampleRate: Double = 16_000
    static let samplesPerFrame: AVAudioFrameCount = 320
    static let bytesPerFrame = 640

    var onFrame: (@Sendable (Data) -> Void)?
    var onDiagnostic: (@Sendable (AudioEngineDiagnostic) -> Void)?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.audio", qos: .userInteractive)
    private var muted = false
    private var pendingInput = Data()
    private var inputConverter: AVAudioConverter?
    private var outputConverter: AVAudioConverter?
    private var networkFormat: AVAudioFormat?
    private var captureSink: AVAudioSinkNode?
    private var captureLifecycle = CaptureSourceLifecycle()
    private var starting = false
    private var firstMicBufferReported = false
    private var firstNetworkFrameReported = false
    private var firstCaptureFailureReported = false
    private var firstPlaybackReported = false
    private var firstPlaybackFailureReported = false

    init() { engine.attach(player) }

    func setMuted(_ value: Bool) { queue.async { self.muted = value } }

    func ensureRecordPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            emit("microphone_permission", "granted")
            return true
        case .denied:
            emit("microphone_permission", "denied")
            return false
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
            emit("microphone_permission", granted ? "requested_granted" : "requested_denied")
            return granted
        @unknown default:
            emit("microphone_permission", "unknown")
            return false
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

    func start() throws {
        guard !engine.isRunning else { throw CallFailure.audioFailed }
        guard !starting else { throw CallFailure.audioFailed }
        starting = true
        emit("audio_engine_start_attempt", "started")
        do {
            cleanupGraph()
            resetFirstEventFlags()

            let input = engine.inputNode
            do {
                try input.setVoiceProcessingEnabled(true)
                emit("voice_processing_enabled", "YES")
            } catch {
                let value = error as NSError
                emit("voice_processing_enabled", "NO", error: value)
            }

            let inputFormat = input.outputFormat(forBus: 0)
            let outputFormat = engine.outputNode.inputFormat(forBus: 0)
            try validate(inputFormat)
            try validate(outputFormat)
            emit("input_format", formatDescription(inputFormat))
            emit("output_format", formatDescription(outputFormat))

            guard let network = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.networkSampleRate,
                channels: 1,
                interleaved: true
            ),
            let captureConverter = AVAudioConverter(from: inputFormat, to: network),
            let playbackConverter = AVAudioConverter(from: network, to: outputFormat)
            else { throw CallFailure.audioFailed }

            captureConverter.primeMethod = .none
            playbackConverter.primeMethod = .none

            networkFormat = network
            inputConverter = captureConverter
            outputConverter = playbackConverter
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            player.volume = 1
            engine.mainMixerNode.outputVolume = 1

            let sink = AVAudioSinkNode { [weak self] _, frameCount, inputData in
                self?.capture(frameCount: frameCount, inputData: inputData, format: inputFormat, converter: captureConverter)
                return noErr
            }
            captureSink = sink
            do {
                try captureLifecycle.install(
                    installSource: { [engine] in
                        engine.attach(sink)
                        engine.connect(input, to: sink, format: inputFormat)
                    },
                    startEngine: { [engine] in
                        engine.prepare()
                        try engine.start()
                    },
                    removeSource: { [engine] in
                        engine.disconnectNodeInput(sink)
                        engine.detach(sink)
                    }
                )
            } catch {
                captureSink = nil
                throw error
            }
            emit("capture_source_connected", "av_audio_sink_node")
            player.play()
            starting = false
            emit("audio_engine_start_success", "success")
        } catch {
            cleanupGraph()
            starting = false
            let value = error as NSError
            emit("audio_engine_start_failure", "failed", error: value)
            throw CallFailure.audioFailed
        }
    }

    func stop() {
        cleanupGraph()
    }

    func play(_ payload: Data) {
        guard payload.count == Self.bytesPerFrame, engine.isRunning, let networkFormat, let outputConverter,
              let source = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: Self.samplesPerFrame)
        else {
            reportPlaybackFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 1))
            return
        }
        source.frameLength = Self.samplesPerFrame
        var copied = false
        payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, let channel = source.int16ChannelData?[0] else { return }
            memcpy(channel, base, payload.count)
            copied = true
        }
        guard copied else {
            reportPlaybackFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 2))
            return
        }
        let ratio = outputConverter.outputFormat.sampleRate / networkFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(Self.samplesPerFrame) * ratio)) + 8
        guard capacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: outputConverter.outputFormat, frameCapacity: capacity)
        else {
            reportPlaybackFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 3))
            return
        }
        var supplied = false
        var conversionError: NSError?
        let status = outputConverter.convert(to: converted, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return source
        }
        guard status != .error, conversionError == nil, converted.frameLength > 0 else {
            reportPlaybackFailure(conversionError ?? NSError(domain: "WiFiSecureCall.AudioEngine", code: 4))
            return
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(converted)
        if !firstPlaybackReported {
            firstPlaybackReported = true
            emit("first_playback_buffer_scheduled", "frameLength=\(converted.frameLength)")
        }
    }

    private func capture(
        frameCount: AVAudioFrameCount,
        inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        converter: AVAudioConverter
    ) {
        guard frameCount > 0,
              let buffer = Self.copyInput(frameCount: frameCount, inputData: inputData, format: format)
        else {
            reportCaptureFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 10))
            return
        }
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else {
            reportCaptureFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 11))
            return
        }
        if !firstMicBufferReported {
            firstMicBufferReported = true
            emit(
                "first_mic_buffer",
                "frameLength=\(buffer.frameLength) sampleRate=\(buffer.format.sampleRate) channelCount=\(buffer.format.channelCount)"
            )
        }
        guard var data = Self.convertToNetworkPCM(buffer, converter: converter) else {
            reportCaptureFailure(NSError(domain: "WiFiSecureCall.AudioEngine", code: 12))
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            if self.muted { data.resetBytes(in: 0..<data.count) }
            self.pendingInput.append(data)
            while self.pendingInput.count >= Self.bytesPerFrame {
                let frame = self.pendingInput.prefix(Self.bytesPerFrame)
                self.pendingInput.removeFirst(Self.bytesPerFrame)
                if !self.firstNetworkFrameReported {
                    self.firstNetworkFrameReported = true
                    self.emit("first_network_audio_frame_generated", "bytes=\(Self.bytesPerFrame)")
                }
                self.onFrame?(Data(frame))
            }
        }
    }

    static func convertToNetworkPCM(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> Data? {
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * networkSampleRate / buffer.format.sampleRate) + 8
        guard capacity > 0,
              let destination = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: destination, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, destination.frameLength > 0,
              let channel = destination.int16ChannelData?[0]
        else { return nil }
        return Data(bytes: channel, count: Int(destination.frameLength) * MemoryLayout<Int16>.size)
    }

    private static func copyInput(
        frameCount: AVAudioFrameCount,
        inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let sourceData = source[index].mData, let destinationData = destination[index].mData else { return nil }
            let byteCount = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            guard byteCount > 0 else { return nil }
            memcpy(destinationData, sourceData, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
        }
        return buffer
    }

    private func cleanupGraph() {
        player.stop()
        if engine.isRunning { engine.stop() }
        let sink = captureSink
        captureLifecycle.remove { [engine] in
            guard let sink else { return }
            engine.disconnectNodeInput(sink)
            engine.detach(sink)
        }
        captureSink = nil
        engine.disconnectNodeOutput(player)
        engine.reset()
        inputConverter = nil
        outputConverter = nil
        networkFormat = nil
        queue.sync {
            pendingInput.removeAll(keepingCapacity: false)
            muted = false
        }
    }

    private func validate(_ format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CallFailure.audioFailed }
    }

    private func formatDescription(_ format: AVAudioFormat) -> String {
        "sampleRate=\(format.sampleRate) channelCount=\(format.channelCount) commonFormat=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved)"
    }

    private func resetFirstEventFlags() {
        firstMicBufferReported = false
        firstNetworkFrameReported = false
        firstCaptureFailureReported = false
        firstPlaybackReported = false
        firstPlaybackFailureReported = false
    }

    private func reportPlaybackFailure(_ error: NSError) {
        guard !firstPlaybackFailureReported else { return }
        firstPlaybackFailureReported = true
        emit("first_playback_failure", "failed", error: error)
    }

    private func reportCaptureFailure(_ error: NSError) {
        guard !firstCaptureFailureReported else { return }
        firstCaptureFailureReported = true
        emit("first_capture_conversion_failure", "failed", error: error)
    }

    private func emit(_ event: String, _ status: String, error: NSError? = nil) {
        onDiagnostic?(.init(event: event, status: status, errorDomain: error?.domain, errorCode: error?.code))
    }
}
