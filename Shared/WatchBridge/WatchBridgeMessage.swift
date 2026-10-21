import Foundation

/// The messages the watch and the iPhone exchange over WatchConnectivity.
///
/// The wire format is a property list dictionary rather than Codable JSON because
/// `WCSession` only accepts property-list types, and because the same payload has
/// to survive three different delivery paths: `sendMessage` while both apps are
/// awake, `transferUserInfo` when only the sender is, and `updateApplicationContext`
/// when neither is. Keeping one representation means a message queued by one path
/// is still readable when it arrives by another.
enum WatchBridgeKind: String, Sendable {
    /// Watch asks the iPhone to place a call.
    case requestCall = "call.request"
    /// Watch withdraws a request it has not had confirmed yet.
    case cancelCall = "call.cancel"
    /// iPhone reports what happened to a request.
    case callState = "call.state"
    /// iPhone tells the watch that a call is ringing.
    case incomingCall = "call.incoming"
    /// Liveness probe, sent by either side while a call is up.
    case ping = "device.ping"
    case pong = "device.pong"
}

struct WatchBridgeMessage: Sendable, Equatable {
    var kind: WatchBridgeKind
    var requestID: UUID
    var number: String?
    var state: String?
    var detail: String?
    var callID: UUID?
    var caller: String?
    var sentAt: Date

    init(
        kind: WatchBridgeKind,
        requestID: UUID = UUID(),
        number: String? = nil,
        state: String? = nil,
        detail: String? = nil,
        callID: UUID? = nil,
        caller: String? = nil,
        sentAt: Date = Date()
    ) {
        self.kind = kind
        self.requestID = requestID
        self.number = number
        self.state = state
        self.detail = detail
        self.callID = callID
        self.caller = caller
        self.sentAt = sentAt
    }

    /// The property-list form `WCSession` accepts.
    var dictionary: [String: Any] {
        var payload: [String: Any] = [
            "v": 1,
            "kind": kind.rawValue,
            "requestID": requestID.uuidString,
            "sentAt": sentAt.timeIntervalSince1970
        ]
        payload["number"] = number
        payload["state"] = state
        payload["detail"] = detail
        payload["callID"] = callID?.uuidString
        payload["caller"] = caller
        return payload
    }

    /// Rebuilds a message received from the other device.
    ///
    /// Returns nil for anything that is not one of ours: the same session also
    /// carries the app's application context, and an unknown payload must be
    /// ignored rather than crash a background wake-up.
    static func parse(_ dictionary: [String: Any]) -> WatchBridgeMessage? {
        guard let rawKind = dictionary["kind"] as? String,
              let kind = WatchBridgeKind(rawValue: rawKind),
              let rawRequest = dictionary["requestID"] as? String,
              let requestID = UUID(uuidString: rawRequest) else {
            return nil
        }
        let sentAt = (dictionary["sentAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) ?? Date()
        return WatchBridgeMessage(
            kind: kind,
            requestID: requestID,
            number: dictionary["number"] as? String,
            state: dictionary["state"] as? String,
            detail: dictionary["detail"] as? String,
            callID: (dictionary["callID"] as? String).flatMap(UUID.init(uuidString:)),
            caller: dictionary["caller"] as? String,
            sentAt: sentAt
        )
    }
}

/// The call states the iPhone reports back to the watch.
enum WatchBridgeCallState: String, Sendable {
    case resolving
    case dialing
    case ringing
    case active
    case ended
    case failed
    case handedToSystem
}
