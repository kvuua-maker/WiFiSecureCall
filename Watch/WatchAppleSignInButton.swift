import SwiftUI
#if os(watchOS)
import AuthenticationServices
import WatchKit
#endif

/// The only Sign in with Apple control App Review accepts on watchOS.
///
/// `WKInterfaceAuthorizationAppleIDButton` is the system-drawn button: it is the
/// one control whose title, logo and proportions Apple require, so the app uses it
/// wrapped in `WKInterfaceObjectRepresentable` instead of drawing its own.
#if os(watchOS)
struct WatchAppleSignInButton: WKInterfaceObjectRepresentable {
    let action: () -> Void

    @MainActor
    final class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeWKInterfaceObject(context: Context) -> WKInterfaceAuthorizationAppleIDButton {
        WKInterfaceAuthorizationAppleIDButton(
            style: .default,
            target: context.coordinator,
            action: #selector(Coordinator.activate)
        )
    }

    func updateWKInterfaceObject(_ object: WKInterfaceAuthorizationAppleIDButton, context: Context) {}
}
#endif
