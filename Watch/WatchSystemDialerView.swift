import Foundation

enum WatchSystemDialerNumber {
    static let maximumCharacterCount = 20

    static func appending(_ character: Character, to number: String) -> String {
        guard number.count < maximumCharacterCount else { return number }
        if character == "+" { return number.isEmpty ? "+" : number }
        guard character.isASCII, character.isNumber else { return number }
        return number + String(character)
    }

    static func isValid(_ number: String) -> Bool {
        guard number.count <= maximumCharacterCount else { return false }
        let digits = number.first == "+" ? number.dropFirst() : number[...]
        return (3...15).contains(digits.count) && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func url(for number: String) -> URL? {
        guard isValid(number) else { return nil }
        var components = URLComponents()
        components.scheme = "tel"
        components.path = number
        return components.url
    }
}

#if os(watchOS)
import SwiftUI
import WatchKit

struct WatchSystemDialerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = WatchSystemDialCoordinator.shared
    @State private var number = ""
    @State private var showsInvalidNumber = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    private let digits: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(number.isEmpty ? "Enter number" : number)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(maxWidth: .infinity)

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(digits, id: \.self) { digit in
                        Button(String(digit)) { append(digit) }
                    }
                }

                HStack(spacing: 6) {
                    Button("+") { append("+") }
                    Button("0") { append("0") }
                    Button { if !number.isEmpty { number.removeLast() } } label: {
                        Image(systemName: "delete.left")
                    }
                    .accessibilityLabel("Delete")
                }

                Button("Call") { callSystemPhone() }
                    .tint(.green)
                    .disabled(coordinator.isPreparing)
                Button("Close") { dismiss() }
                    .font(.caption2)

                if let attempt = coordinator.latestAttempt {
                    let summary = SystemDialUserSummary.make(from: attempt)
                    VStack(spacing: 3) {
                        Text(summary.title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(summary.code)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let detail = summary.detail {
                            Text(detail)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
        }
        .alert("Invalid number", isPresented: $showsInvalidNumber) {
            Button("OK", role: .cancel) { }
        }
    }

    private func append(_ value: Character) {
        number = WatchSystemDialerNumber.appending(value, to: number)
    }

    private func callSystemPhone() {
        guard let url = WatchSystemDialerNumber.url(for: number), url.scheme == "tel" else {
            showsInvalidNumber = true
            return
        }
        Task { await coordinator.prepareAndDial(number: number, url: url) }
    }
}
#endif
