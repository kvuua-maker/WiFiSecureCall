import Foundation

/// Number normalisation for a watch-originated secure call. The watch keeps its own media leg, so the
/// typed value only has to become an E.164 string the server can resolve to a Wi-Fi identity.
enum WatchSecureDialerNumber {
    static func normalized(_ number: String) -> String? {
        let digits = number.filter { $0.isASCII && $0.isNumber }
        guard (3...15).contains(digits.count) else { return nil }
        return "+" + digits
    }
}

#if os(watchOS)
import SwiftUI
import WatchKit

/// Places a call from the Apple Watch. Capture and playback both run on the watch, so no paired
/// iPhone has to be running for the audio path.
struct WatchSecureDialerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = AccountSessionStore.shared
    @State private var number = ""
    @State private var status = ""
    @State private var working = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    private let digits: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    var body: some View {
        ScrollView {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Button("Close") { dismiss() }
                        .font(.caption2)
                        .buttonStyle(.plain)
                    Spacer(minLength: 2)
                    Button("+") { append("+") }
                        .font(.caption)
                        .buttonStyle(.plain)
                }

                Text(number.isEmpty ? "Number" : number)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)

                Text("Audio plays on this Apple Watch")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(digits, id: \.self) { digit in
                        key(String(digit)) { append(digit) }
                    }
                    Button {
                        if !number.isEmpty { number.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                    }
                    .accessibilityLabel("Delete")
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.28)))

                    key("0") { append("0") }

                    Button { startSecureCall() } label: {
                        Image(systemName: "wifi.circle.fill")
                    }
                    .accessibilityLabel("Call over Wi-Fi")
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 8).fill(working ? Color.gray : Color.green))
                }

                Button("Call with cellular") { callOverCellular() }
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
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label) { action() }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.28)))
    }

    private func append(_ value: Character) {
        guard number.count < WatchSystemDialerNumber.maximumCharacterCount else { return }
        guard value.isASCII, value.isNumber || value == "+" else { return }
        if value == "+" {
            guard number.isEmpty else { return }
            number = "+"
            return
        }
        number.append(value)
    }

    private func startSecureCall() {
        guard !working else { return }
        guard let entry = WatchSecureDialerNumber.normalized(number) else {
            status = "Enter at least 3 digits"
            return
        }
        guard let accountID = store.callableAccounts.first(where: { $0.accountID == store.activeAccountID })?.accountID
                ?? store.callableAccounts.first?.accountID else {
            status = "Link an account first"
            return
        }
        working = true
        status = "Resolving…"
        Task { @MainActor in
            do {
                let recipient = try await NotificationRuntime.shared.resolveRecipient(entry, accountID: accountID)
                dismiss()
                await NotificationRuntime.shared.startUserCall(targetUserID: recipient.userID, accountID: accountID)
            } catch is CancellationError {
                working = false
            } catch {
                working = false
                status = Self.safeMessage(error)
            }
        }
    }

    private func callOverCellular() {
        guard let url = WatchSystemDialerNumber.url(for: number), url.scheme == "tel" else {
            status = "Enter a valid number"
            return
        }
        WKApplication.shared().openSystemURL(url)
    }

    private static func safeMessage(_ error: Error) -> String {
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