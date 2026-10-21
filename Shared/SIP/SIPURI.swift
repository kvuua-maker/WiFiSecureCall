import Foundation

/// A sip: or sips: address, split into the parts the client needs.
struct SIPURI: Sendable, Equatable, Hashable {
    var scheme: String = "sip"
    var user: String
    var host: String
    var port: Int?
    /// Everything after the host, for example `;transport=tls`.
    var parameters: String = ""

    init(user: String, host: String, port: Int? = nil, scheme: String = "sip", parameters: String = "") {
        self.user = user
        self.host = host
        self.port = port
        self.scheme = scheme
        self.parameters = parameters
    }

    var rendered: String {
        var text = "\(scheme):\(user)@\(host)"
        if let port { text += ":\(port)" }
        return text + parameters
    }

    /// Parses `sip:user@host:port;params`. A missing scheme is read as sip, which
    /// is what a user typing a plain number expects.
    static func parse(_ raw: String) -> SIPURI? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<"), text.hasSuffix(">") {
            text = String(text.dropFirst().dropLast())
        }
        var scheme = "sip"
        if let colon = text.firstIndex(of: ":") {
            let prefix = String(text[text.startIndex..<colon]).lowercased()
            if prefix == "sip" || prefix == "sips" {
                scheme = prefix
                text = String(text[text.index(after: colon)...])
            }
        }
        // Drop URI parameters, which this client does not use for routing.
        var parameters = ""
        if let semicolon = text.firstIndex(of: ";") {
            parameters = String(text[semicolon...])
            text = String(text[text.startIndex..<semicolon])
        }
        guard let at = text.lastIndex(of: "@") else {
            let host = text.split(separator: ":")
            guard let hostName = host.first, !hostName.isEmpty else { return nil }
            let port = host.count > 1 ? Int(host[1]) : nil
            return SIPURI(user: "", host: String(hostName), port: port, scheme: scheme, parameters: parameters)
        }
        let user = String(text[text.startIndex..<at])
        var hostPart = String(text[text.index(after: at)...])
        var port: Int?
        if let colon = hostPart.lastIndex(of: ":"), let parsed = Int(hostPart[hostPart.index(after: colon)...]) {
            port = parsed
            hostPart = String(hostPart[hostPart.startIndex..<colon])
        }
        guard !hostPart.isEmpty else { return nil }
        return SIPURI(user: user, host: hostPart, port: port, scheme: scheme, parameters: parameters)
    }
}

/// The account a watch registers with.
///
/// The password never lives in this struct's `description` and is only held long
/// enough to answer a challenge: it is read from the keychain when the client is
/// created and never written to a log or a plist.
struct SIPAccount: Sendable, Equatable {
    var username: String
    var host: String
    var port: Int
    var webSocketPath: String
    var displayName: String
    var domain: String

    var webSocketURL: URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = port
        components.path = webSocketPath.isEmpty ? "/" : webSocketPath
        return components.url
    }

    var addressOfRecord: String { "sip:\(username)@\(domain)" }

    var contactURI: String { "sip:\(username)@\(host):\(port);transport=ws" }

    var isComplete: Bool {
        !username.isEmpty && !host.isEmpty && port > 0 && port < 65536 && !domain.isEmpty
    }

    static let empty = SIPAccount(
        username: "",
        host: "",
        port: 443,
        webSocketPath: "/sip",
        displayName: "",
        domain: ""
    )
}

enum SIPConfiguration {
    static let userAgent = "WiFiSecureCall-Watch/2.0"
    static let registrationExpiry: Int = 300
    static let registrationRefreshMargin: Double = 0.8
    static let inviteTimeout: TimeInterval = 60
    static let reconnectingTimeout: TimeInterval = 30
    static let preferredCodecs: [SIPCodec] = [.pcmu, .pcma]
    static let frameDuration: TimeInterval = 0.020
    static let samplesPerFrame = 160
    static let sampleRate = 8_000
}
