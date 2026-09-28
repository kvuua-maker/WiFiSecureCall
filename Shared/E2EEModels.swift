import CryptoKit
import Foundation

enum SecureProtocol {
    static let identityVersion: UInt64 = 2
    static let callVersion: UInt64 = 2
    static let messageVersion: UInt64 = 1
}

struct E2EEPublicDeviceBundle: Codable, Equatable, Sendable, Identifiable {
    let deviceID: UUID
    let signingPublicKey: String
    let agreementPublicKey: String
    let keyVersion: UInt64
    let protocolVersion: UInt64
    let createdAt: Date?
    let updatedAt: Date?
    var id: UUID { deviceID }

    var fingerprint: String {
        guard let signing = Data(base64Encoded: signingPublicKey),
              let agreement = Data(base64Encoded: agreementPublicKey) else { return "INVALID KEY" }
        let digest = SHA256.hash(data: signing + agreement)
        return digest.map { String(format: "%02X", $0) }.joined()
            .splitEvery(4).joined(separator: " ")
    }
}

struct E2EEDeviceRegistrationRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let deviceID: UUID
    let signingPublicKey: String
    let agreementPublicKey: String
    let keyVersion: UInt64
    let protocolVersion: UInt64
    let proofSignature: String
}

enum E2EETrustState: String, Equatable, Sendable {
    case firstTrusted = "TOFU_PINNED"
    case unchanged = "PIN_MATCHED"
    case keyChanged = "KEY_CHANGED"
}

struct E2EECallKeyPackage: Codable, Equatable, Sendable {
    let protocolVersion: UInt64
    let keyEpoch: UInt64
    let callID: UUID
    let userID: UUID
    let deviceID: UUID
    let side: CallPartySide
    let ephemeralPublicKey: String
    let signature: String
}

struct CallAudioKeys: Equatable, Sendable {
    let send: SymmetricKey
    let receive: SymmetricKey
    let epoch: UInt32
    let sendDirection: AudioPacketDirection
    let receiveDirection: AudioPacketDirection

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.send.withUnsafeBytes { Data($0) } == rhs.send.withUnsafeBytes { Data($0) } &&
            lhs.receive.withUnsafeBytes { Data($0) } == rhs.receive.withUnsafeBytes { Data($0) } &&
            lhs.epoch == rhs.epoch && lhs.sendDirection == rhs.sendDirection && lhs.receiveDirection == rhs.receiveDirection
    }
}

private extension String {
    func splitEvery(_ length: Int) -> [String] {
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: length, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<next]))
            index = next
        }
        return result
    }
}
