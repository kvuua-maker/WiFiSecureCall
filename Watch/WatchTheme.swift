import SwiftUI

/// The visual language of the watch app.
///
/// One file rather than scattered literals: a watch face is small, and every
/// spacing, radius and colour has to agree or the screen looks assembled from
/// parts. Numbers were chosen for a 45 mm screen and scale down with Dynamic Type
/// through the relative fonts.
enum WatchTheme {
    static let backgroundTop = Color(red: 0.07, green: 0.09, blue: 0.16)
    static let backgroundBottom = Color(red: 0.02, green: 0.03, blue: 0.06)
    static let card = Color.white.opacity(0.08)
    static let cardStroke = Color.white.opacity(0.12)
    static let accent = Color(red: 0.20, green: 0.85, blue: 0.55)
    static let danger = Color(red: 0.95, green: 0.27, blue: 0.31)
    static let muted = Color.white.opacity(0.62)

    /// The dialpad cell edge. Four rows of these plus the action row still leave
    /// room for the number display on the smallest supported watch.
    static let keySize: CGFloat = 46
    static let keySpacing: CGFloat = 6

    static var background: some View {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// A large, round key.
///
/// The hit area is the circle itself and the padding is inside the shape, so
/// neighbouring keys never claim each other's taps: this is what made "0" and
/// "delete" feel dead in the previous layout, where both lived in a cramped row.
struct WatchKeyButtonStyle: ButtonStyle {
    var tint: Color = Color.white.opacity(0.12)
    var foreground: Color = .white
    var size: CGFloat = WatchTheme.keySize
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: isProminent ? 20 : 22, weight: .regular, design: .rounded))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(isProminent ? tint : tint)
                    .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 1))
            )
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The card used for the account and the call state.
struct WatchCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(WatchTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(WatchTheme.cardStroke, lineWidth: 1)
                    )
            )
    }
}

/// A full-width action row with a clear, single tap target.
struct WatchActionButton: View {
    let title: String
    var systemImage: String?
    var role: Role = .primary
    let action: () -> Void

    enum Role { case primary, secondary, destructive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
                }
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(background)
            )
            .foregroundStyle(foreground)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch role {
        case .primary: return WatchTheme.accent.opacity(0.9)
        case .secondary: return Color.white.opacity(0.12)
        case .destructive: return WatchTheme.danger.opacity(0.85)
        }
    }

    private var foreground: Color {
        switch role {
        case .primary: return .black
        case .secondary, .destructive: return .white
        }
    }
}
