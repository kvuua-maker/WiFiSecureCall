import Foundation

#if os(watchOS)
import SwiftUI
import WatchKit

/// Carrier dialing uses the system's public tel: route; app-to-app calling is a separate action.
/// The background, dimensions and hit shape belong to the Button's LABEL. Applying them outside a
/// plain Button draws a large cell but leaves taps outside its glyph unhandled on watchOS.
struct WatchSecureDialerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var store = AccountSessionStore.shared
    @State private var pad = WatchDialpadModel()
    @State private var status = ""
    var showsSecureAccountCall = true

    private let columnSpacing: CGFloat = 3
    private let rowSpacing: CGFloat = 3
    private let keyHeight: CGFloat = 44

    var body: some View {
        ScrollView {
          VStack(spacing: rowSpacing) {
            HStack(spacing: 4) {
              Text(pad.isEmpty ? "Number" : pad.number)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("dialpad.number")
#if DEBUG
                .accessibilityValue(String(describing: dynamicTypeSize))
#endif
              Button { _ = pad.append("+") } label: {
                  Text("+").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("dialpad.plus")
            }

            ForEach(Array(WatchDialpadLayout.rows.indices), id: \.self) { index in
                HStack(spacing: columnSpacing) {
                    ForEach(WatchDialpadLayout.rows[index], id: \.self) { key in
                        cell(for: key)
                    }
                }
            }

            if showsSecureAccountCall {
                Text(accountState).font(.caption2).foregroundStyle(.secondary)
                Button("Call app user") { startSecureCall() }
                    .font(.caption2)
                    .disabled(!pad.isCallable || pad.isDialing)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dialpad.status")
            }
          }
          .padding(.horizontal, 4)
          .padding(.bottom, 8)
        }
        .accessibilityIdentifier("dialpad.scroll")
    }

    @ViewBuilder
    private func cell(for key: WatchDialpadLayout.Key) -> some View {
        switch key {
        case .delete:
            Button { _ = pad.deleteLast() } label: {
                Image(systemName: "delete.left")
                    .dialpadKey(height: keyHeight, color: .gray.opacity(0.28))
            }
            .accessibilityLabel("Delete")
            .accessibilityIdentifier("dialpad.delete")
            .buttonStyle(.plain)
        case .call:
            Button { placePhoneCall() } label: {
                Image(systemName: "phone.fill")
                    .dialpadKey(height: keyHeight, color: .green)
            }
            .accessibilityLabel("Call")
            .accessibilityIdentifier("dialpad.call")
            .buttonStyle(.plain)
            .disabled(!pad.isCallable || pad.isDialing)
        default:
            Button { _ = pad.append(key.digit ?? "0") } label: {
                Text(String(key.digit ?? "0"))
                    .dialpadKey(height: keyHeight, color: .gray.opacity(0.28))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dialpad.\(key.digit ?? "0")")
        }
    }
}

private extension View {
    func dialpadKey(height: CGFloat, color: Color) -> some View {
        self.frame(maxWidth: .infinity, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(color))
            .contentShape(Rectangle())
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
