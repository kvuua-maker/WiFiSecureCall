import Foundation
import Security

protocol SecureTokenStore: AnyObject {
    func tokens(for accountID: UUID) throws -> AccountTokens?
    func save(_ tokens: AccountTokens, for accountID: UUID) throws
    func delete(accountID: UUID) throws
    @discardableResult
    func deleteIfRefreshTokenMatches(accountID: UUID, refreshToken: String) throws -> Bool
}

enum SecureTokenStoreError: Error { case encoding, keychain(OSStatus), decoding }

final class KeychainSecureTokenStore: SecureTokenStore {
    private let service: String
    private let lock = NSLock()
    init(service: String = "com.vkapps.wifisecurecall.account-session") { self.service = service }

    func tokens(for accountID: UUID) throws -> AccountTokens? {
        lock.lock()
        defer { lock.unlock() }
        return try tokensUnlocked(for: accountID)
    }

    func save(_ tokens: AccountTokens, for accountID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(tokens, for: accountID)
    }

    func delete(accountID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try deleteUnlocked(accountID: accountID)
    }

    @discardableResult
    func deleteIfRefreshTokenMatches(accountID: UUID, refreshToken: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard try tokensUnlocked(for: accountID)?.refreshToken == refreshToken else { return false }
        try deleteUnlocked(accountID: accountID)
        return true
    }

    private func tokensUnlocked(for accountID: UUID) throws -> AccountTokens? {
        var query = base(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecureTokenStoreError.keychain(status) }
        guard let value = try? JSONDecoder.account.decode(AccountTokens.self, from: data) else { throw SecureTokenStoreError.decoding }
        return value
    }

    private func saveUnlocked(_ tokens: AccountTokens, for accountID: UUID) throws {
        guard let data = try? JSONEncoder.account.encode(tokens) else { throw SecureTokenStoreError.encoding }
        var query = base(accountID)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecureTokenStoreError.keychain(status) }
        } else if update != errSecSuccess { throw SecureTokenStoreError.keychain(update) }
    }

    private func deleteUnlocked(accountID: UUID) throws {
        let status = SecItemDelete(base(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureTokenStoreError.keychain(status) }
    }

    private func base(_ accountID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountID.uuidString.lowercased()]
    }
}

extension JSONEncoder {
    static let account: JSONEncoder = { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }()
}
extension JSONDecoder {
    static let account: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let whole = ISO8601DateFormatter(); whole.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: text) ?? whole.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid RFC3339 date")
        }
        return value
    }()
}
