import Foundation

/// One RTP packet (RFC 3550) carrying a narrow-band audio payload.
struct RTPPacket: Sendable, Equatable {
    static let headerSize = 12

    let payloadType: UInt8
    let sequence: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let marker: Bool
    let payload: Data

    func encode() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(0x80) // version 2, no padding, no extension, no CSRC
        data.append((marker ? 0x80 : 0x00) | (payloadType & 0x7F))
        var sequenceBE = sequence.bigEndian
        var timestampBE = timestamp.bigEndian
        var ssrcBE = ssrc.bigEndian
        withUnsafeBytes(of: &sequenceBE) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &timestampBE) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &ssrcBE) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) -> RTPPacket? {
        guard data.count > headerSize else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] >> 6 == 2 else { return nil }
        let padding = (bytes[0] & 0x20) != 0
        let extensionPresent = (bytes[0] & 0x10) != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        let marker = (bytes[1] & 0x80) != 0
        let payloadType = bytes[1] & 0x7F

        var offset = headerSize + csrcCount * 4
        if extensionPresent {
            guard bytes.count >= offset + 4 else { return nil }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + length * 4
        }
        guard bytes.count > offset else { return nil }
        var end = bytes.count
        if padding, let pad = bytes.last {
            end -= Int(pad)
        }
        guard end > offset else { return nil }

        let sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        let ssrc = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        return RTPPacket(
            payloadType: payloadType,
            sequence: sequence,
            timestamp: timestamp,
            ssrc: ssrc,
            marker: marker,
            payload: Data(bytes[offset..<end])
        )
    }
}

/// A bounded jitter buffer that turns an ordered RTP stream into 20 ms frames.
///
/// Audio that arrives out of order, twice, or late must not turn into a stutter in
/// the earpiece. The buffer holds a short window, drops what can no longer be
/// played and conceals a missing packet with silence, which is what a listener
/// expects at this bitrate.
struct RTPJitterBuffer: Sendable {
    private var packets: [UInt16: Data] = [:]
    private var nextSequence: UInt16?
    private var started = false
    private var missingFrames = 0

    private let initialFrames: Int
    private let maximumFrames: Int
    private let lateGraceFrames: Int
    private let silence: Data

    private(set) var received = 0
    private(set) var lateDropped = 0
    private(set) var concealed = 0

    init(
        initialMilliseconds: Int = 60,
        maximumMilliseconds: Int = 200,
        lateGraceMilliseconds: Int = 20,
        silenceByte: UInt8 = 0xFF
    ) {
        initialFrames = max(1, initialMilliseconds / 20)
        maximumFrames = max(initialFrames, maximumMilliseconds / 20)
        lateGraceFrames = max(0, lateGraceMilliseconds / 20)
        silence = Data(repeating: silenceByte, count: SIPConfiguration.samplesPerFrame)
    }

    /// Adds a packet. Returns false when it was discarded as late or duplicate.
    @discardableResult
    mutating func insert(sequence: UInt16, payload: Data) -> Bool {
        if started, let nextSequence {
            // Signed 16-bit subtraction makes the comparison correct across the
            // sequence-number wrap at 65535.
            let distance = Int(Int16(bitPattern: sequence &- nextSequence))
            if distance < 0 {
                lateDropped += 1
                return false
            }
            if distance > maximumFrames * 4 {
                // A jump this large is a restarted stream, not a gap.
                reset()
            }
        }
        guard packets[sequence] == nil else {
            lateDropped += 1
            return false
        }
        packets[sequence] = payload
        received += 1
        if packets.count > maximumFrames {
            let ordered = packets.keys.sorted()
            let base = ordered[ordered.count - maximumFrames]
            packets = packets.filter { $0.key >= base }
            nextSequence = base
            started = true
            missingFrames = 0
        }
        return true
    }

    /// The next payload to play, or nil while the buffer is still filling.
    mutating func next() -> Data? {
        if !started {
            guard packets.count >= initialFrames, let lowest = packets.keys.min() else { return nil }
            started = true
            nextSequence = lowest
        }
        guard let sequence = nextSequence else { return nil }
        if let payload = packets.removeValue(forKey: sequence) {
            nextSequence = sequence &+ 1
            missingFrames = 0
            return payload
        }
        if missingFrames < lateGraceFrames {
            missingFrames += 1
            return silence
        }
        missingFrames = 0
        nextSequence = sequence &+ 1
        concealed += 1
        return silence
    }

    mutating func reset() {
        packets.removeAll(keepingCapacity: true)
        started = false
        missingFrames = 0
        nextSequence = nil
    }
}
