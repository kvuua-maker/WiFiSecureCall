import SwiftUI

struct WatchRootView: View {
    @ObservedObject var session: CallSession
    var body: some View {
        VStack(spacing: 8) {
            Text("WiFi Secure Call").font(.headline)
            Text(status).font(.caption).multilineTextAlignment(.center)
            controls
        }.padding(4)
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
        case .idle: Button("Call iPhone") { Task { await session.startCall() } }
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
