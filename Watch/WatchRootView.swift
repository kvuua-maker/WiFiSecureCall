import SwiftUI

struct WatchRootView: View {
    @ObservedObject var session: CallSession
    @StateObject private var accountStore = AccountSessionStore.shared
    @State private var showAccount = false
    @State private var showSystemDialer = false
    var body: some View {
        VStack(spacing: 8) {
            Text("WiFi Secure Call").font(.headline)
            Text(status).font(.caption).multilineTextAlignment(.center)
            controls
        }
        .padding(4)
        .sheet(isPresented: $showAccount) { WatchAccountLinkView(store: accountStore) }
        .sheet(isPresented: $showSystemDialer) { WatchSystemDialerView() }
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
        case let .failed(_, failure): return failure.rawValue
        }
    }
    @ViewBuilder private var controls: some View {
        switch session.state {
        case .idle:
            VStack {
                Button("Call iPhone") { Task { await NotificationRuntime.shared.startPreferredCall(targetPlatform: "iOS") } }
                Button(accountStore.activeAccount == nil ? "Link account" : "Account") { showAccount = true }.font(.caption2)
                Button("Dial number") { showSystemDialer = true }.font(.caption2)
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
}
