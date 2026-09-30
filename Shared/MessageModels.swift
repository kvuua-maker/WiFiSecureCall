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
    let peer: ResolvedRecipient?
    var id: UUID { conversationID }

    init(conversationID: UUID, participants: [UUID], createdAt: Date, updatedAt: Date, peer: ResolvedRecipient? = nil) {
        self.conversationID = conversationID
        self.participants = participants
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.peer = peer
    }

    var peerDisplayName: String {
        guard let peer else { return "Адресат недоступний" }
        if let name = peer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return "@\(peer.username)"
    }
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
    enum Availability: String, Equatable, Sendable {
        case available
        case unavailableOnDevice
        case securityFailure
    }

    let id: UUID
    let conversationID: UUID
    let senderUserID: UUID
    let text: String
    let createdAt: Date
    let isSentByCurrentUser: Bool
    let delivered: Bool
    let read: Bool
    let availability: Availability

    init(
        id: UUID,
        conversationID: UUID,
        senderUserID: UUID,
        text: String,
        createdAt: Date,
        isSentByCurrentUser: Bool,
        delivered: Bool,
        read: Bool,
        availability: Availability = .available
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderUserID = senderUserID
        self.text = text
        self.createdAt = createdAt
        self.isSentByCurrentUser = isSentByCurrentUser
        self.delivered = delivered
        self.read = read
        self.availability = availability
    }
}

struct E2EESafetyDevice: Identifiable, Equatable, Sendable {
    let deviceID: UUID
    let fingerprint: String
    let trustState: E2EETrustState
    var id: UUID { deviceID }
}

struct E2EEKeyChangeWarning: Identifiable, Equatable, Sendable {
    let accountID: UUID
    let conversationID: UUID
    let userID: UUID
    let deviceID: UUID
    let pinnedFingerprint: String
    let observedFingerprint: String
    let observedBundle: E2EEPublicDeviceBundle
    var id: UUID { deviceID }
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
