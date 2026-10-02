import Foundation

enum WatchSystemDialerNumber {
    static let maximumCharacterCount = 20

    static func appending(_ character: Character, to number: String) -> String {
        guard number.count < maximumCharacterCount else { return number }
        if character == "+" { return number.isEmpty ? "+" : number }
        guard character.isASCII, character.isNumber else { return number }
        return number + String(character)
    }

    static func deletingLast(from number: String) -> String {
        String(number.dropLast())
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
    @State private var number: String
    @State private var showsInvalidNumber = false
    @StateObject private var coordinator = WatchSystemDialCoordinator.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    private let digits: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    init(initialNumber: String = "") {
        let normalized = initialNumber.filter { $0.isNumber || $0 == "+" }
        _number = State(initialValue: String(normalized.prefix(WatchSystemDialerNumber.maximumCharacterCount)))
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Button("Закрити") { dismiss() }
                    .font(.caption2)
                    .buttonStyle(.plain)
                Spacer(minLength: 2)
                Button("+") { append("+") }
                    .font(.caption)
                    .buttonStyle(.plain)
            }

            Text(number.isEmpty ? "Введіть номер" : number)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(digits, id: \.self) { digit in
                    Button(String(digit)) { append(digit) }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.28)))
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

                Button("0") { append("0") }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.28)))

                Button { callSystemPhone() } label: {
                    if coordinator.isPreparing { ProgressView() } else { Image(systemName: "phone.fill") }
                }
                .accessibilityLabel("Мобільний дзвінок")
                .disabled(!WatchSystemDialerNumber.isValid(number) || coordinator.isPreparing)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 8).fill(.green))
            }
        }
        .padding(.horizontal, 3)
        .alert("Не вдалося почати системний дзвінок", isPresented: $showsInvalidNumber) {
            Button("Гаразд", role: .cancel) { }
        } message: {
            Text("Перевірте номер і доступність мобільних викликів на Apple Watch або зв’язаному iPhone.")
        }
        .onAppear { coordinator.activate() }
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
