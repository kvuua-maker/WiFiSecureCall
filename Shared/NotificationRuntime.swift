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

enum ForegroundIncomingNotification {
    enum Outcome: Equatable {
        case unrelated
        case invalidCallID
        case incoming(UUID)
    }

    static func outcome(from userInfo: [AnyHashable: Any]) -> Outcome {
        guard userInfo["event"] as? String == "incoming_call" else {
            return .unrelated
        }
        guard
            let value = userInfo["callID"] as? String,
            let callID = UUID(uuidString: value)
        else {
            return .invalidCallID
        }
        return .incoming(callID)
    }

    @discardableResult
    static func dispatch(
        userInfo: [AnyHashable: Any],
        incoming: (UUID, Bool) -> Void
    ) -> Outcome {
        let result = outcome(from: userInfo)
        if case .incoming(let callID) = result {
            incoming(callID, false)
        }
        return result
    }
}
