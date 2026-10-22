import SwiftUI

/// The call screen.
///
/// One person, one timer, two buttons. The timer is the largest thing on the
/// screen because that is what a wrist glance is for, and the two controls are
/// 60 pt circles at the edge of the display where a thumb reaches without looking.
struct PigeonCallScreen: View {
    @ObservedObject var session: CallSession
    @Environment(\.dismiss) private var dismiss

    private var elapsed: Int { session.elapsedSeconds }
    private var isActive: Bool {
        if case .active = session.state { return true }
        if case .reconnecting = session.state { return true }
        return false
    }
    private var callerTitle: String { session.incomingCallerName ?? "App call" }
    private var initials: String {
        let letters = callerTitle.compactMap { $0.isLetter ? String($0) : nil }
        let value = letters.prefix(2).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    var body: some View {
        ZStack {
            WatchTheme.background.ignoresSafeArea()
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(WatchTheme.accent.opacity(isActive ? 0.28 : 0.14))
                        .frame(width: 56, height: 56)
                    Text(initials)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(WatchTheme.accent)
                }
                .padding(.top, 4)

                Text(callerTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(WatchTheme.muted)

                Text(Self.format(elapsed))
                    .font(.system(size: 26, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("call.timer")

                Spacer(minLength: 0)

                HStack(spacing: 14) {
                    Button {
                        Haptic.key()
                        DiagnosticsLog.shared.log(.callKit, "mute_toggled", .info, details: "muted=\(!session.isMuted)")
                        session.toggleMute()
                    } label: {
                        Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("call.mute")
                    .accessibilityLabel(session.isMuted ? "Unmute" : "Mute")

                    Button {
                        Haptic.failure()
                        DiagnosticsLog.shared.log(.callKit, "call_ended", .info, details: "origin=user")
                        Task { await session.endCall() }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(Color(red: 0.90, green: 0.26, blue: 0.22)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("call.end")
                    .accessibilityLabel("End call")
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 4)
        }
    }

    private var label: String {
        switch session.state {
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

    static func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
