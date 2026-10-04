import SwiftUI

struct WatchRootView: View {
    @ObservedObject var session: CallSession
    @StateObject private var accountStore = AccountSessionStore.shared
    @State private var showAccount = false
    @State private var showAccountPicker = false
    @State private var showCallUser = false
    @State private var showSecureDialer = false
    @State private var showSystemDialer = false
    @State private var showCarrierCallingProbe = false

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Text("WiFi Secure Call").font(.headline)
                Text(status).font(.caption2).multilineTextAlignment(.center)
                Text(audioPlacement).font(.system(size: 9)).foregroundStyle(.secondary)
                controls
            }
            .padding(.horizontal, 3)
        }
        .sheet(isPresented: $showAccount) { WatchAccountLinkView(store: accountStore) }
        .sheet(isPresented: $showAccountPicker) {
            SecureOutgoingAccountPicker(choices: accountStore.callableAccounts.map(SecureAccountChoice.init)) { choice in
                showAccountPicker = false
                Task { await NotificationRuntime.shared.startLocalPeerCall(accountID: choice.accountID) }
            }
        }
        .sheet(isPresented: $showCallUser) { CallUserView(store: accountStore) }
        .sheet(isPresented: $showSecureDialer) {
            WatchSecureDialerView()
#if DEBUG
                // A watchOS sheet starts its own hosting environment; apply the UI-test typography
                // inside that presentation as well as on the root screen.
                .transformEnvironment(\.dynamicTypeSize) { size in
                    if ProcessInfo.processInfo.arguments.contains("--uitest-large-text") { size = .xxxLarge }
                }
#endif
        }
        .sheet(isPresented: $showSystemDialer) { WatchSystemDialerView() }
        .sheet(isPresented: $showCarrierCallingProbe) { WatchCarrierCallingDiagnosticView() }
    }

    private var status: String {
        switch session.state {
        case .idle: return "Ready"
        case .outgoingRinging: return "Calling…"
        case .incomingRinging: return session.incomingCallerName.map { "Incoming from " + $0 } ?? "Incoming Wi-Fi call"
        case .connecting: return "Connecting…"
        case .active: return String(format: "%02d:%02d", session.elapsedSeconds / 60, session.elapsedSeconds % 60)
        case .reconnecting: return "Reconnecting…"
        case .ending: return "Ending…"
        case .ended: return "Call ended"
        case let .failed(_, failure): return failure.rawValue
        }
    }

    /// The watch captures and renders both directions of the call itself; no paired iPhone process
    /// takes part in the media path.
    private var audioPlacement: String {
        switch session.state {
        case .idle, .ended, .failed:
            return "Microphone and speaker stay on this Apple Watch"
        case .outgoingRinging, .incomingRinging, .connecting, .active, .reconnecting, .ending:
            return session.isMuted ? "Muted on Apple Watch" : "Call audio on Apple Watch"
        }
    }

    @ViewBuilder private var controls: some View {
        switch session.state {
        case .idle:
            VStack(spacing: 4) {
                Button("Call number") { beginSecureCall() }
                    .font(.body.weight(.semibold))
                Button("Call user") { if accountStore.callableAccounts.isEmpty { showAccount = true } else { showCallUser = true } }
                    .font(.caption)
                Button("Call linked device") { beginLinkedDeviceCall() }
                    .font(.caption2)
                Button(accountStore.accounts.isEmpty ? "Link Account" : "Account") { showAccount = true }
                    .font(.caption2)
                Button("Cellular call") { showSystemDialer = true }
                    .font(.caption2)
                Button("Carrier probe") { showCarrierCallingProbe = true }
                    .font(.caption2)
            }
        case .outgoingRinging:
            Button("Cancel", role: .destructive) { Task { await session.cancel() } }
        case .incomingRinging:
            HStack { Button("Reject", role: .destructive) { Task { await session.reject() } }; Button("Accept") { Task { await session.accept() } } }
        case .active:
            HStack { Button(session.isMuted ? "Unmute" : "Mute") { session.toggleMute() }; Button("End", role: .destructive) { Task { await session.endCall() } } }
        case .connecting, .reconnecting:
            VStack { ProgressView(); Button("End", role: .destructive) { Task { await session.endCall() } } }
        case .ending:
            ProgressView()
        case .ended, .failed:
            Button("Done") { session.reset() }
        }
    }

    private func beginSecureCall() {
        // A carrier telephone call does not require an account in our service.
        // Authentication is checked separately by the app-to-app action.
        showSecureDialer = true
    }

    private func beginLinkedDeviceCall() {
        let accounts = accountStore.callableAccounts
        if accounts.isEmpty {
            showAccount = true
        } else if accounts.count == 1, let account = accounts.first {
            Task { await NotificationRuntime.shared.startLocalPeerCall(accountID: account.accountID) }
        } else {
            showAccountPicker = true
        }
    }
}
