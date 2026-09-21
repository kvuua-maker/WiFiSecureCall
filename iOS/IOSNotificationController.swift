import UIKit
import UserNotifications

@MainActor
final class IOSNotificationController: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var registrationTask: Task<Void, Never>?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let accept = UNNotificationAction(identifier: "ACCEPT", title: "Accept", options: .foreground)
        let reject = UNNotificationAction(identifier: "REJECT", title: "Reject")
        center.setNotificationCategories([UNNotificationCategory(identifier: "INCOMING_CALL", actions: [accept, reject], intentIdentifiers: [])])
        Diagnostics.shared.record(role: .B, category: "iPhoneAPNsRegistrationStarted", value: "started")
        Task { await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_started", status: "started") }
        application.registerForRemoteNotifications()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            center.getNotificationSettings { settings in
                Task { @MainActor in
                    let status = Self.authorizationStatus(settings.authorizationStatus, error: error)
                    Diagnostics.shared.record(role: .B, category: "iPhoneNotificationPermission", value: status)
                    await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "notification_permission", status: status)
                    if settings.authorizationStatus == .denied {
                        Diagnostics.shared.record(role: .B, category: "notificationCapability", value: CallFailure.notificationUnavailable.rawValue)
                    }
                }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        upload(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let value = Self.failureValue(error)
        Diagnostics.shared.record(role: .B, category: "iPhoneAPNsRegistrationFailed", value: value)
        Task { await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_failed", status: value) }
    }

    private func upload(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let prefix = String(hex.prefix(8))
        Diagnostics.shared.record(role: .B, category: "iPhoneAPNsRegistrationSucceeded", value: "prefix=\(prefix) length=\(hex.count)")
        registrationTask?.cancel()
        registrationTask = Task { @MainActor in
            await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_succeeded", status: "callback", tokenPrefix: prefix, tokenLength: hex.count)
            for attempt in 1...3 {
                do {
                    try await NotificationRuntime.shared.api.registerDevice(token: deviceToken)
                    Diagnostics.shared.record(role: .B, category: "iPhoneAPNsServerRegistrationSucceeded", value: "registered")
                    return
                } catch {
                    if attempt == 3 {
                        Diagnostics.shared.record(role: .B, category: "iPhoneAPNsRegistrationFailed", value: "serverRegistrationFailed")
                        await NotificationRuntime.shared.api.reportNotificationDiagnostic(event: "apns_registration_failed", status: "serverRegistrationFailed")
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private static func authorizationStatus(_ status: UNAuthorizationStatus, error: Error?) -> String {
        if error != nil { return "error" }
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func failureValue(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["callID"] as? String, let id = UUID(uuidString: value) else { return }
        await MainActor.run {
            if response.actionIdentifier == "REJECT" { Task { _ = try? await NotificationRuntime.shared.api.mutate("reject", callID: id) } }
            else { Task { await NotificationRuntime.shared.callSession?.handleIncoming(callID: id, requestAnswer: response.actionIdentifier == "ACCEPT") } }
        }
    }
}
