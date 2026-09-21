import Foundation

enum CallState: Equatable, Sendable {
    case idle
    case outgoingRinging(UUID)
    case incomingRinging(UUID)
    case connecting(UUID)
    case active(UUID)
    case reconnecting(UUID)
    case ending(UUID)
    case ended(UUID)
    case failed(UUID?, CallFailure)

    var callID: UUID? {
        switch self {
        case .idle: return nil
        case let .outgoingRinging(id), let .incomingRinging(id), let .connecting(id),
             let .active(id), let .reconnecting(id), let .ending(id), let .ended(id): return id
        case let .failed(id, _): return id
        }
    }

    var isTerminal: Bool {
        if case .ended = self { return true }
        if case .failed = self { return true }
        return false
    }
}

enum CallStateTransition {
    static func isLegal(from: CallState, to: CallState) -> Bool {
        if from == to { return true }
        if let fromID = from.callID, let toID = to.callID, fromID != toID { return false }
        switch (from, to) {
        case (.idle, .outgoingRinging), (.idle, .incomingRinging),
             (.outgoingRinging, .connecting), (.outgoingRinging, .ending),
             (.incomingRinging, .connecting), (.incomingRinging, .ending),
             (.connecting, .active), (.connecting, .ending),
             (.active, .reconnecting), (.active, .ending),
             (.reconnecting, .active), (.reconnecting, .ending),
             (.ending, .ended), (.ended, .idle), (.failed, .idle):
            return true
        case (.idle, .failed(nil, _)):
            return true
        case (_, .failed(let id, _)):
            return !from.isTerminal && id == from.callID
        default:
            return false
        }
    }
}
