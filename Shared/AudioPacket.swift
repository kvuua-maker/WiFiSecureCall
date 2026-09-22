import Foundation

enum AudioPacketType: UInt8, Sendable { case audio = 1, end = 2, ping = 3 }

struct AudioPacket: Equatable, Sendable {
    static let version: UInt8 = 1
    static let headerSize = 34
    let type: AudioPacketType
    let callID: UUID
    let sequence: UInt64
    let timestampMicroseconds: UInt64
    let payload: Data

    func encode() -> Data {
        var data = Data([Self.version, type.rawValue])
        var uuid = callID.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        var sequenceBE = sequence.bigEndian
        var timestampBE = timestampMicroseconds.bigEndian
        withUnsafeBytes(of: &sequenceBE) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &timestampBE) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) -> AudioPacket? {
        guard data.count >= headerSize, data[0] == version, let type = AudioPacketType(rawValue: data[1]) else { return nil }
        let uuidBytes = [UInt8](data[2..<18])
        let uuid = UUID(uuid: (uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3], uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7], uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11], uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
        let sequence = data[18..<26].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let timestamp = data[26..<34].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let payload = Data(data.dropFirst(headerSize))
        switch type {
        case .audio: guard payload.count == AudioEngine.bytesPerFrame else { return nil }
        case .end, .ping: guard payload.isEmpty else { return nil }
        }
        return AudioPacket(type: type, callID: uuid, sequence: sequence, timestampMicroseconds: timestamp, payload: payload)
    }
}

struct JitterBufferStats: Equatable, Sendable {
    var inserted = 0
    var reordered = 0
    var duplicateDropped = 0
    var lateDropped = 0
    var missingConcealed = 0
    var rebased = 0
    var currentDepth = 0
    var maximumDepth = 0
}

enum JitterPlayout: Equatable, Sendable {
    case buffering
    case frame(Data)
    case lateGrace(Data)
    case concealed(Data)
}

struct JitterBuffer: Sendable {
    private(set) var packets: [UInt64: AudioPacket] = [:]
    private(set) var nextSequence: UInt64?
    private(set) var stats = JitterBufferStats()
    let maximumFrames: Int
    private let initialFrames: Int
    private let lateGraceTicks: Int
    private var started = false
    private var missingTicks = 0
    private var highestSequence: UInt64?

    init(initialMilliseconds: Int = 100, maximumMilliseconds: Int = 240, lateGraceMilliseconds: Int = 20) {
        let boundedInitial = min(max(initialMilliseconds, 40), 120)
        self.initialFrames = max(2, boundedInitial / 20)
        self.maximumFrames = max(initialFrames, min(maximumMilliseconds, 240) / 20)
        self.lateGraceTicks = max(0, min(2, lateGraceMilliseconds / 20))
    }

    mutating func insert(_ packet: AudioPacket) {
        guard packet.type == .audio, packet.payload.count == AudioEngine.bytesPerFrame else { return }
        if started, let nextSequence, packet.sequence < nextSequence {
            stats.lateDropped += 1
            return
        }
        if packets[packet.sequence] != nil {
            stats.duplicateDropped += 1
            return
        }
        if let nextSequence, started, packet.sequence > nextSequence &+ UInt64(maximumFrames * 4) {
            packets.removeAll(keepingCapacity: true)
            self.nextSequence = packet.sequence
            started = false
            missingTicks = 0
            highestSequence = nil
            stats.rebased += 1
        }
        if let highestSequence, packet.sequence < highestSequence { stats.reordered += 1 }
        highestSequence = max(highestSequence ?? packet.sequence, packet.sequence)
        packets[packet.sequence] = packet
        stats.inserted += 1
        if !started { nextSequence = min(nextSequence ?? packet.sequence, packet.sequence) }
        if packets.count > maximumFrames {
            let newBase = packets.keys.sorted().suffix(maximumFrames).first
            if let newBase {
                packets = packets.filter { $0.key >= newBase }
                nextSequence = newBase
                started = true
                missingTicks = 0
                stats.rebased += 1
            }
        }
        updateDepth()
    }

    mutating func nextPlayout() -> JitterPlayout {
        guard started || packets.count >= initialFrames else { updateDepth(); return .buffering }
        if !started {
            started = true
            nextSequence = packets.keys.min()
        }
        guard let sequence = nextSequence else { updateDepth(); return .buffering }
        if let packet = packets.removeValue(forKey: sequence) {
            nextSequence = sequence &+ 1
            missingTicks = 0
            updateDepth()
            return .frame(packet.payload)
        }
        if missingTicks < lateGraceTicks {
            missingTicks += 1
            updateDepth()
            return .lateGrace(Self.silence)
        }
        missingTicks = 0
        nextSequence = sequence &+ 1
        stats.missingConcealed += 1
        updateDepth()
        return .concealed(Self.silence)
    }

    mutating func nextPayload() -> Data? {
        switch nextPlayout() {
        case .buffering: return nil
        case let .frame(data), let .lateGrace(data), let .concealed(data): return data
        }
    }

    mutating func resetForReconnect() {
        packets.removeAll(keepingCapacity: true)
        nextSequence = nil
        started = false
        missingTicks = 0
        highestSequence = nil
        stats.currentDepth = 0
    }

    private mutating func updateDepth() {
        stats.currentDepth = packets.count
        stats.maximumDepth = max(stats.maximumDepth, packets.count)
    }

    private static let silence = Data(repeating: 0, count: AudioEngine.bytesPerFrame)
}

struct AudioPlayoutDiagnostic: Sendable {
    let event: String
    let status: String
}

final class AudioPlayoutController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.audio.playout", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var jitter = JitterBuffer()
    private var onFrame: (@Sendable (Data) -> Void)?
    private var onDiagnostic: (@Sendable (AudioPlayoutDiagnostic) -> Void)?
    private var emitted = Set<String>()
    private var previousStats = JitterBufferStats()

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }

    func start(
        onFrame: @escaping @Sendable (Data) -> Void,
        onDiagnostic: @escaping @Sendable (AudioPlayoutDiagnostic) -> Void
    ) {
        queue.sync {
            stopLocked()
            jitter = JitterBuffer()
            previousStats = jitter.stats
            emitted.removeAll(keepingCapacity: true)
            self.onFrame = onFrame
            self.onDiagnostic = onDiagnostic
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            emitOnce("audio_playout_started", "interval_ms=20 initial_ms=100 maximum_ms=240")
            timer.resume()
        }
    }

    func insert(_ packet: AudioPacket) {
        queue.async { [weak self] in
            guard let self else { return }
            self.jitter.insert(packet)
            self.reportCounterChanges()
        }
    }

    func stop() { queue.sync { stopLocked() } }

    private func tick() {
        switch jitter.nextPlayout() {
        case .buffering:
            break
        case let .frame(payload):
            onFrame?(payload)
        case let .lateGrace(payload):
            emitOnce("audio_playout_underrun", "late_arrival_grace")
            onFrame?(payload)
        case let .concealed(payload):
            emitOnce("audio_playout_missing_concealed", "silence_frame")
            onFrame?(payload)
        }
        reportCounterChanges()
    }

    private func reportCounterChanges() {
        if jitter.stats.lateDropped > previousStats.lateDropped { emitOnce("audio_playout_late_drop", "count=\(jitter.stats.lateDropped)") }
        if jitter.stats.rebased > previousStats.rebased { emitOnce("audio_playout_rebase", "count=\(jitter.stats.rebased)") }
        if jitter.stats.maximumDepth > previousStats.maximumDepth {
            onDiagnostic?(.init(event: "audio_playout_depth", status: "current=\(jitter.stats.currentDepth) peak=\(jitter.stats.maximumDepth)"))
        }
        previousStats = jitter.stats
    }

    private func emitOnce(_ event: String, _ status: String) {
        guard emitted.insert(event).inserted else { return }
        onDiagnostic?(.init(event: event, status: status))
    }

    private func stopLocked() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        onFrame = nil
        onDiagnostic = nil
        jitter.resetForReconnect()
    }
}
