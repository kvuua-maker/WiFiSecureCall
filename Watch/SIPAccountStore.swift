import Foundation
import Security

/// The SIP account a watch uses, with the password in the keychain.
///
/// Nothing about the account is written to UserDefaults: the password is the only
/// credential a SIP trunk sees, and it belongs in the keychain next to the other
/// secrets this app keeps.
final class SIPAccountStore: ObservableObject {
    static let shared = SIPAccountStore()

    @Published private(set) var account: SIPAccount = .empty
    @Published private(set) var hasPassword = false
    private(set) var password: String = ""

    private let service = "com.vkapps.wifisecurecall.sip"
    private let accountKey = "account"

    private init() {
        load()
    }

    var isConfigured: Bool {
        account.isComplete && !password.isEmpty
    }

    func save(account: SIPAccount, password: String) {
        self.account = account
        self.password = password
        hasPassword = !password.isEmpty
        guard let data = try? JSONEncoder().encode(StoredAccount(account: account, password: password)) else { return }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]
        SecItemDelete(query as CFDictionary)
        account = .empty
        password = ""
        hasPassword = false
    }

    private func load() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(StoredAccount.self, from: data) else {
            return
        }
        account = stored.sipAccount
        password = stored.password
        hasPassword = !stored.password.isEmpty
    }

    private struct StoredAccount: Codable {
        let username: String
        let host: String
        let port: Int
        let path: String
        let displayName: String
        let domain: String
        let password: String

        init(account: SIPAccount, password: String) {
            username = account.username
            host = account.host
            port = account.port
            path = account.webSocketPath
            displayName = account.displayName
            domain = account.domain
            self.password = password
        }

        var sipAccount: SIPAccount {
            SIPAccount(username: username, host: host, port: port, webSocketPath: path, displayName: displayName, domain: domain)
        }
    }
}
