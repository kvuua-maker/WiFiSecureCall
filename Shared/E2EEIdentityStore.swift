import CryptoKit
import Foundation
import Security

protocol E2EESecretStorage: Sendable {
    func load(_ key: String) throws -> Data?
    func save(_ data: Data, key: String) throws
}

enum E2EEIdentityError: Error, Equatable {
    case keychain(OSStatus)
    case malformedIdentity
    case keyChanged
    case invalidSignature
}

struct KeychainE2EESecretStorage: E2EESecretStorage {
    let service: String
    init(service: String = "com.vkapps.wifisecurecall.e2ee") { self.service = service }

    func load(_ key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw E2EEIdentityError.keychain(status) }
        return data
    }

    func save(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw E2EEIdentityError.keychain(status) }
        } else if update != errSecSuccess {
            throw E2EEIdentityError.keychain(update)
        }
    }
}

struct E2EEDeviceIdentity: Sendable {
    let deviceID: UUID
    let signingPrivateKey: Curve25519.Signing.PrivateKey
    let agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let keyVersion: UInt64

    var publicBundle: E2EEPublicDeviceBundle {
        E2EEPublicDeviceBundle(
            deviceID: deviceID,
            signingPublicKey: signingPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            agreementPublicKey: agreementPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            keyVersion: keyVersion,
            protocolVersion: SecureProtocol.identityVersion,
            createdAt: nil,
            updatedAt: nil
        )
    }

    func registration(requestID: UUID) throws -> E2EEDeviceRegistrationRequest {
        let unsigned = E2EEDeviceRegistrationRequest(
            requestID: requestID, deviceID: deviceID,
            signingPublicKey: publicBundle.signingPublicKey,
            agreementPublicKey: publicBundle.agreementPublicKey,
            keyVersion: keyVersion, protocolVersion: SecureProtocol.identityVersion,
            proofSignature: ""
        )
        let signature = try signingPrivateKey.signature(for: Self.proofMessage(unsigned))
        return E2EEDeviceRegistrationRequest(
            requestID: requestID, deviceID: deviceID,
            signingPublicKey: unsigned.signingPublicKey,
            agreementPublicKey: unsigned.agreementPublicKey,
            keyVersion: unsigned.keyVersion, protocolVersion: unsigned.protocolVersion,
            proofSignature: signature.base64EncodedString()
        )
    }

    static func proofMessage(_ value: E2EEDeviceRegistrationRequest) -> Data {
        Data([
            "wsc-device-key-v1", value.deviceID.uuidString.lowercased(), value.signingPublicKey,
            value.agreementPublicKey, String(value.keyVersion), String(value.protocolVersion)
        ].joined(separator: "\n").utf8)
    }
}

final class E2EEIdentityStore: @unchecked Sendable {
    private let storage: any E2EESecretStorage
    private let deviceID: UUID
    private let lock = NSLock()
    private var cached: E2EEDeviceIdentity?

    init(storage: any E2EESecretStorage = KeychainE2EESecretStorage(), deviceID: UUID = InstallationIdentity.shared.id) {
        self.storage = storage
        self.deviceID = deviceID
    }

    func identity() throws -> E2EEDeviceIdentity {
        try lock.wscLocked {
            if let cached { return cached }
            let signing: Curve25519.Signing.PrivateKey
            let agreement: Curve25519.KeyAgreement.PrivateKey
            if let signingData = try storage.load("identity.signing.v1"),
               let agreementData = try storage.load("identity.agreement.v1") {
                guard let loadedSigning = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingData),
                      let loadedAgreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementData) else {
                    throw E2EEIdentityError.malformedIdentity
                }
                signing = loadedSigning
                agreement = loadedAgreement
            } else {
                signing = Curve25519.Signing.PrivateKey()
                agreement = Curve25519.KeyAgreement.PrivateKey()
                try storage.save(signing.rawRepresentation, key: "identity.signing.v1")
                try storage.save(agreement.rawRepresentation, key: "identity.agreement.v1")
                try storage.save(Data(String(1).utf8), key: "identity.version.v1")
            }
            let versionData = try storage.load("identity.version.v1") ?? Data("1".utf8)
            guard let versionText = String(data: versionData, encoding: .utf8), let version = UInt64(versionText), version > 0 else {
                throw E2EEIdentityError.malformedIdentity
            }
            let value = E2EEDeviceIdentity(deviceID: deviceID, signingPrivateKey: signing, agreementPrivateKey: agreement, keyVersion: version)
            cached = value
            return value
        }
    }
}

final class E2EEIdentityPinStore: @unchecked Sendable {
    private let storage: any E2EESecretStorage
    init(storage: any E2EESecretStorage = KeychainE2EESecretStorage(service: "com.vkapps.wifisecurecall.e2ee.pins")) { self.storage = storage }

    func evaluate(userID: UUID, bundle: E2EEPublicDeviceBundle) throws -> E2EETrustState {
        let key = "\(userID.uuidString.lowercased()).\(bundle.deviceID.uuidString.lowercased())"
        let encoded = try JSONEncoder().encode(bundle)
        guard let existing = try storage.load(key) else {
            try storage.save(encoded, key: key)
            return .firstTrusted
        }
        guard let pinned = try? JSONDecoder().decode(E2EEPublicDeviceBundle.self, from: existing) else { throw E2EEIdentityError.malformedIdentity }
        guard pinned.signingPublicKey == bundle.signingPublicKey,
              pinned.agreementPublicKey == bundle.agreementPublicKey,
              pinned.keyVersion == bundle.keyVersion else { return .keyChanged }
        return .unchanged
    }
}
