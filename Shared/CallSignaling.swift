import CryptoKit
import Foundation

// Synchronous session boundary: logout invalidates results before it returns,
// even if actor cleanup or a cancellation-ignoring network task runs later.
final class AccountE2EESessionEpochs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: UInt64] = [:]

    func current(_ accountID: UUID) -> UInt64 {
        lock.wscLocked { values[accountID, default: 0] }
    }

    @discardableResult
    func advance(_ accountID: UUID) -> UInt64 {
        lock.wscLocked {
            values[accountID, default: 0] &+= 1
            return values[accountID, default: 0]
        }
    }
}

actor AccountE2EEContext {
    static let shared = AccountE2EEContext()
    private struct SessionKey: Hashable {
        // Retain the client while cached: its address cannot be reused by a
        // different API client with different server/session configuration.
        let client: AccountAPIClient
        let accountID: UUID
        let epoch: UInt64

        static func == (lhs: SessionKey, rhs: SessionKey) -> Bool {
            lhs.client === rhs.client && lhs.accountID == rhs.accountID && lhs.epoch == rhs.epoch
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(client))
            hasher.combine(accountID)
            hasher.combine(epoch)
        }
    }
    private struct BundleKey: Hashable {
        let session: SessionKey
        let userID: UUID
    }
    private struct RegistrationKey: Hashable {
        let session: SessionKey
        let deviceID: UUID
        let keyVersion: UInt64
        let fingerprint: String
    }
    private struct Timed<T> { let value: T; let expires: Date }
    private struct Flight<T: Sendable> {
        let id = UUID()
        let task: Task<T, Error>
    }
    nonisolated private let epochs = AccountE2EESessionEpochs()
    private let profileLoader: @Sendable (AccountAPIClient, UUID) async throws -> UserProfile
    private let onProfileCoalesced: @Sendable () -> Void
    private var profiles: [SessionKey: Timed<UserProfile>] = [:]
    private var bundles: [BundleKey: Timed<[E2EEPublicDeviceBundle]>] = [:]
    private var profileTasks: [SessionKey: Flight<UserProfile>] = [:]
    private var bundleTasks: [BundleKey: Flight<[E2EEPublicDeviceBundle]>] = [:]
    private var registrations: [RegistrationKey: Date] = [:]
    private var registrationTasks: [RegistrationKey: Flight<Void>] = [:]

    init(profileLoader: @escaping @Sendable (AccountAPIClient, UUID) async throws -> UserProfile = {
        try await $0.userProfile(accountID: $1)
    }, onProfileCoalesced: @escaping @Sendable () -> Void = {}) {
        self.profileLoader = profileLoader
        self.onProfileCoalesced = onProfileCoalesced
    }

    func profile(client: AccountAPIClient, accountID: UUID) async throws -> UserProfile {
        let key = sessionKey(client: client, accountID: accountID)
        try requireCurrent(key)
        if let cached = profiles[key], cached.expires > Date() { return cached.value }
        if let flight = profileTasks[key] {
            onProfileCoalesced()
            let value = try await flight.task.value
            try requireCurrent(key)
            return value
        }
        let loader = profileLoader
        let flight = Flight(task: Task { try await loader(client, accountID) })
        profileTasks[key] = flight
        defer { if profileTasks[key]?.id == flight.id { profileTasks.removeValue(forKey: key) } }
        let value = try await flight.task.value
        try requireCurrent(key)
        profiles[key] = .init(value: value, expires: Date().addingTimeInterval(30))
        return value
    }

    func ensureRegistered(client: AccountAPIClient, accountID: UUID, identity: E2EEDeviceIdentity) async throws {
        let session = sessionKey(client: client, accountID: accountID)
        let key = RegistrationKey(session: session, deviceID: identity.deviceID, keyVersion: identity.keyVersion, fingerprint: identity.publicBundle.fingerprint)
        try requireCurrent(session)
        if let confirmed = registrations[key], Date().timeIntervalSince(confirmed) < 60 { return }
        if let flight = registrationTasks[key] {
            try await flight.task.value
            try requireCurrent(session)
            return
        }
        let flight = Flight<Void>(task: Task { _ = try await client.registerDeviceKey(accountID: accountID, request: identity.registration(requestID: UUID())) })
        registrationTasks[key] = flight
        defer { if registrationTasks[key]?.id == flight.id { registrationTasks.removeValue(forKey: key) } }
        try await flight.task.value
        try requireCurrent(session)
        registrations[key] = Date()
    }

    func deviceKeys(client: AccountAPIClient, accountID: UUID, userID: UUID) async throws -> [E2EEPublicDeviceBundle] {
        let session = sessionKey(client: client, accountID: accountID)
        let key = BundleKey(session: session, userID: userID)
        try requireCurrent(session)
        if let cached = bundles[key], cached.expires > Date() { return cached.value }
        if let flight = bundleTasks[key] {
            let value = try await flight.task.value
            try requireCurrent(session)
            return value
        }
        let flight = Flight(task: Task { try await client.deviceKeys(accountID: accountID, userID: userID) })
        bundleTasks[key] = flight
        defer { if bundleTasks[key]?.id == flight.id { bundleTasks.removeValue(forKey: key) } }
        let value = try await flight.task.value
        try requireCurrent(session)
        bundles[key] = .init(value: value, expires: Date().addingTimeInterval(15))
        return value
    }

    nonisolated func invalidate(accountID: UUID) {
        let epoch = epochs.advance(accountID)
        Task { await self.clearInvalidated(accountID: accountID, before: epoch) }
    }

    private func clearInvalidated(accountID: UUID, before epoch: UInt64) {
        func stale(_ key: SessionKey) -> Bool { key.accountID == accountID && key.epoch < epoch }
        for key in profileTasks.keys.filter({ stale($0) }) { profileTasks.removeValue(forKey: key)?.task.cancel() }
        for key in bundleTasks.keys.filter({ stale($0.session) }) { bundleTasks.removeValue(forKey: key)?.task.cancel() }
        for key in registrationTasks.keys.filter({ stale($0.session) }) { registrationTasks.removeValue(forKey: key)?.task.cancel() }
        profiles = profiles.filter { !stale($0.key) }
        bundles = bundles.filter { !stale($0.key.session) }
        registrations = registrations.filter { !stale($0.key.session) }
    }

    private func sessionKey(client: AccountAPIClient, accountID: UUID) -> SessionKey {
        SessionKey(client: client, accountID: accountID, epoch: epochs.current(accountID))
    }

    private func requireCurrent(_ key: SessionKey) throws {
        try Task.checkCancellation()
        guard epochs.current(key.accountID) == key.epoch else { throw CancellationError() }
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
