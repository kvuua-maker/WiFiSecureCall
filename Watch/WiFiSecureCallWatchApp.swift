import SwiftUI

@main
struct WiFiSecureCallWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchNotificationController.self) private var notificationDelegate
    @StateObject private var session = SIPCallSession()
    @StateObject private var accountStore = SIPAccountStore.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView(session: session)
                .environmentObject(accountStore)
        }
    }
}
