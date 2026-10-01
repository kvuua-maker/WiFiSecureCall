import Foundation

enum AccountMutationError: Error, Equatable {
    case callInProgress
    case mutationInProgress
    case serverActionFailed
    case localCleanupFailedAfterRemoteSuccess
}

func callStateBlocksAccountMutation(_ state: CallState) -> Bool {
    switch state {
    case .idle, .ended, .failed: return false
    case .outgoingRinging, .incomingRinging, .connecting, .active, .reconnecting, .ending: return true
    }
}

@MainActor
func routeSecureMessageNotification(
    accountID: UUID,
    conversationID: UUID,
    accountStore: AccountSessionStore,
    callState: CallState,
    open: (UUID, UUID) -> Void
) -> Bool {
    guard accountStore.hasCallableSession(accountID: accountID) else { return false }
    if accountStore.activeAccountID != accountID {
        guard !callStateBlocksAccountMutation(callState),
              accountStore.switchAccount(to: accountID) == .switched else { return false }
    }
    open(accountID, conversationID)
    return true
}

@MainActor
final class NotificationRuntime {
    static let shared = NotificationRuntime()
    let callSession: CallSession
    let api: APIClient
    let accountStore: AccountSessionStore
    let accountAPI: AccountAPIClient
    private let accountIdentityStore: E2EEIdentityStore
    private let accountPinStore: E2EEIdentityPinStore
    private var callKitFactory: (() -> CallKitHandling)?
    private var callKit: CallKitHandling?
    private(set) var callKitCreationCount = 0
    private var mutatingAccountID: UUID?
    private var accountMutationOutcomes: [UUID: Bool] = [:]
    private let accountMutationPushWaitNanoseconds: UInt64

    init(
        config: AppConfig = AppConfig.load(),
        api: APIClient? = nil,
        accountStore: AccountSessionStore? = nil,
        accountAPI: AccountAPIClient? = nil,
        audio: AudioEngineHandling = AudioEngine(),
        media: MediaTransport? = nil,
        accountIdentityStore: E2EEIdentityStore = E2EEIdentityStore(),
        accountPinStore: E2EEIdentityPinStore = E2EEIdentityPinStore(),
        accountMutationPushWaitNanoseconds: UInt64 = 1_500_000_000
    ) {
        let effectiveAPI = api ?? APIClient(config: config)
        self.api = effectiveAPI
        let effectiveAccountStore = accountStore ?? .shared
        self.accountStore = effectiveAccountStore
        self.accountAPI = accountAPI ?? AccountAPIClient(config: config, tokenStore: effectiveAccountStore.tokenStore)
        self.accountIdentityStore = accountIdentityStore
        self.accountPinStore = accountPinStore
        self.accountMutationPushWaitNanoseconds = accountMutationPushWaitNanoseconds
        callSession = CallSession(config: config, api: effectiveAPI, audio: audio, media: media)
        effectiveAccountStore.retryRevokedPendingCleanup()
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
        if let accountID = accountStore.activeAccountID, mutatingAccountID == accountID {
            callSession.failToStart(.accountMutationInProgress)
            return
        }
        _ = ensureCallKit()
        await callSession.startCall()
    }

    func startPreferredCall(targetPlatform: String) async {
        guard let accountID = accountStore.activeAccountID else { await startCall(); return }
        await startPreferredCall(targetPlatform: targetPlatform, accountID: accountID)
    }

    func startPreferredCall(targetPlatform: String, accountID: UUID) async {
        guard mutatingAccountID != accountID else { callSession.failToStart(.accountMutationInProgress); return }
        guard accountStore.hasCallableSession(accountID: accountID) else {
            callSession.failToStart(.accountSessionInvalid)
            return
        }
        guard mutatingAccountID != accountID else { callSession.failToStart(.accountMutationInProgress); return }
        let matches: [AccountDeviceSummary]
        do {
            matches = try await accountAPI.devices(accountID: accountID).filter {
                $0.deviceID != InstallationIdentity.shared.id && $0.callReady && $0.platform == targetPlatform
            }
        } catch {
            callSession.failToStart(Self.isInvalidAccountSession(error) ? .accountSessionInvalid : .serverUnavailable)
            return
        }
        guard mutatingAccountID != accountID else { callSession.failToStart(.accountMutationInProgress); return }
        guard accountStore.hasCallableSession(accountID: accountID) else { callSession.failToStart(.accountSessionInvalid); return }
        guard matches.count == 1 else {
            callSession.failToStart(matches.isEmpty ? .targetUnavailable : .targetAmbiguous)
            return
        }
        _ = ensureCallKit()
        let signaling = AccountCallSignaling(client: accountAPI, accountID: accountID, targetDeviceID: matches[0].deviceID, localSide: .caller, identityStore: accountIdentityStore, pinStore: accountPinStore)
        await callSession.startCall(signaling: signaling)
    }

    func resolveRecipient(_ input: String, accountID: UUID) async throws -> ResolvedRecipient {
        guard accountStore.hasCallableSession(accountID: accountID) else {
            throw AccountAPIError.missingSession
        }
        let recipient = try await accountAPI.resolveRecipient(input, accountID: accountID)
        guard accountStore.hasCallableSession(accountID: accountID) else { throw AccountAPIError.missingSession }
        return recipient
    }

    func startUserCall(targetUserID: UUID, accountID: UUID, peerDisplayName: String? = nil) async {
        guard mutatingAccountID != accountID else { callSession.failToStart(.accountMutationInProgress); return }
        guard accountStore.hasCallableSession(accountID: accountID) else {
            callSession.failToStart(.accountSessionInvalid)
            return
        }
        guard mutatingAccountID != accountID, accountStore.hasCallableSession(accountID: accountID) else { callSession.failToStart(.accountSessionInvalid); return }
        _ = ensureCallKit()
        let signaling = CrossUserCallSignaling(client: accountAPI, accountID: accountID, targetUserID: targetUserID, targetDisplayName: peerDisplayName, localSide: .caller)
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
        guard await awaitAccountMutation(accountID: accountID, callID: callID) else { return }
        guard accountStore.hasCallableSession(accountID: accountID) else {
            callSession.recordLifecycleDiagnostic("account_session_invalid", status: "missing_tokens", callID: callID)
            return
        }
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
        guard await awaitAccountMutation(accountID: accountID, callID: callID) else { return false }
        guard accountStore.hasCallableSession(accountID: accountID) else {
            callSession.recordLifecycleDiagnostic("account_session_invalid", status: "missing_tokens", callID: callID)
            return false
        }
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
        guard await awaitAccountMutation(accountID: accountID, callID: callID) else { return }
        guard accountStore.hasCallableSession(accountID: accountID) else {
            callSession.recordLifecycleDiagnostic("account_session_invalid", status: "missing_tokens", callID: callID)
            return
        }
        guard let signaling = accountIncomingSignaling(accountID: accountID, callID: callID), ensureCallKit() != nil else { return }
        await callSession.handleIncoming(callID: callID, requestAnswer: requestAnswer, signaling: signaling)
    }

    func handleIncomingUserVoIP(callID: UUID, accountID: UUID, caller: CrossUserCallerIdentity) async {
        guard await awaitAccountMutation(accountID: accountID, callID: callID) else { return }
        guard accountStore.hasCallableSession(accountID: accountID) else {
            callSession.recordLifecycleDiagnostic("account_session_invalid", status: "missing_tokens", callID: callID)
            return
        }
        callSession.recordLifecycleDiagnostic("push_received", status: "user", callID: callID)
        guard let signaling = userIncomingSignaling(accountID: accountID, caller: caller), ensureCallKit() != nil else { return }
        await callSession.handleIncomingVoIP(callID: callID, signaling: signaling)
    }

    func handleIncomingUserBackgroundNotification(callID: UUID, accountID: UUID, caller: CrossUserCallerIdentity) async -> Bool {
        guard await awaitAccountMutation(accountID: accountID, callID: callID) else { return false }
        guard accountStore.hasCallableSession(accountID: accountID) else {
            callSession.recordLifecycleDiagnostic("account_session_invalid", status: "missing_tokens", callID: callID)
            return false
        }
        callSession.recordLifecycleDiagnostic("watch_background_notification_received", status: "user", callID: callID)
        if let duplicate = duplicateIncomingResult(callID: callID) { return duplicate }
        guard let signaling = userIncomingSignaling(accountID: accountID, caller: caller), ensureCallKit() != nil else { return false }
        await callSession.handleIncomingVoIP(callID: callID, signaling: signaling)
        return liveStateBelongs(to: callID)
    }

    func handleIncomingUserAlert(callID: UUID, accountID: UUID, caller: CrossUserCallerIdentity, requestAnswer: Bool) async {
        guard await awaitAccountMutation(accountID: accountID, callID: callID) else { return }
        guard accountStore.hasCallableSession(accountID: accountID) else {
            callSession.recordLifecycleDiagnostic("account_session_invalid", status: "missing_tokens", callID: callID)
            return
        }
        guard let signaling = userIncomingSignaling(accountID: accountID, caller: caller), ensureCallKit() != nil else { return }
        await callSession.handleIncoming(callID: callID, requestAnswer: requestAnswer, signaling: signaling)
    }

    func performExclusiveAccountMutation(
        accountID: UUID,
        remote: @MainActor () async throws -> Void,
        local: @MainActor () throws -> Void
    ) async throws {
        guard !(callStateBlocksAccountMutation(callSession.state) && callSession.activeAccountID == accountID) else { throw AccountMutationError.callInProgress }
        guard mutatingAccountID == nil else { throw AccountMutationError.mutationInProgress }
        mutatingAccountID = accountID
        accountMutationOutcomes.removeValue(forKey: accountID)
        do {
            try await remote()
        } catch {
            finishAccountMutation(succeeded: false)
            throw AccountMutationError.serverActionFailed
        }
        accountStore.markRevokedPendingCleanup(accountID: accountID)
        do {
            try local()
            finishAccountMutation(succeeded: true)
        } catch {
            // The remote session is already revoked. Remove local credentials even
            // if metadata cleanup failed, and retain a durable cleanup marker.
            try? accountStore.tokenStore.delete(accountID: accountID)
            finishAccountMutation(succeeded: true)
            throw AccountMutationError.localCleanupFailedAfterRemoteSuccess
        }
    }

    private func finishAccountMutation(succeeded: Bool) {
        if let accountID = mutatingAccountID { accountMutationOutcomes[accountID] = succeeded }
        mutatingAccountID = nil
    }

    func awaitAccountMutation(accountID: UUID, callID: UUID) async -> Bool {
        guard mutatingAccountID == accountID else { return true }
        callSession.recordLifecycleDiagnostic("incoming_waiting_for_account_mutation", status: "pending", callID: callID)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ accountMutationPushWaitNanoseconds
        while mutatingAccountID == accountID {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                callSession.recordLifecycleDiagnostic("incoming_account_mutation_wait_timeout", status: "not_reported", callID: callID)
                return false
            }
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch { return false }
        }
        if accountMutationOutcomes[accountID] == true {
            callSession.recordLifecycleDiagnostic("incoming_blocked_after_account_mutation", status: "session_removed", callID: callID)
            return false
        }
        callSession.recordLifecycleDiagnostic("incoming_resumed_after_account_mutation", status: "mutation_failed", callID: callID)
        return true
    }

    private func userIncomingSignaling(accountID: UUID, caller: CrossUserCallerIdentity) -> CrossUserCallSignaling? {
        guard accountStore.hasCallableSession(accountID: accountID) else { return nil }
        return CrossUserCallSignaling(client: accountAPI, accountID: accountID, localSide: .callee, callerIdentity: caller)
    }

    private func accountIncomingSignaling(accountID: UUID, callID: UUID) -> AccountCallSignaling? {
        guard accountStore.hasCallableSession(accountID: accountID) else {
            callSession.recordLifecycleDiagnostic("account_session_invalid", status: "missing_tokens", callID: callID)
            return nil
        }
        return AccountCallSignaling(client: accountAPI, accountID: accountID, localSide: .callee, identityStore: accountIdentityStore, pinStore: accountPinStore)
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

enum SecureMessageNotificationAction: Equatable, Sendable {
    case refreshOnly
    case openConversation
}

final class SecureMessageNotificationExecutionPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool { lock.wscLocked { open } }

    @discardableResult
    func close() -> Bool {
        lock.wscLocked {
            guard open else { return false }
            open = false
            return true
        }
    }
}

@MainActor
final class SecureMessageNotificationWorkCoordinator {
    typealias Loader = @MainActor (UUID, UUID) async -> Bool
    typealias Router = @MainActor (UUID, UUID) -> Bool
    typealias Sleeper = @Sendable (UInt64) async -> Void

    static let shared = SecureMessageNotificationWorkCoordinator(
        loader: { accountID, conversationID in
            await SecureMessageStore.shared.prepareNotificationConversation(
                conversationID: conversationID,
                accountID: accountID
            )
        },
        router: { accountID, conversationID in
            let runtime = NotificationRuntime.shared
            return routeSecureMessageNotification(
                accountID: accountID,
                conversationID: conversationID,
                accountStore: runtime.accountStore,
                callState: runtime.callSession.state
            ) { routedAccountID, routedConversationID in
                ProductNavigation.shared.openConversation(accountID: routedAccountID, conversationID: routedConversationID)
            }
        },
        sleeper: { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) }
    )

    private final class Outcome {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var value: Bool?

        func wait() async -> Bool {
            if let value { return value }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish(_ value: Bool) {
            guard self.value == nil else { return }
            self.value = value
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private let loader: Loader
    private let router: Router
    private let sleeper: Sleeper
    private var operationTasks: [UUID: Task<Void, Never>] = [:]
    private var deadlineTasks: [UUID: Task<Void, Never>] = [:]

    var trackedOperationCount: Int { operationTasks.count }
    var trackedDeadlineCount: Int { deadlineTasks.count }

    init(loader: @escaping Loader, router: @escaping Router, sleeper: @escaping Sleeper) {
        self.loader = loader
        self.router = router
        self.sleeper = sleeper
    }

    func handle(
        _ envelope: SecureMessagePushEnvelope,
        action: SecureMessageNotificationAction,
        budgetNanoseconds: UInt64 = 5_000_000_000
    ) async -> Bool {
        let operationID = UUID()
        let permit = SecureMessageNotificationExecutionPermit()
        let outcome = Outcome()

        operationTasks[operationID] = Task { @MainActor [weak self] in
            guard let self else { outcome.finish(false); return }
            let loaded = await loader(envelope.accountID, envelope.conversationID)
            guard permit.isOpen else {
                outcome.finish(false)
                operationTasks.removeValue(forKey: operationID)
                return
            }
            let completed = loaded && (action == .refreshOnly || router(envelope.accountID, envelope.conversationID))
            permit.close()
            operationTasks.removeValue(forKey: operationID)
            outcome.finish(completed)
        }
        deadlineTasks[operationID] = Task { @MainActor [weak self] in
            guard let self else { outcome.finish(false); return }
            await sleeper(budgetNanoseconds)
            guard permit.close() else { return }
            operationTasks.removeValue(forKey: operationID)?.cancel()
            outcome.finish(false)
        }

        let result = await outcome.wait()
        operationTasks.removeValue(forKey: operationID)?.cancel()
        deadlineTasks.removeValue(forKey: operationID)?.cancel()
        return result
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
