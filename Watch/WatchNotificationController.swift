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
        center.requestAuthorization(options: [.alert, .sound, .timeSensitive]) { granted, error in
            Task { @MainActor in
                Diagnostics.shared.record(
                    role: .A,
                    category: "watchNotificationPermission",
                    value: error == nil ? (granted ? "authorized" : "denied") : "failed"
                )
                guard granted, error == nil else { return }
                Diagnostics.shared.record(role: .A, category: "watchAPNsRegistrationStarted", value: "started")
                WKApplication.shared().registerForRemoteNotifications()
            }
        }
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Diagnostics.shared.record(
            role: .A,
            category: "watchAPNsRegistrationSucceeded",
            value: "prefix=\(hex.prefix(8)) length=\(hex.count)"
        )
        registrationTask?.cancel()
        registrationTask = Task { @MainActor in
            guard let api = NotificationRuntime.shared.api else {
                Diagnostics.shared.record(role: .A, category: "watchAPNsRegistrationFailed", value: "apiUnavailable")
                return
            }
            for attempt in 1...3 {
                do {
                    try await api.registerDevice(token: deviceToken)
                    Diagnostics.shared.record(role: .A, category: "watchAPNsServerRegistrationSucceeded", value: "registered")
                    return
                } catch {
                    if attempt == 3 {
                        Diagnostics.shared.record(role: .A, category: "watchAPNsRegistrationFailed", value: "serverRegistrationFailed")
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        Diagnostics.shared.record(
            role: .A,
            category: "watchAPNsRegistrationFailed",
            value: String(describing: type(of: error))
        )
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["callID"] as? String, let id = UUID(uuidString: value) else { return }
        await MainActor.run {
            if response.actionIdentifier == "REJECT" { Task { _ = try? await NotificationRuntime.shared.api?.mutate("reject", callID: id) } }
            else { Task { await NotificationRuntime.shared.callSession?.handleIncoming(callID: id, requestAnswer: response.actionIdentifier == "ACCEPT") } }
        }
    }
}
