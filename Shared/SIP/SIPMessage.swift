import Foundation

/// A SIP method this client can send or receive.
enum SIPMethod: String, Sendable, CaseIterable {
    case invite = "INVITE"
    case ack = "ACK"
    case cancel = "CANCEL"
    case bye = "BYE"
    case register = "REGISTER"
    case options = "OPTIONS"
    case info = "INFO"
    case update = "UPDATE"
    case message = "MESSAGE"

    /// ACK, BYE and CANCEL belong to a dialog that already exists.
    var belongsToDialog: Bool {
        switch self {
        case .ack, .bye, .cancel, .info, .update: return true
        default: return false
        }
    }
}

struct SIPHeader: Sendable, Equatable {
    var name: String
    var value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// One SIP request or response.
///
/// The type is a value: parsing produces a copy that callers can rewrite without
/// touching the transport's buffer, which keeps the retransmission and dialog
/// code free of shared mutable state.
struct SIPMessage: Sendable, Equatable {
    enum Start: Sendable, Equatable {
        case request(method: SIPMethod, uri: String)
        case response(code: Int, reason: String)
    }

    var start: Start
    var headers: [SIPHeader]
    var body: Data

    init(start: Start, headers: [SIPHeader] = [], body: Data = Data()) {
        self.start = start
        self.headers = headers
        self.body = body
    }

    // MARK: - Header access

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func headerValues(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    mutating func setHeader(_ name: String, _ value: String) {
        removeHeader(name)
        headers.append(SIPHeader(name, value))
    }

    mutating func addHeader(_ name: String, _ value: String) {
        headers.append(SIPHeader(name, value))
    }

    mutating func removeHeader(_ name: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var callID: String? { header("Call-ID") }

    var cseq: (number: UInt32, method: String)? {
        guard let raw = header("CSeq") else { return nil }
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first, let number = UInt32(first) else { return nil }
        let method = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (number, method.uppercased())
    }

    var contentType: String? { header("Content-Type") }

    var method: SIPMethod? {
        if case let .request(method, _) = start { return method }
        return nil
    }

    var statusCode: Int? {
        if case let .response(code, _) = start { return code }
        return nil
    }

    var requestURI: String? {
        if case let .request(_, uri) = start { return uri }
        return nil
    }

    // MARK: - Serialisation

    /// Renders the message with CRLF line endings and a correct Content-Length.
    func serialized() -> Data {
        var text = ""
        switch start {
        case let .request(method, uri):
            text += "\(method.rawValue) \(uri) SIP/2.0\r\n"
        case let .response(code, reason):
            text += "SIP/2.0 \(code) \(reason)\r\n"
        }
        for header in headers where header.name.caseInsensitiveCompare("Content-Length") != .orderedSame {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\n\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    // MARK: - Parsing

    /// Parses one SIP message.
    ///
    /// Lenient on purpose: a SIP message may arrive with LF line endings, folded
    /// headers, or an unknown method, and rejecting any of those would drop calls
    /// that a commercial peer considers valid.
    static func parse(_ data: Data) -> SIPMessage? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8)) else {
            return nil
        }
        let headData = data[data.startIndex..<separator.lowerBound]
        let body = Data(data[separator.upperBound...])
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        var lines = head.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }
        let startLine = lines.removeFirst()
        guard let start = parseStartLine(startLine) else { return nil }

        var headers: [SIPHeader] = []
        for line in lines where !line.isEmpty {
            // A line starting with whitespace continues the previous header (RFC 3261 §7.3.1).
            if line.first == " " || line.first == "\t" {
                if var last = headers.popLast() {
                    last.value += " " + line.trimmingCharacters(in: .whitespaces)
                    headers.append(last)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append(SIPHeader(name, value))
        }

        var message = SIPMessage(start: start, headers: headers, body: body)
        if let length = message.header("Content-Length").flatMap(Int.init), length >= 0, body.count > length {
            message.body = Data(body.prefix(length))
        }
        return message
    }

    private static func parseStartLine(_ line: String) -> Start? {
        if line.hasPrefix("SIP/2.0 ") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
            let reason = parts.count > 2 ? String(parts[2]) : ""
            return .response(code: code, reason: reason)
        }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2] == "SIP/2.0" else { return nil }
        guard let method = SIPMethod(rawValue: String(parts[0]).uppercased()) else { return nil }
        return .request(method: method, uri: String(parts[1]))
    }
}

// MARK: - Convenience construction

extension SIPMessage {
    /// Builds a request with the headers every outgoing message needs.
    static func request(
        _ method: SIPMethod,
        uri: String,
        from: String,
        to: String,
        callID: String,
        cseq: UInt32,
        via: String,
        contact: String? = nil,
        extraHeaders: [SIPHeader] = []
    ) -> SIPMessage {
        var message = SIPMessage(start: .request(method: method, uri: uri))
        message.addHeader("Via", via)
        message.addHeader("Max-Forwards", "70")
        message.addHeader("From", from)
        message.addHeader("To", to)
        message.addHeader("Call-ID", callID)
        message.addHeader("CSeq", "\(cseq) \(method.rawValue)")
        if let contact {
            message.addHeader("Contact", contact)
        }
        message.addHeader("User-Agent", SIPConfiguration.userAgent)
        for header in extraHeaders {
            message.addHeader(header.name, header.value)
        }
        return message
    }

    /// Builds a response to a request, copying the fields that must match.
    static func response(to request: SIPMessage, code: Int, reason: String, body: Data = Data()) -> SIPMessage {
        var message = SIPMessage(start: .response(code: code, reason: reason))
        for name in ["Via", "From", "To", "Call-ID", "CSeq"] {
            for value in request.headerValues(name) {
                message.addHeader(name, value)
            }
        }
        if !body.isEmpty {
            message.addHeader("Content-Type", "application/sdp")
            message.body = body
        }
        return message
    }
}

/// Serialises SIP requests onto a connection that must not interleave frames.
final class SIPMessageQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var draining = false
    private let send: (Data) -> Void

    init(send: @escaping (Data) -> Void) {
        self.send = send
    }

    func enqueue(_ message: SIPMessage) {
        let data = message.serialized()
        lock.lock()
        queue.append(data)
        let shouldDrain = !draining
        if shouldDrain { draining = true }
        lock.unlock()
        guard shouldDrain else { return }
        Task.detached { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !queue.isEmpty else {
                draining = false
                lock.unlock()
                return
            }
            let next = queue.removeFirst()
            lock.unlock()
            send(next)
        }
    }
}
