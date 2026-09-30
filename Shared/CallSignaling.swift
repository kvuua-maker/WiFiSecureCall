import CryptoKit
import Foundation

actor AccountE2EEContext {
    static let shared = AccountE2EEContext()
    private struct Timed<T> { let value: T; let expires: Date }
    private var profiles: [String: Timed<UserProfile>] = [:]
    private var bundles: [String: Timed<[E2EEPublicDeviceBundle]>] = [:]
    private var profileTasks: [String: Task<UserProfile, Error>] = [:]
    private var bundleTasks: [String: Task<[E2EEPublicDeviceBundle], Error>] = [:]
    private var registrations: [String: Date] = [:]
    private var registrationTasks: [String: Task<Void, Error>] = [:]
    private var accountEpochs: [UUID: UInt64] = [:]

    func profile(client: AccountAPIClient, accountID: UUID) async throws -> UserProfile {
        let key = cacheKey(client: client, accountID: accountID)
        let epoch = accountEpochs[accountID, default: 0]
        if let cached = profiles[key], cached.expires > Date() { return cached.value }
        if let task = profileTasks[key] { return try await task.value }
        let task = Task { try await client.userProfile(accountID: accountID) }
        profileTasks[key] = task
        defer { profileTasks.removeValue(forKey: key) }
        let value = try await task.value
        guard accountEpochs[accountID, default: 0] == epoch else { throw CancellationError() }
        profiles[key] = .init(value: value, expires: Date().addingTimeInterval(30))
        return value
    }

    func ensureRegistered(client: AccountAPIClient, accountID: UUID, identity: E2EEDeviceIdentity) async throws {
        let key = "\(cacheKey(client: client, accountID: accountID)):\(identity.deviceID.uuidString):\(identity.keyVersion):\(identity.publicBundle.fingerprint)"
        let epoch = accountEpochs[accountID, default: 0]
        if let confirmed = registrations[key], Date().timeIntervalSince(confirmed) < 60 { return }
        if let task = registrationTasks[key] { return try await task.value }
        let task = Task { _ = try await client.registerDeviceKey(accountID: accountID, request: identity.registration(requestID: UUID())) }
        registrationTasks[key] = task
        defer { registrationTasks.removeValue(forKey: key) }
        try await task.value
        guard accountEpochs[accountID, default: 0] == epoch else { throw CancellationError() }
        registrations[key] = Date()
    }

    func deviceKeys(client: AccountAPIClient, accountID: UUID, userID: UUID) async throws -> [E2EEPublicDeviceBundle] {
        let key = "\(cacheKey(client: client, accountID: accountID)):\(userID.uuidString)"
        let epoch = accountEpochs[accountID, default: 0]
        if let cached = bundles[key], cached.expires > Date() { return cached.value }
        if let task = bundleTasks[key] { return try await task.value }
        let task = Task { try await client.deviceKeys(accountID: accountID, userID: userID) }
        bundleTasks[key] = task
        defer { bundleTasks.removeValue(forKey: key) }
        let value = try await task.value
        guard accountEpochs[accountID, default: 0] == epoch else { throw CancellationError() }
        bundles[key] = .init(value: value, expires: Date().addingTimeInterval(15))
        return value
    }

    func invalidate(accountID: UUID) {
        accountEpochs[accountID, default: 0] &+= 1
        let marker = ":" + accountID.uuidString
        for key in profileTasks.keys.filter({ $0.hasSuffix(marker) }) { profileTasks.removeValue(forKey: key)?.cancel() }
        for key in bundleTasks.keys.filter({ $0.contains(marker + ":") }) { bundleTasks.removeValue(forKey: key)?.cancel() }
        for key in registrationTasks.keys.filter({ $0.contains(marker + ":") }) { registrationTasks.removeValue(forKey: key)?.cancel() }
        profiles = profiles.filter { !$0.key.hasSuffix(":" + accountID.uuidString) }
        bundles = bundles.filter { !$0.key.contains(":" + accountID.uuidString + ":") }
        registrations = registrations.filter { !$0.key.contains(":" + accountID.uuidString + ":") }
    }

    private func cacheKey(client: AccountAPIClient, accountID: UUID) -> String {
        "\(ObjectIdentifier(client).hashValue):\(accountID.uuidString)"
    }
}

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

enum CallSignalingError: Error {
    case invalidResponse
    case missingTarget
    case postCommitValidation(callID: UUID, state: ServerCallState, mutationApplied: Bool?, reason: String)
}

protocol CallSignaling: Sendable {
    var mediaPeerIdentity: MediaPeerIdentity { get }
    var historyAccountID: UUID? { get }
    var incomingCallerName: String? { get }
    var historyPeerDisplayName: String? { get }
    var historyTargetUserID: UUID? { get }
    var requiresIncomingReconciliation: Bool { get }
    func create(callID: UUID, requestID: UUID) async throws -> CallSignalView
    func call(_ id: UUID) async throws -> CallSignalView
    func rawCall(_ id: UUID) async throws -> CallSignalView
    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView
    func eraseSecrets()
}

extension CallSignaling {
    var historyAccountID: UUID? { nil }
    var incomingCallerName: String? { nil }
    var historyPeerDisplayName: String? { incomingCallerName }
    var historyTargetUserID: UUID? { nil }
    var requiresIncomingReconciliation: Bool { false }
    func rawCall(_ id: UUID) async throws -> CallSignalView { try await call(id) }
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

final class AccountCallSignaling: CallSignaling, @unchecked Sendable {
    let client: AccountAPIClient
    let accountID: UUID
    let targetDeviceID: UUID?
    let localSide: CallPartySide
    private let identityStore: E2EEIdentityStore
    private let pinStore: E2EEIdentityPinStore
    private let lock = NSLock()
    private var ephemeralByCall: [UUID: Curve25519.KeyAgreement.PrivateKey] = [:]
    private var secureMode = false
    var mediaPeerIdentity: MediaPeerIdentity { lock.wscLocked { secureMode } ? .secureAccount(localSide) : .account(localSide) }
    var historyAccountID: UUID? { accountID }
    var historyPeerDisplayName: String? { "Зв’язаний пристрій" }
    var requiresIncomingReconciliation: Bool { true }

    init(client: AccountAPIClient, accountID: UUID, targetDeviceID: UUID? = nil, localSide: CallPartySide, identityStore: E2EEIdentityStore = E2EEIdentityStore(), pinStore: E2EEIdentityPinStore = E2EEIdentityPinStore()) {
        self.client = client
        self.accountID = accountID
        self.targetDeviceID = targetDeviceID
        self.localSide = localSide
        self.identityStore = identityStore
        self.pinStore = pinStore
    }

    func create(callID: UUID, requestID: UUID) async throws -> CallSignalView {
        guard let targetDeviceID else { throw CallSignalingError.missingTarget }
        let package = try await localPackage(callID: callID, side: .caller)
        lock.wscLocked { secureMode = true }
        return try await map(await client.createCall(accountID: accountID, callID: callID, requestID: requestID, targetDeviceID: targetDeviceID, callerKeyPackage: package), expectedCallID: callID)
    }
    func call(_ id: UUID) async throws -> CallSignalView { try await map(await client.call(accountID: accountID, callID: id), expectedCallID: id) }
    func rawCall(_ id: UUID) async throws -> CallSignalView { try rawMap(await client.call(accountID: accountID, callID: id), expectedCallID: id) }
    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView {
        var package: E2EECallKeyPackage?
        if action == .accept {
            let current = try await client.call(accountID: accountID, callID: callID)
            if current.callerKeyPackage != nil { package = try await localPackage(callID: callID, side: .callee) }
        }
        let response = try await client.mutateCall(accountID: accountID, action: action, callID: callID, requestID: requestID, calleeKeyPackage: package)
        do { return try await map(response, expectedCallID: callID) }
        catch {
            if action == .accept, response.state == .accepted {
                throw CallSignalingError.postCommitValidation(callID: response.callID, state: response.state, mutationApplied: response.mutationApplied, reason: "secure_media_validation_failed")
            }
            throw error
        }
    }
    private func map(_ response: AccountCallResponse, expectedCallID: UUID) async throws -> CallSignalView {
        guard response.callID == expectedCallID, response.localSide == localSide else { throw CallSignalingError.invalidResponse }
        if response.state != .ringing && response.state != .accepted { return try rawMap(response, expectedCallID: expectedCallID) }
        let hasKeys = response.callerKeyPackage != nil || response.calleeKeyPackage != nil
        let requiresSecureProtocol = lock.wscLocked { secureMode } || hasKeys
        if requiresSecureProtocol { lock.wscLocked { secureMode = true } }
        var audioKeys: CallAudioKeys?
        if requiresSecureProtocol {
            guard let caller = response.callerKeyPackage,
                  let callerUserID = response.callerUserID, let callerDeviceID = response.callerDeviceID,
                  let calleeUserID = response.calleeUserID, let calleeDeviceID = response.calleeDeviceID,
                  callerUserID == calleeUserID else { throw CallSignalingError.invalidResponse }
            let profile = try await AccountE2EEContext.shared.profile(client: client, accountID: accountID)
            let identity = try identityStore.identity()
            guard profile.userID == callerUserID,
                  (localSide == .caller ? callerDeviceID : calleeDeviceID) == identity.deviceID,
                  targetDeviceID == nil || (localSide == .caller && targetDeviceID == calleeDeviceID) else { throw CallSignalingError.invalidResponse }
            try await verify(caller, expectedCallID: expectedCallID, expectedSide: .caller, expectedUserID: callerUserID, expectedDeviceID: callerDeviceID)
            if let callee = response.calleeKeyPackage {
                try await verify(callee, expectedCallID: expectedCallID, expectedSide: .callee, expectedUserID: calleeUserID, expectedDeviceID: calleeDeviceID)
            }
            if response.state == .accepted {
                guard let callee = response.calleeKeyPackage,
                      response.mediaToken != nil,
                      let ephemeral = lock.wscLocked({ ephemeralByCall[expectedCallID] }) else { throw CallSignalingError.invalidResponse }
                audioKeys = try E2EECallKeyAgreement.derive(localSide: localSide, localEphemeral: ephemeral, caller: caller, callee: callee)
            } else if response.mediaToken != nil {
                throw CallSignalingError.invalidResponse
            }
        }
        return CallSignalView(callID: response.callID, localSide: response.localSide, state: response.state, expiresAt: response.expiresAt, mediaToken: response.mediaToken, ringExpiresAt: response.ringExpiresAt, acceptedAt: response.acceptedAt, terminalAt: response.terminalAt, terminalReason: response.terminalReason, deliveryStatus: response.deliveryStatus, peerReady: response.peerReady, createdNew: response.createdNew, mutationApplied: response.mutationApplied, audioKeys: audioKeys)
    }

    private func rawMap(_ response: AccountCallResponse, expectedCallID: UUID) throws -> CallSignalView {
        guard response.callID == expectedCallID, response.localSide == localSide else { throw CallSignalingError.invalidResponse }
        return CallSignalView(callID: response.callID, localSide: response.localSide, state: response.state, expiresAt: response.expiresAt, mediaToken: response.state == .accepted ? response.mediaToken : nil, ringExpiresAt: response.ringExpiresAt, acceptedAt: response.acceptedAt, terminalAt: response.terminalAt, terminalReason: response.terminalReason, deliveryStatus: response.deliveryStatus, peerReady: response.peerReady, createdNew: response.createdNew, mutationApplied: response.mutationApplied)
    }

    func eraseSecrets() { lock.wscLocked { ephemeralByCall.removeAll(keepingCapacity: false); secureMode = false } }

    private func localPackage(callID: UUID, side: CallPartySide) async throws -> E2EECallKeyPackage {
        let profile = try await AccountE2EEContext.shared.profile(client: client, accountID: accountID)
        let identity = try identityStore.identity()
        try await AccountE2EEContext.shared.ensureRegistered(client: client, accountID: accountID, identity: identity)
        let ephemeral = lock.wscLocked { () -> Curve25519.KeyAgreement.PrivateKey in
            if let value = ephemeralByCall[callID] { return value }
            let value = Curve25519.KeyAgreement.PrivateKey(); ephemeralByCall[callID] = value; return value
        }
        return try E2EECallKeyAgreement.makePackage(callID: callID, userID: profile.userID, identity: identity, side: side, ephemeral: ephemeral)
    }

    private func verify(_ package: E2EECallKeyPackage, expectedCallID: UUID, expectedSide: CallPartySide, expectedUserID: UUID, expectedDeviceID: UUID) async throws {
        let bundles = try await AccountE2EEContext.shared.deviceKeys(client: client, accountID: accountID, userID: expectedUserID)
        guard let bundle = bundles.first(where: { $0.deviceID == expectedDeviceID }) else { throw E2EEKeyAgreementError.invalidIdentity }
        let pinned = try pinStore.pinnedBundle(userID: expectedUserID, deviceID: bundle.deviceID, accountID: accountID)
        guard try pinStore.evaluate(userID: expectedUserID, bundle: bundle, accountID: accountID) != .keyChanged else {
            if let pinned {
                await E2EEKeyChangeRegistry.shared.record(.init(accountID: accountID, userID: expectedUserID, deviceID: bundle.deviceID, pinnedFingerprint: pinned.fingerprint, observedFingerprint: bundle.fingerprint, observedBundle: bundle))
            }
            throw E2EEKeyAgreementError.keyChanged
        }
        await E2EEKeyChangeRegistry.shared.clear(accountID: accountID, userID: expectedUserID, deviceID: bundle.deviceID)
        try E2EECallKeyAgreement.verify(package, identity: bundle, expectedCallID: expectedCallID, expectedSide: expectedSide, expectedUserID: expectedUserID, expectedDeviceID: expectedDeviceID)
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
    var historyTargetUserID: UUID? { localSide == .caller ? targetUserID : nil }
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
    func rawCall(_ id: UUID) async throws -> CallSignalView { try rawMap(await client.userCall(accountID: accountID, callID: id), expectedCallID: id) }

    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView {
        let package = action == .accept ? try await localPackage(callID: callID, side: .callee) : nil
        let response = try await client.mutateUserCall(accountID: accountID, action: action, callID: callID, requestID: requestID, calleeKeyPackage: package)
        do { return try await map(response, expectedCallID: callID) }
        catch {
            if action == .accept, response.state == .accepted {
                throw CallSignalingError.postCommitValidation(callID: response.callID, state: response.state, mutationApplied: response.mutationApplied, reason: "secure_media_validation_failed")
            }
            throw error
        }
    }

    private func map(_ response: CrossUserCallResponse, expectedCallID: UUID) async throws -> CallSignalView {
        guard response.callID == expectedCallID, response.localSide == localSide else { throw CallSignalingError.invalidResponse }
        let answeredElsewhere = response.legState == .answeredElsewhere
        let callerName = response.caller?.callKitName ?? pushedCallerIdentity?.callKitName
        if response.state != .ringing && response.state != .accepted { return try rawMap(response, expectedCallID: expectedCallID) }
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

    private func rawMap(_ response: CrossUserCallResponse, expectedCallID: UUID) throws -> CallSignalView {
        guard response.callID == expectedCallID, response.localSide == localSide else { throw CallSignalingError.invalidResponse }
        let elsewhere = response.legState == .answeredElsewhere
        return CallSignalView(callID: response.callID, localSide: response.localSide, state: response.state, expiresAt: response.expiresAt, mediaToken: response.state == .accepted && !elsewhere ? response.mediaToken : nil, ringExpiresAt: response.ringExpiresAt, acceptedAt: response.acceptedAt, terminalAt: response.terminalAt, terminalReason: response.terminalReason, deliveryStatus: response.deliveryStatus, peerReady: response.peerReady, createdNew: response.createdNew, mutationApplied: response.mutationApplied, answeredElsewhere: elsewhere, incomingCallerName: response.caller?.callKitName ?? pushedCallerIdentity?.callKitName)
    }

    func eraseSecrets() { lock.wscLocked { ephemeralByCall.removeAll(keepingCapacity: false) } }

    private func localPackage(callID: UUID, side: CallPartySide) async throws -> E2EECallKeyPackage {
        let profile = try await AccountE2EEContext.shared.profile(client: client, accountID: accountID)
        let identity = try identityStore.identity()
        try await AccountE2EEContext.shared.ensureRegistered(client: client, accountID: accountID, identity: identity)
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
        let profile = try await AccountE2EEContext.shared.profile(client: client, accountID: accountID)
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
        let bundles = try await AccountE2EEContext.shared.deviceKeys(client: client, accountID: accountID, userID: expectedUserID)
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
