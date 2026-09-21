import SwiftUI

@main
struct WiFiSecureCallWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchNotificationController.self) private var notificationDelegate
    @StateObject private var session: CallSession

    init() {
        let runtime = NotificationRuntime.shared
        runtime.configureCallKitFactory { WatchCallKitAdapter() }
        _session = StateObject(wrappedValue: runtime.callSession)
    }
    var body: some Scene { WindowGroup { WatchRootView(session: session) } }
}
