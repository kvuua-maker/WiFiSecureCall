import SwiftUI

@main
struct WiFiSecureCallApp: App {
    @UIApplicationDelegateAdaptor(IOSNotificationController.self) private var notificationDelegate
    @StateObject private var session: CallSession

    init() {
        let runtime = NotificationRuntime.shared
        runtime.configureCallKitFactory { IOSCallKitAdapter() }
        WatchRemoteExecutionProbeDonation.register()
        _session = StateObject(wrappedValue: runtime.callSession)
    }

    var body: some Scene { WindowGroup { IOSRootView(session: session) } }
}
