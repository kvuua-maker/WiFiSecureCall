import CryptoKit
import Foundation

enum E2EEKeyAgreementError: Error, Equatable {
    case invalidPackage
    case invalidIdentity
    case keyChanged
}

enum E2EECallKeyAgreement {
    static func packageMessage(_ value: E2EECallKeyPackage) -> Data {
        Data([
            "wsc-call-key-v2", value.callID.uuidString.lowercased(), value.userID.uuidString.lowercased(),
            value.deviceID.uuidString.lowercased(), value.side.rawValue, String(value.protocolVersion),
            String(value.keyEpoch), value.ephemeralPublicKey
        ].joined(separator: "\n").utf8)
    }

    static func makePackage(
        callID: UUID,
        userID: UUID,
        identity: E2EEDeviceIdentity,
        side: CallPartySide,
        epoch: UInt64 = 1,
        ephemeral: Curve25519.KeyAgreement.PrivateKey
    ) throws -> E2EECallKeyPackage {
        let unsigned = E2EECallKeyPackage(
            protocolVersion: SecureProtocol.callVersion, keyEpoch: epoch, callID: callID,
            userID: userID, deviceID: identity.deviceID, side: side,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation.base64EncodedString(), signature: ""
        )
        let signature = try identity.signingPrivateKey.signature(for: packageMessage(unsigned))
        return E2EECallKeyPackage(
            protocolVersion: unsigned.protocolVersion, keyEpoch: unsigned.keyEpoch, callID: unsigned.callID,
            userID: unsigned.userID, deviceID: unsigned.deviceID, side: unsigned.side,
            ephemeralPublicKey: unsigned.ephemeralPublicKey, signature: signature.base64EncodedString()
        )
    }

    static func verify(_ package: E2EECallKeyPackage, identity: E2EEPublicDeviceBundle, expectedCallID: UUID, expectedSide: CallPartySide) throws {
        guard package.protocolVersion == SecureProtocol.callVersion, package.keyEpoch > 0,
              package.callID == expectedCallID, package.side == expectedSide, package.deviceID == identity.deviceID,
              let signingData = Data(base64Encoded: identity.signingPublicKey),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signingData),
              let signature = Data(base64Encoded: package.signature),
              publicKey.isValidSignature(signature, for: packageMessage(package)),
              let ephemeral = Data(base64Encoded: package.ephemeralPublicKey), ephemeral.count == 32 else {
            throw E2EEKeyAgreementError.invalidPackage
        }
    }

    static func derive(
        localSide: CallPartySide,
        localEphemeral: Curve25519.KeyAgreement.PrivateKey,
        caller: E2EECallKeyPackage,
        callee: E2EECallKeyPackage
    ) throws -> CallAudioKeys {
        let peer = localSide == .caller ? callee : caller
        guard let peerData = Data(base64Encoded: peer.ephemeralPublicKey),
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData) else {
            throw E2EEKeyAgreementError.invalidPackage
        }
        let shared = try localEphemeral.sharedSecretFromKeyAgreement(with: peerKey)
        let context = Data([
            "wsc-call-audio-v2", caller.callID.uuidString.lowercased(), caller.userID.uuidString.lowercased(),
            caller.deviceID.uuidString.lowercased(), callee.userID.uuidString.lowercased(),
            callee.deviceID.uuidString.lowercased(), caller.ephemeralPublicKey, callee.ephemeralPublicKey,
            String(caller.keyEpoch)
        ].joined(separator: "\n").utf8)
        let callerToCallee = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: Data("caller-to-callee".utf8), outputByteCount: 32)
        let calleeToCaller = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: Data("callee-to-caller".utf8), outputByteCount: 32)
        if localSide == .caller {
            return CallAudioKeys(send: callerToCallee, receive: calleeToCaller, epoch: UInt32(caller.keyEpoch), sendDirection: .callerToCallee, receiveDirection: .calleeToCaller)
        }
        return CallAudioKeys(send: calleeToCaller, receive: callerToCallee, epoch: UInt32(caller.keyEpoch), sendDirection: .calleeToCaller, receiveDirection: .callerToCallee)
    }
}
