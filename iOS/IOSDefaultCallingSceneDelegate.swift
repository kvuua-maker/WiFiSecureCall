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
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        _ = IOSSystemDialCoordinator.shared.handleDefaultCallingActivity(userActivity)
    }
}
