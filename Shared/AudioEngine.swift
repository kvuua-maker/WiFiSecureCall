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

struct InputTapLifecycle {
    private(set) var isInstalled = false

    mutating func install(
        installTap: () -> Void,
        startEngine: () throws -> Void,
        removeTap: () -> Void
    ) throws {
        guard !isInstalled else { throw CallFailure.audioFailed }
        installTap()
        isInstalled = true
        do {
            try startEngine()
        } catch {
            removeTap()
            isInstalled = false
            throw error
        }
    }

    mutating func remove(_ removeTap: () -> Void) {
        guard isInstalled else { return }
        removeTap()
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
    private var tapLifecycle = InputTapLifecycle()
    private var starting = false
    private var firstMicBufferReported = false
    private var firstNetworkFrameReported = false
    private var firstPlaybackReported = false
    private var firstPlaybackFailureReported = false

    init() { engine.attach(player) }

    func setMuted(_ value: Bool) { queue.async { self.muted = value } }

    func ensureRecordPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default:
            return false
        }
    }

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        #if os(watchOS)
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        #else
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
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

            networkFormat = network
            inputConverter = captureConverter
            outputConverter = playbackConverter
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            try tapLifecycle.install(
                installTap: { [weak self] in
                    input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                        self?.capture(buffer, converter: captureConverter)
                    }
                    self?.firstMicBufferReported = false
                },
                startEngine: { [engine] in
                    engine.prepare()
                    try engine.start()
                },
                removeTap: { input.removeTap(onBus: 0) }
            )
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
            if supplied { status.pointee = .endOfStream; return nil }
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

    private func capture(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { return }
        if !firstMicBufferReported {
            firstMicBufferReported = true
            emit(
                "first_mic_buffer",
                "frameLength=\(buffer.frameLength) sampleRate=\(buffer.format.sampleRate) channelCount=\(buffer.format.channelCount)"
            )
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.networkSampleRate / buffer.format.sampleRate) + 8
        guard capacity > 0,
              let destination = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: destination, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, destination.frameLength > 0,
              let channel = destination.int16ChannelData?[0] else { return }
        var data = Data(bytes: channel, count: Int(destination.frameLength) * MemoryLayout<Int16>.size)
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

    private func cleanupGraph() {
        let input = engine.inputNode
        tapLifecycle.remove { input.removeTap(onBus: 0) }
        player.stop()
        if engine.isRunning { engine.stop() }
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
        firstPlaybackReported = false
        firstPlaybackFailureReported = false
    }

    private func reportPlaybackFailure(_ error: NSError) {
        guard !firstPlaybackFailureReported else { return }
        firstPlaybackFailureReported = true
        emit("first_playback_failure", "failed", error: error)
    }

    private func emit(_ event: String, _ status: String, error: NSError? = nil) {
        onDiagnostic?(.init(event: event, status: status, errorDomain: error?.domain, errorCode: error?.code))
    }
}
