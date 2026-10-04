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
            WatchRootView(session: session)
                .environmentObject(appleAuthentication)
#if DEBUG
                // Only typography is overridden: UI tests still tap the production views/actions.
                // Simulator's `simctl ui content_size` is unsupported for watchOS 26.5.
                .transformEnvironment(\.dynamicTypeSize) { size in
                    if ProcessInfo.processInfo.arguments.contains("--uitest-large-text") {
                        size = .xxxLarge
                    }
                }
#endif
        }
    }
}
