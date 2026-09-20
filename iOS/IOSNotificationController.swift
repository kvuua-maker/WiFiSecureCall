import UIKit
import UserNotifications

@MainActor
final class IOSNotificationController: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        let accept = UNNotificationAction(identifier: "ACCEPT", title: "Accept", options: .foreground)
        let reject = UNNotificationAction(identifier: "REJECT", title: "Reject")
        center.setNotificationCategories([UNNotificationCategory(identifier: "INCOMING_CALL", actions: [accept, reject], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in if granted { DispatchQueue.main.async { application.registerForRemoteNotifications() } } }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) { Task { try? await NotificationRuntime.shared.api?.registerDevice(token: deviceToken) } }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["callID"] as? String, let id = UUID(uuidString: value) else { return }
        await MainActor.run {
            if response.actionIdentifier == "REJECT" { Task { _ = try? await NotificationRuntime.shared.api?.mutate("reject", callID: id) } }
            else { Task { await NotificationRuntime.shared.callSession?.handleIncoming(callID: id, requestAnswer: response.actionIdentifier == "ACCEPT") } }
        }
    }
}
