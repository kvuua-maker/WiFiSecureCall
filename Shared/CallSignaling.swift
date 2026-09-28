import CryptoKit
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
    let audioKeys: CallAudioKeys?

    init(callID: UUID, localSide: CallPartySide, state: ServerCallState, expiresAt: Date, mediaToken: String?, ringExpiresAt: Date?, acceptedAt: Date?, terminalAt: Date?, terminalReason: String?, deliveryStatus: String?, peerReady: Bool?, createdNew: Bool?, mutationApplied: Bool?, answeredElsewhere: Bool = false, incomingCallerName: String? = nil, audioKeys: CallAudioKeys? = nil) {
        self.callID = callID; self.localSide = localSide; self.state = state; self.expiresAt = expiresAt; self.mediaToken = mediaToken
        self.ringExpiresAt = ringExpiresAt; self.acceptedAt = acceptedAt; self.terminalAt = terminalAt; self.terminalReason = terminalReason
        self.deliveryStatus = deliveryStatus; self.peerReady = peerReady; self.createdNew = createdNew; self.mutationApplied = mutationApplied
        self.answeredElsewhere = answeredElsewhere; self.incomingCallerName = incomingCallerName
        self.audioKeys = audioKeys
    }
}

enum CallSignalingError: Error { case invalidResponse, missingTarget }

protocol CallSignaling: Sendable {
    var mediaPeerIdentity: MediaPeerIdentity { get }
    var historyAccountID: UUID? { get }
    var incomingCallerName: String? { get }
    var historyPeerDisplayName: String? { get }
    var requiresIncomingReconciliation: Bool { get }
    func create(callID: UUID, requestID: UUID) async throws -> CallSignalView
    func call(_ id: UUID) async throws -> CallSignalView
    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView
    func eraseSecrets()
}

extension CallSignaling {
    var historyAccountID: UUID? { nil }
    var incomingCallerName: String? { nil }
    var historyPeerDisplayName: String? { incomingCallerName }
    var requiresIncomingReconciliation: Bool { false }
    func eraseSecrets() {}
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
    var historyAccountID: UUID? { accountID }
    var historyPeerDisplayName: String? { "Linked device" }

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

final class CrossUserCallSignaling: CallSignaling, @unchecked Sendable {
    let client: AccountAPIClient
    let accountID: UUID
    let targetUserID: UUID?
    let localSide: CallPartySide
    let pushedCallerIdentity: CrossUserCallerIdentity?
    let targetDisplayName: String?
    private let identityStore: E2EEIdentityStore
    private let pinStore: E2EEIdentityPinStore
    private let lock = NSLock()
    private var ephemeralByCall: [UUID: Curve25519.KeyAgreement.PrivateKey] = [:]
    var mediaPeerIdentity: MediaPeerIdentity { .secureAccount(localSide) }
    var historyAccountID: UUID? { accountID }
    var incomingCallerName: String? { pushedCallerIdentity?.callKitName }
    var historyPeerDisplayName: String? { localSide == .caller ? targetDisplayName : pushedCallerIdentity?.callKitName }
    var requiresIncomingReconciliation: Bool { true }

    init(client: AccountAPIClient, accountID: UUID, targetUserID: UUID? = nil, targetDisplayName: String? = nil, localSide: CallPartySide, callerIdentity: CrossUserCallerIdentity? = nil, identityStore: E2EEIdentityStore = E2EEIdentityStore(), pinStore: E2EEIdentityPinStore = E2EEIdentityPinStore()) {
        self.client = client
        self.accountID = accountID
        self.targetUserID = targetUserID
        self.targetDisplayName = targetDisplayName
        self.localSide = localSide
        self.pushedCallerIdentity = callerIdentity
        self.identityStore = identityStore
        self.pinStore = pinStore
    }

    func create(callID: UUID, requestID: UUID) async throws -> CallSignalView {
        guard let targetUserID else { throw CallSignalingError.missingTarget }
        do {
            let package = try await localPackage(callID: callID, side: .caller)
            return try await map(await client.createUserCall(accountID: accountID, callID: callID, requestID: requestID, targetUserID: targetUserID, callerKeyPackage: package), expectedCallID: callID)
        } catch let error as AccountAPIError {
            if case let .status(_, response) = error, response?.error == "recipient_unavailable" {
                throw CallFailure.targetUnavailable
            }
            throw error
        }
    }

    func call(_ id: UUID) async throws -> CallSignalView {
        try await map(await client.userCall(accountID: accountID, callID: id), expectedCallID: id)
    }

    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView {
        let package = action == .accept ? try await localPackage(callID: callID, side: .callee) : nil
        return try await map(await client.mutateUserCall(accountID: accountID, action: action, callID: callID, requestID: requestID, calleeKeyPackage: package), expectedCallID: callID)
    }

    private func map(_ response: CrossUserCallResponse, expectedCallID: UUID) async throws -> CallSignalView {
        guard response.callID == expectedCallID, response.localSide == localSide else { throw CallSignalingError.invalidResponse }
        let answeredElsewhere = response.legState == .answeredElsewhere
        let callerName = response.caller?.callKitName ?? pushedCallerIdentity?.callKitName
        var audioKeys: CallAudioKeys?
        let hasKeyMaterial = response.callerKeyPackage != nil || response.calleeKeyPackage != nil
        let expectedIdentities = hasKeyMaterial ? try await authoritativeIdentities(response, answeredElsewhere: answeredElsewhere) : nil
        if let callerPackage = response.callerKeyPackage {
            guard let expectedIdentities else { throw CallSignalingError.invalidResponse }
            try await verify(
                callerPackage, expectedCallID: expectedCallID, expectedSide: .caller,
                expectedUserID: expectedIdentities.callerUserID,
                expectedDeviceID: expectedIdentities.callerDeviceID
            )
        }
        if let calleePackage = response.calleeKeyPackage {
            guard let expectedIdentities, let calleeDeviceID = expectedIdentities.calleeDeviceID else {
                throw CallSignalingError.invalidResponse
            }
            try await verify(
                calleePackage, expectedCallID: expectedCallID, expectedSide: .callee,
                expectedUserID: expectedIdentities.calleeUserID,
                expectedDeviceID: calleeDeviceID
            )
        }
        if response.state == .accepted, !answeredElsewhere, response.mediaToken != nil,
           let callerPackage = response.callerKeyPackage, let calleePackage = response.calleeKeyPackage,
           response.calleeDeviceID == calleePackage.deviceID,
           let ephemeral = lock.wscLocked({ ephemeralByCall[response.callID] }) {
            audioKeys = try E2EECallKeyAgreement.derive(localSide: localSide, localEphemeral: ephemeral, caller: callerPackage, callee: calleePackage)
        }
        return CallSignalView(
            callID: response.callID, localSide: response.localSide, state: response.state, expiresAt: response.expiresAt,
            mediaToken: answeredElsewhere ? nil : response.mediaToken, ringExpiresAt: response.ringExpiresAt,
            acceptedAt: response.acceptedAt, terminalAt: response.terminalAt, terminalReason: response.terminalReason,
            deliveryStatus: response.deliveryStatus, peerReady: response.peerReady, createdNew: response.createdNew,
            mutationApplied: response.mutationApplied, answeredElsewhere: answeredElsewhere, incomingCallerName: callerName,
            audioKeys: audioKeys
        )
    }

    func eraseSecrets() { lock.wscLocked { ephemeralByCall.removeAll(keepingCapacity: false) } }

    private func localPackage(callID: UUID, side: CallPartySide) async throws -> E2EECallKeyPackage {
        let profile = try await client.userProfile(accountID: accountID)
        let identity = try identityStore.identity()
        _ = try await client.registerDeviceKey(accountID: accountID, request: identity.registration(requestID: UUID()))
        let ephemeral = lock.wscLocked { () -> Curve25519.KeyAgreement.PrivateKey in
            if let value = ephemeralByCall[callID] { return value }
            let value = Curve25519.KeyAgreement.PrivateKey(); ephemeralByCall[callID] = value; return value
        }
        return try E2EECallKeyAgreement.makePackage(callID: callID, userID: profile.userID, identity: identity, side: side, ephemeral: ephemeral)
    }

    private func authoritativeIdentities(_ response: CrossUserCallResponse, answeredElsewhere: Bool) async throws -> (callerUserID: UUID, callerDeviceID: UUID, calleeUserID: UUID, calleeDeviceID: UUID?) {
        guard let callerUserID = response.callerUserID,
              let callerDeviceID = response.callerDeviceID,
              let calleeUserID = response.calleeUserID else {
            throw CallSignalingError.invalidResponse
        }
        let profile = try await client.userProfile(accountID: accountID)
        let localIdentity = try identityStore.identity()
        if localSide == .caller {
            guard callerUserID == profile.userID, callerDeviceID == localIdentity.deviceID,
                  calleeUserID == targetUserID else {
                throw CallSignalingError.invalidResponse
            }
        } else {
            guard calleeUserID == profile.userID,
                  answeredElsewhere || response.calleeDeviceID == nil || response.calleeDeviceID == localIdentity.deviceID,
                  let pushedCallerIdentity else {
                throw CallSignalingError.invalidResponse
            }
            let resolvedCaller = try await client.resolveRecipient(pushedCallerIdentity.publicIdentity, accountID: accountID)
            guard resolvedCaller.userID == callerUserID else {
                throw CallSignalingError.invalidResponse
            }
        }
        return (callerUserID, callerDeviceID, calleeUserID, response.calleeDeviceID)
    }

    private func verify(
        _ package: E2EECallKeyPackage,
        expectedCallID: UUID,
        expectedSide: CallPartySide,
        expectedUserID: UUID,
        expectedDeviceID: UUID
    ) async throws {
        let bundles = try await client.deviceKeys(accountID: accountID, userID: expectedUserID)
        guard let bundle = bundles.first(where: { $0.deviceID == package.deviceID }) else { throw E2EEKeyAgreementError.invalidIdentity }
        let pinned = try pinStore.pinnedBundle(userID: expectedUserID, deviceID: bundle.deviceID, accountID: accountID)
        guard try pinStore.evaluate(userID: expectedUserID, bundle: bundle, accountID: accountID) != .keyChanged else {
            if let pinned {
                await E2EEKeyChangeRegistry.shared.record(.init(
                    accountID: accountID,
                    userID: expectedUserID,
                    deviceID: bundle.deviceID,
                    pinnedFingerprint: pinned.fingerprint,
                    observedFingerprint: bundle.fingerprint,
                    observedBundle: bundle
                ))
            }
            throw E2EEKeyAgreementError.keyChanged
        }
        await E2EEKeyChangeRegistry.shared.clear(accountID: accountID, userID: expectedUserID, deviceID: bundle.deviceID)
        try E2EECallKeyAgreement.verify(
            package, identity: bundle, expectedCallID: expectedCallID, expectedSide: expectedSide,
            expectedUserID: expectedUserID, expectedDeviceID: expectedDeviceID
        )
    }
}
