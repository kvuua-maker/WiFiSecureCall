import SwiftUI

/// What the watch shows, in three states and no more: signed out, the list of
/// people, or a call.
struct WatchRootView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var accountStore = AccountSessionStore.shared
    @ObservedObject private var contacts = WatchContactsStore.shared
    @ObservedObject private var bridge = WatchCallBridge.shared
    @EnvironmentObject private var appleAuthentication: WatchAppleAuthenticationCoordinator
    @Environment(\.scenePhase) private var scenePhase

    @State private var showAccount = false
    @State private var showStatus = false

    private var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uiTesting") }
    private var account: AccountSummary? { accountStore.activeAccount }
    private var isOnCall: Bool {
        switch session.state {
        case .idle, .ended, .failed: return false
        default: return true
        }
    }

    var body: some View {
        Group {
            if isOnCall {
                WatchInCallView(session: session)
            } else if account == nil && !isUITesting {
                WatchSignInView()
            } else {
                ZStack(alignment: .bottom) {
                    WatchHomeView(session: session)
                    bottomBar
                }
            }
        }
        .sheet(isPresented: $showAccount) { WatchAccountLinkView(store: accountStore) }
        .sheet(isPresented: $showStatus) { WatchDiagnosticsView(session: session) }
        .onAppear {
            bridge.activate()
            contacts.refresh(synced: bridge.syncedAccounts)
            if isUITesting { contacts.seedForUITesting() }
            DiagnosticsLog.shared.log(.ui, "screen_rendered", .info, details: "home")
        }
        .onChange(of: bridge.syncedAccounts) { synced in
            contacts.refresh(synced: synced)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                DiagnosticsLog.shared.log(.lifecycle, "entered_foreground", .info)
                bridge.applicationDidBecomeActive()
                contacts.refresh(synced: bridge.syncedAccounts)
                if account != nil, case .ended = session.state { session.reset() }
            case .inactive:
                DiagnosticsLog.shared.log(.lifecycle, "entered_background", .info)
                bridge.applicationWillResignActive()
            case .background:
                DiagnosticsLog.shared.log(.lifecycle, "entered_background", .info)
            @unknown default:
                break
            }
        }
    }

    /// Two glyphs at the bottom edge, away from the cards: account and status.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { showAccount = true } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WatchTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.account")

            Button { showStatus = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WatchTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.status")
        }
        .padding(.bottom, 1)
        .padding(.horizontal, 10)
        .background(
            LinearGradient(colors: [.clear, WatchTheme.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
                .allowsHitTesting(false),
            alignment: .bottom
        )
    }
}

/// Status, small and out of the way.
struct WatchDiagnosticsView: View {
    @ObservedObject var session: CallSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Button("Close") { dismiss() }.font(.system(size: 10))
                row("Call", String(describing: session.state))
                row("Muted", session.isMuted ? "yes" : "no")
                row("Phone", WatchCallBridge.shared.isPhoneReachable ? "reachable" : "not reachable")
                row("Accounts", WatchCallBridge.shared.syncedAccounts.isEmpty ? "none" : WatchCallBridge.shared.syncedAccounts.count.description)
            }
            .padding(.horizontal, 4)
        }
        .onAppear { DiagnosticsLog.shared.log(.ui, "screen_rendered", .info, details: "status") }
    }

    private func row(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.system(size: 8)).foregroundStyle(WatchTheme.muted)
            Text(value).font(.system(size: 10)).lineLimit(2)
        }
    }
}
