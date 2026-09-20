import Foundation

@MainActor
final class NotificationRuntime {
    static let shared = NotificationRuntime()
    weak var callSession: CallSession?
    var api: APIClient?
    private init() {}
}

