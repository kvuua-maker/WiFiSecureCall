import SwiftUI

/// The home screen: a list of people, and nothing that is not a person.
///
/// Each row is a card with initials, name and status. Long-press opens the two
/// ways to reach somebody, swipe-left removes the row from this watch, and a glow
/// in the corner says the media path is live without needing a status line.
struct PigeonListView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var contacts = WatchContactsStore.shared
    @ObservedObject private var bridge = WatchCallBridge.shared
    @ObservedObject private var accountStore = AccountSessionStore.shared

    @State private var showDialPad = ProcessInfo.processInfo.arguments.contains("-uiTestingDialPad")

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WatchTheme.background.ignoresSafeArea()
            cornerGlow

            ScrollView {
                VStack(spacing: 8) {
                    header
                    if contacts.contacts.isEmpty {
                        emptyCard
                    } else {
                        ForEach(contacts.contacts) { contact in
                            contactCard(contact)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 10)
            }
        }
        .sheet(isPresented: $showDialPad) { PigeonDialView() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Text("Calls")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            // Mode B lives behind one obvious glyph: it leaves the app entirely.
            Button {
                DiagnosticsLog.shared.log(.ui, "button_tapped", .info, details: "home.dial")
                showDialPad = true
            } label: {
                Image(systemName: "dial.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WatchTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.dialNumber")
        }
        .padding(.top, 2)
    }

    private func contactCard(_ contact: WatchContact) -> some View {
        Button {
            call(contact)
        } label: {
            HStack(spacing: 8) {
                avatar(for: contact)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(contact.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(WatchTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WatchTheme.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                call(contact)
            } label: {
                Label("Call in app", systemImage: "phone.fill")
            }
            Button {
                showDialPad = true
            } label: {
                Label("Dial a number", systemImage: "dial.fill")
            }
            Button(role: .destructive) {
                hide(contact)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .accessibilityIdentifier("home.contact.\(contact.id)")
    }

    private func avatar(for contact: WatchContact) -> some View {
        ZStack {
            Circle()
                .fill(Color(hue: contact.hue, saturation: 0.55, brightness: 0.55))
                .frame(width: 32, height: 32)
            Text(contact.initials)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(WatchTheme.muted)
            Text("No contacts yet")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
            Text("Sign in on the iPhone to sync")
                .font(.system(size: 9))
                .foregroundStyle(WatchTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    /// The corner glow: a soft accent light that is only lit while the phone is
    /// reachable, so "connected" is visible at a glance and never costs a row.
    private var cornerGlow: some View {
        Circle()
            .fill(WatchTheme.accent)
            .frame(width: 90, height: 90)
            .blur(radius: 38)
            .opacity(bridge.isPhoneReachable ? 0.55 : 0.12)
            .offset(x: 42, y: -48)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.8), value: bridge.isPhoneReachable)
    }

    // MARK: - Actions

    private func call(_ contact: WatchContact) {
        DiagnosticsLog.shared.log(.ui, "button_tapped", .info, details: "home.card.call")
        DiagnosticsLog.shared.log(.signaling, "call_create_requested", .info, details: "target=iOS")
        Haptic.success()
        Task { await NotificationRuntime.shared.startPreferredCall(targetPlatform: "iOS") }
    }

    private func hide(_ contact: WatchContact) {
        DiagnosticsLog.shared.log(.ui, "gesture_recognized", .info, details: "swipe_delete")
        WatchContactsStore.shared.hide(contact)
    }
}
