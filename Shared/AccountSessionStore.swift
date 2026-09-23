import Foundation

@MainActor
final class AccountSessionStore: ObservableObject {
    static let shared = AccountSessionStore()

    @Published private(set) var accounts: [AccountSummary]
    @Published private(set) var activeAccountID: UUID?
    let tokenStore: SecureTokenStore
    private let defaults: UserDefaults
    private let accountsKey = "WiFiSecureCall.accounts.v1"
    private let activeKey = "WiFiSecureCall.activeAccountID.v1"
    private let accountAdded: ((UUID) -> Void)?

    init(tokenStore: SecureTokenStore = KeychainSecureTokenStore(), defaults: UserDefaults = .standard, accountAdded: ((UUID) -> Void)? = nil) {
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.accountAdded = accountAdded
        accounts = (defaults.data(forKey: accountsKey)).flatMap { try? JSONDecoder().decode([AccountSummary].self, from: $0) } ?? []
        activeAccountID = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        if let activeAccountID, !accounts.contains(where: { $0.accountID == activeAccountID }) { self.activeAccountID = accounts.first?.accountID }
    }

    var activeAccount: AccountSummary? { accounts.first { $0.accountID == activeAccountID } }

    func add(_ response: AccountSessionResponse) throws {
        try tokenStore.save(response.tokens, for: response.account.accountID)
        if let index = accounts.firstIndex(where: { $0.accountID == response.account.accountID }) { accounts[index] = response.account }
        else { accounts.append(response.account) }
        activeAccountID = response.account.accountID
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

    func switchAccount(to accountID: UUID) {
        guard accounts.contains(where: { $0.accountID == accountID }) else { return }
        activeAccountID = accountID
        persistMetadata()
    }

    func logout(accountID: UUID) throws { try removeLocal(accountID: accountID) }
    func delete(accountID: UUID) throws { try removeLocal(accountID: accountID) }

    private func removeLocal(accountID: UUID) throws {
        try tokenStore.delete(accountID: accountID)
        accounts.removeAll { $0.accountID == accountID }
        if activeAccountID == accountID { activeAccountID = accounts.first?.accountID }
        persistMetadata()
    }

    private func persistMetadata() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: accountsKey)
        defaults.set(activeAccountID?.uuidString, forKey: activeKey)
    }
}
