import SwiftUI

/// Telegram Dark, reduced to the handful of values this app needs.
enum IOSTheme {
    static let background = Color(red: 0.09, green: 0.13, blue: 0.17)      // #17212B
    static let surface = Color(red: 0.12, green: 0.18, blue: 0.24)         // #1E2A36
    static let surfaceRaised = Color(red: 0.16, green: 0.22, blue: 0.29)
    static let accent = Color(red: 0.16, green: 0.67, blue: 0.93)          // #2AABEE
    static let outgoingBubble = Color(red: 0.18, green: 0.40, blue: 0.55)
    static let incomingBubble = Color(red: 0.14, green: 0.20, blue: 0.27)
    static let textSecondary = Color(white: 0.62)
    static let destructive = Color(red: 0.90, green: 0.30, blue: 0.26)
    static let success = Color(red: 0.35, green: 0.78, blue: 0.45)
    static let corner: CGFloat = 14
    static let smallCorner: CGFloat = 12

    static func avatarColor(for seed: String) -> Color {
        let scalar = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Color(hue: Double(scalar % 360) / 360.0, saturation: 0.45, brightness: 0.62)
    }

    static func initials(_ name: String) -> String {
        let letters = name.compactMap { $0.isLetter ? String($0) : nil }
        let value = letters.prefix(2).joined().uppercased()
        return value.isEmpty ? "?" : value
    }
}

struct IOSAvatar: View {
    let name: String
    var size: CGFloat = 52
    var body: some View {
        ZStack {
            Circle().fill(IOSTheme.avatarColor(for: name))
            Text(IOSTheme.initials(name))
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
