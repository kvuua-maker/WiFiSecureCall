import Foundation

@MainActor
final class NotificationRuntime {
    static let shared = NotificationRuntime()
    let callSession: CallSession
    let api: APIClient
    private var callKitFactory: (() -> CallKitHandling)?
    private var callKit: CallKitHandling?
    private(set) var callKitCreationCount = 0

    init(
        config: AppConfig = AppConfig.load(),
        api: APIClient? = nil,
        audio: AudioEngineHandling = AudioEngine(),
        media: MediaTransport? = nil
    ) {
        let effectiveAPI = api ?? APIClient(config: config)
        self.api = effectiveAPI
        callSession = CallSession(config: config, api: effectiveAPI, audio: audio, media: media)
    }

    func configureCallKitFactory(_ factory: @escaping () -> CallKitHandling) {
        guard callKitFactory == nil else { return }
        callKitFactory = factory
    }

    @discardableResult
    func ensureCallKit() -> CallKitHandling? {
        if let callKit { return callKit }
        guard let factory = callKitFactory else { return nil }
        let created = factory()
        callKit = created
        callKitCreationCount += 1
        callSession.attach(callKit: created)
        callSession.recordLifecycleDiagnostic(
            "callkit_provider_created",
            status: "instance=\(created.diagnosticInstanceID.uuidString)",
            callID: nil
        )
        return created
    }

    func startCall() async {
        _ = ensureCallKit()
        await callSession.startCall()
    }

    func handleIncomingVoIP(callID: UUID) async {
        callSession.recordLifecycleDiagnostic("push_received", status: "voip", callID: callID)
        guard ensureCallKit() != nil else {
            callSession.recordLifecycleDiagnostic("incoming_callkit_report_started", status: "provider_unavailable", callID: callID)
            return
        }
        await callSession.handleIncomingVoIP(callID: callID)
    }

    func handleIncomingBackgroundNotification(callID: UUID) async -> Bool {
        callSession.recordLifecycleDiagnostic("watch_background_notification_received", status: "received", callID: callID)
        if callSession.state.callID == callID {
            callSession.recordLifecycleDiagnostic("duplicate_incoming_suppressed", status: "same_server_call_id", callID: callID)
            switch callSession.state {
            case .incomingRinging, .connecting, .active, .reconnecting:
                return true
            default:
                return false
            }
        }
        guard ensureCallKit() != nil else {
            callSession.recordLifecycleDiagnostic("watch_background_callkit_handoff", status: "provider_unavailable", callID: callID)
            return false
        }
        callSession.recordLifecycleDiagnostic("watch_background_callkit_handoff", status: "started", callID: callID)
        await callSession.handleIncomingVoIP(callID: callID)
        let reported: Bool
        switch callSession.state {
        case let .incomingRinging(currentCallID), let .connecting(currentCallID),
             let .active(currentCallID), let .reconnecting(currentCallID):
            reported = currentCallID == callID
        default:
            reported = false
        }
        callSession.recordLifecycleDiagnostic("watch_background_callkit_handoff", status: reported ? "success" : "not_reported", callID: callID)
        return reported
    }

    func handleIncomingAlert(callID: UUID, requestAnswer: Bool) async {
        guard ensureCallKit() != nil else { return }
        await callSession.handleIncoming(callID: callID, requestAnswer: requestAnswer)
    }
}

enum ForegroundIncomingNotification {
    enum Outcome: Equatable {
        case unrelated
        case invalidCallID
        case incoming(UUID)
    }

    static func outcome(from userInfo: [AnyHashable: Any]) -> Outcome {
        guard userInfo["event"] as? String == "incoming_call" else {
            return .unrelated
        }
        guard
            let value = (userInfo["serverCallID"] as? String) ?? (userInfo["callID"] as? String),
            let callID = UUID(uuidString: value)
        else {
            return .invalidCallID
        }
        return .incoming(callID)
    }

    static func callID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard case .incoming(let callID) = outcome(from: userInfo) else { return nil }
        return callID
    }

    @discardableResult
    static func dispatch(
        userInfo: [AnyHashable: Any],
        incoming: (UUID, Bool) -> Void
    ) -> Outcome {
        let result = outcome(from: userInfo)
        if case .incoming(let callID) = result {
            incoming(callID, false)
        }
        return result
    }
}

enum VoIPIncomingNotification {
    static func callID(from payload: [AnyHashable: Any]) -> UUID? {
        guard payload["event"] as? String == "incoming_call",
              let value = payload["serverCallID"] as? String
        else { return nil }
        return UUID(uuidString: value)
    }
}
