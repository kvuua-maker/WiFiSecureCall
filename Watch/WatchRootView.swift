import SwiftUI

/// The watch home screen.
///
/// Two ways to call, and the screen says which is which: **Call App User** runs
/// our own Wi-Fi call whose audio lives on this watch (Mode A), while **Dial
/// Number** hands a number to watchOS and the carrier (Mode B). Nothing else is
/// on the main screen.
struct WatchRootView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var accountStore = AccountSessionStore.shared
    /// Kept alive so the paired iPhone can publish its account list and any
    /// incoming-call hint; the bridge carries commands, never audio.
    @ObservedObject private var bridge = WatchCallBridge.shared
    @EnvironmentObject private var appleAuthentication: WatchAppleAuthenticationCoordinator
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDialPad = ProcessInfo.processInfo.arguments.contains("-uiTestingDialPad")
    @State private var showAccount = false
    @State private var showDiagnostics = false

    /// A simulator cannot complete Sign in with Apple, so a UI test starts as if
    /// the account were already there. This never triggers in a real launch.
    private var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uiTesting") }
    private var account: AccountSummary? { accountStore.activeAccount }
    private var isOnAppCall: Bool {
        switch session.state {
        case .idle, .ended, .failed: return false
        default: return true
        }
    }

    var body: some View {
        ZStack {
            WatchTheme.background
            if isOnAppCall {
                WatchInCallView(session: session)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        header
                        if account == nil && !isUITesting {
                            signInCard
                        } else {
                            readyContent
                        }
                        footer
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
            }
        }
        .sheet(isPresented: $showDialPad) { WatchDialPadView() }
        .sheet(isPresented: $showAccount) { WatchAccountLinkView(store: accountStore) }
        .sheet(isPresented: $showDiagnostics) { WatchDiagnosticsView(session: session) }
        .onAppear { bridge.activate() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                bridge.applicationDidBecomeActive()
                if account != nil, case .ended = session.state { session.reset() }
            case .inactive, .background:
                bridge.applicationWillResignActive()
            @unknown default:
                break
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "wifi")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WatchTheme.accent)
            Text("WiFi Secure Call")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var signInCard: some View {
        WatchCard {
            VStack(spacing: 8) {
                VStack(spacing: 2) {
                    Text("Sign in to call")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("Your calls run on this watch")
                        .font(.system(size: 9))
                        .foregroundStyle(WatchTheme.muted)
                        .multilineTextAlignment(.center)
                }

                if appleAuthentication.isAuthenticating {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Signing in…").font(.system(size: 10))
                    }
                } else {
                    WatchAppleSignInButton { appleAuthentication.start() }
                        .frame(height: 40)
                        .accessibilityIdentifier("home.signin.apple")
                }

                if !appleAuthentication.message.isEmpty {
                    Text(appleAuthentication.message)
                        .font(.system(size: 9))
                        .foregroundStyle(WatchTheme.muted)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var readyContent: some View {
        VStack(spacing: 8) {
            if account != nil { accountCard }

            // Mode A. The watch is the phone: microphone, speaker and media socket
            // all live here, which is why it works across different networks.
            Button {
                startAppCall()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill").font(.system(size: 15, weight: .bold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Call App User")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text("Wi-Fi, in the app")
                            .font(.system(size: 8))
                            .opacity(0.7)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WatchTheme.accent))
                .foregroundStyle(.black)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.callApp")

            // Mode B. The number goes to watchOS and the carrier; our app is out of
            // the media path from that moment on.
            Button {
                showDialPad = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "dial.fill").font(.system(size: 15, weight: .bold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Dial Number")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text("Phone call via carrier")
                            .font(.system(size: 8))
                            .opacity(0.7)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.14)))
                .foregroundStyle(.white)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.dialNumber")

            HStack(spacing: 6) {
                Button { showAccount = true } label: {
                    Label("Account", systemImage: "person.crop.circle")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.account")

                Button { showDiagnostics = true } label: {
                    Label("Status", systemImage: "info.circle")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.status")
            }
        }
    }

    private var accountCard: some View {
        WatchCard {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(WatchTheme.accent.opacity(0.25)).frame(width: 26, height: 26)
                    Text(initials)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(WatchTheme.accent)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(account?.phoneNumber ?? "Apple ID")
                        .font(.system(size: 9))
                        .foregroundStyle(WatchTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("home.accountCard")
    }

    private var footer: some View {
        Text(footerText)
            .font(.system(size: 9))
            .foregroundStyle(WatchTheme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityIdentifier("home.footer")
    }

    private var footerText: String {
        switch session.state {
        case let .failed(_, failure): return failure.rawValue
        case .ended: return "Call ended"
        default: return "Ready"
        }
    }

    // MARK: - Actions

    private func startAppCall() {
        Haptic.success()
        Task { await NotificationRuntime.shared.startPreferredCall(targetPlatform: "iOS") }
    }

    // MARK: - Account text

    private var displayName: String {
        guard let account else { return "Signed in" }
        let label = account.displayLabel.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "Signed in" : label
    }

    private var initials: String {
        let letters = displayName.compactMap { $0.isLetter ? String($0) : nil }
        return letters.prefix(2).joined().uppercased()
    }
}

/// Diagnostics, kept out of the main screen but still reachable on the wrist.
struct WatchDiagnosticsView: View {
    @ObservedObject var session: CallSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Button("Close") { dismiss() }.font(.system(size: 10))
                row("Account", AccountSessionStore.shared.activeAccount?.displayLabel ?? "signed out")
                row("Call", String(describing: session.state))
                row("Muted", session.isMuted ? "yes" : "no")
                row("Accounts in sync", WatchCallBridge.shared.syncedAccounts.isEmpty ? "none" : WatchCallBridge.shared.syncedAccounts.joined(separator: ", "))
            }
            .padding(.horizontal, 4)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.system(size: 8)).foregroundStyle(WatchTheme.muted)
            Text(value).font(.system(size: 10)).lineLimit(2)
        }
    }
}
