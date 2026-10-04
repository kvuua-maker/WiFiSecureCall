import Foundation

#if os(watchOS)
import SwiftUI
import WatchKit

/// Places a call from the Apple Watch.
///
/// The green key is a handset and it places a phone call, because that is what the shape of the key says
/// it does and what it was pressed for. It used to carry a Wi-Fi glyph and run an account lookup instead,
/// which is a different action wearing the same key; that route is still here, on its own labelled
/// button, where it cannot be mistaken for the call action or take its place.
///
/// The keypad is four `HStack`s in a `VStack` and nothing else. It was a `LazyVGrid` inside a
/// `ScrollView`, and on the watch its last row was drawn and could not be tapped: delete, zero and the
/// call key were all dead while the three rows above them worked. Neither of those containers decides
/// where a key is, so neither of them decides whether a tap reaches it any more. Every key also states
/// its own `contentShape`, so what is tappable is the whole cell and not the symbol drawn inside it, and
/// `WatchDialpadLayout` is what the tests measure these arrangements against.
///
/// The account line reports state and never disables a key: a key that looks available and does nothing
/// was the reported failure, so presentation state is kept out of the action.
struct WatchSecureDialerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = AccountSessionStore.shared
    @State private var pad = WatchDialpadModel()
    @State private var status = ""

    private let columnSpacing: CGFloat = 3
    private let rowSpacing: CGFloat = 3
    private let keyHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: rowSpacing) {
            HStack(spacing: 4) {
                Button("Close") { dismiss() }
                    .font(.caption2)
                    .buttonStyle(.plain)
                Spacer(minLength: 2)
                Button("+") { _ = pad.append("+") }
                    .font(.caption)
                    .buttonStyle(.plain)
            }

            Text(pad.isEmpty ? "Number" : pad.number)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)

            Text(accountState)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            ForEach(Array(WatchDialpadLayout.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: columnSpacing) {
                    ForEach(row, id: \.self) { key in
                        key(for: key)
                    }
                }
            }

            Button("Call over Wi-Fi account") { startSecureCall() }
                .font(.caption2)
                .buttonStyle(.plain)

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 3)
    }

    @ViewBuilder
    private func key(for key: WatchDialpadLayout.Key) -> some View {
        switch key {
        case .delete:
            Button { _ = pad.deleteLast() } label: {
                Image(systemName: "delete.left")
            }
            .accessibilityLabel("Delete")
            .buttonStyle(.plain)
            .cell(keyHeight: keyHeight)
        case .call:
            Button { placePhoneCall() } label: {
                Image(systemName: "phone.fill")
            }
            .accessibilityLabel("Call")
            .buttonStyle(.plain)
            .cell(keyHeight: keyHeight)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(pad.callButtonState == .ready ? Color.green : Color.gray)
            )
        default:
            Button(String(key.digit ?? "0")) { _ = pad.append(key.digit ?? "0") }
                .buttonStyle(.plain)
                .cell(keyHeight: keyHeight)
                .background(RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.28)))
        }
    }
}

/// The one place a key's hit target is defined.
///
/// `contentShape` is what makes the whole cell tappable rather than the glyph or the digit inside it, and
/// it is applied to every key through here so that no key can be given a label without it.
private struct WatchDialpadCell: ViewModifier {
    let keyHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: keyHeight)
            .contentShape(Rectangle())
    }
}

private extension View {
    func cell(keyHeight: CGFloat) -> some View {
        modifier(WatchDialpadCell(keyHeight: keyHeight))
    }
}

private extension WatchSecureDialerView {
    /// Hands the typed number to the system as a phone call.
    ///
    /// The claim is taken for the hand-over and released straight after, because the system owns the call
    /// from that moment and reports nothing back: a latch held open across a hand-off that never leaves
    /// this app is exactly how a call key stops working.
    func placePhoneCall() {
        switch pad.dialDecision {
        case .noNumber:
            status = "Enter a number first"
        case .invalidNumber:
            status = "Enter 3 to 15 digits"
        case let .start(url):
            guard pad.beginDial() else { return }
            status = "Opening phone…"
            WKApplication.shared().openSystemURL(url)
            pad.endDial()
        }
    }

    /// The Wi-Fi account route, kept because it reaches another Wi-Fi Secure Call user, and kept off the
    /// call key because it is not a phone call.
    func startSecureCall() {
        guard pad.beginDial() else { return }
        guard let entry = pad.e164 else {
            pad.endDial()
            status = pad.isEmpty ? "Enter a number first" : "Enter 3 to 15 digits"
            return
        }
        guard let accountID = activeAccountID else {
            pad.endDial()
            status = "Link an account first"
            return
        }
        status = "Resolving…"
        Task { @MainActor in
            do {
                let recipient = try await NotificationRuntime.shared.resolveRecipient(entry, accountID: accountID)
                dismiss()
                await NotificationRuntime.shared.startUserCall(targetUserID: recipient.userID, accountID: accountID)
            } catch is CancellationError {
                pad.endDial()
            } catch {
                pad.endDial()
                status = Self.safeMessage(error)
            }
        }
    }

    var activeAccountID: UUID? {
        store.callableAccounts.first(where: { $0.accountID == store.activeAccountID })?.accountID
            ?? store.callableAccounts.first?.accountID
    }

    /// Reported beside the keypad and read as information only. This line has no way to disable a key.
    var accountState: String {
        let count = store.callableAccounts.count
        if count == 0 { return "Wi-Fi account: not linked" }
        return "Wi-Fi account: \(count) linked"
    }

    static func safeMessage(_ error: Error) -> String {
        guard let apiError = error as? AccountAPIError else { return "Call failed" }
        switch apiError {
        case let .status(_, response):
            switch response?.error {
            case "invalid_recipient": return "Invalid number"
            case "recipient_not_found": return "Number not on Wi-Fi calling"
            case "recipient_unavailable": return "User unavailable"
            default: return "Call failed"
            }
        case .missingSession: return "Link an account first"
        default: return "Call failed"
        }
    }
}
#endif
