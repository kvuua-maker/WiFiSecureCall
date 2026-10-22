import Combine
import SwiftUI

/// The Mode A call screen.
///
/// This is an app-to-app call: the watch owns its own microphone, speaker and
/// media socket, so mute and end act locally through `CallSession`. CallKit draws
/// the system call UI on top; this screen is what the wrist sees inside the app.
struct WatchInCallView: View {
    @ObservedObject var session: CallSession
    @Environment(\.dismiss) private var dismiss

    private var elapsed: Int { session.elapsedSeconds }
    private var state: CallState { session.state }

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
            Image(systemName: isActive ? "waveform" : "phone.arrow.up.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
        .overlay(alignment: .bottomTrailing) {
            if isActive {
                Circle()
                    .fill(WatchTheme.accent)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(WatchTheme.backgroundBottom, lineWidth: 2))
            }
        }
    }

    private var title: some View {
        VStack(spacing: 1) {
            Text(callerTitle)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(WatchTheme.muted)
        }
    }

    private var isActive: Bool {
        if case .active = state { return true }
        if case .reconnecting = state { return true }
        return false
    }

    private var callerTitle: String {
        session.incomingCallerName ?? "App call"
    }

    private var label: String {
        switch state {
        case .idle: return "Starting…"
        case .outgoingRinging: return "Calling…"
        case .incomingRinging: return "Incoming…"
        case .connecting: return "Connecting…"
        case .active: return "Wi-Fi call"
        case .reconnecting: return "Reconnecting…"
        case .ending: return "Ending…"
        case .ended: return "Ended"
        case let .failed(_, failure): return failure.rawValue
        }
    }

    private var time: String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Haptic.key()
                session.toggleMute()
            } label: {
                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("call.mute")
            .accessibilityLabel(session.isMuted ? "Unmute" : "Mute")

            Button {
                Haptic.failure()
                Task { await session.endCall() }
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

}
