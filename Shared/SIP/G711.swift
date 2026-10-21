import Foundation

/// The narrow-band codecs a watch can encode without a media framework.
///
/// G.711 is uncompressed 64 kbit/s audio: a table lookup per sample, no licence,
/// and every SIP provider supports it. That is the right first codec for a
/// device that has to keep the radio and the CPU idle enough to last a call.
enum SIPCodec: UInt8, Sendable, CaseIterable, Equatable {
    case pcmu = 0
    case pcma = 8

    var name: String {
        switch self {
        case .pcmu: return "PCMU"
        case .pcma: return "PCMA"
        }
    }

    var clockRate: Int { 8_000 }

    /// Encodes 160 linear 16-bit samples (320 bytes) into 160 bytes.
    func encode(_ pcm: Data) -> Data {
        var output = Data(capacity: pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                switch self {
                case .pcmu: output.append(Self.linearToMuLaw(sample))
                case .pcma: output.append(Self.linearToALaw(sample))
                }
            }
        }
        return output
    }

    /// Decodes 160 compressed bytes into 320 bytes of linear 16-bit samples.
    func decode(_ payload: Data) -> Data {
        var output = Data(capacity: payload.count * 2)
        for byte in payload {
            let sample: Int16
            switch self {
            case .pcmu: sample = Self.muLawToLinear(byte)
            case .pcma: sample = Self.aLawToLinear(byte)
            }
            withUnsafeBytes(of: sample.littleEndian) { output.append(contentsOf: $0) }
        }
        return output
    }

    // MARK: - G.711 tables

    /// ITU-T G.711 µ-law, computed rather than tabulated so the code stays short.
    static func linearToMuLaw(_ sample: Int16) -> UInt8 {
        let sign: Int16 = sample < 0 ? 0x80 : 0
        let magnitude = min(abs(Int(sample)), 32635) + 0x84
        var exponent = 7
        var mask = 0x4000
        while exponent > 0, magnitude & mask == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (magnitude >> (exponent + 3)) & 0x0F
        return UInt8((sign | Int16(exponent << 4) | Int16(mantissa)) ^ 0xFF)
    }

    static func muLawToLinear(_ byte: UInt8) -> Int16 {
        let value = ~Int(byte) & 0xFF
        let sign = value & 0x80
        let exponent = (value >> 4) & 0x07
        let mantissa = value & 0x0F
        var sample = ((mantissa << 3) + 0x84) << exponent
        sample -= 0x84
        return Int16(sign != 0 ? -sample : sample)
    }

    /// ITU-T G.711 A-law.
    static func linearToALaw(_ sample: Int16) -> UInt8 {
        var value = Int(sample)
        var sign = 0x00
        if value < 0 {
            sign = 0x80
            value = -value
        }
        if value > 32635 { value = 32635 }
        if value >= 256 {
            var exponent = 7
            var mask = 0x4000
            while exponent > 0, value & mask == 0 {
                exponent -= 1
                mask >>= 1
            }
            let mantissa = (value >> (exponent + 3)) & 0x0F
            return UInt8(sign | (exponent << 4) | mantissa)
        }
        return UInt8(sign | (value >> 4))
    }

    static func aLawToLinear(_ byte: UInt8) -> Int16 {
        let value = Int(byte) ^ 0x55
        let sign = value & 0x80
        let exponent = (value >> 4) & 0x07
        let mantissa = value & 0x0F
        var sample: Int
        if exponent == 0 {
            sample = (mantissa << 4) + 8
        } else {
            sample = ((mantissa << 4) + 0x108) << (exponent - 1)
        }
        return Int16(sign != 0 ? -sample : sample)
    }
}
