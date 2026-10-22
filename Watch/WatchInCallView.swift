import Combine
import SwiftUI

/// The call screen.
///
/// CallKit draws the system call UI, and this is the app's own view of the same
/// call: who is on the line, how long it has run, and the two controls a wrist
/// needs. The call itself is hosted on the iPhone, so mute and end are requests
/// sent over WatchConnectivity rather than local state changes.
struct WatchInCallView: View {
    @ObservedObject var bridge: WatchCallBridge
    @Environment(\.dismiss) private var dismiss

    @State private var now = Date()

    private var elapsed: Int {
        guard let start = bridge.callStartedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(start)))
    }

    private var state: WatchBridgeCallState? { bridge.lastIncomingState }

    var body: some View {
        ZStack {
            WatchTheme.background
            VStack(spacing: 10) {
                avatar
                title
                Text(time)
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(WatchTheme.muted)
                controls
            }
            .padding(.horizontal, 8)
        }
        .onAppear { tick() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in tick() }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [WatchTheme.accent.opacity(0.55), WatchTheme.accent.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 54, height: 54)
            Image(systemName: state == .active ? "waveform" : "phone.arrow.up.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
        .overlay(alignment: .bottomTrailing) {
            if state == .active {
                Circle()
                    .fill(WatchTheme.accent)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(WatchTheme.backgroundBottom, lineWidth: 2))
            }
        }
    }

    private var title: some View {
        VStack(spacing: 1) {
            Text(bridge.remoteDisplayName)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(WatchTheme.muted)
        }
    }

    private var label: String {
        switch state {
        case .active: return "Call on iPhone"
        case .dialing: return "Calling…"
        case .ringing: return "Ringing…"
        case .resolving: return "Resolving…"
        case .ended: return "Ended"
        case .failed: return bridge.status.isEmpty ? "Failed" : bridge.status
        case .handedToSystem: return "Dialled on iPhone"
        case .none: return "Starting…"
        }
    }

    private var time: String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Haptic.key()
                bridge.toggleMuteOnPhone()
            } label: {
                Image(systemName: bridge.isMutedOnPhone ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("call.mute")
            .accessibilityLabel(bridge.isMutedOnPhone ? "Unmute" : "Mute")

            Button {
                Haptic.failure()
                bridge.endCallOnPhone()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(WatchTheme.danger))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("call.end")
            .accessibilityLabel("End call")
        }
    }

    private func tick() {
        now = Date()
        guard let started = bridge.callStartedAt else { return }
        // A call the phone ended without telling the watch should not tick forever.
        if state == .ended && Date().timeIntervalSince(started) > 5 {
            bridge.resetCallDisplay()
        }
    }
}
