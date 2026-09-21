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

struct JitterBuffer: Sendable {
    private(set) var packets: [UInt64: AudioPacket] = [:]
    private(set) var nextSequence: UInt64?
    let maximumFrames: Int
    private let initialFrames: Int
    private var started = false
    private var consecutiveMisses = 0

    init(initialMilliseconds: Int = 60, maximumMilliseconds: Int = 120) {
        let boundedInitial = min(max(initialMilliseconds, 40), 120)
        self.initialFrames = max(2, boundedInitial / 20)
        self.maximumFrames = max(initialFrames, maximumMilliseconds / 20)
    }

    mutating func insert(_ packet: AudioPacket) {
        guard packet.type == .audio else { return }
        if nextSequence == nil { nextSequence = packet.sequence }
        if let nextSequence, packet.sequence &+ UInt64(maximumFrames * 4) < nextSequence { return }
        packets[packet.sequence] = packet
        while packets.count > maximumFrames, let oldest = packets.keys.min() { packets.removeValue(forKey: oldest) }
    }

    mutating func nextPayload() -> Data? {
        guard started || packets.count >= initialFrames else { return nil }
        started = true
        guard let sequence = nextSequence else { return nil }
        if let packet = packets.removeValue(forKey: sequence) {
            nextSequence = sequence &+ 1; consecutiveMisses = 0; return packet.payload
        }
        consecutiveMisses += 1
        if consecutiveMisses >= maximumFrames, let lowest = packets.keys.min() { nextSequence = lowest; consecutiveMisses = 0 }
        else { nextSequence = sequence &+ 1 }
        return Data(repeating: 0, count: AudioEngine.bytesPerFrame)
    }

    mutating func resetForReconnect() { packets.removeAll(keepingCapacity: true); nextSequence = nil; started = false; consecutiveMisses = 0 }
}
