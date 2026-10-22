import SwiftUI

/// The door: a mark, a name, and Sign in with Apple.
///
/// Nothing else is on this screen, because on a 40 mm display every extra control
/// is a thing to misread while standing up.
struct WatchSignInView: View {
    @EnvironmentObject private var appleAuthentication: WatchAppleAuthenticationCoordinator

    var body: some View {
        ZStack {
            WatchTheme.background.ignoresSafeArea()
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(WatchTheme.accent.opacity(0.18))
                        .frame(width: 52, height: 52)
                    Image(systemName: "phone.badge.waveform.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(WatchTheme.accent)
                }

                VStack(spacing: 2) {
                    Text("WiFi Secure Call")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Calls over Wi-Fi, from your wrist")
                        .font(.system(size: 9))
                        .foregroundStyle(WatchTheme.muted)
                        .multilineTextAlignment(.center)
                }

                if appleAuthentication.isAuthenticating {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Signing in…").font(.system(size: 10))
                    }
                } else {
                    WatchAppleSignInButton { appleAuthentication.start() }
                        .frame(height: 40)
                        .accessibilityIdentifier("signin.apple")
                }

                if !appleAuthentication.message.isEmpty {
                    Text(appleAuthentication.message)
                        .font(.system(size: 9))
                        .foregroundStyle(WatchTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 6)
        }
    }
}
