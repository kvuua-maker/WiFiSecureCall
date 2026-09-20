import SwiftUI

@main
struct WiFiSecureCallWatchApp: App {
    @WKExtensionDelegateAdaptor(WatchNotificationController.self) private var notificationDelegate
    @StateObject private var session: CallSession

    init() {
        let config = AppConfig.load()
        let api = APIClient(config: config)
        let callSession = CallSession(config: config, api: api)
        callSession.attach(callKit: WatchCallKitAdapter())
        NotificationRuntime.shared.callSession = callSession
        NotificationRuntime.shared.api = api
        _session = StateObject(wrappedValue: callSession)
    }
    var body: some Scene { WindowGroup { WatchRootView(session: session) } }
}

