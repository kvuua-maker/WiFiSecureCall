import SwiftUI

/// The watch home screen.
///
/// Three states and nothing else: signed out, ready, on a call. The previous
/// screen stacked eight different buttons, a carrier probe and three status lines
/// in one scroll view, which is why it read as a debug build.
struct WatchRootView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var bridge = WatchCallBridge.shared
    @ObservedObject private var accountStore = AccountSessionStore.shared
    @EnvironmentObject private var appleAuthentication: WatchAppleAuthenticationCoordinator
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDialPad = ProcessInfo.processInfo.arguments.contains("-uiTestingDialPad")
    @State private var showAccount = false
    @State private var showDiagnostics = false

    /// A simulator cannot complete Sign in with Apple, so a UI test starts the app
    /// as if the account were already there. This never triggers in a real launch.
    private var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uiTesting") }

    private var account: AccountSummary? { accountStore.activeAccount }
    private var isOnCall: Bool {
        switch bridge.lastIncomingState {
        case .dialing, .ringing, .resolving, .active: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            WatchTheme.background
            if isOnCall {
                WatchInCallView(bridge: bridge)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        header
                        if account == nil && !isUITesting {
                            signInCard
                        } else {
                            readyContent
                        }
                        if let incoming = bridge.incoming {
                            incomingCard(incoming)
                        }
                        footer
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
            }
        }
        .sheet(isPresented: $showDialPad) { WatchDialPadView(bridge: bridge) }
        .sheet(isPresented: $showAccount) { WatchAccountLinkView(store: accountStore) }
        .sheet(isPresented: $showDiagnostics) { WatchDiagnosticsView(session: session, bridge: bridge) }
        .onAppear {
            bridge.activate()
            bridge.applicationDidBecomeActive()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: bridge.applicationDidBecomeActive()
            case .inactive, .background: bridge.applicationWillResignActive()
            @unknown default: break
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

    /// Signing in is the first screen, not something hidden behind a link flow.
    private var signInCard: some View {
        WatchCard {
            VStack(spacing: 8) {
                VStack(spacing: 2) {
                    Text("Sign in to call")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("Your calls run through your iPhone")
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
                        Text(accountSubtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(WatchTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .accessibilityIdentifier("home.accountCard")

            Button {
                showDialPad = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill").font(.system(size: 16, weight: .bold))
                    Text("Call").font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(WatchTheme.accent)
                )
                .foregroundStyle(.black)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.call")

            HStack(spacing: 6) {
                Button {
                    showAccount = true
                } label: {
                    Label("Account", systemImage: "person.crop.circle")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.account")

                Button {
                    showDiagnostics = true
                } label: {
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

    private func incomingCard(_ incoming: WatchBridgeMessage) -> some View {
        WatchCard {
            VStack(spacing: 3) {
                Text("Incoming call").font(.system(size: 11, weight: .semibold))
                if let caller = incoming.caller, !caller.isEmpty {
                    Text(caller).font(.system(size: 10)).foregroundStyle(WatchTheme.muted)
                }
                Text("Answer on iPhone")
                    .font(.system(size: 9))
                    .foregroundStyle(WatchTheme.muted)
                Button("Dismiss") { bridge.clearIncoming() }
                    .font(.system(size: 10))
                    .accessibilityIdentifier("incoming.dismiss")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(bridge.isPhoneReachable ? WatchTheme.accent : Color.orange)
                .frame(width: 5, height: 5)
            Text(bridge.isPhoneReachable ? "iPhone connected" : bridge.status.isEmpty ? "iPhone not reachable" : bridge.status)
                .font(.system(size: 9))
                .foregroundStyle(WatchTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - Account text

    private var displayName: String {
        guard let account else { return "" }
        let label = account.displayLabel.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "Signed in" : label
    }

    private var accountSubtitle: String {
        account?.phoneNumber ?? "Apple ID"
    }

    private var initials: String {
        let letters = displayName.compactMap { $0.isLetter ? String($0) : nil }
        return letters.prefix(2).joined().uppercased()
    }
}

/// Diagnostics, kept out of the main screen but still reachable on the wrist.
struct WatchDiagnosticsView: View {
    @ObservedObject var session: CallSession
    @ObservedObject var bridge: WatchCallBridge
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Button("Close") { dismiss() }.font(.system(size: 10))
                row("Account", AccountSessionStore.shared.activeAccount?.displayLabel ?? "signed out")
                row("iPhone", bridge.isPhoneReachable ? "reachable" : "not reachable")
                row("Call", bridge.lastIncomingState.map(\.rawValue) ?? "none")
                row("Watch call", String(describing: session.state))
                if !bridge.status.isEmpty { row("Status", bridge.status) }
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
