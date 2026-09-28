import Foundation

struct MessageAPIClient: Sendable {
    let accountAPI: AccountAPIClient

    func registerIdentity(accountID: UUID, registration: E2EEDeviceRegistrationRequest) async throws -> E2EEPublicDeviceBundle {
        try await accountAPI.registerDeviceKey(accountID: accountID, request: registration)
    }

    func deviceKeys(accountID: UUID, userID: UUID) async throws -> [E2EEPublicDeviceBundle] {
        try await accountAPI.deviceKeys(accountID: accountID, userID: userID)
    }

    func createConversation(accountID: UUID, targetUserID: UUID, requestID: UUID = UUID()) async throws -> SecureConversation {
        try await accountAPI.createSecureConversation(accountID: accountID, requestID: requestID, targetUserID: targetUserID)
    }

    func conversations(accountID: UUID) async throws -> [SecureConversation] { try await accountAPI.secureConversations(accountID: accountID) }
    func messages(accountID: UUID, conversationID: UUID, cursor: String? = nil, limit: Int = 30) async throws -> SecureMessagePage {
        try await accountAPI.secureMessages(accountID: accountID, conversationID: conversationID, cursor: cursor, limit: limit)
    }
    func send(accountID: UUID, conversationID: UUID, input: SecureMessageInput) async throws -> SecureMessageRecord {
        try await accountAPI.sendSecureMessage(accountID: accountID, conversationID: conversationID, input: input)
    }
    func delivered(accountID: UUID, conversationID: UUID, messageID: UUID) async throws -> SecureMessageRecord {
        try await accountAPI.markSecureMessage(accountID: accountID, conversationID: conversationID, messageID: messageID, action: "delivered")
    }
    func read(accountID: UUID, conversationID: UUID, messageID: UUID) async throws -> SecureMessageRecord {
        try await accountAPI.markSecureMessage(accountID: accountID, conversationID: conversationID, messageID: messageID, action: "read")
    }
}
