import SwiftUI

@main
struct WiFiSecureCallApp: App {
    @UIApplicationDelegateAdaptor(IOSNotificationController.self) private var notificationDelegate
    @StateObject private var session: CallSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let runtime = NotificationRuntime.shared
        runtime.configureCallKitFactory { IOSCallKitAdapter() }
        ContactsToWatchSync.shared.activate()
        _ = LocalContactsStore.shared
        WatchRemoteExecutionProbeDonation.register()
        _session = StateObject(wrappedValue: runtime.callSession)
    }

    var body: some Scene {
        WindowGroup { IOSProductRootView(session: session) }
            .onChange(of: scenePhase) { phase in
                if phase == .active { LocalContactsStore.shared.refreshAuthorizationAndContacts() }
            }
    }
}
