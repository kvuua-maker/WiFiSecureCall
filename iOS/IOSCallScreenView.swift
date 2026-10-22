import SwiftUI

/// The call, full screen.
///
/// The contact's colour fills the background as a blurred wash, so the screen is
/// recognisably *them* before a single word is read. Three buttons, one timer.
struct IOSCallScreenView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var history = CallHistoryStore.shared
    @State private var speaker = false

    private var name: String { session.incomingCallerName ?? "App call" }
    private var elapsed: Int { session.elapsedSeconds }
    private var isActive: Bool {
        if case .active = session.state { return true }
        if case .reconnecting = session.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            IOSTheme.background.ignoresSafeArea()
            blurredBackdrop

            VStack(spacing: 0) {
                Spacer(minLength: 30)
                IOSAvatar(name: name, size: 96)
                    .shadow(color: IOSTheme.avatarColor(for: name).opacity(0.6), radius: 30)
                Text(name)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 16)
                Text(label)
                    .font(.system(size: 14))
                    .foregroundColor(IOSTheme.textSecondary)
                    .padding(.top, 4)
                Text(IOSTheme.format(elapsed))
                    .font(.system(size: 40, weight: .light).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.top, 10)
                    .accessibilityIdentifier("call.timer")

                Spacer(minLength: 0)

                HStack(spacing: 28) {
                    roundButton(symbol: session.isMuted ? "mic.slash.fill" : "mic.fill", title: "Mute", tint: IOSTheme.surfaceRaised) {
                        session.toggleMute()
                    }
                    roundButton(symbol: speaker ? "speaker.wave.3.fill" : "speaker.wave.2.fill", title: "Speaker", tint: IOSTheme.surfaceRaised) {
                        speaker.toggle()
                    }
                    roundButton(symbol: "phone.down.fill", title: "End", tint: IOSTheme.destructive) {
                        Task { await session.endCall() }
                    }
                }
                .padding(.bottom, 46)
            }
        }
        .onAppear {
            DiagnosticsLog.shared.log(.ui, "screen_rendered", .info, details: "call")
        }
    }

    private var blurredBackdrop: some View {
        ZStack {
            Circle()
                .fill(IOSTheme.avatarColor(for: name))
                .frame(width: 380, height: 380)
                .blur(radius: 120)
                .opacity(0.55)
                .offset(y: -140)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func roundButton(symbol: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button {
                DiagnosticsLog.shared.log(.ui, "button_tapped", .info, details: "call.\(title.lowercased())")
                action()
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(tint))
            }
            .buttonStyle(.plain)
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(IOSTheme.textSecondary)
        }
    }

    private var label: String {
        switch session.state {
        case .idle: return "Starting…"
        case .outgoingRinging: return "Calling…"
        case .incomingRinging: return "Incoming call"
        case .connecting: return "Connecting…"
        case .active: return "Wi-Fi call"
        case .reconnecting: return "Reconnecting…"
        case .ending: return "Ending…"
        case .ended: return "Call ended"
        case let .failed(_, failure): return failure.rawValue
        }
    }
}
