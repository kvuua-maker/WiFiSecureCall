import Foundation

struct SecureMessageEnvelope: Codable, Equatable, Sendable {
    let deviceID: UUID
    let ephemeralPublicKey: String
    let nonce: String
    let ciphertext: String
    let tag: String
    let keyVersion: UInt64
}

struct SecureMessageInput: Codable, Equatable, Sendable {
    let messageID: UUID
    let clientMessageID: UUID
    let protocolVersion: UInt64
    let keyVersion: UInt64
    let nonce: String
    let ciphertext: String
    let tag: String
    let envelopes: [SecureMessageEnvelope]
    let signature: String
}

struct SecureMessageRecord: Codable, Equatable, Sendable, Identifiable {
    let messageID: UUID
    let conversationID: UUID
    let clientMessageID: UUID
    let senderUserID: UUID
    let senderDeviceID: UUID
    let recipientUserID: UUID
    let createdAt: Date
    let protocolVersion: UInt64
    let keyVersion: UInt64
    let nonce: String
    let ciphertext: String
    let tag: String
    let envelopes: [SecureMessageEnvelope]
    let signature: String
    let receipts: [SecureMessageReceipt]
    var id: UUID { messageID }
}

struct SecureMessageReceipt: Codable, Equatable, Sendable {
    let deviceID: UUID
    let deliveredAt: Date?
    let readAt: Date?
}

struct SecureConversation: Codable, Equatable, Sendable, Identifiable {
    let conversationID: UUID
    let participants: [UUID]
    let createdAt: Date
    let updatedAt: Date
    var id: UUID { conversationID }
}

struct SecureMessagePage: Codable, Equatable, Sendable {
    let messages: [SecureMessageRecord]
    let nextCursor: String?
}

struct CreateSecureConversationRequest: Codable, Sendable {
    let requestID: UUID
    let targetUserID: UUID
}

struct SecureMessageReceiptRequest: Codable, Sendable { let requestID: UUID }

struct DecryptedMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    let senderUserID: UUID
    let text: String
    let createdAt: Date
    let isSentByCurrentUser: Bool
    let delivered: Bool
    let read: Bool
}

struct SecureMessagePushEnvelope: Equatable, Sendable {
    let conversationID: UUID
    let messageID: UUID
    let accountID: UUID

    static func parse(_ userInfo: [AnyHashable: Any]) -> Self? {
        guard userInfo["event"] as? String == "secure_message",
              let conversation = (userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:)),
              let message = (userInfo["messageID"] as? String).flatMap(UUID.init(uuidString:)),
              let account = (userInfo["accountID"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return Self(conversationID: conversation, messageID: message, accountID: account)
    }
}
