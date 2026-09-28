import Foundation

enum SecureMessageViewState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class SecureMessageStore: ObservableObject {
    static let shared = SecureMessageStore()
    @Published private(set) var conversations: [SecureConversation] = []
    @Published private(set) var messages: [UUID: [DecryptedMessage]] = [:]
    @Published private(set) var state: SecureMessageViewState = .idle
    @Published private(set) var safetyFingerprints: [UUID: [String]] = [:]

    private let sessions: AccountSessionStore
    private let api: MessageAPIClient
    private let identityStore: E2EEIdentityStore
    private let pinStore: E2EEIdentityPinStore
    private var registeredAccounts = Set<UUID>()
    private var nextCursor: [UUID: String] = [:]
    private var conversationAccounts: [UUID: UUID] = [:]

    init(
        sessions: AccountSessionStore,
        accountAPI: AccountAPIClient? = nil,
        identityStore: E2EEIdentityStore = E2EEIdentityStore(),
        pinStore: E2EEIdentityPinStore = E2EEIdentityPinStore()
    ) {
        self.sessions = sessions
        self.api = MessageAPIClient(accountAPI: accountAPI ?? NotificationRuntime.shared.accountAPI)
        self.identityStore = identityStore
        self.pinStore = pinStore
    }

    convenience init() {
        self.init(sessions: .shared)
    }

    func refresh() async {
        guard let accountID = sessions.activeAccountID else { conversations = []; state = .idle; return }
        state = .loading
        do {
            try await ensureIdentity(accountID: accountID)
            conversations = try await api.conversations(accountID: accountID)
            for conversation in conversations { conversationAccounts[conversation.id] = accountID }
            state = .loaded
        } catch {
            state = .failed(Self.safeError(error))
        }
    }

    func createConversation(targetUserID: UUID, accountID requestedAccountID: UUID? = nil) async throws -> SecureConversation {
        guard let accountID = requestedAccountID ?? sessions.activeAccountID else { throw AccountAPIError.missingSession }
        try await ensureIdentity(accountID: accountID)
        let value = try await api.createConversation(accountID: accountID, targetUserID: targetUserID)
        conversationAccounts[value.id] = accountID
        if !conversations.contains(where: { $0.id == value.id }) { conversations.insert(value, at: 0) }
        return value
    }

    func loadMessages(conversationID: UUID, accountID requestedAccountID: UUID? = nil, append: Bool = false) async {
        guard let accountID = requestedAccountID ?? conversationAccounts[conversationID] ?? sessions.activeAccountID else { return }
        conversationAccounts[conversationID] = accountID
        state = .loading
        do {
            try await ensureIdentity(accountID: accountID)
            let identity = try identityStore.identity()
            let profile = try await api.accountAPI.userProfile(accountID: accountID)
            let page = try await api.messages(accountID: accountID, conversationID: conversationID, cursor: append ? nextCursor[conversationID] : nil)
            var decoded: [DecryptedMessage] = []
            for record in page.messages {
                if let cached = messages[conversationID]?.first(where: { $0.id == record.messageID }) { decoded.append(cached); continue }
                let bundles = try await api.deviceKeys(accountID: accountID, userID: record.senderUserID)
                guard let sender = bundles.first(where: { $0.deviceID == record.senderDeviceID }),
                      try pinStore.evaluate(userID: record.senderUserID, bundle: sender) != .keyChanged,
                      SecureMessageCrypto.verifySignature(record, senderIdentity: sender) else { continue }
                safetyFingerprints[conversationID] = Array(Set((safetyFingerprints[conversationID] ?? []) + [sender.fingerprint])).sorted()
                let text = try SecureMessageCrypto.decrypt(record, identity: identity)
                decoded.append(DecryptedMessage(
                    id: record.messageID, conversationID: record.conversationID, senderUserID: record.senderUserID,
                    text: text, createdAt: record.createdAt, isSentByCurrentUser: record.senderUserID == profile.userID,
                    delivered: !record.receipts.isEmpty, read: record.receipts.contains { $0.readAt != nil }
                ))
                if record.senderUserID != profile.userID {
                    _ = try? await api.delivered(accountID: accountID, conversationID: conversationID, messageID: record.messageID)
                }
            }
            let prior = append ? (messages[conversationID] ?? []) : []
            messages[conversationID] = Dictionary(uniqueKeysWithValues: (prior + decoded).map { ($0.id, $0) }).values.sorted { $0.createdAt < $1.createdAt }
            if let cursor = page.nextCursor { nextCursor[conversationID] = cursor } else { nextCursor.removeValue(forKey: conversationID) }
            state = .loaded
        } catch {
            state = .failed(Self.safeError(error))
        }
    }

    func send(text: String, conversation: SecureConversation) async throws {
        guard let accountID = conversationAccounts[conversation.id] ?? sessions.activeAccountID else { throw AccountAPIError.missingSession }
        try await ensureIdentity(accountID: accountID)
        let profile = try await api.accountAPI.userProfile(accountID: accountID)
        guard let recipient = conversation.participants.first(where: { $0 != profile.userID }) else { throw SecureMessageCryptoError.noRecipientDevices }
        let identity = try identityStore.identity()
        let recipientDevices = try await api.deviceKeys(accountID: accountID, userID: recipient)
        let ownDevices = try await api.deviceKeys(accountID: accountID, userID: profile.userID)
        for bundle in recipientDevices {
            guard try pinStore.evaluate(userID: recipient, bundle: bundle) != .keyChanged else { throw E2EEIdentityError.keyChanged }
        }
        safetyFingerprints[conversation.id] = recipientDevices.map(\.fingerprint).sorted()
        let input = try SecureMessageCrypto.encrypt(
            text: text, conversationID: conversation.id, senderUserID: profile.userID, identity: identity,
            recipientDevices: recipientDevices, senderOtherDevices: ownDevices
        )
        let record = try await api.send(accountID: accountID, conversationID: conversation.id, input: input)
        let local = DecryptedMessage(
            id: record.messageID, conversationID: conversation.id, senderUserID: profile.userID,
            text: text, createdAt: record.createdAt, isSentByCurrentUser: true,
            delivered: !record.receipts.isEmpty, read: record.receipts.contains { $0.readAt != nil }
        )
        messages[conversation.id, default: []].append(local)
    }

    func markRead(conversationID: UUID) async {
        guard let accountID = conversationAccounts[conversationID] ?? sessions.activeAccountID else { return }
        for message in messages[conversationID, default: []] where !message.isSentByCurrentUser {
            _ = try? await api.read(accountID: accountID, conversationID: conversationID, messageID: message.id)
        }
    }

    private func ensureIdentity(accountID: UUID) async throws {
        guard !registeredAccounts.contains(accountID) else { return }
        let identity = try identityStore.identity()
        let bundle = try await api.registerIdentity(accountID: accountID, registration: identity.registration(requestID: UUID()))
        guard bundle.deviceID == identity.deviceID,
              bundle.signingPublicKey == identity.publicBundle.signingPublicKey,
              bundle.agreementPublicKey == identity.publicBundle.agreementPublicKey else { throw E2EEIdentityError.keyChanged }
        registeredAccounts.insert(accountID)
    }

    static func safeError(_ error: Error) -> String {
        if error is E2EEIdentityError { return "Encryption identity needs attention" }
        if error is SecureMessageCryptoError { return "Secure message could not be processed" }
        return "Network request failed"
    }
}
