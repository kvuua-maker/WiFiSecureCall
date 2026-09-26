import SwiftUI

struct IOSRootView: View {
    @ObservedObject var session: CallSession
    @StateObject private var accountStore = AccountSessionStore.shared
    @State private var showAccount = false
    @State private var showAccountPicker = false
    @State private var showDialDiagnostics = false

    var body: some View {
        VStack(spacing: 24) {
            Text("WiFi Secure Call").font(.largeTitle.bold())
            Text(status).foregroundStyle(.secondary)
            controls
        }
        .padding(32)
        .sheet(isPresented: $showAccount) { AccountView(store: accountStore) }
        .sheet(isPresented: $showAccountPicker) {
            SecureOutgoingAccountPicker(choices: accountStore.callableAccounts.map(SecureAccountChoice.init)) { choice in
                showAccountPicker = false
                Task {
                    await NotificationRuntime.shared.startPreferredCall(
                        targetPlatform: "watchOS",
                        accountID: choice.accountID
                    )
                }
            }
        }
        .sheet(isPresented: $showDialDiagnostics) { SystemDialDiagnosticsView() }
    }

    private var status: String {
        switch session.state {
        case .idle: return "Ready"
        case .outgoingRinging: return "Calling…"
        case .incomingRinging: return "Incoming Wi-Fi call"
        case .connecting: return "Connecting…"
        case .active: return String(format: "%02d:%02d", session.elapsedSeconds / 60, session.elapsedSeconds % 60)
        case .reconnecting: return "Reconnecting…"
        case .ending: return "Ending…"
        case .ended: return "Call ended"
        case let .failed(_, reason): return "Call failed: \(reason.rawValue)"
        }
    }

    @ViewBuilder private var controls: some View {
        switch session.state {
        case .idle:
            VStack {
                Button("Secure Call to Watch") { beginSecureCall() }.buttonStyle(.borderedProminent)
                Button(accountStore.activeAccount?.phoneNumber ?? "Account") { showAccount = true }.font(.footnote)
                Button("Dial diagnostics") { showDialDiagnostics = true }.font(.footnote)
            }
        case .outgoingRinging:
            Button("Cancel", role: .destructive) { Task { await session.cancel() } }
        case .incomingRinging:
            HStack { Button("Reject", role: .destructive) { Task { await session.reject() } }; Button("Accept") { Task { await session.accept() } }.buttonStyle(.borderedProminent) }
        case .connecting, .reconnecting:
            VStack { ProgressView(); Button("End", role: .destructive) { Task { await session.endCall() } } }
        case .ending:
            ProgressView()
        case .active:
            HStack { Button(session.isMuted ? "Unmute" : "Mute") { session.toggleMute() }; Button("End", role: .destructive) { Task { await session.endCall() } } }
        case .ended, .failed:
            Button("Done") { session.reset() }
        }
    }

    private func beginSecureCall() {
        let accounts = accountStore.callableAccounts
        if accounts.isEmpty {
            showAccount = true
        } else if accounts.count == 1, let account = accounts.first {
            Task {
                await NotificationRuntime.shared.startPreferredCall(
                    targetPlatform: "watchOS",
                    accountID: account.accountID
                )
            }
        } else {
            showAccountPicker = true
        }
    }
}
