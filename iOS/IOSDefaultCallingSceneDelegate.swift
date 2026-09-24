import UIKit

@MainActor
final class IOSDefaultCallingSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        for activity in connectionOptions.userActivities {
            _ = IOSSystemDialCoordinator.shared.handleDefaultCallingActivity(activity)
        }
        for context in connectionOptions.urlContexts {
            _ = IOSSystemDialCoordinator.shared.handleDefaultCallingURL(context.url)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        _ = IOSSystemDialCoordinator.shared.handleDefaultCallingActivity(userActivity)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            _ = IOSSystemDialCoordinator.shared.handleDefaultCallingURL(context.url)
        }
    }
}
