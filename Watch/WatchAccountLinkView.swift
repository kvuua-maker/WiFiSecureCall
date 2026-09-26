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
            message = "Apple credential unavailable"
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
            message = "Signed in with Apple"
        } catch let error as AppleCredentialValidationError {
            message = error == .stateMismatch
                ? "Apple sign-in state verification failed"
                : "Apple credential unavailable"
        } catch {
            message = "Apple sign-in could not be verified"
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
                    Text(code.isEmpty ? "Link with iPhone" : code)
                        .font(code.isEmpty ? .headline : .title2.monospacedDigit())
                    if code.isEmpty {
                        Button("Create code") { begin() }
                            .disabled(polling != nil)
                    }
                    Button("Cancel") { cancelLinking() }
                        .font(.caption2)
                } else {
                    if store.accounts.isEmpty {
                        Text("Account").font(.headline)
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

                        Text("Add account").font(.caption)
                    }

                    WatchNativeAppleIDButton { appleAuthentication.start() }
                        .frame(height: 34)
                        .allowsHitTesting(!appleAuthentication.isAuthenticating)
                        .opacity(appleAuthentication.isAuthenticating ? 0.6 : 1)

                    Button("Link with iPhone") { startAdding() }
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
            code = ""
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
