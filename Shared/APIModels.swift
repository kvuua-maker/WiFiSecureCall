import Foundation

enum DeviceRole: String, Codable, Sendable { case A, B }

enum DevicePushType: String, Codable, Sendable { case alert, voip }

enum APNSEnvironment: String, Codable, Sendable { case production, development }

struct DeviceCapabilities: Codable, Sendable, Equatable {
    let voipPush: Bool
    let alertPush: Bool
    let notificationsAuthorized: Bool
    let microphoneReady: Bool
}

struct DeviceRegistrationRequest: Codable, Sendable {
    let requestID: UUID
    let role: DeviceRole
    let token: String
    let invalidatedToken: String?
    let platform: String
    let pushType: DevicePushType
    let installationID: UUID?
    let installationGeneration: UInt64?
    let environment: APNSEnvironment?
    let capabilities: DeviceCapabilities?

    init(
        requestID: UUID,
        role: DeviceRole,
        token: String,
        invalidatedToken: String? = nil,
        platform: String,
        pushType: DevicePushType,
        installationID: UUID? = nil,
        installationGeneration: UInt64? = nil,
        environment: APNSEnvironment? = nil,
        capabilities: DeviceCapabilities? = nil
    ) {
        self.requestID = requestID
        self.role = role
        self.token = token
        self.invalidatedToken = invalidatedToken
        self.platform = platform
        self.pushType = pushType
        self.installationID = installationID
        self.installationGeneration = installationGeneration
        self.environment = environment
        self.capabilities = capabilities
    }
}

struct NotificationDiagnosticRequest: Codable, Sendable {
    let requestID: UUID
    let role: DeviceRole
    let platform: String
    let event: String
    let status: String
    let tokenPrefix: String?
    let tokenLength: Int?
    let stage: String?
    let errorDomain: String?
    let errorCode: Int?
    let callID: UUID?
}

struct CallMutationRequest: Codable, Sendable { let requestID: UUID }

enum CallMutation: String, Codable, Sendable { case accept, reject, cancel, end }

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
    let ringExpiresAt: Date?
    let acceptedAt: Date?
    let terminalAt: Date?
    let terminalReason: String?
    let deliveryStatus: String?
    let peerReady: Bool?
    let createdNew: Bool?
    let mutationApplied: Bool?

    init(
        callID: UUID,
        caller: DeviceRole,
        callee: DeviceRole,
        state: ServerCallState,
        expiresAt: Date,
        mediaToken: String?,
        ringExpiresAt: Date? = nil,
        acceptedAt: Date? = nil,
        terminalAt: Date? = nil,
        terminalReason: String? = nil,
        deliveryStatus: String? = nil,
        peerReady: Bool? = nil,
        createdNew: Bool? = nil,
        mutationApplied: Bool? = nil
    ) {
        self.callID = callID
        self.caller = caller
        self.callee = callee
        self.state = state
        self.expiresAt = expiresAt
        self.mediaToken = mediaToken
        self.ringExpiresAt = ringExpiresAt
        self.acceptedAt = acceptedAt
        self.terminalAt = terminalAt
        self.terminalReason = terminalReason
        self.deliveryStatus = deliveryStatus
        self.peerReady = peerReady
        self.createdNew = createdNew
        self.mutationApplied = mutationApplied
    }
}

struct HealthResponse: Codable, Sendable {
    let ok: Bool
    let apnsConfigured: Bool
    let build: String?
    let mediaReady: Bool?
    let roleAReady: Bool?
    let roleBReady: Bool?
}

struct ServerErrorResponse: Codable, Sendable, Error {
    let error: String
    let currentState: ServerCallState?
    let retryable: Bool?
}
