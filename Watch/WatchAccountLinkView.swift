import SwiftUI

struct WatchAccountLinkView: View {
    @ObservedObject var store: AccountSessionStore
    private let client: AccountAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var message = ""
    @State private var polling: Task<Void, Never>?

    init(store: AccountSessionStore) {
        self.store = store
        self.client = AccountAPIClient(config: .load(), tokenStore: store.tokenStore)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let active = store.activeAccount {
                    Text(active.phoneNumber)
                    Button("Sign out", role: .destructive) { Task { await signOut(active.accountID) } }
                } else {
                    Text(code.isEmpty ? "Link account" : code).font(code.isEmpty ? .headline : .title2.monospacedDigit())
                    if code.isEmpty { Button("Create code") { begin() } }
                    if !message.isEmpty { Text(message).font(.caption) }
                }
            }
        }
        .onDisappear { polling?.cancel(); polling = nil }
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
                    if status.status == "claimed", let accountID = status.accountID, let phone = status.phoneNumber,
                       let access = status.accessToken, let accessExpiry = status.accessExpiresAt,
                       let refresh = status.refreshToken, let refreshExpiry = status.refreshExpiresAt {
                        try await MainActor.run { try store.addLinkedAccount(accountID: accountID, phoneNumber: phone, tokens: AccountTokens(accessToken: access, accessExpiresAt: accessExpiry, refreshToken: refresh, refreshExpiresAt: refreshExpiry)) }
                        await MainActor.run { dismiss() }
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
        do { try await client.logout(accountID: accountID); try store.logout(accountID: accountID); dismiss() }
        catch { message = "Unable to sign out" }
    }
}
