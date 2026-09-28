import PushKit
@preconcurrency import UserNotifications
import WatchKit

@MainActor
final class WatchNotificationController: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    private var alertRegistrationTask: Task<Void, Never>?
    private var voipRegistrationTask: Task<Void, Never>?
    private var voipRegistry: PKPushRegistry?
    private var lastAlertToken: Data?
    private var lastVoIPToken: Data?
    private var notificationsAuthorized = false

    func applicationDidFinishLaunching() {
        NotificationRuntime.shared.configureCallKitFactory { WatchCallKitAdapter() }
        let center = UNUserNotificationCenter.current(); center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "INCOMING_CALL", actions: [
            UNNotificationAction(identifier: "ACCEPT", title: "Accept", options: .foreground),
            UNNotificationAction(identifier: "REJECT", title: "Reject")
        ], intentIdentifiers: [])])
        WKApplication.shared().registerForRemoteNotifications(); configureVoIPPushes()
        Task { await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_started", status: "started") }
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            Task { @MainActor in await self.refreshNotificationAuthorization(requestError: error) }
        }
    }

    func applicationDidBecomeActive() {
        Task { await refreshNotificationAuthorization() }
    }

    nonisolated func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
        guard let envelope = ForegroundIncomingNotification.envelope(from: userInfo) else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            let handled: Bool
            switch envelope {
            case let .legacy(callID): handled = await NotificationRuntime.shared.handleIncomingBackgroundNotification(callID: callID)
            case let .account(callID, accountID): handled = await NotificationRuntime.shared.handleIncomingBackgroundNotification(callID: callID, accountID: accountID)
            case let .user(callID, accountID, caller): handled = await NotificationRuntime.shared.handleIncomingUserBackgroundNotification(callID: callID, accountID: accountID, caller: caller)
            }
            completionHandler(handled ? .newData : .noData)
        }
    }

    func didRegisterForRemoteNotifications(withDeviceToken token: Data) { upload(token, pushType: .alert) }
    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) { registrationFailed(error) }
    private func configureVoIPPushes() { let registry = PKPushRegistry(queue: .main); registry.delegate = self; registry.desiredPushTypes = [.voIP]; voipRegistry = registry }

    private func upload(_ token: Data, pushType: DevicePushType) {
        if pushType == .alert { lastAlertToken = token }
        else { lastVoIPToken = token }
        let task = Task { @MainActor in
            await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_succeeded", status: "\(pushType.rawValue)_callback")
            for attempt in 1...3 {
                do {
                    try Task.checkCancellation()
                    try await NotificationRuntime.shared.api.registerDevice(token: token, pushType: pushType, capabilities: capabilities())
                    Diagnostics.shared.record(role: .A, category: "pushRegistration", value: "\(pushType.rawValue)_registered")
                    await AccountPushRegistrationCoordinator.shared.update(token: token, pushType: pushType, capabilities: capabilities())
                    return
                } catch is CancellationError { return }
                catch {
                    if attempt == 3 { await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_failed", status: "\(pushType.rawValue)_server_failed"); return }
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
        }
        if pushType == .alert { alertRegistrationTask?.cancel(); alertRegistrationTask = task }
        else { voipRegistrationTask?.cancel(); voipRegistrationTask = task }
    }

    private func refreshNotificationAuthorization(requestError: Error? = nil) async {
        let settings = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { continuation.resume(returning: $0) }
        }
        let previous = notificationsAuthorized
        let current: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: current = true
        case .notDetermined, .denied: current = false
        @unknown default: current = false
        }
        notificationsAuthorized = current
        let status = Self.authorizationStatus(settings.authorizationStatus, error: requestError)
        Diagnostics.shared.record(role: .A, category: "notificationPermission", value: status)
        await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "notification_permission", status: status)
        guard previous != current else { return }
        await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "watch_notification_capabilities_refreshed", status: current ? "authorized" : "unauthorized")
        if let lastAlertToken {
            upload(lastAlertToken, pushType: .alert)
        } else {
            WKApplication.shared().registerForRemoteNotifications()
        }
    }

    private func capabilities() -> DeviceCapabilities { .init(voipPush: true, alertPush: true, notificationsAuthorized: notificationsAuthorized, microphoneReady: true) }
    private func registrationFailed(_ error: Error) { let value = error as NSError; Diagnostics.shared.record(role: .A, category: "pushRegistration", value: "failed \(value.domain):\(value.code)"); Task { await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_failed", status: "domain=\(value.domain) code=\(value.code)") } }
    private static func authorizationStatus(_ status: UNAuthorizationStatus, error: Error?) -> String { if error != nil { return "error" }; switch status { case .notDetermined: return "notDetermined"; case .denied: return "denied"; case .authorized: return "authorized"; case .provisional: return "provisional"; case .ephemeral: return "ephemeral"; @unknown default: return "unknown" } }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if let envelope = SecureMessagePushEnvelope.parse(notification.request.content.userInfo) {
            Task { @MainActor in
                if NotificationRuntime.shared.accountStore.accounts.contains(where: { $0.accountID == envelope.accountID }) {
                    await SecureMessageStore.shared.loadMessages(conversationID: envelope.conversationID, accountID: envelope.accountID)
                }
            }
            completionHandler([.banner, .sound])
            return
        }
        guard let envelope = ForegroundIncomingNotification.envelope(from: notification.request.content.userInfo) else { completionHandler([.banner, .sound]); return }
        Task { @MainActor in await self.handle(envelope, voip: false, requestAnswer: false) }
        completionHandler([])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let envelope = SecureMessagePushEnvelope.parse(response.notification.request.content.userInfo) {
            await MainActor.run {
                guard NotificationRuntime.shared.accountStore.accounts.contains(where: { $0.accountID == envelope.accountID }) else { return }
                Task { await SecureMessageStore.shared.loadMessages(conversationID: envelope.conversationID, accountID: envelope.accountID) }
            }
            return
        }
        guard let envelope = IncomingNotificationEnvelope.parse(response.notification.request.content.userInfo) else { return }
        let callID: UUID
        switch envelope { case let .legacy(value): callID = value; case let .account(value, _): callID = value; case let .user(value, _, _): callID = value }
        let actionStatus: String
        if response.actionIdentifier == "REJECT" { actionStatus = "reject" }
        else if response.actionIdentifier == "ACCEPT" { actionStatus = "accept" }
        else { actionStatus = "default" }
        await MainActor.run { NotificationRuntime.shared.callSession.recordLifecycleDiagnostic("watch_alert_action_received", status: actionStatus, callID: callID) }
        await handle(envelope, voip: false, requestAnswer: false)
        let session = await MainActor.run { NotificationRuntime.shared.callSession }
        if response.actionIdentifier == "REJECT" { await session.reject() }
        else if response.actionIdentifier == "ACCEPT" { await session.accept() }
    }

    private func handle(_ envelope: IncomingNotificationEnvelope, voip: Bool, requestAnswer: Bool) async {
        switch envelope {
        case let .legacy(callID):
            if voip { await NotificationRuntime.shared.handleIncomingVoIP(callID: callID) }
            else { await NotificationRuntime.shared.handleIncomingAlert(callID: callID, requestAnswer: requestAnswer) }
        case let .account(callID, accountID):
            if voip { await NotificationRuntime.shared.handleIncomingVoIP(callID: callID, accountID: accountID) }
            else { await NotificationRuntime.shared.handleIncomingAlert(callID: callID, accountID: accountID, requestAnswer: requestAnswer) }
        case let .user(callID, accountID, caller):
            if voip { await NotificationRuntime.shared.handleIncomingUserVoIP(callID: callID, accountID: accountID, caller: caller) }
            else { await NotificationRuntime.shared.handleIncomingUserAlert(callID: callID, accountID: accountID, caller: caller, requestAnswer: requestAnswer) }
        }
    }
}

extension WatchNotificationController: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) { guard type == .voIP else { return }; let token = credentials.token; Task { @MainActor in self.upload(token, pushType: .voip) } }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) { guard type == .voIP else { return }; Task { @MainActor in let token = self.lastVoIPToken; self.lastVoIPToken = nil; self.voipRegistrationTask?.cancel(); await NotificationRuntime.shared.api.invalidateDevice(pushType: .voip, expectedToken: token); await AccountPushRegistrationCoordinator.shared.invalidate(pushType: .voip, expectedToken: token) } }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP, let envelope = VoIPIncomingNotification.envelope(from: payload.dictionaryPayload) else { completion(); return }
        Task { @MainActor in await self.handle(envelope, voip: true, requestAnswer: false); completion() }
    }
    @available(watchOS 26.4, *)
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingVoIPPushWith payload: PKPushPayload, metadata: PKVoIPPushMetadata, withCompletionHandler completion: @escaping @Sendable () -> Void) {
        guard let envelope = VoIPIncomingNotification.envelope(from: payload.dictionaryPayload) else { completion(); return }
        Task { @MainActor in await self.handle(envelope, voip: true, requestAnswer: false); completion() }
    }
}
