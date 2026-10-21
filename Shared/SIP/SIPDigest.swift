import CryptoKit
import Foundation

/// A `WWW-Authenticate` or `Proxy-Authenticate` challenge.
struct SIPDigestChallenge: Sendable, Equatable {
    let realm: String
    let nonce: String
    let opaque: String?
    let algorithm: String
    let qualityOfProtection: [String]

    /// Parses the challenge value. Only quoted and bare parameter values occur in
    /// practice, so the parser accepts both and ignores anything it cannot read.
    static func parse(_ value: String) -> SIPDigestChallenge? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("digest") else { return nil }
        let parameters = parseParameters(String(trimmed.dropFirst("digest".count)))
        guard let realm = parameters["realm"], let nonce = parameters["nonce"] else { return nil }
        let qop = (parameters["qop"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return SIPDigestChallenge(
            realm: realm,
            nonce: nonce,
            opaque: parameters["opaque"],
            algorithm: (parameters["algorithm"] ?? "MD5").uppercased(),
            qualityOfProtection: qop
        )
    }

    /// The qop this client answers with, or nil for the older RFC 2069 scheme.
    var selectedQualityOfProtection: String? {
        if qualityOfProtection.contains("auth") { return "auth" }
        return nil
    }
}

/// Computes the Authorization header for a challenge (RFC 7616).
///
/// MD5 is still what SIP deployments negotiate, so it is used when asked for;
/// SHA-256 is supported for providers that offer it. The digest never leaves the
/// device except as the response hash.
enum SIPDigest {
    static func authorization(
        username: String,
        password: String,
        method: SIPMethod,
        uri: String,
        challenge: SIPDigestChallenge,
        nonceCount: UInt32
    ) -> String {
        let cnonce = randomCnonce()
        let nc = String(format: "%08x", nonceCount)
        let qop = challenge.selectedQualityOfProtection

        let algorithm = challenge.algorithm
        let useSession = algorithm.hasSuffix("-SESS")
        let hash = hasher(for: algorithm)

        var ha1 = hash("\(username):\(challenge.realm):\(password)")
        if useSession {
            ha1 = hash("\(ha1):\(challenge.nonce):\(cnonce)")
        }
        let ha2 = hash("\(method.rawValue):\(uri)")

        let response: String
        if let qop {
            response = hash("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\(qop):\(ha2)")
        } else {
            response = hash("\(ha1):\(challenge.nonce):\(ha2)")
        }
        var fields = [
            "username=\"\(escape(username))\"",
            "realm=\"\(escape(challenge.realm))\"",
            "nonce=\"\(escape(challenge.nonce))\"",
            "uri=\"\(escape(uri))\"",
            "response=\"\(response)\"",
            "algorithm=\(algorithm)"
        ]
        if let opaque = challenge.opaque {
            fields.append("opaque=\"\(escape(opaque))\"")
        }
        if let qop {
            fields.append("qop=\(qop)")
            fields.append("nc=\(nc)")
            fields.append("cnonce=\"\(cnonce)\"")
        }
        return "Digest " + fields.joined(separator: ", ")
    }

    /// The header value a client echoes back for a 401 or 407.
    static func headerName(for statusCode: Int) -> String {
        statusCode == 407 ? "Proxy-Authorization" : "Authorization"
    }

    /// The challenge header a 401 or 407 carries.
    static func challengeHeaderName(for statusCode: Int) -> String {
        statusCode == 407 ? "Proxy-Authenticate" : "WWW-Authenticate"
    }

    private static func hasher(for algorithm: String) -> (String) -> String {
        if algorithm.hasPrefix("SHA-256") {
            return { input in
                Data(SHA256.hash(data: Data(input.utf8))).map { String(format: "%02x", $0) }.joined()
            }
        }
        return { input in
            Data(Insecure.MD5.hash(data: Data(input.utf8))).map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func randomCnonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<8).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Splits `k=v, k="v"` into a dictionary. Shared by the challenge parser and the
/// tests, so both read a header the same way.
func parseParameters(_ text: String) -> [String: String] {
    var parameters: [String: String] = [:]
    var key = ""
    var value = ""
    var index = text.startIndex
    var inQuotes = false
    var readingKey = true

    func commit() {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces).lowercased()
        if !trimmedKey.isEmpty {
            parameters[trimmedKey] = value.trimmingCharacters(in: .whitespaces)
        }
        key = ""
        value = ""
        readingKey = true
    }

    while index < text.endIndex {
        let character = text[index]
        if readingKey {
            if character == "=" {
                readingKey = false
            } else if character == "," {
                commit()
            } else {
                key.append(character)
            }
        } else if inQuotes {
            if character == "\\", index < text.index(before: text.endIndex) {
                index = text.index(after: index)
                value.append(text[index])
            } else if character == "\"" {
                inQuotes = false
            } else {
                value.append(character)
            }
        } else if character == "\"" {
            inQuotes = true
        } else if character == "," {
            commit()
        } else {
            value.append(character)
        }
        index = text.index(after: index)
    }
    commit()
    return parameters
}
