import AuthenticationServices
import SwiftUI
import WatchKit

@MainActor
final class WatchAppleAuthenticationCoordinator: NSObject, ObservableObject, ASAuthorizationControllerDelegate {
    @Published private(set) var isAuthenticating = false
    @Published private(set) var message = ""
    @Published private(set) var lastSignedInAccountID: UUID?

    private let store: AccountSessionStore
    private let client: AccountAPIClient
    private let pushRegistration: AccountPushRegistrationCoordinator
    private var attempt: AppleSignInAttempt?
    private var authorizationController: ASAuthorizationController?
    private var submissionTask: Task<Void, Never>?

    init(
        store: AccountSessionStore,
        client: AccountAPIClient? = nil,
        pushRegistration: AccountPushRegistrationCoordinator? = nil
    ) {
        self.store = store
        self.client = client ?? AccountAPIClient(
            config: .load(),
            tokenStore: store.tokenStore,
            platform: "watchOS"
        )
        self.pushRegistration = pushRegistration ?? .shared
        super.init()
    }

    func start() {
        guard !isAuthenticating else { return }
        do {
            let attempt = try AppleSignInAttempt.make()
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = attempt.requestNonce
            request.state = attempt.state

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            self.attempt = attempt
            authorizationController = controller
            isAuthenticating = true
            message = ""
            controller.performRequests()
        } catch {
            clearAttempt()
            isAuthenticating = false
            message = "Apple sign-in unavailable"
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard controller === authorizationController,
              let attempt,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            clearAttempt()
            isAuthenticating = false
            message = "Дані Apple недоступні"
            return
        }

        let input = AppleNativeCredentialInput(
            state: credential.state,
            identityToken: credential.identityToken,
            authorizationCode: credential.authorizationCode,
            displayName: Self.displayName(from: credential.fullName),
            email: credential.email ?? ""
        )
        clearAttempt()
        submissionTask = Task { [self] in
            await complete(input: input, attempt: attempt)
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        guard controller === authorizationController else { return }
        clearAttempt()
        isAuthenticating = false
        message = "Apple sign-in cancelled or unavailable"
    }

    private func complete(input: AppleNativeCredentialInput, attempt: AppleSignInAttempt) async {
        defer {
            submissionTask = nil
            isAuthenticating = false
        }
        do {
            let response = try await client.signInWithAppleFromWatch(
                credential: input,
                expectedState: attempt.state,
                rawNonce: attempt.rawNonce
            )
            try store.add(response)
            await pushRegistration.registerKnownTokens(for: response.account.accountID)
            lastSignedInAccountID = response.account.accountID
            message = "Вхід через Apple виконано"
        } catch let error as AppleCredentialValidationError {
            message = error == .stateMismatch
                ? "Не вдалося перевірити стан входу Apple"
                : "Дані Apple недоступні"
        } catch {
            message = "Не вдалося перевірити вхід через Apple"
        }
    }

    private func clearAttempt() {
        attempt = nil
        authorizationController = nil
    }

    private static func displayName(from components: PersonNameComponents?) -> String {
        guard let components else { return "" }
        return [components.givenName, components.middleName, components.familyName]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")
    }
}

private struct WatchNativeAppleIDButton: WKInterfaceObjectRepresentable {
    let action: () -> Void

    @MainActor
    final class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeWKInterfaceObject(context: Context) -> WKInterfaceAuthorizationAppleIDButton {
        WKInterfaceAuthorizationAppleIDButton(
            style: .default,
            target: context.coordinator,
            action: #selector(Coordinator.activate)
        )
    }

    func updateWKInterfaceObject(
        _ wkInterfaceObject: WKInterfaceAuthorizationAppleIDButton,
        context: Context
    ) {}
}

struct WatchAccountLinkView: View {
    @ObservedObject var store: AccountSessionStore
    @EnvironmentObject private var appleAuthentication: WatchAppleAuthenticationCoordinator
    private let client: AccountAPIClient
    private let canSwitchAccounts: () -> Bool
    @State private var code = ""
    @State private var message = ""
    @State private var selectedAccountID: UUID?
    @State private var isAdding = false
    @State private var showsAddMethods = false
    @State private var polling: Task<Void, Never>?

    init(store: AccountSessionStore, canSwitchAccounts: @escaping () -> Bool = { true }) {
        self.store = store
        self.client = AccountAPIClient(config: .load(), tokenStore: store.tokenStore)
        self.canSwitchAccounts = canSwitchAccounts
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if isAdding {
                    Text(code.isEmpty ? "Зв’язати з iPhone" : code)
                        .font(code.isEmpty ? .headline : .title2.monospacedDigit())
                    if code.isEmpty {
                        Button("Створити код") { begin() }
                            .disabled(polling != nil)
                    }
                    Button("Скасувати") { cancelLinking() }
                        .font(.caption2)
                } else if store.accounts.isEmpty || showsAddMethods {
                    Text(store.accounts.isEmpty ? "Додайте акаунт" : "Новий акаунт").font(.headline)
                    WatchNativeAppleIDButton { appleAuthentication.start() }
                        .frame(height: 34)
                        .allowsHitTesting(!appleAuthentication.isAuthenticating)
                        .opacity(appleAuthentication.isAuthenticating ? 0.6 : 1)
                    Button("Зв’язати через iPhone") { startAdding() }
                    if !store.accounts.isEmpty { Button("Скасувати") { showsAddMethods = false } }
                } else {
                        Text("Акаунти").font(.headline)
                        ForEach(store.callableAccounts) { account in
                            Button {
                                guard canSwitchAccounts() else { message = "Завершіть виклик перед перемиканням акаунта."; return }
                                if store.switchAccount(to: account.accountID) == .switched { selectedAccountID = account.accountID }
                                else { message = "Потрібне повторне зв’язування" }
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
                        ForEach(orphanedAccounts) { account in
                            VStack(spacing: 4) {
                                Text(account.displayLabel).lineLimit(1)
                                Text("Потрібне повторне зв’язування").font(.caption2).foregroundStyle(.secondary)
                                Button("Відновити") { relink(account.accountID) }
                                Button("Вилучити запис", role: .destructive) { removeOrphan(account.accountID) }
                            }
                        }

                        if let selected = selectedAccount {
                            if needsRelinking(selected.accountID) {
                                Text("Потрібне повторне зв’язування")
                                Button("Зв’язати повторно") { relink(selected.accountID) }
                            } else {
                                Button("Вийти", role: .destructive) {
                                    Task { await signOut(selected.accountID) }
                                }
                            }
                        }
                        Button("Додати акаунт") { showsAddMethods = true }
                }
                if !message.isEmpty { Text(message).font(.caption) }
                if !appleAuthentication.message.isEmpty {
                    Text(appleAuthentication.message).font(.caption)
                }
            }
        }
        .onAppear {
            if selectedAccountID == nil {
                selectedAccountID = store.activeAccountID ?? store.accounts.first?.accountID
            }
        }
        .onChange(of: appleAuthentication.lastSignedInAccountID) { accountID in
            guard let accountID else { return }
            selectedAccountID = accountID
            isAdding = false
            showsAddMethods = false
            code = ""
        }
        .onDisappear { polling?.cancel(); polling = nil }
    }

    private var selectedAccount: AccountSummary? {
        store.accounts.first { $0.accountID == selectedAccountID }
    }

    private var orphanedAccounts: [AccountSummary] {
        store.accounts.filter { account in !store.callableAccounts.contains(where: { $0.accountID == account.accountID }) }
    }

    private func needsRelinking(_ accountID: UUID) -> Bool {
        (try? store.tokenStore.tokens(for: accountID)) == nil
    }

    private func relink(_ accountID: UUID) {
        do {
            guard try store.removeOrphanedLocalAccount(accountID: accountID) else {
                message = "Сесію акаунта відновлено"
                return
            }
            selectedAccountID = store.activeAccountID ?? store.accounts.first?.accountID
            isAdding = true
            begin()
        } catch {
            message = "Не вдалося зв’язати повторно"
        }
    }

    private func startAdding() {
        isAdding = true
        showsAddMethods = false
        code = ""
        message = ""
        begin()
    }

    private func removeOrphan(_ accountID: UUID) {
        do {
            _ = try store.removeOrphanedLocalAccount(accountID: accountID)
            selectedAccountID = store.activeAccountID
            message = "Локальний запис вилучено"
        } catch { message = "Не вдалося вилучити запис" }
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
                await MainActor.run { code = link.code; message = "Введіть цей код на iPhone" }
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
                            message = "Акаунт зв’язано"
                            isAdding = false
                        }
                        return
                    }
                    if status.status == "expired" { await MainActor.run { message = "Строк коду минув" }; return }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch is CancellationError { }
            catch { await MainActor.run { message = "Не вдалося зв’язати" } }
        }
    }

    @MainActor private func signOut(_ accountID: UUID) async {
        do {
            try await client.logout(accountID: accountID)
            try store.logout(accountID: accountID)
            selectedAccountID = store.activeAccountID ?? store.accounts.first?.accountID
            message = "Вихід виконано"
        }
        catch { message = "Не вдалося вийти" }
    }
}
