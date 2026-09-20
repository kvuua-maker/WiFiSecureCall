import SwiftUI

@main
struct WiFiSecureCallApp: App {
    @UIApplicationDelegateAdaptor(IOSNotificationController.self) private var notificationDelegate
    @StateObject private var session: CallSession

    init() {
        let config = AppConfig.load()
        let api = NotificationRuntime.shared.api
        let callSession = CallSession(config: config, api: api)
        callSession.attach(callKit: IOSCallKitAdapter())
        NotificationRuntime.shared.callSession = callSession
        _session = StateObject(wrappedValue: callSession)
    }

    var body: some Scene { WindowGroup { IOSRootView(session: session) } }
}
