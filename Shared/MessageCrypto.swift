import CryptoKit
import Foundation

enum SecureMessageCryptoError: Error, Equatable {
    case emptyMessage
    case messageTooLarge
    case noRecipientDevices
    case conflictingDeviceBundle
    case noEnvelope
    case invalidEnvelope
    case authentication
}

enum SecureMessageCrypto {
    static let maximumUTF8Bytes = 12 * 1024

    static func encrypt(
        text: String,
        conversationID: UUID,
        senderUserID: UUID,
        identity: E2EEDeviceIdentity,
        recipientDevices: [E2EEPublicDeviceBundle],
        senderOtherDevices: [E2EEPublicDeviceBundle],
        messageID: UUID = UUID(),
        clientMessageID: UUID = UUID()
    ) throws -> SecureMessageInput {
        let plaintext = Data(text.utf8)
        guard !plaintext.isEmpty else { throw SecureMessageCryptoError.emptyMessage }
        guard plaintext.count <= maximumUTF8Bytes else { throw SecureMessageCryptoError.messageTooLarge }
        let devices = try mergedEncryptionDevices(recipientDevices: recipientDevices, senderOtherDevices: senderOtherDevices)
        let messageKey = SymmetricKey(size: .bits256)
        let messageBox = try ChaChaPoly.seal(plaintext, using: messageKey)
        let rawMessageKey = messageKey.withUnsafeBytes { Data($0) }
        let envelopes = try devices.map { device -> SecureMessageEnvelope in
            guard let agreementData = Data(base64Encoded: device.agreementPublicKey),
                  let agreementKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementData) else {
                throw SecureMessageCryptoError.invalidEnvelope
            }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: agreementKey)
            let context = envelopeContext(conversationID: conversationID, messageID: messageID, deviceID: device.deviceID)
            let wrappingKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: Data("wsc-message-key-envelope-v1".utf8), outputByteCount: 32)
            let box = try ChaChaPoly.seal(rawMessageKey, using: wrappingKey)
            return SecureMessageEnvelope(
                deviceID: device.deviceID,
                ephemeralPublicKey: ephemeral.publicKey.rawRepresentation.base64EncodedString(),
                nonce: Data(box.nonce).base64EncodedString(), ciphertext: box.ciphertext.base64EncodedString(),
                tag: box.tag.base64EncodedString(), keyVersion: device.keyVersion
            )
        }
        let unsigned = SecureMessageInput(
            messageID: messageID, clientMessageID: clientMessageID, protocolVersion: SecureProtocol.messageVersion,
            keyVersion: identity.keyVersion, nonce: Data(messageBox.nonce).base64EncodedString(),
            ciphertext: messageBox.ciphertext.base64EncodedString(), tag: messageBox.tag.base64EncodedString(),
            envelopes: envelopes, signature: ""
        )
        let signature = try identity.signingPrivateKey.signature(for: signatureMessage(conversationID: conversationID, senderUserID: senderUserID, senderDeviceID: identity.deviceID, input: unsigned))
        return SecureMessageInput(
            messageID: unsigned.messageID, clientMessageID: unsigned.clientMessageID,
            protocolVersion: unsigned.protocolVersion, keyVersion: unsigned.keyVersion,
            nonce: unsigned.nonce, ciphertext: unsigned.ciphertext, tag: unsigned.tag,
            envelopes: unsigned.envelopes, signature: signature.base64EncodedString()
        )
    }

    static func decrypt(_ message: SecureMessageRecord, identity: E2EEDeviceIdentity) throws -> String {
        guard let envelope = message.envelopes.first(where: { $0.deviceID == identity.deviceID }) else { throw SecureMessageCryptoError.noEnvelope }
        do {
            guard let ephemeralData = Data(base64Encoded: envelope.ephemeralPublicKey),
                  let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralData),
                  let envelopeNonce = Data(base64Encoded: envelope.nonce),
                  let envelopeCiphertext = Data(base64Encoded: envelope.ciphertext),
                  let envelopeTag = Data(base64Encoded: envelope.tag),
                  let messageNonce = Data(base64Encoded: message.nonce),
                  let messageCiphertext = Data(base64Encoded: message.ciphertext),
                  let messageTag = Data(base64Encoded: message.tag) else { throw SecureMessageCryptoError.invalidEnvelope }
            let shared = try identity.agreementPrivateKey.sharedSecretFromKeyAgreement(with: ephemeral)
            let context = envelopeContext(conversationID: message.conversationID, messageID: message.messageID, deviceID: identity.deviceID)
            let wrappingKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: Data("wsc-message-key-envelope-v1".utf8), outputByteCount: 32)
            let envelopeBox = try ChaChaPoly.SealedBox(nonce: .init(data: envelopeNonce), ciphertext: envelopeCiphertext, tag: envelopeTag)
            let rawKey = try ChaChaPoly.open(envelopeBox, using: wrappingKey)
            let messageKey = SymmetricKey(data: rawKey)
            let messageBox = try ChaChaPoly.SealedBox(nonce: .init(data: messageNonce), ciphertext: messageCiphertext, tag: messageTag)
            let plaintext = try ChaChaPoly.open(messageBox, using: messageKey)
            guard let text = String(data: plaintext, encoding: .utf8) else { throw SecureMessageCryptoError.authentication }
            return text
        } catch let error as SecureMessageCryptoError {
            throw error
        } catch {
            throw SecureMessageCryptoError.authentication
        }
    }

    static func verifySignature(_ message: SecureMessageRecord, senderIdentity: E2EEPublicDeviceBundle) -> Bool {
        guard let keyData = Data(base64Encoded: senderIdentity.signingPublicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64Encoded: message.signature) else { return false }
        let input = SecureMessageInput(
            messageID: message.messageID, clientMessageID: message.clientMessageID,
            protocolVersion: message.protocolVersion, keyVersion: message.keyVersion,
            nonce: message.nonce, ciphertext: message.ciphertext, tag: message.tag,
            envelopes: message.envelopes, signature: ""
        )
        return key.isValidSignature(signature, for: signatureMessage(conversationID: message.conversationID, senderUserID: message.senderUserID, senderDeviceID: message.senderDeviceID, input: input))
    }

    static func signatureMessage(conversationID: UUID, senderUserID: UUID, senderDeviceID: UUID, input: SecureMessageInput) -> Data {
        var fields = [
            "wsc-message-v1", conversationID.uuidString.lowercased(), input.messageID.uuidString.lowercased(),
            input.clientMessageID.uuidString.lowercased(), senderUserID.uuidString.lowercased(), senderDeviceID.uuidString.lowercased(),
            String(input.protocolVersion), String(input.keyVersion), input.nonce, input.ciphertext, input.tag
        ]
        fields.append(contentsOf: input.envelopes.map {
            [$0.deviceID.uuidString.lowercased(), String($0.keyVersion), $0.ephemeralPublicKey, $0.nonce, $0.ciphertext, $0.tag].joined(separator: "|")
        })
        return Data(fields.joined(separator: "\n").utf8)
    }

    private static func envelopeContext(conversationID: UUID, messageID: UUID, deviceID: UUID) -> Data {
        Data("wsc-message-envelope-v1\n\(conversationID.uuidString.lowercased())\n\(messageID.uuidString.lowercased())\n\(deviceID.uuidString.lowercased())".utf8)
    }

    static func mergedEncryptionDevices(
        recipientDevices: [E2EEPublicDeviceBundle],
        senderOtherDevices: [E2EEPublicDeviceBundle]
    ) throws -> [E2EEPublicDeviceBundle] {
        guard !recipientDevices.isEmpty else { throw SecureMessageCryptoError.noRecipientDevices }
        var devicesByID: [UUID: E2EEPublicDeviceBundle] = [:]
        for bundle in recipientDevices + senderOtherDevices {
            if let existing = devicesByID[bundle.deviceID] {
                let sameCryptographicBundle =
                    existing.signingPublicKey == bundle.signingPublicKey &&
                    existing.agreementPublicKey == bundle.agreementPublicKey &&
                    existing.keyVersion == bundle.keyVersion &&
                    existing.protocolVersion == bundle.protocolVersion
                guard sameCryptographicBundle else {
                    throw SecureMessageCryptoError.conflictingDeviceBundle
                }
                continue
            }
            devicesByID[bundle.deviceID] = bundle
        }
        return devicesByID.values.sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
    }
}
