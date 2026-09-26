import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

struct AccountView: View {
    @ObservedObject var store: AccountSessionStore
    private let client: AccountAPIClient
    @State private var showRegistration = false
    @State private var watchCode = ""
    @State private var message = ""
    @State private var appleNonce = ""
    @State private var appleState = ""

    init(store: AccountSessionStore) {
        self.store = store
        self.client = AccountAPIClient(config: .load(), tokenStore: store.tokenStore)
    }

    var body: some View {
        NavigationView {
            List {
                if store.profiles.isEmpty {
                    Section("Free account") {
                        SignInWithAppleButton(.signIn, onRequest: configureAppleRequest, onCompletion: handleAppleResult)
                            .signInWithAppleButtonStyle(.black)
                            .frame(height: 46)
                        Text("Sign in without SMS. Your username and QR identity do not expose your Apple ID or phone number.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if store.accounts.isEmpty {
                    Section("Legacy phone account") { Button("Register phone") { showRegistration = true } }
                } else {
                    Section {
                        ForEach(store.accounts) { account in
                            Button {
                                store.switchAccount(to: account.accountID)
                            } label: {
                                HStack { Text(account.displayLabel); Spacer(); if account.accountID == store.activeAccountID { Image(systemName: "checkmark") } }
                            }
                        }
                        Button("Add account") { showRegistration = true }
                    } header: {
                        Text("Accounts")
                    } footer: {
                        Text("Multiple accounts can coexist. The checkmark is only the management and Watch-linking default; choose the outgoing Secure Call identity per call.")
                    }
                    if let active = store.activeAccountID {
                        if let profile = store.profiles[active] {
                            Section("Public identity") {
                                Text("@\(profile.username)")
                                Text(profile.publicIdentity).font(.caption).textSelection(.enabled)
                            }
                        }
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

    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomSecret()
        let state = Self.randomSecret()
        appleNonce = nonce
        appleState = state
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
        request.state = state
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure:
            message = "Apple sign-in was not completed"
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  credential.state == appleState,
                  let tokenData = credential.identityToken,
                  let codeData = credential.authorizationCode,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  let authorizationCode = String(data: codeData, encoding: .utf8),
                  !appleNonce.isEmpty else {
                message = "Apple credential is incomplete"
                return
            }
            let displayName = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) } ?? ""
            let email = credential.email ?? ""
            let nonce = appleNonce
            appleNonce = ""; appleState = ""
            Task { await finishAppleSignIn(identityToken: identityToken, authorizationCode: authorizationCode, nonce: nonce, displayName: displayName, email: email) }
        }
    }

    @MainActor private func finishAppleSignIn(identityToken: String, authorizationCode: String, nonce: String, displayName: String, email: String) async {
        do {
            let response = try await client.signInWithApple(identityToken: identityToken, authorizationCode: authorizationCode, nonce: nonce, displayName: displayName, email: email)
            try store.add(response)
            await AccountPushRegistrationCoordinator.shared.registerKnownTokens(for: response.account.accountID)
            message = "Apple account ready"
        } catch { message = "Apple sign-in could not be verified" }
    }

    private static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return UUID().uuidString }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func sha256(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

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
