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
    var body: some View {
        WatchSecureDialerView(showsSecureAccountCall: false)
    }
}
#endif
