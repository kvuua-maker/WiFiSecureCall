import Foundation

@MainActor
final class NotificationRuntime {
    static let shared = NotificationRuntime()
    weak var callSession: CallSession?
    let api: APIClient

    private init() {
        api = APIClient(config: AppConfig.load())
    }
}
