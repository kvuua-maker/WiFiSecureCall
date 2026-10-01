import Combine
import Foundation

enum SecureMessageViewState: Equatable { case idle, loading, loaded, failed(String) }

@MainActor
final class SecureMessageStore: ObservableObject {
    static let shared = SecureMessageStore()
    @Published private(set) var conversations: [SecureConversation] = []
    @Published private(set) var messages: [UUID: [DecryptedMessage]] = [:]
    @Published private(set) var state: SecureMessageViewState = .idle
    @Published private(set) var safetyFingerprints: [UUID: [String]] = [:]
    @Published private(set) var safetyDevices: [UUID: [E2EESafetyDevice]] = [:]
    @Published private(set) var keyChangeWarnings: [UUID: [E2EEKeyChangeWarning]] = [:]
    var activeAccountID: UUID? { sessions.activeAccountID }

    private struct AccountCache {
        var conversations: [SecureConversation] = []
        var messages: [UUID: [DecryptedMessage]] = [:]
        var state: SecureMessageViewState = .idle
        var safetyDevices: [UUID: [E2EESafetyDevice]] = [:]
        var keyChangeWarnings: [UUID: [E2EEKeyChangeWarning]] = [:]
        var nextCursor: [UUID: String] = [:]
    }

    private let sessions: AccountSessionStore
    private let api: MessageAPIClient
    private let identityStore: E2EEIdentityStore
    private let pinStore: E2EEIdentityPinStore
    private var registeredAccounts = Set<UUID>()
    private var caches: [UUID: AccountCache] = [:]
    private var accountObserver: AnyCancellable?

    init(sessions: AccountSessionStore, accountAPI: AccountAPIClient? = nil, identityStore: E2EEIdentityStore = E2EEIdentityStore(), pinStore: E2EEIdentityPinStore = E2EEIdentityPinStore()) {
        self.sessions = sessions
        api = MessageAPIClient(accountAPI: accountAPI ?? NotificationRuntime.shared.accountAPI)
        self.identityStore = identityStore
        self.pinStore = pinStore
        accountObserver = sessions.$activeAccountID.removeDuplicates().sink { [weak self] accountID in
            guard let self else { return }
            self.publish(accountID: accountID)
        }
    }

    convenience init() { self.init(sessions: .shared) }

    func refresh() async {
        guard let accountID = sessions.activeAccountID else { publish(accountID: nil); return }
        _ = await refresh(accountID: accountID)
    }

    @discardableResult
    func refresh(accountID: UUID, reportsLoading: Bool = true) async -> Bool {
        guard sessions.hasCallableSession(accountID: accountID) else { return false }
        guard !Task.isCancelled else { return false }
        if reportsLoading { setState(.loading, accountID: accountID) }
        do {
            try await ensureIdentity(accountID: accountID)
            try requireCallable(accountID)
            try Task.checkCancellation()
            let values = try await api.conversations(accountID: accountID)
            try Task.checkCancellation()
            try requireCallable(accountID)
            updateCache(accountID) { $0.conversations = values; $0.state = .loaded }
            return true
        } catch {
            guard sessions.hasCallableSession(accountID: accountID), !Task.isCancelled, !Self.isCancellation(error) else { return false }
            setState(.failed(Self.safeError(error)), accountID: accountID)
            return false
        }
    }

    func createConversation(targetUserID: UUID, accountID requestedAccountID: UUID? = nil) async throws -> SecureConversation {
        guard let accountID = requestedAccountID ?? sessions.activeAccountID,
              sessions.hasCallableSession(accountID: accountID) else { throw AccountAPIError.missingSession }
        try await ensureIdentity(accountID: accountID)
        try requireCallable(accountID)
        let value = try await api.createConversation(accountID: accountID, targetUserID: targetUserID)
        try requireCallable(accountID)
        updateCache(accountID) { if !$0.conversations.contains(where: { $0.id == value.id }) { $0.conversations.insert(value, at: 0) } }
        return value
    }

    @discardableResult
    func loadMessages(conversationID: UUID, accountID: UUID, append: Bool = false, reportsLoading: Bool = true) async -> Bool {
        guard sessions.hasCallableSession(accountID: accountID) else { return false }
        guard !Task.isCancelled else { return false }
        if reportsLoading { setState(.loading, accountID: accountID) }
        do {
            try await ensureIdentity(accountID: accountID)
            try requireCallable(accountID)
            try Task.checkCancellation()
            let identity = try identityStore.identity()
            let profile = try await api.accountAPI.userProfile(accountID: accountID)
            try requireCallable(accountID)
            try Task.checkCancellation()
            let cursor = append ? caches[accountID]?.nextCursor[conversationID] : nil
            let page = try await api.messages(accountID: accountID, conversationID: conversationID, cursor: cursor)
            try Task.checkCancellation()
            try requireCallable(accountID)
            var decoded: [DecryptedMessage] = []
            var devices = caches[accountID]?.safetyDevices[conversationID] ?? []
            var warnings = caches[accountID]?.keyChangeWarnings[conversationID] ?? []
            for record in page.messages {
                try Task.checkCancellation()
                if let cached = caches[accountID]?.messages[conversationID]?.first(where: { $0.id == record.messageID }) {
                    decoded.append(Self.mergingReceiptState(cached: cached, record: record))
                    continue
                }
                let value = try await decode(record, accountID: accountID, conversationID: conversationID, profile: profile, identity: identity, safetyDevices: &devices, keyChanges: &warnings)
                try Task.checkCancellation()
                try requireCallable(accountID)
                decoded.append(value)
                if value.availability == .available, !value.isSentByCurrentUser {
                    try requireCallable(accountID)
                    _ = try? await api.delivered(accountID: accountID, conversationID: conversationID, messageID: record.messageID)
                    try Task.checkCancellation()
                    try requireCallable(accountID)
                }
            }
            try Task.checkCancellation()
            try requireCallable(accountID)
            updateCache(accountID) { cache in
                let prior = append ? (cache.messages[conversationID] ?? []) : []
                var merged = Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) })
                for message in decoded { merged[message.id] = message }
                cache.messages[conversationID] = merged.values.sorted { $0.createdAt < $1.createdAt }
                cache.safetyDevices[conversationID] = devices.sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
                cache.keyChangeWarnings[conversationID] = warnings.sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
                if let next = page.nextCursor { cache.nextCursor[conversationID] = next } else { cache.nextCursor.removeValue(forKey: conversationID) }
                cache.state = .loaded
            }
            return true
        } catch {
            guard sessions.hasCallableSession(accountID: accountID), !Task.isCancelled, !Self.isCancellation(error) else { return false }
            setState(.failed(Self.safeError(error)), accountID: accountID)
            return false
        }
    }

    @discardableResult
    func prepareNotificationConversation(conversationID: UUID, accountID: UUID) async -> Bool {
        guard !Task.isCancelled,
              await refresh(accountID: accountID, reportsLoading: false),
              !Task.isCancelled,
              caches[accountID]?.conversations.contains(where: { $0.id == conversationID }) == true else { return false }
        let loaded = await loadMessages(
            conversationID: conversationID,
            accountID: accountID,
            reportsLoading: false
        )
        return !Task.isCancelled && loaded
    }

    func prepareSafety(conversation: SecureConversation, accountID: UUID) async {
        guard sessions.hasCallableSession(accountID: accountID) else { return }
        do {
            try await ensureIdentity(accountID: accountID)
            try requireCallable(accountID)
            let profile = try await api.accountAPI.userProfile(accountID: accountID)
            try requireCallable(accountID)
            guard let peerID = conversation.participants.first(where: { $0 != profile.userID }) else { return }
            let bundles = try await api.deviceKeys(accountID: accountID, userID: peerID)
            try requireCallable(accountID)
            var devices: [E2EESafetyDevice] = [], warnings: [E2EEKeyChangeWarning] = []
            for bundle in bundles {
                let pinned = try pinStore.pinnedBundle(userID: peerID, deviceID: bundle.deviceID, accountID: accountID)
                let trust = try pinStore.evaluate(userID: peerID, bundle: bundle, accountID: accountID)
                devices.append(.init(deviceID: bundle.deviceID, fingerprint: bundle.fingerprint, trustState: trust))
                if trust == .keyChanged, let pinned { warnings.append(warning(accountID: accountID, conversationID: conversation.id, userID: peerID, pinned: pinned, observed: bundle)) }
            }
            updateCache(accountID) { $0.safetyDevices[conversation.id] = devices; $0.keyChangeWarnings[conversation.id] = warnings }
        } catch { if sessions.hasCallableSession(accountID: accountID) { setState(.failed(Self.safeError(error)), accountID: accountID) } }
    }

    func hasOlderMessages(conversationID: UUID, accountID: UUID) -> Bool {
        caches[accountID]?.nextCursor[conversationID] != nil
    }

    func approveKeyChange(_ warning: E2EEKeyChangeWarning) async throws {
        guard sessions.hasCallableSession(accountID: warning.accountID) else { throw AccountAPIError.missingSession }
        let fresh = try await api.deviceKeys(accountID: warning.accountID, userID: warning.userID)
        try requireCallable(warning.accountID)
        guard let bundle = fresh.first(where: { $0.deviceID == warning.deviceID }),
              bundle.signingPublicKey == warning.observedBundle.signingPublicKey,
              bundle.agreementPublicKey == warning.observedBundle.agreementPublicKey,
              bundle.keyVersion == warning.observedBundle.keyVersion,
              bundle.protocolVersion == warning.observedBundle.protocolVersion else { throw E2EEIdentityError.keyChanged }
        try pinStore.approveReplacement(userID: warning.userID, bundle: bundle, accountID: warning.accountID)
        E2EEKeyChangeRegistry.shared.clear(accountID: warning.accountID, userID: warning.userID, deviceID: warning.deviceID)
        updateCache(warning.accountID) { cache in
            cache.keyChangeWarnings[warning.conversationID]?.removeAll { $0.deviceID == warning.deviceID }
            if let index = cache.safetyDevices[warning.conversationID]?.firstIndex(where: { $0.deviceID == warning.deviceID }) {
                cache.safetyDevices[warning.conversationID]?[index] = .init(deviceID: bundle.deviceID, fingerprint: bundle.fingerprint, trustState: .unchanged)
            }
            // A prior security placeholder must never be treated as freshly verified
            // after approval. Force the next load to fetch and decrypt current bytes.
            cache.messages.removeValue(forKey: warning.conversationID)
            cache.nextCursor.removeValue(forKey: warning.conversationID)
        }
    }

    func send(text: String, conversation: SecureConversation, accountID: UUID) async throws {
        guard sessions.hasCallableSession(accountID: accountID),
              caches[accountID]?.conversations.contains(where: { $0.id == conversation.id }) == true else { throw AccountAPIError.missingSession }
        try await ensureIdentity(accountID: accountID)
        try requireCallable(accountID)
        let profile = try await api.accountAPI.userProfile(accountID: accountID)
        try requireCallable(accountID)
        guard let recipient = conversation.participants.first(where: { $0 != profile.userID }) else { throw SecureMessageCryptoError.noRecipientDevices }
        let identity = try identityStore.identity()
        let recipientDevices = try await api.deviceKeys(accountID: accountID, userID: recipient)
        try requireCallable(accountID)
        let ownDevices = try await api.deviceKeys(accountID: accountID, userID: profile.userID)
        try requireCallable(accountID)
        var safety: [E2EESafetyDevice] = [], warnings: [E2EEKeyChangeWarning] = []
        for bundle in recipientDevices {
            let pinned = try pinStore.pinnedBundle(userID: recipient, deviceID: bundle.deviceID, accountID: accountID)
            let trust = try pinStore.evaluate(userID: recipient, bundle: bundle, accountID: accountID)
            safety.append(.init(deviceID: bundle.deviceID, fingerprint: bundle.fingerprint, trustState: trust))
            if trust == .keyChanged, let pinned { warnings.append(warning(accountID: accountID, conversationID: conversation.id, userID: recipient, pinned: pinned, observed: bundle)) }
        }
        updateCache(accountID) { $0.safetyDevices[conversation.id] = safety; $0.keyChangeWarnings[conversation.id] = warnings }
        guard warnings.isEmpty else { throw E2EEIdentityError.keyChanged }
        try requireCallable(accountID)
        let input = try SecureMessageCrypto.encrypt(text: text, conversationID: conversation.id, senderUserID: profile.userID, identity: identity, recipientDevices: recipientDevices, senderOtherDevices: ownDevices)
        let record = try await api.send(accountID: accountID, conversationID: conversation.id, input: input)
        try requireCallable(accountID)
        let local = DecryptedMessage(id: record.messageID, conversationID: conversation.id, senderUserID: profile.userID, text: text, createdAt: record.createdAt, isSentByCurrentUser: true, delivered: record.receipts.contains { $0.deliveredAt != nil }, read: record.receipts.contains { $0.readAt != nil })
        updateCache(accountID) { $0.messages[conversation.id, default: []].append(local) }
    }

    func markRead(conversationID: UUID, accountID: UUID) async {
        guard sessions.hasCallableSession(accountID: accountID),
              let values = caches[accountID]?.messages[conversationID] else { return }
        for message in values where !message.isSentByCurrentUser && message.availability == .available {
            guard sessions.hasCallableSession(accountID: accountID) else { return }
            _ = try? await api.read(accountID: accountID, conversationID: conversationID, messageID: message.id)
            guard sessions.hasCallableSession(accountID: accountID) else { return }
        }
    }

    func messages(conversationID: UUID, accountID: UUID) -> [DecryptedMessage] {
        caches[accountID]?.messages[conversationID] ?? []
    }

    func safetyDevices(conversationID: UUID, accountID: UUID) -> [E2EESafetyDevice] {
        caches[accountID]?.safetyDevices[conversationID] ?? []
    }

    func keyChangeWarnings(conversationID: UUID, accountID: UUID) -> [E2EEKeyChangeWarning] {
        caches[accountID]?.keyChangeWarnings[conversationID] ?? []
    }

    private func decode(_ record: SecureMessageRecord, accountID: UUID, conversationID: UUID, profile: UserProfile, identity: E2EEDeviceIdentity, safetyDevices: inout [E2EESafetyDevice], keyChanges: inout [E2EEKeyChangeWarning]) async throws -> DecryptedMessage {
        let own = record.senderUserID == profile.userID
        func result(_ text: String, _ availability: DecryptedMessage.Availability) -> DecryptedMessage {
            .init(id: record.messageID, conversationID: record.conversationID, senderUserID: record.senderUserID, text: text, createdAt: record.createdAt, isSentByCurrentUser: own, delivered: record.receipts.contains { $0.deliveredAt != nil }, read: record.receipts.contains { $0.readAt != nil }, availability: availability)
        }
        let bundles = try await api.deviceKeys(accountID: accountID, userID: record.senderUserID)
        try requireCallable(accountID)
        guard let sender = bundles.first(where: { $0.deviceID == record.senderDeviceID }) else { return result("Secure message could not be verified", .securityFailure) }
        let pinned = try pinStore.pinnedBundle(userID: record.senderUserID, deviceID: sender.deviceID, accountID: accountID)
        let trust = try pinStore.evaluate(userID: record.senderUserID, bundle: sender, accountID: accountID)
        safetyDevices.removeAll { $0.deviceID == sender.deviceID }
        safetyDevices.append(.init(deviceID: sender.deviceID, fingerprint: sender.fingerprint, trustState: trust))
        guard trust != .keyChanged else {
            if let pinned { keyChanges.removeAll { $0.deviceID == sender.deviceID }; keyChanges.append(warning(accountID: accountID, conversationID: conversationID, userID: record.senderUserID, pinned: pinned, observed: sender)) }
            return result("Secure message could not be verified", .securityFailure)
        }
        return Self.materialize(record, currentUserID: profile.userID, identity: identity, senderIdentity: sender, trust: trust)
    }

    /// Pure record-level policy used by page processing. One bad record produces
    /// a safe placeholder and cannot fail or suppress the rest of the page.
    nonisolated static func materialize(
        _ record: SecureMessageRecord,
        currentUserID: UUID,
        identity: E2EEDeviceIdentity,
        senderIdentity: E2EEPublicDeviceBundle,
        trust: E2EETrustState
    ) -> DecryptedMessage {
        let own = record.senderUserID == currentUserID
        func value(_ text: String, _ availability: DecryptedMessage.Availability) -> DecryptedMessage {
            .init(
                id: record.messageID,
                conversationID: record.conversationID,
                senderUserID: record.senderUserID,
                text: text,
                createdAt: record.createdAt,
                isSentByCurrentUser: own,
                delivered: record.receipts.contains { $0.deliveredAt != nil },
                read: record.receipts.contains { $0.readAt != nil },
                availability: availability
            )
        }
        guard trust != .keyChanged,
              SecureMessageCrypto.verifySignature(record, senderIdentity: senderIdentity) else {
            return value("Secure message could not be verified", .securityFailure)
        }
        do { return value(try SecureMessageCrypto.decrypt(record, identity: identity), .available) }
        catch SecureMessageCryptoError.noEnvelope { return value("Message unavailable on this device", .unavailableOnDevice) }
        catch { return value("Secure message could not be verified", .securityFailure) }
    }

    nonisolated static func mergingReceiptState(cached: DecryptedMessage, record: SecureMessageRecord) -> DecryptedMessage {
        let serverRead = record.receipts.contains { $0.readAt != nil }
        let serverDelivered = serverRead || record.receipts.contains { $0.deliveredAt != nil }
        return .init(
            id: cached.id,
            conversationID: cached.conversationID,
            senderUserID: cached.senderUserID,
            text: cached.text,
            createdAt: cached.createdAt,
            isSentByCurrentUser: cached.isSentByCurrentUser,
            delivered: cached.delivered || serverDelivered,
            read: cached.read || serverRead,
            availability: cached.availability
        )
    }

    private func warning(accountID: UUID, conversationID: UUID, userID: UUID, pinned: E2EEPublicDeviceBundle, observed: E2EEPublicDeviceBundle) -> E2EEKeyChangeWarning {
        .init(accountID: accountID, conversationID: conversationID, userID: userID, deviceID: observed.deviceID, pinnedFingerprint: pinned.fingerprint, observedFingerprint: observed.fingerprint, observedBundle: observed)
    }

    private func ensureIdentity(accountID: UUID) async throws {
        try requireCallable(accountID)
        guard !registeredAccounts.contains(accountID) else { return }
        try Task.checkCancellation()
        let identity = try identityStore.identity()
        let bundle = try await api.registerIdentity(accountID: accountID, registration: identity.registration(requestID: UUID()))
        try Task.checkCancellation()
        try requireCallable(accountID)
        guard bundle.deviceID == identity.deviceID, bundle.signingPublicKey == identity.publicBundle.signingPublicKey, bundle.agreementPublicKey == identity.publicBundle.agreementPublicKey else { throw E2EEIdentityError.keyChanged }
        registeredAccounts.insert(accountID)
    }

    private func updateCache(_ accountID: UUID, _ update: (inout AccountCache) -> Void) {
        guard sessions.hasCallableSession(accountID: accountID) else { return }
        var cache = caches[accountID] ?? AccountCache(); update(&cache); caches[accountID] = cache
        if sessions.activeAccountID == accountID { publish(accountID: accountID) }
        else { objectWillChange.send() }
    }

    private func requireCallable(_ accountID: UUID) throws {
        guard sessions.hasCallableSession(accountID: accountID) else { throw AccountAPIError.missingSession }
    }

    private func setState(_ value: SecureMessageViewState, accountID: UUID) { updateCache(accountID) { $0.state = value } }

    private func publish(accountID: UUID?) {
        guard let accountID else { conversations = []; messages = [:]; state = .idle; safetyFingerprints = [:]; safetyDevices = [:]; keyChangeWarnings = [:]; return }
        let cache = caches[accountID] ?? AccountCache()
        conversations = cache.conversations; messages = cache.messages; state = cache.state
        safetyDevices = cache.safetyDevices; safetyFingerprints = cache.safetyDevices.mapValues { $0.map(\.fingerprint) }; keyChangeWarnings = cache.keyChangeWarnings
    }

    static func safeError(_ error: Error) -> String {
        if error is E2EEIdentityError { return "Encryption identity needs attention" }
        if error is SecureMessageCryptoError { return "Secure message could not be processed" }
        return "Network request failed"
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
