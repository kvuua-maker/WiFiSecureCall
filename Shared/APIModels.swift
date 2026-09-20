import Foundation

enum DeviceRole: String, Codable, Sendable { case A, B }

struct DeviceRegistrationRequest: Codable, Sendable {
    let requestID: UUID
    let role: DeviceRole
    let token: String
    let platform: String
}

struct CallMutationRequest: Codable, Sendable { let requestID: UUID }

struct CreateCallRequest: Codable, Sendable {
    let requestID: UUID
    let callID: UUID
}

enum ServerCallState: String, Codable, Sendable {
    case ringing, accepted, rejected, cancelled, expired, ended
}

struct CallResponse: Codable, Sendable, Equatable {
    let callID: UUID
    let caller: DeviceRole
    let callee: DeviceRole
    let state: ServerCallState
    let expiresAt: Date
    let mediaToken: String?
}

struct HealthResponse: Codable, Sendable {
    let ok: Bool
    let apnsConfigured: Bool
}

struct ServerErrorResponse: Codable, Sendable { let error: String }

