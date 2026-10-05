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
/// choose whether to continue". So this screen brings the watch's own network up first, takes its only
/// claim of success from the system reporting the call connected, and can always be dialled again.
struct WatchSecureDialerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var store = AccountSessionStore.shared
    @ObservedObject private var carrierCall = WatchCarrierCallObserver.shared
    @ObservedObject private var preparer = WatchCallPreparer.shared
    @ObservedObject private var handoff = WatchCallPreparer.shared.handoff
    @State private var dialerOwnerID = UUID()
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
              .disabled(isDialing)
              Button { appendKey("+") } label: {
                  Text("+").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("dialpad.plus")
              .disabled(isDialing)
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
            .disabled(!pad.isCallable || isDialing)

            if !visibleStatus.isEmpty {
                Text(visibleStatus).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dialpad.status")
#if DEBUG
                    .accessibilityValue(String(handoff.handoffCount))
#endif
            }

            // Only the case where it changes what a failure means: the number went to the system on a path
            // this app could not prove. Kept beside the verdict and out of the keypad's geometry.
            if let caution = carrierCall.report.handoffEvidence?.caution {
                Text(caution).font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dialpad.hand-off-path")
            }

            ForEach(Array(WatchDialpadLayout.rows.indices), id: \.self) { index in
                HStack(spacing: columnSpacing) {
                    // One carrier action above the number pad. Keep zero/delete as real buttons,
                    // without a second handset or an empty placeholder occupying the bottom row.
                    ForEach(WatchDialpadLayout.rows[index].filter { $0 != .call }, id: \.self) { key in
                        cell(for: key)
                    }
                }
                .disabled(isDialing)
            }

            if showsSecureAccountCall {
                Text(accountState).font(.caption2).foregroundStyle(.secondary)
                Button("Call app user") { startSecureCall() }
                    .font(.caption2)
                    .disabled(!pad.isCallable || isDialing)
            }

          }
          .padding(.horizontal, 4)
          .padding(.bottom, 8)
        }
        .accessibilityIdentifier("dialpad.scroll")
        .onAppear { handoff.screenDidAppear(owner: dialerOwnerID) }
        .onDisappear { handoff.screenDidDisappear(owner: dialerOwnerID) }
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
    var isDialing: Bool { pad.isDialing || handoff.isBusy }
    /// What the screen says about the attempt, newest first.
    ///
    /// Once a number has been handed over the verdict replaces the editing hint. A line about the number
    /// being editable is not what the owner needs to read after asking for a call.
    private var visibleStatus: String {
        if preparer.isWarmingUp { return "Готовимо мережу Watch…" }
        return carrierCall.report.isHandedOff ? carrierCall.report.verdict.displayText : status
    }

    func appendKey(_ key: Character) {
        guard !isDialing else { return }
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
        guard !isDialing, text != pad.number else { return }
        if pad.replaceFromSystemInput(text) {
            numberDidChange()
        } else {
            status = "Номер не змінено. Диктуйте по одній цифрі; плюс — лише на початку."
        }
        // The native TextField edits the number only. No onSubmit/onChange starts a call.
    }

    /// Brings the watch's own network up, then hands the typed number to the system as a phone call.
    ///
    /// The order is the fix, not the message. A watch keeps its radios switched off while the iPhone is not
    /// nearby until an app uses the network, and Apple states that outgoing calls then take longer; handing
    /// the number over before that has happened asks the carrier to place a call over a network the system
    /// has not finished bringing up. So the network is asked for first, bounded so the key cannot hang, and
    /// the number is handed over either way — the system phone app may have a path this app cannot see.
    ///
    /// The coordinator owns the task and keeps the claim across system handoff. Dismissal cancels
    /// preparation; returning from the system releases the claim without relying on this closure resuming.
    func placePhoneCall() {
        switch pad.dialDecision {
        case .noNumber:
            status = "Спочатку введіть номер."
        case .invalidNumber:
            status = "Введіть від 3 до 15 цифр."
        case let .start(url):
            guard !pad.isDialing else { return }
            handoff.begin(owner: dialerOwnerID,
                          prepare: { await preparer.prepareForHandOff() },
                          cancelPreparation: { preparer.cancelWarmUp() }) { evidence in
                carrierCall.requestHandoff()
                carrierCall.noteHandoffEvidence(evidence)
                WKApplication.shared().openSystemURL(url)
            }
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
