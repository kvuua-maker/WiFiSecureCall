import AVFoundation
import Foundation

final class AudioEngine: @unchecked Sendable {
    static let networkSampleRate: Double = 16_000
    static let samplesPerFrame: AVAudioFrameCount = 320
    static let bytesPerFrame = 640

    var onFrame: (@Sendable (Data) -> Void)?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.audio", qos: .userInteractive)
    private var muted = false
    private var pendingInput = Data()
    private var inputConverter: AVAudioConverter?
    private var outputConverter: AVAudioConverter?
    private var networkFormat: AVAudioFormat?

    init() { engine.attach(player) }

    func setMuted(_ value: Bool) { queue.async { self.muted = value } }

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        #if os(watchOS)
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        #else
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        #endif
    }

    func start() throws {
        guard !engine.isRunning else { return }
        guard let network = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.networkSampleRate, channels: 1, interleaved: true) else { throw CallFailure.audioFailed }
        networkFormat = network
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        inputConverter = AVAudioConverter(from: inputFormat, to: network)
        outputConverter = AVAudioConverter(from: network, to: outputFormat)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        do { try input.setVoiceProcessingEnabled(true) } catch { }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in self?.capture(buffer) }
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop(); engine.stop(); pendingInput.removeAll(keepingCapacity: false)
    }

    func play(_ payload: Data) {
        guard payload.count == Self.bytesPerFrame, let networkFormat, let outputConverter,
              let source = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: Self.samplesPerFrame) else { return }
        source.frameLength = Self.samplesPerFrame
        payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, let channel = source.int16ChannelData?[0] else { return }
            memcpy(channel, base, payload.count)
        }
        let ratio = outputConverter.outputFormat.sampleRate / networkFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(Self.samplesPerFrame) * ratio)) + 8
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputConverter.outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        outputConverter.convert(to: converted, error: &conversionError) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return source
        }
        if conversionError == nil { player.scheduleBuffer(converted) }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter = inputConverter,
              let destination = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * Self.networkSampleRate / buffer.format.sampleRate) + 8) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: destination, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let channel = destination.int16ChannelData?[0] else { return }
        var data = Data(bytes: channel, count: Int(destination.frameLength) * MemoryLayout<Int16>.size)
        queue.async { [weak self] in
            guard let self else { return }
            if self.muted { data.resetBytes(in: 0..<data.count) }
            self.pendingInput.append(data)
            while self.pendingInput.count >= Self.bytesPerFrame {
                let frame = self.pendingInput.prefix(Self.bytesPerFrame)
                self.pendingInput.removeFirst(Self.bytesPerFrame)
                self.onFrame?(Data(frame))
            }
        }
    }
}
