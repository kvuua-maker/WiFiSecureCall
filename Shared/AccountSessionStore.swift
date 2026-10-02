import Foundation

enum AccountSwitchResult: Equatable {
    case switched
    case unknownAccount
    case missingSession
}

enum AccountRecoveryValidationError: LocalizedError, Equatable {
    case unexpectedAccount

    var errorDescription: String? {
        "Отримано інший акаунт. Дані не збережено."
    }
}

func validateRecoveredAccount(expectedAccountID: UUID?, actualAccountID: UUID) throws {
    guard expectedAccountID == nil || expectedAccountID == actualAccountID else {
        throw AccountRecoveryValidationError.unexpectedAccount
    }
}

enum WatchAccountSwitchAttemptResult: Equatable {
    case switched
    case blockedByActiveCall
    case missingSession
    case unknownAccount
}

enum WatchRelinkValidationError: Error, Equatable {
    case wrongAccount
}

struct AccountSessionIntegrationDecision: Equatable {
    let activate: Bool
    let invalidateE2EE: Bool
}

func accountSessionIntegrationDecision(
    canChangeActiveAccount: Bool,
    activeAccountID: UUID?,
    incomingAccountID: UUID
) -> AccountSessionIntegrationDecision {
    AccountSessionIntegrationDecision(
        activate: canChangeActiveAccount,
        invalidateE2EE: canChangeActiveAccount || activeAccountID != incomingAccountID
    )
}

func isCurrentWatchLinkAttempt(current: UUID?, candidate: UUID, isCancelled: Bool) -> Bool {
    !isCancelled && current == candidate
}

@MainActor
func attemptWatchAccountSwitch(
    store: AccountSessionStore,
    accountID: UUID,
    canSwitchAccounts: Bool
) -> WatchAccountSwitchAttemptResult {
    guard canSwitchAccounts else { return .blockedByActiveCall }
    switch store.switchAccount(to: accountID) {
    case .switched: return .switched
    case .missingSession: return .missingSession
    case .unknownAccount: return .unknownAccount
    }
}

func validateWatchRelinkClaim(expectedAccountID: UUID?, claimedAccountID: UUID) throws {
    if let expectedAccountID, expectedAccountID != claimedAccountID {
        throw WatchRelinkValidationError.wrongAccount
    }
}

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
    private let revokedPendingKey = "WiFiSecureCall.revokedPendingCleanup.v1"
    private let legacyPendingCleanupKey = "wsc.pendingAccountCleanup.v1"
    private let accountAdded: ((UUID) -> Void)?
    @Published private(set) var revokedPendingCleanupAccountIDs: Set<UUID>

    init(tokenStore: SecureTokenStore = KeychainSecureTokenStore(), defaults: UserDefaults = .standard, accountAdded: ((UUID) -> Void)? = nil) {
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.accountAdded = accountAdded
        accounts = (defaults.data(forKey: accountsKey)).flatMap { try? JSONDecoder().decode([AccountSummary].self, from: $0) } ?? []
        profiles = (defaults.data(forKey: profilesKey)).flatMap { try? JSONDecoder().decode([UUID: UserProfile].self, from: $0) } ?? [:]
        let currentRevoked = Set((defaults.stringArray(forKey: revokedPendingKey) ?? []).compactMap(UUID.init(uuidString:)))
        let legacyRevoked = Set((defaults.stringArray(forKey: legacyPendingCleanupKey) ?? []).compactMap(UUID.init(uuidString:)))
        revokedPendingCleanupAccountIDs = currentRevoked.union(legacyRevoked)
        activeAccountID = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        if let activeAccountID,
           accounts.contains(where: { $0.accountID == activeAccountID }),
           !revokedPendingCleanupAccountIDs.contains(activeAccountID),
           (try? tokenStore.tokens(for: activeAccountID)) != nil {
            self.activeAccountID = activeAccountID
        } else {
            self.activeAccountID = accounts.first(where: { !revokedPendingCleanupAccountIDs.contains($0.accountID) && (try? tokenStore.tokens(for: $0.accountID)) != nil })?.accountID
        }
        if !legacyRevoked.isEmpty {
            defaults.set(revokedPendingCleanupAccountIDs.map(\.uuidString).sorted(), forKey: revokedPendingKey)
            defaults.removeObject(forKey: legacyPendingCleanupKey)
        }
    }

    var activeAccount: AccountSummary? { accounts.first { $0.accountID == activeAccountID } }

    var callableAccounts: [AccountSummary] {
        accounts.filter { account in
            !revokedPendingCleanupAccountIDs.contains(account.accountID) && (try? tokenStore.tokens(for: account.accountID)) != nil
        }
    }

    func hasCallableSession(accountID: UUID) -> Bool {
        accounts.contains(where: { $0.accountID == accountID }) &&
            !revokedPendingCleanupAccountIDs.contains(accountID) &&
            (try? tokenStore.tokens(for: accountID)) != nil
    }

    func add(_ response: AccountSessionResponse, activate: Bool = true, invalidateE2EE: Bool = true, identityKind: AccountIdentityKind? = nil) throws {
        try tokenStore.save(response.tokens, for: response.account.accountID)
        clearRevokedPendingCleanup(response.account.accountID)
        if invalidateE2EE { AccountE2EEContext.shared.invalidate(accountID: response.account.accountID) }
        let kind = identityKind ?? response.account.identityKind
        let summary = AccountSummary(accountID: response.account.accountID, userID: response.account.userID, phoneNumber: response.account.phoneNumber, displayLabel: response.account.displayLabel, identityKind: kind)
        if let index = accounts.firstIndex(where: { $0.accountID == response.account.accountID }) { accounts[index] = summary }
        else { accounts.append(summary) }
        if activate { activeAccountID = response.account.accountID }
        if let profile = response.user { profiles[response.account.accountID] = profile }
        persistMetadata()
        accountAdded?(response.account.accountID)
        SecureMessageStore.shared.invalidateIdentityRegistration(accountID: response.account.accountID)
    }

    func addLinkedAccount(accountID: UUID, phoneNumber: String, tokens: AccountTokens) throws {
        try tokenStore.save(tokens, for: accountID)
        clearRevokedPendingCleanup(accountID)
        AccountE2EEContext.shared.invalidate(accountID: accountID)
        let summary = AccountSummary(accountID: accountID, userID: nil, phoneNumber: phoneNumber, displayLabel: phoneNumber, identityKind: .linked)
        if let index = accounts.firstIndex(where: { $0.accountID == accountID }) { accounts[index] = summary } else { accounts.append(summary) }
        activeAccountID = accountID
        persistMetadata()
        accountAdded?(accountID)
        SecureMessageStore.shared.invalidateIdentityRegistration(accountID: accountID)
    }

    func addLinkedAccount(accountID: UUID, phoneNumber: String?, tokens: AccountTokens) throws {
        try addLinkedAccount(accountID: accountID, userID: nil, phoneNumber: phoneNumber, displayLabel: phoneNumber ?? "Secure account", tokens: tokens)
    }

    func addLinkedAccount(accountID: UUID, userID: UUID?, phoneNumber: String?, displayLabel: String, tokens: AccountTokens, activate: Bool = true) throws {
        try tokenStore.save(tokens, for: accountID)
        clearRevokedPendingCleanup(accountID)
        AccountE2EEContext.shared.invalidate(accountID: accountID)
        let summary = AccountSummary(accountID: accountID, userID: userID, phoneNumber: phoneNumber, displayLabel: displayLabel, identityKind: .linked)
        if let index = accounts.firstIndex(where: { $0.accountID == accountID }) { accounts[index] = summary } else { accounts.append(summary) }
        if activate { activeAccountID = accountID }
        persistMetadata()
        accountAdded?(accountID)
        SecureMessageStore.shared.invalidateIdentityRegistration(accountID: accountID)
    }

    @discardableResult
    func switchAccount(to accountID: UUID) -> AccountSwitchResult {
        guard accounts.contains(where: { $0.accountID == accountID }) else { return .unknownAccount }
        guard hasCallableSession(accountID: accountID) else { return .missingSession }
        activeAccountID = accountID
        persistMetadata()
        return .switched
    }

    func logout(accountID: UUID) throws { try removeLocal(accountID: accountID) }
    func delete(accountID: UUID) throws { try removeLocal(accountID: accountID) }

    /// Called immediately after the server has revoked the session. This is the
    /// authoritative local gate even when Keychain or metadata cleanup fails.
    func markRevokedPendingCleanup(accountID: UUID) {
        revokedPendingCleanupAccountIDs.insert(accountID)
        if activeAccountID == accountID { activeAccountID = callableAccounts.first?.accountID }
        persistMetadata()
    }

    func retryRevokedPendingCleanup() {
        for accountID in revokedPendingCleanupAccountIDs {
            do { try removeLocal(accountID: accountID) }
            catch { /* marker deliberately remains durable */ }
        }
    }

    @discardableResult
    func removeOrphanedLocalAccount(accountID: UUID) throws -> Bool {
        guard accounts.contains(where: { $0.accountID == accountID }),
              try tokenStore.tokens(for: accountID) == nil else { return false }
        try removeLocal(accountID: accountID)
        return true
    }

    private func removeLocal(accountID: UUID) throws {
        SecureMessageStore.shared.invalidateIdentityRegistration(accountID: accountID)
        try tokenStore.delete(accountID: accountID)
        AccountE2EEContext.shared.invalidate(accountID: accountID)
        accounts.removeAll { $0.accountID == accountID }
        profiles.removeValue(forKey: accountID)
        revokedPendingCleanupAccountIDs.remove(accountID)
        if activeAccountID == accountID || activeAccountID.map({ (try? tokenStore.tokens(for: $0)) == nil }) == true {
            activeAccountID = callableAccounts.first?.accountID
        }
        persistMetadata()
    }

    private func persistMetadata() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: accountsKey)
        defaults.set(activeAccountID?.uuidString, forKey: activeKey)
        defaults.set(try? JSONEncoder().encode(profiles), forKey: profilesKey)
        defaults.set(revokedPendingCleanupAccountIDs.map(\.uuidString).sorted(), forKey: revokedPendingKey)
    }

    private func clearRevokedPendingCleanup(_ accountID: UUID) {
        guard revokedPendingCleanupAccountIDs.remove(accountID) != nil else { return }
        persistMetadata()
    }
}
