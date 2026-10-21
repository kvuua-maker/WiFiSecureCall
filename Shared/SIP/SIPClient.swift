import Foundation

/// Registration state of the SIP account.
enum SIPClientState: Sendable, Equatable {
    case idle
    case connecting
    case registering
    case registered(expiresAt: Date)
    case failed(String)

    var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }
}

/// Something that happened to a call.
enum SIPClientEvent: Sendable, Equatable {
    /// A remote party is calling. The client has already answered 100 Trying.
    case incoming(callID: String, from: String, displayName: String, offer: SIPMediaDescription?)
    /// A provisional response: 180 Ringing, 183 Session Progress and so on.
    case progressing(callID: String, code: Int, reason: String)
    /// The call is up. `media` is the far end's audio endpoint, if it sent one.
    case answered(callID: String, media: SIPMediaDescription?)
    /// The call is over, either normally or because the far end refused it.
    case terminated(callID: String, code: Int, reason: String)
    /// The call could not be placed or maintained locally.
    case failed(callID: String, reason: String)
    /// The remote party's audio endpoint changed, for example after a re-INVITE.
    case mediaUpdated(callID: String, media: SIPMediaDescription)
}

protocol SIPClientDelegate: AnyObject, Sendable {
    func sipClient(_ client: SIPClient, didChange state: SIPClientState)
    func sipClient(_ client: SIPClient, didReceive event: SIPClientEvent)
}

/// A SIP user agent for one account.
///
/// The client owns the registration and the single active dialog. All mutable
/// state is confined to `queue`; the delegate is always called on the main queue
/// so the UI layer never has to marshal anything itself.
final class SIPClient: NSObject, @unchecked Sendable {
    weak var delegate: SIPClientDelegate?

    private let account: SIPAccount
    private let password: String
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.sip.client", qos: .userInitiated)
    private var transport: SIPTransport?

    private var state: SIPClientState = .idle
    private var registrationCSeq: UInt32 = 1
    private var registrationExpiry = SIPConfiguration.registrationExpiry
    private var refreshWorkItem: DispatchWorkItem?
    private var authAttempts = 0
    private var dialog: Dialog?

    private struct Dialog {
        var callID: String
        var remoteURI: String
        var localTag: String
        var remoteTag: String
        var localCSeq: UInt32
        var outgoing: Bool
        var branch: String
        var invite: SIPMessage?
        var toHeader: String
        var fromHeader: String
        var answered: Bool
        var media: SIPMediaDescription?
        var cancelled: Bool
    }

    init(account: SIPAccount, password: String) {
        self.account = account
        self.password = password
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.account.isComplete, let url = self.account.webSocketURL else {
                self.publish(.failed("SIP account is incomplete"))
                return
            }
            self.publish(.connecting)
            let transport = WebSocketSIPTransport(url: url)
            transport.delegate = self
            self.transport = transport
            transport.start()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshWorkItem?.cancel()
            self.refreshWorkItem = nil
            self.dialog = nil
            self.transport?.stop()
            self.transport = nil
            self.publish(.idle)
        }
    }

    /// Re-registers after the app returns to the foreground or the network changes.
    func refreshRegistration() {
        queue.async { [weak self] in
            guard let self, self.transport != nil else { return }
            self.sendRegister(authorization: nil)
        }
    }

    // MARK: - Outgoing call

    /// Places a call and returns the call identifier that will appear in events.
    @discardableResult
    func placeCall(to destination: String, offer: Data) -> String {
        let callID = Self.makeCallID(host: account.host)
        queue.async { [weak self] in
            guard let self else { return }
            guard self.state.isRegistered else {
                self.event(.failed(callID: callID, reason: "Not registered"))
                return
            }
            let remote = Self.normaliseDestination(destination, domain: self.account.domain)
            let localTag = Self.makeTag()
            let branch = Self.makeBranch()
            let cseq = self.registrationCSeq &+ 1
            self.registrationCSeq = cseq
            self.dialog = Dialog(
                callID: callID,
                remoteURI: remote,
                localTag: localTag,
                remoteTag: "",
                localCSeq: cseq,
                outgoing: true,
                branch: branch,
                invite: nil,
                toHeader: "<\(remote)>",
                fromHeader: "<\(self.account.addressOfRecord)>;tag=\(localTag)",
                answered: false,
                media: nil,
                cancelled: false
            )
            self.sendInvite(callID: callID, offer: offer, cseq: cseq, branch: branch, authorization: nil)
        }
        return callID
    }

    private func sendInvite(callID: String, offer: Data, cseq: UInt32, branch: String, authorization: String?) {
        guard var dialog = self.dialog, dialog.callID == callID else { return }
        var message = SIPMessage.request(
            .invite,
            uri: dialog.remoteURI,
            from: dialog.fromHeader,
            to: dialog.toHeader,
            callID: dialog.callID,
            cseq: cseq,
            via: Self.via(host: account.host, branch: branch),
            contact: "<\(account.contactURI)>"
        )
        message.addHeader("Content-Type", "application/sdp")
        message.body = offer
        if let authorization {
            message.addHeader("Proxy-Authorization", authorization)
        }
        dialog.invite = message
        dialog.branch = branch
        dialog.localCSeq = cseq
        self.dialog = dialog
        send(message)
    }

    // MARK: - Incoming call

    /// Accepts an incoming call. `answer` is the SDP body describing local media.
    func accept(callID: String, answer: Data) {
        queue.async { [weak self] in
            guard let self, var dialog = self.dialog, dialog.callID == callID, !dialog.answered else { return }
            var response = SIPMessage.response(to: dialog.invite ?? SIPMessage(start: .response(code: 200, reason: "OK")), code: 200, reason: "OK", body: answer)
            response.setHeader("Contact", "<\(self.account.contactURI)>")
            if !dialog.remoteTag.isEmpty, var to = response.header("To"), !to.contains("tag=") {
                to += ";tag=\(dialog.remoteTag)"
                response.setHeader("To", to)
            }
            self.send(response)
            dialog.answered = true
            self.dialog = dialog
        }
    }

    func reject(callID: String, code: Int = 486) {
        queue.async { [weak self] in
            guard let self, let dialog = self.dialog, dialog.callID == callID else { return }
            guard let invite = dialog.invite else { return }
            let reason = code == 603 ? "Decline" : "Busy Here"
            self.send(SIPMessage.response(to: invite, code: code, reason: reason))
            self.dialog = nil
        }
    }

    // MARK: - Hangup

    func hangUp(callID: String) {
        queue.async { [weak self] in
            guard let self, var dialog = self.dialog, dialog.callID == callID else { return }
            if dialog.answered {
                var bye = SIPMessage.request(
                    .bye,
                    uri: dialog.remoteURI,
                    from: dialog.fromHeader,
                    to: dialog.toHeader,
                    callID: dialog.callID,
                    cseq: dialog.localCSeq &+ 1,
                    via: Self.via(host: self.account.host, branch: Self.makeBranch())
                )
                if let remoteTag = Self.tag(from: dialog.toHeader) {
                    dialog.remoteTag = remoteTag
                }
                bye.setHeader("To", Self.withTag(dialog.toHeader, tag: dialog.remoteTag))
                self.send(bye)
            } else if dialog.outgoing, let invite = dialog.invite {
                // A CANCEL must repeat the branch and CSeq of the INVITE it cancels.
                var cancel = SIPMessage.request(
                    .cancel,
                    uri: dialog.remoteURI,
                    from: dialog.fromHeader,
                    to: dialog.toHeader,
                    callID: dialog.callID,
                    cseq: dialog.localCSeq,
                    via: Self.via(host: self.account.host, branch: dialog.branch)
                )
                cancel.setHeader("CSeq", "\(dialog.localCSeq) CANCEL")
                cancel.removeHeader("Contact")
                cancel.removeHeader("User-Agent")
                if let inviteHeader = invite.header("Proxy-Authorization") {
                    cancel.addHeader("Proxy-Authorization", inviteHeader)
                }
                self.send(cancel)
                dialog.cancelled = true
            }
            self.dialog = dialog
        }
    }

    /// Sends one DTMF digit as an INFO body, the method every SIP trunk supports.
    func sendDTMF(_ digit: String) {
        queue.async { [weak self] in
            guard let self, let dialog = self.dialog, dialog.answered else { return }
            var info = SIPMessage.request(
                .info,
                uri: dialog.remoteURI,
                from: dialog.fromHeader,
                to: Self.withTag(dialog.toHeader, tag: dialog.remoteTag),
                callID: dialog.callID,
                cseq: dialog.localCSeq &+ 1,
                via: Self.via(host: self.account.host, branch: Self.makeBranch())
            )
            info.addHeader("Content-Type", "application/dtmf-relay")
            info.body = Data("Signal=\(digit)\r\nDuration=160\r\n".utf8)
            self.send(info)
        }
    }

    // MARK: - Registration

    private func sendRegister(authorization: String?) {
        guard transport != nil else { return }
        var message = SIPMessage.request(
            .register,
            uri: "sip:\(account.domain)",
            from: "<\(account.addressOfRecord)>;tag=\(Self.makeTag())",
            to: "<\(account.addressOfRecord)>",
            callID: Self.makeCallID(host: account.host),
            cseq: registrationCSeq,
            via: Self.via(host: account.host, branch: Self.makeBranch()),
            contact: "<\(account.contactURI)>"
        )
        message.addHeader("Expires", "\(registrationExpiry)")
        message.addHeader("Allow", "INVITE, ACK, CANCEL, BYE, OPTIONS, INFO")
        message.addHeader("Supported", "outbound")
        if let authorization {
            message.addHeader("Authorization", authorization)
        }
        publish(.registering)
        send(message)
    }

    private func scheduleRefresh(expires: Int) {
        refreshWorkItem?.cancel()
        let delay = max(30, Double(expires) * SIPConfiguration.registrationRefreshMargin)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.registrationCSeq = self.registrationCSeq &+ 1
            self.sendRegister(authorization: nil)
        }
        refreshWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Incoming message handling

    private func handle(_ message: SIPMessage) {
        switch message.start {
        case let .response(code, reason):
            handleResponse(message, code: code, reason: reason)
        case let .request(method, _):
            handleRequest(message, method: method)
        }
    }

    private func handleResponse(_ message: SIPMessage, code: Int, reason: String) {
        guard let cseq = message.cseq else { return }
        switch cseq.method {
        case "REGISTER":
            handleRegisterResponse(message, code: code, reason: reason)
        case "INVITE":
            handleInviteResponse(message, code: code, reason: reason)
        case "BYE":
            if (200..<300).contains(code) {
                finishDialog(callID: message.callID, code: code, reason: reason)
            }
        default:
            break
        }
    }

    private func handleRegisterResponse(_ message: SIPMessage, code: Int, reason: String) {
        switch code {
        case 401, 407:
            guard authAttempts < 2 else {
                publish(.failed("Registration rejected: \(reason)"))
                return
            }
            authAttempts += 1
            let headerName = SIPDigest.challengeHeaderName(for: code)
            guard let challengeValue = message.header(headerName),
                  let challenge = SIPDigestChallenge.parse(challengeValue) else {
                publish(.failed("Registration challenge is unreadable"))
                return
            }
            registrationCSeq = registrationCSeq &+ 1
            let authorization = SIPDigest.authorization(
                username: account.username,
                password: password,
                method: .register,
                uri: "sip:\(account.domain)",
                challenge: challenge,
                nonceCount: UInt32(authAttempts)
            )
            sendRegister(authorization: authorization)
        case 200:
            authAttempts = 0
            let expires = message.header("Expires").flatMap(Int.init) ?? registrationExpiry
            registrationExpiry = max(60, expires)
            let expiryDate = Date().addingTimeInterval(Double(registrationExpiry))
            publish(.registered(expiresAt: expiryDate))
            scheduleRefresh(expires: registrationExpiry)
        default:
            publish(.failed("Registration failed: \(code) \(reason)"))
        }
    }

    private func handleInviteResponse(_ message: SIPMessage, code: Int, reason: String) {
        guard let dialog, let callID = message.callID, callID == dialog.callID else { return }
        switch code {
        case 100:
            break
        case 180, 183, 181, 182:
            event(.progressing(callID: callID, code: code, reason: reason))
        case 200:
            // The forked 2xx needs an ACK before any BYE can be sent.
            ackForSuccess(message)
            var updated = dialog
            updated.answered = true
            updated.remoteTag = Self.tag(from: message.header("To") ?? "") ?? ""
            updated.toHeader = Self.stripTag(message.header("To") ?? dialog.toHeader)
            let media = SDP.parse(message.body)
            updated.media = media
            self.dialog = updated
            event(.answered(callID: callID, media: media))
        case 401, 407:
            // A challenged INVITE must be acknowledged before it is retried.
            ackForFailure(message)
            guard authAttempts < 2 else {
                failDialog(callID: callID, reason: "Call rejected: \(reason)")
                return
            }
            authAttempts += 1
            let headerName = SIPDigest.challengeHeaderName(for: code)
            guard let challengeValue = message.header(headerName),
                  let challenge = SIPDigestChallenge.parse(challengeValue) else {
                failDialog(callID: callID, reason: "Call challenge is unreadable")
                return
            }
            let authorization = SIPDigest.authorization(
                username: account.username,
                password: password,
                method: .invite,
                uri: dialog.remoteURI,
                challenge: challenge,
                nonceCount: UInt32(authAttempts)
            )
            let newCSeq = dialog.localCSeq &+ 1
            let branch = Self.makeBranch()
            sendInvite(callID: callID, offer: dialog.invite?.body ?? Data(), cseq: newCSeq, branch: branch, authorization: authorization)
        default:
            ackForFailure(message)
            finishDialog(callID: callID, code: code, reason: reason)
        }
    }

    private func handleRequest(_ message: SIPMessage, method: SIPMethod) {
        switch method {
        case .invite:
            handleIncomingInvite(message)
        case .ack:
            break
        case .bye:
            send(SIPMessage.response(to: message, code: 200, reason: "OK"))
            finishDialog(callID: message.callID, code: 200, reason: "Remote hangup")
        case .cancel:
            send(SIPMessage.response(to: message, code: 200, reason: "OK"))
            if let invite = dialog?.invite {
                send(SIPMessage.response(to: invite, code: 487, reason: "Request Terminated"))
            }
            dialog = nil
            if let callID = message.callID {
                event(.terminated(callID: callID, code: 487, reason: "Cancelled"))
            }
        case .info:
            send(SIPMessage.response(to: message, code: 200, reason: "OK"))
        case .options:
            var response = SIPMessage.response(to: message, code: 200, reason: "OK")
            response.addHeader("Allow", "INVITE, ACK, CANCEL, BYE, OPTIONS, INFO")
            send(response)
        default:
            send(SIPMessage.response(to: message, code: 405, reason: "Method Not Allowed"))
        }
    }

    private func handleIncomingInvite(_ message: SIPMessage) {
        guard dialog == nil else {
            send(SIPMessage.response(to: message, code: 486, reason: "Busy Here"))
            return
        }
        guard let callID = message.callID else { return }
        guard let from = message.header("From") else { return }
        let remoteTag = Self.tag(from: from) ?? ""
        let remoteURI = Self.uri(from: from) ?? from
        let localTag = Self.makeTag()
        // The 200 OK echoes the To tag that the request carried, or adds ours.
        let toHeader = Self.stripTag(message.header("To") ?? "<\(account.addressOfRecord)>")
        var dialog = Dialog(
            callID: callID,
            remoteURI: remoteURI,
            localTag: localTag,
            remoteTag: remoteTag,
            localCSeq: message.cseq?.number ?? 0,
            outgoing: false,
            branch: Self.branch(from: message.header("Via") ?? "") ?? Self.makeBranch(),
            invite: message,
            toHeader: toHeader,
            fromHeader: "<\(account.addressOfRecord)>;tag=\(localTag)",
            answered: false,
            media: SDP.parse(message.body),
            cancelled: false
        )
        dialog.remoteTag = remoteTag
        self.dialog = dialog

        send(SIPMessage.response(to: message, code: 100, reason: "Trying"))
        let display = Self.displayName(from: message.header("From") ?? "")
        event(.incoming(callID: callID, from: remoteURI, displayName: display, offer: dialog.media))
    }

    // MARK: - Dialog helpers

    private func ackForSuccess(_ response: SIPMessage) {
        guard let dialog else { return }
        let toHeader = response.header("To") ?? dialog.toHeader
        var ack = SIPMessage.request(
            .ack,
            uri: dialog.remoteURI,
            from: dialog.fromHeader,
            to: toHeader,
            callID: dialog.callID,
            cseq: dialog.localCSeq,
            via: Self.via(host: account.host, branch: dialog.branch)
        )
        ack.removeHeader("Contact")
        ack.removeHeader("User-Agent")
        send(ack)
    }

    private func ackForFailure(_ response: SIPMessage) {
        // An ACK for a non-2xx response is part of the same transaction: same
        // branch, same CSeq number, and it must not be sent for anything else.
        guard let dialog, let invite = dialog.invite else { return }
        let toHeader = response.header("To") ?? dialog.toHeader
        var ack = SIPMessage.request(
            .ack,
            uri: dialog.remoteURI,
            from: dialog.fromHeader,
            to: toHeader,
            callID: dialog.callID,
            cseq: dialog.localCSeq,
            via: Self.via(host: account.host, branch: dialog.branch)
        )
        ack.setHeader("To", toHeader)
        ack.removeHeader("Contact")
        ack.removeHeader("User-Agent")
        ack.body = Data()
        _ = invite
        send(ack)
    }

    private func finishDialog(callID: String?, code: Int, reason: String) {
        guard let dialog, let callID, dialog.callID == callID else { return }
        self.dialog = nil
        event(.terminated(callID: callID, code: code, reason: reason))
    }

    private func failDialog(callID: String, reason: String) {
        dialog = nil
        event(.failed(callID: callID, reason: reason))
    }

    private func send(_ message: SIPMessage) {
        transport?.send(message)
    }

    private func publish(_ state: SIPClientState) {
        self.state = state
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.sipClient(self, didChange: state)
        }
    }

    private func event(_ event: SIPClientEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.sipClient(self, didReceive: event)
        }
    }

    // MARK: - Header helpers

    private static func via(host: String, branch: String) -> String {
        "SIP/2.0/WSS \(host);branch=\(branch)"
    }

    private static func makeBranch() -> String {
        "z9hG4bK" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
    }

    private static func makeTag() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
    }

    private static func makeCallID(host: String) -> String {
        UUID().uuidString + "@" + host
    }

    /// Turns what the user typed into a request URI.
    ///
    /// A bare number is dialled at the account's domain, because the server is the
    /// trunk's gateway; a full sip: URI is used as it stands.
    static func normaliseDestination(_ input: String, domain: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("sip:") || trimmed.lowercased().hasPrefix("sips:") {
            return trimmed
        }
        if trimmed.contains("@") {
            return "sip:\(trimmed)"
        }
        let digits = trimmed.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        return "sip:\(digits)@\(domain)"
    }

    static func branch(from via: String) -> String? {
        guard let range = via.range(of: "branch=") else { return nil }
        let rest = via[range.upperBound...]
        let value = rest.split(separator: ";").first.map(String.init) ?? String(rest)
        return value.trimmingCharacters(in: .whitespaces)
    }

    static func tag(from header: String) -> String? {
        guard let range = header.range(of: "tag=") else { return nil }
        let rest = header[range.upperBound...]
        return rest.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func uri(from header: String) -> String? {
        guard let start = header.firstIndex(of: "<"), let end = header.firstIndex(of: ">"), start < end else {
            return header.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        return String(header[header.index(after: start)..<end])
    }

    static func displayName(from header: String) -> String {
        guard let quote = header.firstIndex(of: "\"") else {
            let name = header.split(separator: "<").first.map(String.init) ?? ""
            return name.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
        }
        let after = header.index(after: quote)
        guard let closing = header[after...].firstIndex(of: "\"") else { return "" }
        return String(header[after..<closing])
    }

    static func stripTag(_ header: String) -> String {
        guard let range = header.range(of: ";tag=") else { return header }
        return String(header[header.startIndex..<range.lowerBound])
    }

    static func withTag(_ header: String, tag: String) -> String {
        guard !tag.isEmpty else { return header }
        if header.contains("tag=") { return header }
        return header + ";tag=\(tag)"
    }
}

// MARK: - Transport delegate

extension SIPClient: SIPTransportDelegate {
    func sipTransport(_ transport: SIPTransport, didReceive message: SIPMessage) {
        queue.async { [weak self] in
            self?.handle(message)
        }
    }

    func sipTransport(_ transport: SIPTransport, didChange state: SIPTransportState) {
        queue.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connecting:
                self.publish(.connecting)
            case .connected:
                self.authAttempts = 0
                self.registrationCSeq = self.registrationCSeq &+ 1
                self.sendRegister(authorization: nil)
            case .disconnected:
                self.publish(.connecting)
            case let .failed(reason):
                self.publish(.failed(reason))
            }
        }
    }
}
