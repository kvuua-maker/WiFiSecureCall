import AuthenticationServices
import SwiftUI

struct AccountView: View {
    @ObservedObject var store: AccountSessionStore
    private let client: AccountAPIClient
    @State private var showRegistration = false
    @State private var watchCode = ""
    @State private var message = ""
    @State private var appleNonce = ""
    @State private var appleState = ""
    @State private var appleDiagnostic: AppleVerificationDiagnostic?
    @State private var appleTransportDetail: String?
    @State private var confirmsSignOut = false
    @State private var confirmsDeletion = false
    @State private var showsAppleSignIn = false

    init(store: AccountSessionStore) {
        self.store = store
        self.client = AccountAPIClient(config: .load(), tokenStore: store.tokenStore)
    }

    var body: some View {
        List {
                if store.accounts.isEmpty || showsAppleSignIn {
                Section(store.accounts.isEmpty ? "Вхід через Apple" : "Додати акаунт через Apple") {
                    SignInWithAppleButton(.signIn, onRequest: configureAppleRequest, onCompletion: handleAppleResult)
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 46)
                    Text("Увійдіть через Apple без SMS. Публічне ім’я не розкриває Apple ID або номер телефону.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !store.accounts.isEmpty { Button("Скасувати") { showsAppleSignIn = false } }
                }
                }
                if store.accounts.isEmpty {
                    Section("Акаунт за номером") { Button("Зареєструвати номер") { showRegistration = true } }
                } else {
                    if let active = store.activeAccountID,
                       let account = store.accounts.first(where: { $0.accountID == active }) {
                        Section {
                            HStack(spacing: 14) {
                                Text(String(account.displayLabel.prefix(1)).uppercased())
                                    .font(.title.bold()).frame(width: 52, height: 52)
                                    .background(Circle().fill(Color.accentColor.opacity(0.2)))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.profiles[active]?.displayName ?? account.displayLabel).font(.headline).lineLimit(1)
                                    if let username = store.profiles[active]?.username { Text("@\(username)").foregroundStyle(.secondary) }
                                    else { Text(account.displayLabel).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }
                        }
                    }
                    Section {
                        ForEach(store.accounts) { account in
                            Button {
                                store.switchAccount(to: account.accountID)
                            } label: {
                                HStack { Text(account.displayLabel); Spacer(); if account.accountID == store.activeAccountID { Image(systemName: "checkmark") } }
                            }
                        }
                        Button("Додати акаунт через Apple") { showsAppleSignIn = true }
                        Button("Додати акаунт за номером") { showRegistration = true }
                    } header: {
                        Text("Акаунти")
                    } footer: {
                        Text("Позначка показує активний акаунт. Для дзвінка або повідомлення перевірте вибрану вихідну ідентичність.")
                    }
                    if let active = store.activeAccountID {
                        Section("Налаштування") {
                            NavigationLink("Зв’язані пристрої та Apple Watch") {
                                Form {
                                    Text("Введіть код, показаний на Apple Watch.")
                                    TextField("Шестизначний код", text: $watchCode).keyboardType(.numberPad)
                                    Button("Зв’язати") { Task { await claimWatch(accountID: active) } }.disabled(watchCode.count != 6)
                                }.navigationTitle("Apple Watch")
                            }
                            NavigationLink("Безпека та шифрування") {
                                List {
                                    Text("Нові захищені виклики використовують E2EE protocol 2. Зміна ключа блокує зв’язок до підтвердження.")
                                    CallKeyChangeWarningsView(accountID: active)
                                }.navigationTitle("Безпека")
                            }
                        }
                        Section {
                            Button("Вийти", role: .destructive) { confirmsSignOut = true }
                            Button("Видалити акаунт", role: .destructive) { confirmsDeletion = true }
                        }
                    }
                }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                #if DEBUG
                if let appleDiagnostic {
                    Text("Diagnostic: \(appleDiagnostic.rawValue)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let appleTransportDetail {
                        Text("Transport: \(appleTransportDetail)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                #endif
            }
            .navigationTitle("Профіль")
            .sheet(isPresented: $showRegistration) { NavigationView { PhoneRegistrationView(store: store, client: client) } }
            .confirmationDialog("Вийти з активного акаунта?", isPresented: $confirmsSignOut) {
                Button("Вийти", role: .destructive) {
                    if let active = store.activeAccountID { Task { await logout(active) } }
                }
            }
            .confirmationDialog("Видалити активний акаунт і його дані?", isPresented: $confirmsDeletion) {
                Button("Видалити акаунт", role: .destructive) {
                    if let active = store.activeAccountID { Task { await delete(active) } }
                }
            }
    }

    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        appleDiagnostic = nil
        appleTransportDetail = nil
        do {
            let rawNonce = try AppleSignInNonceContract.makeRawNonce()
            let state = try AppleSignInNonceContract.makeRawNonce()
            appleNonce = rawNonce
            appleState = state
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleSignInNonceContract.requestNonce(forRawNonce: rawNonce)
            request.state = state
        } catch {
            appleNonce = ""
            appleState = ""
            appleDiagnostic = .serverRequest
            message = "Не вдалося почати вхід через Apple"
        }
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure:
            message = "Вхід через Apple не завершено"
            appleDiagnostic = .serverRequest
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  credential.state == appleState,
                  let tokenData = credential.identityToken,
                  let codeData = credential.authorizationCode,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  let authorizationCode = String(data: codeData, encoding: .utf8),
                  !appleNonce.isEmpty else {
                message = "Дані Apple неповні"
                appleDiagnostic = .jwtFormat
                return
            }
            let displayName = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) } ?? ""
            let email = credential.email ?? ""
            let nonce = AppleSignInNonceContract.serverNonce(forRawNonce: appleNonce)
            appleNonce = ""; appleState = ""
            Task { await finishAppleSignIn(identityToken: identityToken, authorizationCode: authorizationCode, nonce: nonce, displayName: displayName, email: email) }
        }
    }

    @MainActor private func finishAppleSignIn(identityToken: String, authorizationCode: String, nonce: String, displayName: String, email: String) async {
        do {
            let response = try await client.signInWithApple(identityToken: identityToken, authorizationCode: authorizationCode, nonce: nonce, displayName: displayName, email: email)
            try store.add(response)
            await AccountPushRegistrationCoordinator.shared.registerKnownTokens(for: response.account.accountID)
            appleDiagnostic = nil
            appleTransportDetail = nil
            message = "Акаунт Apple готовий"
            showsAppleSignIn = false
        } catch {
            appleDiagnostic = AppleVerificationDiagnostic.classify(error)
            appleTransportDetail = AppleVerificationDiagnostic.safeTransportDetail(error)
            message = "Не вдалося перевірити вхід через Apple"
        }
    }

    @MainActor private func claimWatch(accountID: UUID) async {
        do { try await client.claimWatch(code: watchCode, accountID: accountID); watchCode = ""; message = "Apple Watch зв’язано" }
        catch { message = "Не вдалося зв’язати Apple Watch" }
    }
    @MainActor private func logout(_ accountID: UUID) async {
        do { try await client.logout(accountID: accountID); try store.logout(accountID: accountID) }
        catch { message = "Не вдалося вийти" }
    }
    @MainActor private func delete(_ accountID: UUID) async {
        do { try await client.deleteAccount(accountID: accountID); try store.delete(accountID: accountID) }
        catch { message = "Не вдалося видалити акаунт" }
    }
}
