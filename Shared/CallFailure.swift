import Foundation

enum CallFailure: String, Codable, Error, Equatable, Sendable {
    case permissionDenied
    case serverUnavailable
    case callExpired
    case callRejected
    case callCancelled
    case callKitRejected
    case audioActivationTimeout
    case callKitReactivationFailed
    case audioFailed
    case mediaConnectionFailed
    case networkLost
    case invalidServerState
    case notificationUnavailable
    case accountSessionInvalid
    case accountMutationInProgress
    case targetUnavailable
    case targetAmbiguous
    case answeredElsewhere
}
