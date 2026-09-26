import SwiftUI

struct WatchAccountLinkView: View {
    @ObservedObject var store: AccountSessionStore
    private let client: AccountAPIClient
    @State private var code = ""
    @State private var message = ""
    @State private var selectedAccountID: UUID?
    @State private var isAdding = false
    @State private var polling: Task<Void, Never>?

    init(store: AccountSessionStore) {
        self.store = store
        self.client = AccountAPIClient(config: .load(), tokenStore: store.tokenStore)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if isAdding {
                    Text(code.isEmpty ? "Link another account" : code)
                        .font(code.isEmpty ? .headline : .title2.monospacedDigit())
                    if code.isEmpty {
                        Button("Create code") { begin() }
                            .disabled(polling != nil)
                    }
                    Button("Cancel") { cancelLinking() }
                        .font(.caption2)
                } else if store.accounts.isEmpty {
                    Text("Link account").font(.headline)
                    Button("Create code") { startAdding() }
                } else {
                    Text("Linked accounts").font(.headline)
                    ForEach(store.accounts) { account in
                        Button {
                            selectedAccountID = account.accountID
                        } label: {
                            HStack {
                                Text(account.displayLabel)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                if account.accountID == store.activeAccountID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    if let selected = selectedAccount {
                        if selected.accountID != store.activeAccountID {
                            Button("Set as default") {
                                store.switchAccount(to: selected.accountID)
                            }
                            .font(.caption2)
                        }
                        if needsRelinking(selected.accountID) {
                            Text("Account needs relinking")
                            Button("Relink account") { relink(selected.accountID) }
                        } else {
                            Button("Sign out", role: .destructive) {
                                Task { await signOut(selected.accountID) }
                            }
                        }
                    }

                    Button("Add account") { startAdding() }
                }
                if !message.isEmpty { Text(message).font(.caption) }
            }
        }
        .onAppear {
            if selectedAccountID == nil {
                selectedAccountID = store.activeAccountID ?? store.accounts.first?.accountID
            }
        }
        .onDisappear { polling?.cancel(); polling = nil }
    }

    private var selectedAccount: AccountSummary? {
        store.accounts.first { $0.accountID == selectedAccountID }
    }

    private func needsRelinking(_ accountID: UUID) -> Bool {
        (try? store.tokenStore.tokens(for: accountID)) == nil
    }

    private func relink(_ accountID: UUID) {
        do {
            guard try store.removeOrphanedLocalAccount(accountID: accountID) else {
                message = "Account session restored"
                return
            }
            selectedAccountID = store.activeAccountID ?? store.accounts.first?.accountID
            isAdding = true
            begin()
        } catch {
            message = "Unable to relink"
        }
    }

    private func startAdding() {
        isAdding = true
        code = ""
        message = ""
        begin()
    }

    private func cancelLinking() {
        polling?.cancel()
        polling = nil
        code = ""
        message = ""
        isAdding = false
    }

    private func begin() {
        polling?.cancel()
        polling = Task {
            do {
                let link = try await client.watchLinkStart()
                guard !Task.isCancelled else { return }
                await MainActor.run { code = link.code; message = "Enter this code on iPhone" }
                while !Task.isCancelled && Date() < link.expiresAt {
                    let status = try await client.watchLinkStatus(linkID: link.linkID, secret: link.linkSecret)
                    if status.status == "claimed", let accountID = status.accountID,
                       let access = status.accessToken, let accessExpiry = status.accessExpiresAt,
                       let refresh = status.refreshToken, let refreshExpiry = status.refreshExpiresAt {
                        try await MainActor.run { try store.addLinkedAccount(accountID: accountID, userID: status.userID, phoneNumber: status.phoneNumber, displayLabel: status.displayLabel ?? status.phoneNumber ?? "Secure account", tokens: AccountTokens(accessToken: access, accessExpiresAt: accessExpiry, refreshToken: refresh, refreshExpiresAt: refreshExpiry)) }
                        await AccountPushRegistrationCoordinator.shared.registerKnownTokens(for: accountID)
                        await MainActor.run {
                            selectedAccountID = accountID
                            code = ""
                            message = "Account linked"
                            isAdding = false
                        }
                        return
                    }
                    if status.status == "expired" { await MainActor.run { message = "Code expired" }; return }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch is CancellationError { }
            catch { await MainActor.run { message = "Unable to link" } }
        }
    }

    @MainActor private func signOut(_ accountID: UUID) async {
        do {
            try await client.logout(accountID: accountID)
            try store.logout(accountID: accountID)
            selectedAccountID = store.activeAccountID ?? store.accounts.first?.accountID
            message = "Account signed out"
        }
        catch { message = "Unable to sign out" }
    }
}
