import UserNotifications
import WatchKit

@MainActor
final class WatchNotificationController: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    private var registrationTask: Task<Void, Never>?

    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let accept = UNNotificationAction(identifier: "ACCEPT", title: "Accept", options: .foreground)
        let reject = UNNotificationAction(identifier: "REJECT", title: "Reject")
        center.setNotificationCategories([UNNotificationCategory(identifier: "INCOMING_CALL", actions: [accept, reject], intentIdentifiers: [])])
        Diagnostics.shared.record(role: .A, category: "watchAPNsRegistrationStarted", value: "started")
        Task { await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_started", status: "started") }
        WKApplication.shared().registerForRemoteNotifications()
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            center.getNotificationSettings { settings in
                Task { @MainActor in
                    let status = Self.authorizationStatus(settings.authorizationStatus, error: error)
                    Diagnostics.shared.record(role: .A, category: "watchNotificationPermission", value: status)
                    await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "notification_permission", status: status)
                    if settings.authorizationStatus == .denied {
                        Diagnostics.shared.record(role: .A, category: "notificationCapability", value: CallFailure.notificationUnavailable.rawValue)
                    }
                }
            }
        }
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let prefix = String(hex.prefix(8))
        Diagnostics.shared.record(
            role: .A,
            category: "watchAPNsRegistrationSucceeded",
            value: "prefix=\(prefix) length=\(hex.count)"
        )
        registrationTask?.cancel()
        registrationTask = Task { @MainActor in
            await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_succeeded", status: "callback", tokenPrefix: prefix, tokenLength: hex.count)
            for attempt in 1...3 {
                do {
                    try await NotificationRuntime.shared.api.registerDevice(token: deviceToken)
                    Diagnostics.shared.record(role: .A, category: "watchAPNsServerRegistrationSucceeded", value: "registered")
                    return
                } catch {
                    if attempt == 3 {
                        Diagnostics.shared.record(role: .A, category: "watchAPNsRegistrationFailed", value: "serverRegistrationFailed")
                        await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_failed", status: "serverRegistrationFailed")
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        let value = Self.failureValue(error)
        Diagnostics.shared.record(role: .A, category: "watchAPNsRegistrationFailed", value: value)
        Task { await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_failed", status: value) }
    }

    private static func authorizationStatus(_ status: UNAuthorizationStatus, error: Error?) -> String {
        if error != nil { return "error" }
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        @unknown default: return "unknown"
        }
    }

    private static func failureValue(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let outcome = ForegroundIncomingNotification.dispatch(
            userInfo: notification.request.content.userInfo
        ) { callID, requestAnswer in
            Task { @MainActor in
                Diagnostics.shared.record(
                    role: .A,
                    callID: callID,
                    category: "incomingNotification",
                    value: "foreground_received"
                )
                guard let callSession = NotificationRuntime.shared.callSession else {
                    Diagnostics.shared.record(
                        role: .A,
                        callID: callID,
                        category: "incomingNotification",
                        value: "call_session_unavailable"
                    )
                    return
                }
                await callSession.handleIncoming(callID: callID, requestAnswer: requestAnswer)
            }
        }

        switch outcome {
        case .incoming:
            completionHandler([])
        case .invalidCallID:
            Task { @MainActor in
                Diagnostics.shared.record(role: .A, category: "incomingNotification", value: "invalid_call_id")
            }
            completionHandler([.banner, .sound])
        case .unrelated:
            completionHandler([.banner, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["callID"] as? String, let id = UUID(uuidString: value) else { return }
        await MainActor.run {
            if response.actionIdentifier == "REJECT" { Task { _ = try? await NotificationRuntime.shared.api.mutate("reject", callID: id) } }
            else { Task { await NotificationRuntime.shared.callSession?.handleIncoming(callID: id, requestAnswer: response.actionIdentifier == "ACCEPT") } }
        }
    }
}
