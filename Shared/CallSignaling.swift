import Foundation

enum CallPartySide: String, Codable, Sendable { case caller, callee }

struct CallSignalView: Sendable, Equatable {
    let callID: UUID
    let localSide: CallPartySide
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
    let answeredElsewhere: Bool
    let incomingCallerName: String?

    init(callID: UUID, localSide: CallPartySide, state: ServerCallState, expiresAt: Date, mediaToken: String?, ringExpiresAt: Date?, acceptedAt: Date?, terminalAt: Date?, terminalReason: String?, deliveryStatus: String?, peerReady: Bool?, createdNew: Bool?, mutationApplied: Bool?, answeredElsewhere: Bool = false, incomingCallerName: String? = nil) {
        self.callID = callID; self.localSide = localSide; self.state = state; self.expiresAt = expiresAt; self.mediaToken = mediaToken
        self.ringExpiresAt = ringExpiresAt; self.acceptedAt = acceptedAt; self.terminalAt = terminalAt; self.terminalReason = terminalReason
        self.deliveryStatus = deliveryStatus; self.peerReady = peerReady; self.createdNew = createdNew; self.mutationApplied = mutationApplied
        self.answeredElsewhere = answeredElsewhere; self.incomingCallerName = incomingCallerName
    }
}

enum CallSignalingError: Error { case invalidResponse, missingTarget }

protocol CallSignaling: Sendable {
    var mediaPeerIdentity: MediaPeerIdentity { get }
    var incomingCallerName: String? { get }
    var requiresIncomingReconciliation: Bool { get }
    func create(callID: UUID, requestID: UUID) async throws -> CallSignalView
    func call(_ id: UUID) async throws -> CallSignalView
    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView
}

extension CallSignaling {
    var incomingCallerName: String? { nil }
    var requiresIncomingReconciliation: Bool { false }
}

struct LegacyCallSignaling: CallSignaling {
    let api: APIClient
    let role: DeviceRole
    var mediaPeerIdentity: MediaPeerIdentity { .legacy(role) }

    func create(callID: UUID, requestID: UUID) async throws -> CallSignalView {
        try map(await api.create(callID: callID, requestID: requestID))
    }
    func call(_ id: UUID) async throws -> CallSignalView { try map(await api.call(id)) }
    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView {
        try map(await api.mutate(action, callID: callID, requestID: requestID))
    }
    private func map(_ response: CallResponse) throws -> CallSignalView {
        let side: CallPartySide
        if response.caller == role { side = .caller }
        else if response.callee == role { side = .callee }
        else { throw CallSignalingError.invalidResponse }
        return CallSignalView(callID: response.callID, localSide: side, state: response.state, expiresAt: response.expiresAt, mediaToken: response.mediaToken, ringExpiresAt: response.ringExpiresAt, acceptedAt: response.acceptedAt, terminalAt: response.terminalAt, terminalReason: response.terminalReason, deliveryStatus: response.deliveryStatus, peerReady: response.peerReady, createdNew: response.createdNew, mutationApplied: response.mutationApplied)
    }
}

struct AccountCallSignaling: CallSignaling {
    let client: AccountAPIClient
    let accountID: UUID
    let targetDeviceID: UUID?
    let localSide: CallPartySide
    var mediaPeerIdentity: MediaPeerIdentity { .account(localSide) }

    init(client: AccountAPIClient, accountID: UUID, targetDeviceID: UUID? = nil, localSide: CallPartySide) {
        self.client = client
        self.accountID = accountID
        self.targetDeviceID = targetDeviceID
        self.localSide = localSide
    }

    func create(callID: UUID, requestID: UUID) async throws -> CallSignalView {
        guard let targetDeviceID else { throw CallSignalingError.missingTarget }
        return try map(await client.createCall(accountID: accountID, callID: callID, requestID: requestID, targetDeviceID: targetDeviceID))
    }
    func call(_ id: UUID) async throws -> CallSignalView { try map(await client.call(accountID: accountID, callID: id)) }
    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView {
        try map(await client.mutateCall(accountID: accountID, action: action, callID: callID, requestID: requestID))
    }
    private func map(_ response: AccountCallResponse) throws -> CallSignalView {
        guard response.localSide == localSide else { throw CallSignalingError.invalidResponse }
        return CallSignalView(callID: response.callID, localSide: response.localSide, state: response.state, expiresAt: response.expiresAt, mediaToken: response.mediaToken, ringExpiresAt: response.ringExpiresAt, acceptedAt: response.acceptedAt, terminalAt: response.terminalAt, terminalReason: response.terminalReason, deliveryStatus: response.deliveryStatus, peerReady: response.peerReady, createdNew: response.createdNew, mutationApplied: response.mutationApplied)
    }
}

struct CrossUserCallSignaling: CallSignaling {
    let client: AccountAPIClient
    let accountID: UUID
    let targetUserID: UUID?
    let localSide: CallPartySide
    let pushedCallerIdentity: CrossUserCallerIdentity?
    var mediaPeerIdentity: MediaPeerIdentity { .account(localSide) }
    var incomingCallerName: String? { pushedCallerIdentity?.callKitName }
    var requiresIncomingReconciliation: Bool { true }

    init(client: AccountAPIClient, accountID: UUID, targetUserID: UUID? = nil, localSide: CallPartySide, callerIdentity: CrossUserCallerIdentity? = nil) {
        self.client = client
        self.accountID = accountID
        self.targetUserID = targetUserID
        self.localSide = localSide
        self.pushedCallerIdentity = callerIdentity
    }

    func create(callID: UUID, requestID: UUID) async throws -> CallSignalView {
        guard let targetUserID else { throw CallSignalingError.missingTarget }
        do {
            return try map(await client.createUserCall(accountID: accountID, callID: callID, requestID: requestID, targetUserID: targetUserID))
        } catch let error as AccountAPIError {
            if case let .status(_, response) = error, response?.error == "recipient_unavailable" {
                throw CallFailure.targetUnavailable
            }
            throw error
        }
    }

    func call(_ id: UUID) async throws -> CallSignalView {
        try map(await client.userCall(accountID: accountID, callID: id))
    }

    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView {
        try map(await client.mutateUserCall(accountID: accountID, action: action, callID: callID, requestID: requestID))
    }

    private func map(_ response: CrossUserCallResponse) throws -> CallSignalView {
        guard response.localSide == localSide else { throw CallSignalingError.invalidResponse }
        let answeredElsewhere = response.legState == .answeredElsewhere
        let callerName = response.caller?.callKitName ?? pushedCallerIdentity?.callKitName
        return CallSignalView(
            callID: response.callID, localSide: response.localSide, state: response.state, expiresAt: response.expiresAt,
            mediaToken: answeredElsewhere ? nil : response.mediaToken, ringExpiresAt: response.ringExpiresAt,
            acceptedAt: response.acceptedAt, terminalAt: response.terminalAt, terminalReason: response.terminalReason,
            deliveryStatus: response.deliveryStatus, peerReady: response.peerReady, createdNew: response.createdNew,
            mutationApplied: response.mutationApplied, answeredElsewhere: answeredElsewhere, incomingCallerName: callerName
        )
    }
}
