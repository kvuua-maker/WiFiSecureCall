import SwiftUI

@main
struct WiFiSecureCallApp: App {
    @UIApplicationDelegateAdaptor(IOSNotificationController.self) private var notificationDelegate
    @StateObject private var session: CallSession

    init() {
        let callSession = NotificationRuntime.shared.install(callKit: IOSCallKitAdapter())
        _session = StateObject(wrappedValue: callSession)
    }

    var body: some Scene { WindowGroup { IOSRootView(session: session) } }
}
