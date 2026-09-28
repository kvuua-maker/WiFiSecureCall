import SwiftUI

@main
struct WiFiSecureCallWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchNotificationController.self) private var notificationDelegate
    @StateObject private var session: CallSession
    @StateObject private var appleAuthentication: WatchAppleAuthenticationCoordinator

    init() {
        let runtime = NotificationRuntime.shared
        let accountStore = AccountSessionStore.shared
        runtime.configureCallKitFactory { WatchCallKitAdapter() }
        _session = StateObject(wrappedValue: runtime.callSession)
        _appleAuthentication = StateObject(
            wrappedValue: WatchAppleAuthenticationCoordinator(store: accountStore)
        )
    }

    var body: some Scene {
        WindowGroup {
            WatchProductRootView(session: session)
                .environmentObject(appleAuthentication)
        }
    }
}
