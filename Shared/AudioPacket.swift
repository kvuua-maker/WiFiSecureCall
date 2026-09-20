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
        return AudioPacket(type: type, callID: uuid, sequence: sequence, timestampMicroseconds: timestamp, payload: Data(data.dropFirst(headerSize)))
    }
}

struct JitterBuffer: Sendable {
    private(set) var packets: [UInt64: AudioPacket] = [:]
    private(set) var nextSequence: UInt64?
    let maximumFrames: Int

    init(initialMilliseconds: Int = 60, maximumMilliseconds: Int = 120) {
        let boundedInitial = min(max(initialMilliseconds, 40), 120)
        self.maximumFrames = max(boundedInitial / 20, maximumMilliseconds / 20)
    }

    mutating func insert(_ packet: AudioPacket) {
        guard packet.type == .audio else { return }
        if nextSequence == nil { nextSequence = packet.sequence }
        packets[packet.sequence] = packet
        while packets.count > maximumFrames, let oldest = packets.keys.min() { packets.removeValue(forKey: oldest) }
    }

    mutating func pop() -> AudioPacket? {
        guard let sequence = nextSequence else { return nil }
        nextSequence = sequence &+ 1
        return packets.removeValue(forKey: sequence)
    }
}

