import Foundation

#if os(watchOS)
import SwiftUI
import WatchKit

/// Carrier dialing uses the system's public tel: route; app-to-app calling is a separate action.
/// The background, dimensions and hit shape belong to the Button's LABEL. Applying them outside a
/// plain Button draws a large cell but leaves taps outside its glyph unhandled on watchOS.
///
/// The tel: route is the only public way to ask watchOS for a carrier call, and it cannot place one on
/// its own: Apple documents that the number goes to the system Phone app, "at which point the user can
/// choose whether to continue". So this screen says which of those steps has been reached, and it takes
/// its only claim of success from the system reporting the call connected.
struct WatchSecureDialerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var store = AccountSessionStore.shared
    @ObservedObject private var carrierCall = WatchCarrierCallObserver.shared
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
              TextField("Ввести номер", text: Binding(
                  get: { pad.number },
                  set: { commitNumberInput($0) }
              ))
                .font(.headline.monospacedDigit())
                .lineLimit(2)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
              .accessibilityIdentifier("dialpad.edit-number")
              .accessibilityHint("Ввести або продиктувати номер")
              .disabled(pad.isDialing)
              Button { appendKey("+") } label: {
                  Text("+").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("dialpad.plus")
            }

            if !pad.isEmpty {
                // watchOS truncates the native TextField's label. Review the complete recipient here.
                Text(pad.number)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("dialpad.review-number")
            }

            // Always reachable near the top, independently of the keypad's bottom row.
            Button { placePhoneCall() } label: {
                Label("Зателефонувати", systemImage: "phone.fill")
                    .font(.caption)
                    .dialpadKey(height: keyHeight, color: .green)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dialpad.call")
#if DEBUG
            .accessibilityValue(String(describing: dynamicTypeSize))
#endif
            .disabled(!pad.isCallable || pad.isDialing)

            if !visibleStatus.isEmpty {
                Text(visibleStatus).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dialpad.status")
            }

            ForEach(Array(WatchDialpadLayout.rows.indices), id: \.self) { index in
                HStack(spacing: columnSpacing) {
                    // One carrier action above the number pad. Keep zero/delete as real buttons,
                    // without a second handset or an empty placeholder occupying the bottom row.
                    ForEach(WatchDialpadLayout.rows[index].filter { $0 != .call }, id: \.self) { key in
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

            // Only after a hand-off, and below the keypad, so the keys this screen was rebuilt around keep
            // the geometry they were tested with until a call has actually been requested.
            ForEach(requirements) { requirement in
                Text(WatchCarrierCallRequirements.displayText(for: requirement))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dialpad.requirement")
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
            Button {
                if pad.deleteLast() { numberDidChange() }
            } label: {
                Image(systemName: "delete.left")
                    .dialpadKey(height: keyHeight, color: .gray.opacity(0.28))
            }
            .accessibilityLabel("Видалити останню цифру")
            .accessibilityIdentifier("dialpad.delete")
            .buttonStyle(.plain)
        case .call:
            // The legacy layout model includes a handset; production renders it only once, above.
            EmptyView()
        default:
            Button { appendKey(key.digit ?? "0") } label: {
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
    /// What the screen says about the attempt, newest first.
    ///
    /// Once a number has been handed over the verdict replaces the editing hint. A line about the number
    /// being editable is not what the owner needs to read after asking for a call.
    private var visibleStatus: String {
        carrierCall.report.isHandedOff ? carrierCall.report.verdict.displayText : status
    }

    /// What the watch could establish about this route, read at the moment it is shown.
    ///
    /// The carrier's half of the route is listed as `notDetectable` rather than guessed, because nothing
    /// on watchOS reports whether the carrier offers Wi-Fi calling or whether the iPhone has
    /// `Add Wi-Fi Calling For Other Devices` switched on.
    private var requirements: [WatchCarrierCallRequirement] {
        guard carrierCall.report.isHandedOff else { return [] }
        return WatchCarrierCallRequirements.evaluate(
            network: SystemDialNetworkMonitor.shared.current,
            paired: carrierCall.isPairedWithIPhone,
            verdict: carrierCall.report.verdict
        )
    }

    func appendKey(_ key: Character) {
        if pad.append(key) { numberDidChange() }
    }

    func numberDidChange() {
        // A prior handoff/error describes the prior number, never the newly edited recipient.
        carrierCall.discardAttempt()
        status = pad.isEmpty ? "" : (pad.isCallable
            ? "Перевірте номер і натисніть трубку."
            : "Введіть від 3 до 15 цифр; плюс — лише на початку.")
    }

    func commitNumberInput(_ text: String) {
        // Native watchOS input can reflect the accepted value back into this binding after an
        // invalid edit. That is not another user edit and must not erase the rejection message.
        guard !pad.isDialing, text != pad.number else { return }
        if pad.replaceFromSystemInput(text) {
            numberDidChange()
        } else {
            status = "Номер не змінено. Диктуйте по одній цифрі; плюс — лише на початку."
        }
        // The native TextField edits the number only. No onSubmit/onChange starts a call.
    }

    /// Hands the typed number to the system as a phone call.
    ///
    /// The system owns the call from the moment the URL is opened and reports nothing back through this
    /// call site: watchOS shows the Phone app, where the owner confirms, and the carrier then carries the
    /// call. So the claim made here is the hand-off, `WatchCarrierCallObserver` takes over from that point,
    /// and the latch is released straight after so a hand-off that never leaves this app cannot leave the
    /// key dead.
    func placePhoneCall() {
        switch pad.dialDecision {
        case .noNumber:
            status = "Спочатку введіть номер."
        case .invalidNumber:
            status = "Введіть від 3 до 15 цифр."
        case let .start(url):
            guard pad.beginDial() else { return }
            carrierCall.requestHandoff()
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
