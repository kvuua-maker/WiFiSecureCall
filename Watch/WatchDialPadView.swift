import SwiftUI
#if os(watchOS)
import WatchKit
#endif

/// The dialpad.
///
/// Every key is a fixed circle with its own hit area, laid out in a real grid
/// rather than a stack of cramped rows. That is the whole fix for the previous
/// screen: "0", delete and call each own a cell, so a tap can never land on a
/// neighbour, and the call action is a full-width button instead of a glyph
/// squeezed between two other controls.
struct WatchDialPadView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var number = ""
    @State private var feedback = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: WatchTheme.keySpacing), count: 3)
    private let maximumDigits = 15

    private var digits: String { number.filter(\.isNumber) }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                header
                display
                keypad
                numberRow
                WatchDialPadActionRow(isEnabled: digits.count >= 3) {
                    placeCall()
                }
                if !feedback.isEmpty {
                    Text(feedback)
                        .font(.system(size: 10))
                        .foregroundStyle(WatchTheme.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
        .background(WatchTheme.background)
        .onAppear { feedback = "" }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dialpad.close")

            Spacer()

            Text("Dial number")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(WatchTheme.muted)
        }
    }

    private var display: some View {
        Text(number.isEmpty ? " " : number)
            .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, minHeight: 30)
            .foregroundStyle(number.isEmpty ? WatchTheme.muted : .white)
            .accessibilityIdentifier("dialpad.display")
            .accessibilityValue(number)
    }

    private var keypad: some View {
        LazyVGrid(columns: columns, spacing: WatchTheme.keySpacing) {
            ForEach(Self.keys, id: \.label) { key in
                Button {
                    press(key.label)
                } label: {
                    Text(key.label)
                }
                .buttonStyle(WatchKeyButtonStyle())
                .accessibilityIdentifier("dialpad.key.\(key.identifier)")
                .accessibilityLabel(key.accessibilityLabel)
            }
        }
    }

    private var numberRow: some View {
        HStack(spacing: WatchTheme.keySpacing) {
            Button {
                press("+")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(WatchKeyButtonStyle())
            .accessibilityIdentifier("dialpad.key.plus")
            .accessibilityLabel("Plus")

            Button {
                press("0")
            } label: {
                Text("0")
            }
            .buttonStyle(WatchKeyButtonStyle())
            .accessibilityIdentifier("dialpad.key.0")
            .accessibilityLabel("Zero")

            Button {
                deleteLast()
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(WatchKeyButtonStyle())
            .accessibilityIdentifier("dialpad.key.delete")
            .accessibilityLabel("Delete")
        }
    }

    // MARK: - Actions

    private func press(_ key: String) {
        switch key {
        case "+":
            guard number.isEmpty else { return }
            number = "+"
        case "0":
            append("0")
        default:
            append(key)
        }
        Haptic.key()
        if !feedback.isEmpty { feedback = "" }
    }

    private func append(_ digit: String) {
        guard digits.count < maximumDigits else {
            feedback = "That is as long as a number gets"
            return
        }
        number.append(digit)
    }

    private func deleteLast() {
        guard !number.isEmpty else { return }
        number.removeLast()
        Haptic.key()
        if !feedback.isEmpty { feedback = "" }
    }

    /// Mode B: the watch asks watchOS to place the call.
    ///
    /// No request goes to our server and no audio passes through this app: the
    /// system Phone takes over, exactly as documented in Docs/CallArchitecture.md.
    /// The Apple confirmation on the iPhone is Apple's, not ours, and stays.
    private func placeCall() {
        guard digits.count >= 3 else {
            feedback = "Enter at least 3 digits"
            Haptic.failure()
            return
        }
        guard let url = WatchSystemDialerNumber.url(for: number), url.scheme == "tel" else {
            feedback = "That is not a valid number"
            Haptic.failure()
            return
        }
        DiagnosticsLog.shared.log(.modeB, "system_dial_requested", .info, details: "digits=\(digits.count)")
        Haptic.success()
        feedback = "Opening the Phone app…"
        // A simulator cannot hand a call to Phone, and a UI test needs the screen
        // to stay put so it can assert what happened.
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") { return }
        #if os(watchOS)
        WKApplication.shared().openSystemURL(url)
        DiagnosticsLog.shared.log(.modeB, "url_opened", .info, details: "tel")
        #endif
        dismiss()
    }

    // MARK: - Keys

    private struct Key {
        let label: String
        let identifier: String
        let accessibilityLabel: String
    }

    private static let keys: [Key] = [
        Key(label: "1", identifier: "1", accessibilityLabel: "One"),
        Key(label: "2", identifier: "2", accessibilityLabel: "Two"),
        Key(label: "3", identifier: "3", accessibilityLabel: "Three"),
        Key(label: "4", identifier: "4", accessibilityLabel: "Four"),
        Key(label: "5", identifier: "5", accessibilityLabel: "Five"),
        Key(label: "6", identifier: "6", accessibilityLabel: "Six"),
        Key(label: "7", identifier: "7", accessibilityLabel: "Seven"),
        Key(label: "8", identifier: "8", accessibilityLabel: "Eight"),
        Key(label: "9", identifier: "9", accessibilityLabel: "Nine")
    ]
}

/// The call action lives outside the grid so it is always a large target.
struct WatchDialPadActionRow: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "phone.fill").font(.system(size: 15, weight: .bold))
                Text("Call").font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isEnabled ? WatchTheme.accent : Color.white.opacity(0.10))
            )
            .foregroundStyle(isEnabled ? Color.black : WatchTheme.muted)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier("dialpad.call")
        .accessibilityLabel("Call")
    }
}

/// Haptics, guarded so the views still compile where WatchKit is absent.
enum Haptic {
    static func key() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #endif
    }

    static func success() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.success)
        #endif
    }

    static func failure() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.failure)
        #endif
    }
}
