import SwiftUI

@main
struct WiFiSecureCallWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchNotificationController.self) private var notificationDelegate
    @StateObject private var session: CallSession

    init() {
        let callSession = NotificationRuntime.shared.install(callKit: WatchCallKitAdapter())
        _session = StateObject(wrappedValue: callSession)
    }
    var body: some Scene { WindowGroup { WatchRootView(session: session) } }
}
