import Foundation

/// The audio parameters a call negotiated.
struct SIPMediaDescription: Sendable, Equatable {
    var address: String
    var port: Int
    var codec: SIPCodec
    var payloadType: UInt8
    var sessionID: UInt64
    var version: UInt64

    var isUsable: Bool { port > 0 && !address.isEmpty }
}

/// Builds and reads the SDP bodies this client exchanges.
///
/// Only the audio stream is modelled. Everything the provider sends beyond that
/// is ignored rather than rejected, because an offer that also advertises video
/// is still a perfectly good audio call.
enum SDP {
    /// The offer or answer this client sends.
    ///
    /// The connection address is the one the phone should send RTP to, which on a
    /// watch is the address of the interface the socket bound to. `options` carries
    /// the codecs in preference order and the local RTP port.
    static func make(
        address: String,
        port: Int,
        codecs: [SIPCodec],
        sessionID: UInt64,
        telephoneEventPayload: UInt8 = 101
    ) -> Data {
        var lines: [String] = [
            "v=0",
            "o=- \(sessionID) 1 IN IP4 \(address)",
            "s=WiFi Secure Call",
            "c=IN IP4 \(address)",
            "t=0 0",
            "m=audio \(port) RTP/AVP " + codecs.map { String($0.rawValue) }.joined(separator: " ") + " \(telephoneEventPayload)",
            "a=rtpmap:\(telephoneEventPayload) telephone-event/8000",
            "a=fmtp:\(telephoneEventPayload) 0-16",
            "a=ptime:20",
            "a=sendrecv"
        ]
        for codec in codecs {
            lines.append("a=rtpmap:\(codec.rawValue) \(codec.name)/8000")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Reads the audio stream out of an SDP body.
    ///
    /// Returns nil when the body carries no audio stream, or when the audio port
    /// is zero, which is how a peer puts a stream on hold.
    static func parse(_ data: Data) -> SIPMediaDescription? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var sessionAddress: String?
        var audioAddress: String?
        var port = 0
        var payloads: [UInt8] = []
        var inAudio = false
        var sessionID: UInt64 = 0
        var version: UInt64 = 1

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("o=") {
                let fields = line.dropFirst(2).split(separator: " ")
                if fields.count >= 3 {
                    sessionID = UInt64(fields[1]) ?? 0
                    version = UInt64(fields[2]) ?? 1
                }
            } else if line.hasPrefix("m=") {
                let fields = line.dropFirst(2).split(separator: " ")
                inAudio = fields.first?.lowercased() == "audio"
                if inAudio, fields.count >= 4 {
                    port = Int(fields[1].split(separator: "/").first ?? "0") ?? 0
                    payloads = fields.dropFirst(3).compactMap { UInt8($0) }
                }
            } else if line.hasPrefix("c=") {
                let fields = line.dropFirst(2).split(separator: " ")
                guard fields.count >= 3 else { continue }
                var address = String(fields[2])
                if let slash = address.firstIndex(of: "/") {
                    address = String(address[address.startIndex..<slash])
                }
                if inAudio {
                    audioAddress = address
                } else {
                    sessionAddress = address
                }
            }
        }

        guard let address = audioAddress ?? sessionAddress, port > 0 else { return nil }
        let codec = payloads.compactMap(SIPCodec.init(rawValue:)).first ?? .pcmu
        return SIPMediaDescription(
            address: address,
            port: port,
            codec: codec,
            payloadType: codec.rawValue,
            sessionID: sessionID,
            version: version
        )
    }
}
