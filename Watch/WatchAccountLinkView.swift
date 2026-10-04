import AuthenticationServices
import SwiftUI
import WatchKit

@MainActor
final class WatchAppleAuthenticationCoordinator: NSObject, ObservableObject, ASAuthorizationControllerDelegate {
    @Published private(set) var isAuthenticating = false
    @Published private(set) var message = ""
    @Published private(set) var lastSignedInAccountID: UUID?

    /// What the flow is doing, in the order it does it, so that a tap that never becomes a system sheet is
    /// distinguishable from a sheet that is refused. Sign in with Apple was reported as doing nothing at
    /// all on a watch, and a single "nothing" cannot say which of those two happened.
    enum Stage: Equatable {
        case idle
        case tapped
        case sheetPresented
        case credentialReceived
        case signedIn
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle

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
            // The controller is held for the length of the flow. A controller that is not retained is
            // released while the system sheet is still up, and the delegate callbacks it owes never arrive,
            // which is a sign-in that stops without a word.
            authorizationController = controller
            isAuthenticating = true
            message = "Waiting for Apple…"
            stage = .tapped
            controller.performRequests()
            stage = .sheetPresented
        } catch {
            clearAttempt()
            isAuthenticating = false
            message = "Apple sign-in unavailable"
            stage = .failed("request could not be created")
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        stage = .credentialReceived
        guard controller === authorizationController,
              let attempt,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            clearAttempt()
            isAuthenticating = false
            message = "Apple credential unavailable"
            stage = .failed("no Apple ID credential in the response")
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
        message = Self.message(for: error)
        stage = .failed(message)
    }

    /// Each refusal is reported as what it was rather than as one catch-all string.
    ///
    /// Nothing here prints the identity token, the authorization code, the Apple ID, the user identifier
    /// or any other credential: only the category of the failure is named.
    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == ASAuthorizationError.errorDomain,
              let code = ASAuthorizationError.Code(rawValue: nsError.code) else {
            return "Apple sign-in could not be verified"
        }
        switch code {
        case .canceled:
            return "Apple sign-in cancelled"
        case .notHandled:
            // Apple requires a passcode on Apple Watch for Sign in with Apple, and an unhandled request is
            // what a watch without one produces.
            return "Apple sign-in not handled. Check the Apple Watch has a passcode and an Apple ID signed in."
        case .invalidResponse:
            return "Apple returned an invalid response"
        case .failed:
            return "Apple sign-in failed. Check the watch passcode and the Sign in with Apple entitlement."
        case .unknown:
            return "Apple sign-in could not be verified"
        @unknown default:
            return "Apple sign-in could not be verified"
        }
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
            stage = .signedIn
        } catch let error as AppleCredentialValidationError {
            message = error == .stateMismatch
                ? "Apple sign-in state verification failed"
                : "Apple credential unavailable"
            stage = .failed("server rejected the Apple credential")
        } catch {
            message = "Apple sign-in could not be verified"
            stage = .failed("the server could not be reached or refused the credential")
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

                    // The stage is on screen while the flow runs, and stays on screen after it stops. Sign
                    // in with Apple was reported as doing nothing at all, and this is what turns that
                    // report into a question with an answer: a stage stuck at tapped never became a sheet,
                    // a stage stuck at sheetPresented never came back.
                    WatchNativeAppleIDButton { appleAuthentication.start() }
                        .frame(height: 34)
                        .allowsHitTesting(!appleAuthentication.isAuthenticating)
                        .opacity(appleAuthentication.isAuthenticating ? 0.6 : 1)

                    Text(stageLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)

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

    /// The stage, named for a person reading it on a watch.
    private var stageLabel: String {
        switch appleAuthentication.stage {
        case .idle: return ""
        case .tapped: return "Sign in with Apple: tapped, no sheet yet"
        case .sheetPresented: return "Sign in with Apple: waiting for Apple"
        case .credentialReceived: return "Sign in with Apple: checking with server"
        case .signedIn: return "Sign in with Apple: signed in"
        case let .failed(reason): return "Sign in with Apple: " + reason
        }
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
