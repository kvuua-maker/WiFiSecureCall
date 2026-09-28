import SwiftUI

struct ActiveCallView: View {
    @ObservedObject var session: CallSession

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill").font(.largeTitle).foregroundStyle(.green)
            Text(session.incomingCallerName ?? "Secure contact").font(.title2).multilineTextAlignment(.center)
            Text(connectionText).foregroundStyle(.secondary)
            if session.elapsedSeconds > 0 { Text(duration).monospacedDigit() }
            HStack(spacing: 30) {
                Button { session.toggleMute() } label: {
                    Label(session.isMuted ? "Unmute" : "Mute", systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill")
                }
                .accessibilityLabel(session.isMuted ? ProductAccessibility.unmute : ProductAccessibility.mute)
                Button(role: .destructive) { Task { await session.endCall() } } label: { Label("End", systemImage: "phone.down.fill") }
                    .accessibilityLabel(ProductAccessibility.endCall)
            }
        }
        .padding()
        .navigationTitle("Call")
    }

    private var duration: String { String(format: "%02d:%02d", session.elapsedSeconds / 60, session.elapsedSeconds % 60) }
    private var connectionText: String {
        switch session.state {
        case .idle: return "Ready"
        case .incomingRinging: return "Incoming encrypted call"
        case .outgoingRinging: return "Calling securely…"
        case .connecting: return "Establishing encryption…"
        case .active: return "End-to-end encrypted"
        case .reconnecting: return "Reconnecting securely…"
        case .ending: return "Ending…"
        case .ended: return "Call ended"
        case .failed: return "Call failed"
        }
    }
}
