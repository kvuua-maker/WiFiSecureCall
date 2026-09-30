import Foundation

@MainActor
final class AccountSessionStore: ObservableObject {
    static let shared = AccountSessionStore()

    @Published private(set) var accounts: [AccountSummary]
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var profiles: [UUID: UserProfile]
    let tokenStore: SecureTokenStore
    private let defaults: UserDefaults
    private let accountsKey = "WiFiSecureCall.accounts.v1"
    private let activeKey = "WiFiSecureCall.activeAccountID.v1"
    private let profilesKey = "WiFiSecureCall.userProfiles.v1"
    private let accountAdded: ((UUID) -> Void)?

    init(tokenStore: SecureTokenStore = KeychainSecureTokenStore(), defaults: UserDefaults = .standard, accountAdded: ((UUID) -> Void)? = nil) {
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.accountAdded = accountAdded
        accounts = (defaults.data(forKey: accountsKey)).flatMap { try? JSONDecoder().decode([AccountSummary].self, from: $0) } ?? []
        profiles = (defaults.data(forKey: profilesKey)).flatMap { try? JSONDecoder().decode([UUID: UserProfile].self, from: $0) } ?? [:]
        activeAccountID = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        if let activeAccountID, !accounts.contains(where: { $0.accountID == activeAccountID }) { self.activeAccountID = accounts.first?.accountID }
    }

    var activeAccount: AccountSummary? { accounts.first { $0.accountID == activeAccountID } }

    var callableAccounts: [AccountSummary] {
        accounts.filter { account in
            (try? tokenStore.tokens(for: account.accountID)) != nil
        }
    }

    func add(_ response: AccountSessionResponse) throws {
        try tokenStore.save(response.tokens, for: response.account.accountID)
        if let index = accounts.firstIndex(where: { $0.accountID == response.account.accountID }) { accounts[index] = response.account }
        else { accounts.append(response.account) }
        activeAccountID = response.account.accountID
        if let profile = response.user { profiles[response.account.accountID] = profile }
        persistMetadata()
        accountAdded?(response.account.accountID)
    }

    func addLinkedAccount(accountID: UUID, phoneNumber: String, tokens: AccountTokens) throws {
        try tokenStore.save(tokens, for: accountID)
        let summary = AccountSummary(accountID: accountID, phoneNumber: phoneNumber)
        if let index = accounts.firstIndex(where: { $0.accountID == accountID }) { accounts[index] = summary } else { accounts.append(summary) }
        activeAccountID = accountID
        persistMetadata()
        accountAdded?(accountID)
    }

    func addLinkedAccount(accountID: UUID, phoneNumber: String?, tokens: AccountTokens) throws {
        try addLinkedAccount(accountID: accountID, userID: nil, phoneNumber: phoneNumber, displayLabel: phoneNumber ?? "Secure account", tokens: tokens)
    }

    func addLinkedAccount(accountID: UUID, userID: UUID?, phoneNumber: String?, displayLabel: String, tokens: AccountTokens) throws {
        try tokenStore.save(tokens, for: accountID)
        let summary = AccountSummary(accountID: accountID, userID: userID, phoneNumber: phoneNumber, displayLabel: displayLabel)
        if let index = accounts.firstIndex(where: { $0.accountID == accountID }) { accounts[index] = summary } else { accounts.append(summary) }
        activeAccountID = accountID
        persistMetadata()
        accountAdded?(accountID)
    }

    func switchAccount(to accountID: UUID) {
        guard accounts.contains(where: { $0.accountID == accountID }) else { return }
        activeAccountID = accountID
        persistMetadata()
    }

    func logout(accountID: UUID) throws { try removeLocal(accountID: accountID) }
    func delete(accountID: UUID) throws { try removeLocal(accountID: accountID) }

    @discardableResult
    func removeOrphanedLocalAccount(accountID: UUID) throws -> Bool {
        guard accounts.contains(where: { $0.accountID == accountID }),
              try tokenStore.tokens(for: accountID) == nil else { return false }
        try removeLocal(accountID: accountID)
        return true
    }

    private func removeLocal(accountID: UUID) throws {
        Task { await AccountE2EEContext.shared.invalidate(accountID: accountID) }
        try tokenStore.delete(accountID: accountID)
        accounts.removeAll { $0.accountID == accountID }
        profiles.removeValue(forKey: accountID)
        if activeAccountID == accountID { activeAccountID = accounts.first?.accountID }
        persistMetadata()
    }

    private func persistMetadata() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: accountsKey)
        defaults.set(activeAccountID?.uuidString, forKey: activeKey)
        defaults.set(try? JSONEncoder().encode(profiles), forKey: profilesKey)
    }
}
