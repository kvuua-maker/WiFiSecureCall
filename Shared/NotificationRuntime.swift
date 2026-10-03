import Foundation

@MainActor
final class NotificationRuntime {
    static let shared = NotificationRuntime()
    let callSession: CallSession
    let api: APIClient
    let accountStore: AccountSessionStore
    let accountAPI: AccountAPIClient
    private var callKitFactory: (() -> CallKitHandling)?
    private var callKit: CallKitHandling?
    private(set) var callKitCreationCount = 0

    init(
        config: AppConfig = AppConfig.load(),
        api: APIClient? = nil,
        accountStore: AccountSessionStore? = nil,
        accountAPI: AccountAPIClient? = nil,
        audio: AudioEngineHandling = AudioEngine(),
        media: MediaTransport? = nil
    ) {
        let effectiveAPI = api ?? APIClient(config: config)
        self.api = effectiveAPI
        let effectiveAccountStore = accountStore ?? .shared
        self.accountStore = effectiveAccountStore
        self.accountAPI = accountAPI ?? AccountAPIClient(config: config, tokenStore: effectiveAccountStore.tokenStore)
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

    static var localPlatform: String {
        #if os(watchOS)
        "watchOS"
        #else
        "iOS"
        #endif
    }

    func startCall() async {
        _ = ensureCallKit()
        await callSession.startCall()
    }

    func startPreferredCall(targetPlatform: String) async {
        guard let accountID = accountStore.activeAccountID else { await startCall(); return }
        await startPreferredCall(targetPlatform: targetPlatform, accountID: accountID)
    }

    func startPreferredCall(targetPlatform: String, accountID: UUID) async {
        await startPreferredCall(preferredPlatforms: [targetPlatform], accountID: accountID, allowAnyPlatformFallback: false)
    }

    /// Places a call that stays on this device: this installation keeps its own media leg and only
    /// the remote leg needs another registered device. On watchOS this is the path that produces a
    /// call whose audio is captured and rendered by the Apple Watch alone.
    func startLocalPeerCall(accountID: UUID) async {
        let platforms = Self.localPlatform == "watchOS" ? ["watchOS", "iOS"] : ["iOS", "watchOS"]
        await startPreferredCall(preferredPlatforms: platforms, accountID: accountID, allowAnyPlatformFallback: true)
    }

    func startPreferredCall(preferredPlatforms: [String], accountID: UUID, allowAnyPlatformFallback: Bool = false) async {
        guard accountStore.accounts.contains(where: { $0.accountID == accountID }) else {
            callSession.failToStart(.accountSessionInvalid)
            return
        }
        do {
            guard try accountStore.tokenStore.tokens(for: accountID) != nil else {
                callSession.failToStart(.accountSessionInvalid)
                return
            }
        } catch {
            callSession.failToStart(.accountSessionInvalid)
            return
        }
        let matches: [AccountDeviceSummary]
        do {
            matches = try await accountAPI.devices(accountID: accountID).filter {
                $0.deviceID != InstallationIdentity.shared.id && $0.callReady
            }
        } catch {
            callSession.failToStart(Self.isInvalidAccountSession(error) ? .accountSessionInvalid : .serverUnavailable)
            return
        }
        let preferred = matches.filter { preferredPlatforms.contains($0.platform) }
        guard let target = Self.selectTarget(preferred: preferred, allReady: matches, allowAnyPlatformFallback: allowAnyPlatformFallback) else {
            let ambiguous = preferred.count > 1 || (allowAnyPlatformFallback && preferred.isEmpty && matches.count > 1)
            callSession.failToStart(ambiguous ? .targetAmbiguous : .targetUnavailable)
            return
        }
        _ = ensureCallKit()
        let signaling = AccountCallSignaling(client: accountAPI, accountID: accountID, targetDeviceID: target.deviceID, localSide: .caller)
        callSession.recordLifecycleDiagnostic("local_media_leg_selected", status: "local=\(Self.localPlatform) remote=\(target.platform)", callID: nil)
        await callSession.startCall(signaling: signaling)
    }

    private static func selectTarget(preferred: [AccountDeviceSummary], allReady: [AccountDeviceSummary], allowAnyPlatformFallback: Bool) -> AccountDeviceSummary? {
        if preferred.count == 1 { return preferred[0] }
        if preferred.count > 1 { return nil }
        guard allowAnyPlatformFallback, allReady.count == 1 else { return nil }
        return allReady[0]
    }

    func resolveRecipient(_ input: String, accountID: UUID) async throws -> ResolvedRecipient {
        guard accountStore.accounts.contains(where: { $0.accountID == accountID }),
              try accountStore.tokenStore.tokens(for: accountID) != nil else {
            throw AccountAPIError.missingSession
        }
        return try await accountAPI.resolveRecipient(input, accountID: accountID)
    }

    func startUserCall(targetUserID: UUID, accountID: UUID) async {
        guard accountStore.accounts.contains(where: { $0.accountID == accountID }) else {
            callSession.failToStart(.accountSessionInvalid)
            return
        }
        do {
            guard try accountStore.tokenStore.tokens(for: accountID) != nil else {
                callSession.failToStart(.accountSessionInvalid)
                return
            }
        } catch {
            callSession.failToStart(.accountSessionInvalid)
            return
        }
        _ = ensureCallKit()
        let signaling = CrossUserCallSignaling(client: accountAPI, accountID: accountID, targetUserID: targetUserID, localSide: .caller)
        await callSession.startCall(signaling: signaling)
    }

    func handleIncomingVoIP(callID: UUID) async {
        callSession.recordLifecycleDiagnostic("push_received", status: "voip", callID: callID)
        guard ensureCallKit() != nil else {
            callSession.recordLifecycleDiagnostic("incoming_callkit_report_started", status: "provider_unavailable", callID: callID)
            return
        }
        await callSession.handleIncomingVoIP(callID: callID)
    }

    func handleIncomingVoIP(callID: UUID, accountID: UUID) async {
        callSession.recordLifecycleDiagnostic("push_received", status: "account", callID: callID)
        guard let signaling = accountIncomingSignaling(accountID: accountID, callID: callID) else {
            if !accountStore.accounts.contains(where: { $0.accountID == accountID }) {
                callSession.recordLifecycleDiagnostic("new_call_blocked", status: "account_missing", callID: callID)
            }
            return
        }
        guard ensureCallKit() != nil else { return }
        await callSession.handleIncomingVoIP(callID: callID, signaling: signaling)
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

    func handleIncomingBackgroundNotification(callID: UUID, accountID: UUID) async -> Bool {
        callSession.recordLifecycleDiagnostic("watch_background_notification_received", status: "account", callID: callID)
        if let duplicate = duplicateIncomingResult(callID: callID) { return duplicate }
        guard let signaling = accountIncomingSignaling(accountID: accountID, callID: callID) else { return false }
        guard ensureCallKit() != nil else { return false }
        callSession.recordLifecycleDiagnostic("watch_background_callkit_handoff", status: "started", callID: callID)
        await callSession.handleIncomingVoIP(callID: callID, signaling: signaling)
        let reported = liveStateBelongs(to: callID)
        callSession.recordLifecycleDiagnostic("watch_background_callkit_handoff", status: reported ? "success" : "not_reported", callID: callID)
        return reported
    }

    func handleIncomingAlert(callID: UUID, requestAnswer: Bool) async {
        guard ensureCallKit() != nil else { return }
        await callSession.handleIncoming(callID: callID, requestAnswer: requestAnswer)
    }

    func handleIncomingAlert(callID: UUID, accountID: UUID, requestAnswer: Bool) async {
        guard let signaling = accountIncomingSignaling(accountID: accountID, callID: callID), ensureCallKit() != nil else { return }
        await callSession.handleIncoming(callID: callID, requestAnswer: requestAnswer, signaling: signaling)
    }

    func handleIncomingUserVoIP(callID: UUID, accountID: UUID, caller: CrossUserCallerIdentity) async {
        callSession.recordLifecycleDiagnostic("push_received", status: "user", callID: callID)
        guard let signaling = userIncomingSignaling(accountID: accountID, caller: caller), ensureCallKit() != nil else { return }
        await callSession.handleIncomingVoIP(callID: callID, signaling: signaling)
    }

    func handleIncomingUserBackgroundNotification(callID: UUID, accountID: UUID, caller: CrossUserCallerIdentity) async -> Bool {
        callSession.recordLifecycleDiagnostic("watch_background_notification_received", status: "user", callID: callID)
        if let duplicate = duplicateIncomingResult(callID: callID) { return duplicate }
        guard let signaling = userIncomingSignaling(accountID: accountID, caller: caller), ensureCallKit() != nil else { return false }
        await callSession.handleIncomingVoIP(callID: callID, signaling: signaling)
        return liveStateBelongs(to: callID)
    }

    func handleIncomingUserAlert(callID: UUID, accountID: UUID, caller: CrossUserCallerIdentity, requestAnswer: Bool) async {
        guard let signaling = userIncomingSignaling(accountID: accountID, caller: caller), ensureCallKit() != nil else { return }
        await callSession.handleIncoming(callID: callID, requestAnswer: requestAnswer, signaling: signaling)
    }

    private func userIncomingSignaling(accountID: UUID, caller: CrossUserCallerIdentity) -> CrossUserCallSignaling? {
        guard accountStore.accounts.map(\.accountID).contains(accountID),
              (try? accountStore.tokenStore.tokens(for: accountID)) != nil else { return nil }
        return CrossUserCallSignaling(client: accountAPI, accountID: accountID, localSide: .callee, callerIdentity: caller)
    }

    private func accountIncomingSignaling(accountID: UUID, callID: UUID) -> AccountCallSignaling? {
        guard accountStore.accounts.contains(where: { $0.accountID == accountID }) else { return nil }
        guard (try? accountStore.tokenStore.tokens(for: accountID)) != nil else {
            callSession.recordLifecycleDiagnostic("account_session_invalid", status: "missing_tokens", callID: callID)
            return nil
        }
        return AccountCallSignaling(client: accountAPI, accountID: accountID, localSide: .callee)
    }

    private static func isInvalidAccountSession(_ error: Error) -> Bool {
        guard let error = error as? AccountAPIError else { return false }
        switch error {
        case .missingSession: return true
        case let .status(status, _): return status == 401 || status == 403
        default: return false
        }
    }

    private func duplicateIncomingResult(callID: UUID) -> Bool? {
        guard callSession.state.callID == callID else { return nil }
        callSession.recordLifecycleDiagnostic("duplicate_incoming_suppressed", status: "same_server_call_id", callID: callID)
        return liveStateBelongs(to: callID)
    }

    private func liveStateBelongs(to callID: UUID) -> Bool {
        switch callSession.state {
        case let .incomingRinging(value), let .connecting(value), let .active(value), let .reconnecting(value): return value == callID
        default: return false
        }
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

    static func envelope(from userInfo: [AnyHashable: Any]) -> IncomingNotificationEnvelope? {
        IncomingNotificationEnvelope.parse(userInfo)
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


    static func envelope(from payload: [AnyHashable: Any]) -> IncomingNotificationEnvelope? {
        IncomingNotificationEnvelope.parse(payload)
    }
}

enum IncomingNotificationEnvelope: Equatable, Sendable {
    case legacy(callID: UUID)
    case account(callID: UUID, accountID: UUID)
    case user(callID: UUID, accountID: UUID, caller: CrossUserCallerIdentity)

    static func parse(_ payload: [AnyHashable: Any]) -> IncomingNotificationEnvelope? {
        guard let event = payload["event"] as? String else { return nil }
        guard let rawCallID = (payload["serverCallID"] as? String) ?? (payload["callID"] as? String),
              let callID = UUID(uuidString: rawCallID) else { return nil }
        if event == "incoming_call" { return .legacy(callID: callID) }
        if event == "incoming_call_v2",
           let rawAccountID = payload["accountID"] as? String,
           let accountID = UUID(uuidString: rawAccountID) {
            return .account(callID: callID, accountID: accountID)
        }
        if event == "incoming_call_v3",
           let rawAccountID = payload["accountID"] as? String,
           let accountID = UUID(uuidString: rawAccountID),
           let rawUsername = payload["callerUsername"] as? String {
            let username = rawUsername.lowercased()
            guard username.range(of: "^[a-z0-9][a-z0-9._-]{2,29}$", options: .regularExpression) != nil,
                  payload["callerPublicIdentity"] as? String == "wsc:user:" + username else { return nil }
            var displayName: String?
            if let rawDisplayName = payload["callerDisplayName"] as? String, !rawDisplayName.isEmpty {
                guard rawDisplayName.count <= 80, rawDisplayName.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
                displayName = rawDisplayName
            }
            return .user(
                callID: callID, accountID: accountID,
                caller: CrossUserCallerIdentity(username: username, displayName: displayName, publicIdentity: "wsc:user:" + username)
            )
        }
        return nil
    }
}
