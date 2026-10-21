import AVFoundation
import Foundation

/// Narrow-band audio for a SIP call.
///
/// The existing in-app call engine runs at 16 kHz because the server transport
/// carries 640-byte frames. G.711 is an 8 kHz codec, so this engine is separate on
/// purpose: resampling 16 kHz to 8 kHz inside the call path would add a converter
/// on both directions and a second source of drift for no benefit.
final class SIPAudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.sip.audio", qos: .userInteractive)

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var frameBuffer = Data()
    private var running = false
    private var muted = false
    private var playoutTimer: DispatchSourceTimer?
    private let playoutQueue = DispatchQueue(label: "com.vkapps.wifisecurecall.sip.playout", qos: .userInteractive)
    private let jitterLock = NSLock()
    private var pendingFrames: [Data] = []

    /// The codec the far end negotiated. Set before the first frame is captured.
    var codec: SIPCodec = .pcmu
    /// Called with one 20 ms G.711 frame every 20 ms.
    var onEncodedFrame: (@Sendable (Data) -> Void)?
    /// Called when the microphone produces a frame, for level meters and tests.
    var onCapturedPCM: (@Sendable (Data) -> Void)?
    var onDiagnostic: (@Sendable (String) -> Void)?

    var isRunning: Bool { queue.sync { running } }

    // MARK: - Session

    static func requestRecordPermission() async -> Bool {
        if #available(iOS 17.0, watchOS 10.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied: return false
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
                }
            @unknown default: return false
            }
        }
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        #if os(watchOS)
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        #else
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        #endif
        try session.setActive(true)
    }

    func start() throws {
        try queue.sync {
            guard !running else { return }
            engine.attach(player)
            let input = engine.inputNode
            let hardware = input.inputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw SIPAudioError.unsupportedInput }
            inputFormat = hardware

            guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(SIPConfiguration.sampleRate), channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: hardware, to: target) else {
                throw SIPAudioError.unsupportedInput
            }
            self.converter = converter
            try connectPlayer(target: target)

            let bufferSize = AVAudioFrameCount(hardware.sampleRate * SIPConfiguration.frameDuration)
            input.installTap(onBus: 0, bufferSize: max(bufferSize, 160), format: hardware) { [weak self] buffer, _ in
                self?.handleInput(buffer, target: target)
            }
            engine.prepare()
            try engine.start()
            player.play()
            running = true
            startPlayout()
            onDiagnostic?("audio_started hardware_rate=\(Int(hardware.sampleRate)) channels=\(hardware.channelCount)")
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            playoutTimer?.setEventHandler {}
            playoutTimer?.cancel()
            playoutTimer = nil
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            engine.detach(player)
            frameBuffer.removeAll(keepingCapacity: false)
            converter = nil
            inputFormat = nil
            jitterLock.lock()
            pendingFrames.removeAll(keepingCapacity: false)
            jitterLock.unlock()
            onDiagnostic?("audio_stopped")
        }
    }

    func setMuted(_ value: Bool) {
        queue.sync { muted = value }
    }

    /// Queues an encoded frame received from the network. Frames are decoded and
    /// played in order by the 20 ms playout timer.
    func enqueueEncodedFrame(_ payload: Data, codec: SIPCodec) {
        let pcm = codec.decode(payload)
        jitterLock.lock()
        pendingFrames.append(pcm)
        if pendingFrames.count > 10 { pendingFrames.removeFirst(pendingFrames.count - 10) }
        jitterLock.unlock()
    }

    // MARK: - Capture

    private func handleInput(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard running, let converter else { return }
        if muted {
            emitSilence()
            return
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var delivered = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return }
        guard converted.frameLength > 0, let channel = converted.int16ChannelData?[0] else { return }
        let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
        frameBuffer.append(Data(bytes: channel, count: byteCount))
        let frameBytes = SIPConfiguration.samplesPerFrame * MemoryLayout<Int16>.size
        while frameBuffer.count >= frameBytes {
            let frame = Data(frameBuffer.prefix(frameBytes))
            frameBuffer.removeFirst(frameBytes)
            onCapturedPCM?(frame)
            onEncodedFrame?(codec.encode(frame))
        }
    }

    private func emitSilence() {
        frameBuffer.removeAll(keepingCapacity: true)
        onEncodedFrame?(codec.encode(Data(count: SIPConfiguration.samplesPerFrame * MemoryLayout<Int16>.size)))
    }

    // MARK: - Playback

    private func connectPlayer(target: AVAudioFormat) throws {
        engine.connect(player, to: engine.mainMixerNode, format: target)
    }

    private func startPlayout() {
        playoutTimer?.setEventHandler {}
        playoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: playoutQueue)
        timer.schedule(deadline: .now() + SIPConfiguration.frameDuration, repeating: SIPConfiguration.frameDuration, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.playNextFrame() }
        playoutTimer = timer
        timer.resume()
    }

    private func playNextFrame() {
        jitterLock.lock()
        let frame = pendingFrames.isEmpty ? nil : pendingFrames.removeFirst()
        jitterLock.unlock()
        guard let frame else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(SIPConfiguration.sampleRate), channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(SIPConfiguration.samplesPerFrame)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(SIPConfiguration.samplesPerFrame)
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let destination = buffer.int16ChannelData?[0] else { return }
            destination.update(from: base.assumingMemoryBound(to: Int16.self), count: SIPConfiguration.samplesPerFrame)
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}

enum SIPAudioError: Error, Equatable {
    case unsupportedInput
    case engineFailed(String)
}
