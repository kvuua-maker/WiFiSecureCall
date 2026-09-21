import PushKit
@preconcurrency import UserNotifications
import WatchKit

@MainActor
final class WatchNotificationController: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    private var alertRegistrationTask: Task<Void, Never>?
    private var voipRegistrationTask: Task<Void, Never>?
    private var voipRegistry: PKPushRegistry?
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
            center.getNotificationSettings { settings in Task { @MainActor in
                self.notificationsAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                let status = Self.authorizationStatus(settings.authorizationStatus, error: error)
                Diagnostics.shared.record(role: .A, category: "notificationPermission", value: status)
                await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "notification_permission", status: status)
            } }
        }
    }

    func didRegisterForRemoteNotifications(withDeviceToken token: Data) { upload(token, pushType: .alert) }
    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) { registrationFailed(error) }
    private func configureVoIPPushes() { let registry = PKPushRegistry(queue: .main); registry.delegate = self; registry.desiredPushTypes = [.voIP]; voipRegistry = registry }

    private func upload(_ token: Data, pushType: DevicePushType) {
        if pushType == .voip { lastVoIPToken = token }
        let task = Task { @MainActor in
            await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_succeeded", status: "\(pushType.rawValue)_callback")
            for attempt in 1...3 {
                do {
                    try Task.checkCancellation()
                    try await NotificationRuntime.shared.api.registerDevice(token: token, pushType: pushType, capabilities: capabilities())
                    Diagnostics.shared.record(role: .A, category: "pushRegistration", value: "\(pushType.rawValue)_registered")
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

    private func capabilities() -> DeviceCapabilities { .init(voipPush: true, alertPush: true, notificationsAuthorized: notificationsAuthorized, microphoneReady: true) }
    private func registrationFailed(_ error: Error) { let value = error as NSError; Diagnostics.shared.record(role: .A, category: "pushRegistration", value: "failed \(value.domain):\(value.code)"); Task { await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_failed", status: "domain=\(value.domain) code=\(value.code)") } }
    private static func authorizationStatus(_ status: UNAuthorizationStatus, error: Error?) -> String { if error != nil { return "error" }; switch status { case .notDetermined: return "notDetermined"; case .denied: return "denied"; case .authorized: return "authorized"; case .provisional: return "provisional"; @unknown default: return "unknown" } }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        switch ForegroundIncomingNotification.outcome(from: notification.request.content.userInfo) {
        case let .incoming(callID): Task { @MainActor in await NotificationRuntime.shared.handleIncomingAlert(callID: callID, requestAnswer: false) }; completionHandler([])
        case .invalidCallID, .unrelated: completionHandler([.banner, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let callID = VoIPIncomingNotification.callID(from: response.notification.request.content.userInfo) ?? ForegroundIncomingNotification.callID(from: response.notification.request.content.userInfo) else { return }
        await NotificationRuntime.shared.handleIncomingAlert(callID: callID, requestAnswer: false)
        let session = await MainActor.run { NotificationRuntime.shared.callSession }
        if response.actionIdentifier == "REJECT" { await session.reject() }
        else if response.actionIdentifier == "ACCEPT" { await session.accept() }
    }
}

extension WatchNotificationController: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) { guard type == .voIP else { return }; let token = credentials.token; Task { @MainActor in self.upload(token, pushType: .voip) } }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) { guard type == .voIP else { return }; Task { @MainActor in let token = self.lastVoIPToken; self.lastVoIPToken = nil; self.voipRegistrationTask?.cancel(); await NotificationRuntime.shared.api.invalidateDevice(pushType: .voip, expectedToken: token) } }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP, let callID = VoIPIncomingNotification.callID(from: payload.dictionaryPayload) else { completion(); return }
        Task { @MainActor in await NotificationRuntime.shared.handleIncomingVoIP(callID: callID); completion() }
    }
    @available(watchOS 26.4, *)
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingVoIPPushWith payload: PKPushPayload, metadata: PKVoIPPushMetadata, withCompletionHandler completion: @escaping @Sendable () -> Void) {
        guard let callID = VoIPIncomingNotification.callID(from: payload.dictionaryPayload) else { completion(); return }
        Task { @MainActor in await NotificationRuntime.shared.handleIncomingVoIP(callID: callID); completion() }
    }
}
