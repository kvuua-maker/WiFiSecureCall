import SwiftUI

struct AccountView: View {
    @ObservedObject var store: AccountSessionStore
    private let client: AccountAPIClient
    @State private var showRegistration = false
    @State private var watchCode = ""
    @State private var message = ""

    init(store: AccountSessionStore) {
        self.store = store
        self.client = AccountAPIClient(config: .load(), tokenStore: store.tokenStore)
    }

    var body: some View {
        NavigationView {
            List {
                if store.accounts.isEmpty {
                    Button("Register phone") { showRegistration = true }
                } else {
                    Section("Accounts") {
                        ForEach(store.accounts) { account in
                            Button {
                                store.switchAccount(to: account.accountID)
                            } label: {
                                HStack { Text(account.phoneNumber); Spacer(); if account.accountID == store.activeAccountID { Image(systemName: "checkmark") } }
                            }
                        }
                        Button("Add account") { showRegistration = true }
                    }
                    if let active = store.activeAccountID {
                        Section("Link Apple Watch") {
                            TextField("6-digit code", text: $watchCode).keyboardType(.numberPad)
                            Button("Link") { Task { await claimWatch(accountID: active) } }.disabled(watchCode.count != 6)
                        }
                        Section {
                            Button("Sign out", role: .destructive) { Task { await logout(active) } }
                            Button("Delete account", role: .destructive) { Task { await delete(active) } }
                        }
                    }
                }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle("Account")
            .sheet(isPresented: $showRegistration) { NavigationView { PhoneRegistrationView(store: store, client: client) } }
        }
    }

    @MainActor private func claimWatch(accountID: UUID) async {
        do { try await client.claimWatch(code: watchCode, accountID: accountID); watchCode = ""; message = "Watch linked" }
        catch { message = "Unable to link Watch" }
    }
    @MainActor private func logout(_ accountID: UUID) async {
        do { try await client.logout(accountID: accountID); try store.logout(accountID: accountID) }
        catch { message = "Unable to sign out" }
    }
    @MainActor private func delete(_ accountID: UUID) async {
        do { try await client.deleteAccount(accountID: accountID); try store.delete(accountID: accountID) }
        catch { message = "Unable to delete account" }
    }
}
