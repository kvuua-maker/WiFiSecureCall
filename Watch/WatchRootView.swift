import SwiftUI

struct WatchRootView: View {
    @ObservedObject var session: CallSession
    @StateObject private var accountStore = AccountSessionStore.shared
    @State private var showAccount = false
    @State private var showAccountPicker = false
    @State private var showCallUser = false
    @State private var showSystemDialer = false
    @State private var showCarrierCallingProbe = false
    @State private var showRemoteCellularControl = false
    var body: some View {
        VStack(spacing: 8) {
            Text("WiFi Secure Call").font(.headline)
            Text(status).font(.caption).multilineTextAlignment(.center)
            controls
        }
        .padding(4)
        .sheet(isPresented: $showAccount) { WatchAccountLinkView(store: accountStore) }
        .sheet(isPresented: $showAccountPicker) {
            SecureOutgoingAccountPicker(choices: accountStore.callableAccounts.map(SecureAccountChoice.init)) { choice in
                showAccountPicker = false
                Task {
                    await NotificationRuntime.shared.startPreferredCall(
                        targetPlatform: "iOS",
                        accountID: choice.accountID
                    )
                }
            }
        }
        .sheet(isPresented: $showCallUser) { CallUserView(store: accountStore) }
        .sheet(isPresented: $showSystemDialer) { WatchSystemDialerView() }
        .sheet(isPresented: $showCarrierCallingProbe) { WatchCarrierCallingDiagnosticView() }
        .sheet(isPresented: $showRemoteCellularControl) { WatchRemoteCellularControlView() }
    }
    private var status: String {
        switch session.state {
        case .idle: return "Ready"
        case .outgoingRinging: return "Calling…"
        case .incomingRinging: return session.incomingCallerName.map { "Incoming call from " + $0 } ?? "Incoming Wi-Fi call"
        case .connecting: return "Connecting…"
        case .active: return String(format: "%02d:%02d", session.elapsedSeconds / 60, session.elapsedSeconds % 60)
        case .reconnecting: return "Reconnecting…"
        case .ending: return "Ending…"
        case .ended: return "Call ended"
        case let .failed(_, failure): return failure.rawValue
        }
    }
    @ViewBuilder private var controls: some View {
        switch session.state {
        case .idle:
            VStack(spacing: 6) {
                Button("Secure Call") { beginSecureCall() }
                Button("Call user") { if accountStore.callableAccounts.isEmpty { showAccount = true } else { showCallUser = true } }
                Button("Mobile Call") { showSystemDialer = true }
                Button("Carrier probe") { showCarrierCallingProbe = true }
                    .font(.caption2)
                Button("Remote cellular probe") { showRemoteCellularControl = true }
                    .font(.caption2)
                Button(accountStore.accounts.isEmpty ? "Link Account" : "Account") { showAccount = true }
                    .font(.caption2)
            }
        case .outgoingRinging: Button("Cancel", role: .destructive) { Task { await session.cancel() } }
        case .incomingRinging:
            HStack { Button("Reject", role: .destructive) { Task { await session.reject() } }; Button("Accept") { Task { await session.accept() } } }
        case .active:
            HStack { Button(session.isMuted ? "Unmute" : "Mute") { session.toggleMute() }; Button("End", role: .destructive) { Task { await session.endCall() } } }
        case .connecting, .reconnecting: VStack { ProgressView(); Button("End", role: .destructive) { Task { await session.endCall() } } }
        case .ending: ProgressView()
        case .ended, .failed: Button("Done") { session.reset() }
        }
    }

    private func beginSecureCall() {
        let accounts = accountStore.callableAccounts
        if accounts.isEmpty {
            showAccount = true
        } else if accounts.count == 1, let account = accounts.first {
            Task {
                await NotificationRuntime.shared.startPreferredCall(
                    targetPlatform: "iOS",
                    accountID: account.accountID
                )
            }
        } else {
            showAccountPicker = true
        }
    }
}
