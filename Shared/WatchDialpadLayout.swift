import CoreGraphics
import Foundation

/// Shared key ordering plus a pure geometry model for unit tests.
/// Only `rows` is used to construct the production SwiftUI dialpad. These calculated rectangles do not
/// measure SwiftUI's actual layout or hit testing, and cannot establish that a visible key is tappable.
/// WatchUITests exercises real touch events, scrolling, and resulting number changes in Simulator.
struct WatchDialpadLayout: Equatable {
    enum Key: String, Equatable, CaseIterable {
        case one, two, three
        case four, five, six
        case seven, eight, nine
        case delete, zero, call

        var isDigit: Bool {
            switch self {
            case .one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .zero:
                return true
            case .delete, .call:
                return false
            }
        }

        /// The digit a key types, and nil for the two that act instead of typing.
        var digit: Character? {
            switch self {
            case .one: return "1"
            case .two: return "2"
            case .three: return "3"
            case .four: return "4"
            case .five: return "5"
            case .six: return "6"
            case .seven: return "7"
            case .eight: return "8"
            case .nine: return "9"
            case .zero: return "0"
            case .delete, .call: return nil
            }
        }
    }

    /// The four rows of three in reading order. The last row is written out rather than appended, so a key
    /// cannot quietly stop being reachable behind a count.
    static let rows: [[Key]] = [
        [.one, .two, .three],
        [.four, .five, .six],
        [.seven, .eight, .nine],
        [.delete, .zero, .call],
    ]

    /// The row that was reported dead, named so the tests about it cannot be mistaken for tests about a
    /// row that happened to be fine.
    static let bottomRow: [Key] = [.delete, .zero, .call]

    /// The screen the grid is placed on, the point the grid starts at, and the part of the screen at the
    /// bottom that the system keeps for itself.
    let size: CGSize
    let origin: CGPoint
    let bottomInset: CGFloat
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let keyHeight: CGFloat

    init(
        size: CGSize,
        origin: CGPoint = .zero,
        bottomInset: CGFloat = 0,
        columnSpacing: CGFloat = 3,
        rowSpacing: CGFloat = 3,
        keyHeight: CGFloat = 26
    ) {
        self.size = size
        self.origin = origin
        self.bottomInset = bottomInset
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
        self.keyHeight = keyHeight
    }

    var columnCount: Int { WatchDialpadLayout.rows.first?.count ?? 0 }
    var rowCount: Int { WatchDialpadLayout.rows.count }

    /// The widest a column can be once the spacing is taken out. A column of zero width is a column of
    /// keys that cannot be tapped.
    var columnWidth: CGFloat {
        let gaps = columnSpacing * CGFloat(max(columnCount - 1, 0))
        let available = size.width - gaps
        guard columnCount > 0 else { return 0 }
        return available / CGFloat(columnCount)
    }

    func column(_ index: Int) -> CGFloat {
        origin.x + (columnWidth + columnSpacing) * CGFloat(index)
    }

    func row(_ index: Int) -> CGFloat {
        origin.y + (keyHeight + rowSpacing) * CGFloat(index)
    }

    /// The rectangle a key occupies, or nil when the size leaves it no width. A key with no rectangle is a
    /// key that cannot be tapped, and the tests require that no key is ever in that state.
    func frame(for key: Key) -> CGRect? {
        guard let position = position(of: key) else { return nil }
        let (rowIndex, columnIndex) = position
        guard columnWidth > 0 else { return nil }
        return CGRect(
            x: column(columnIndex),
            y: row(rowIndex),
            width: columnWidth,
            height: keyHeight
        )
    }

    private func position(of key: Key) -> (row: Int, column: Int)? {
        for (rowIndex, keys) in WatchDialpadLayout.rows.enumerated() {
            if let columnIndex = keys.firstIndex(of: key) {
                return (rowIndex, columnIndex)
            }
        }
        return nil
    }

    /// Which key a touch at this point belongs to, or nil when the point is not on a key.
    ///
    /// A point that is inside the screen but on no key is the signature of the reported defect: content
    /// that is drawn, that the owner can see, and that no tap reaches.
    func key(at point: CGPoint) -> Key? {
        for (rowIndex, keys) in WatchDialpadLayout.rows.enumerated() {
            for (columnIndex, key) in keys.enumerated() {
                let rect = CGRect(
                    x: column(columnIndex),
                    y: row(rowIndex),
                    width: columnWidth,
                    height: keyHeight
                )
                if rect.contains(point) { return key }
            }
        }
        return nil
    }

    /// Keys whose rectangle falls outside the screen or into the bottom inset the system reserves.
    var unreachableKeys: [Key] {
        let usableBottom = size.height - bottomInset
        return Key.allCases.filter { key in
            guard let rect = frame(for: key) else { return true }
            if rect.isEmpty || rect.isNull { return true }
            return rect.minX < 0
                || rect.maxX > size.width
                || rect.minY < 0
                || rect.maxY > usableBottom
        }
    }

    /// Pairs of keys whose rectangles overlap, which would make one of them untappable behind the other.
    func overlappingKeyPairs() -> [(Key, Key)] {
        var found: [(Key, Key)] = []
        for first in Key.allCases {
            guard let a = frame(for: first) else { continue }
            for second in Key.allCases where second != first {
                guard let b = frame(for: second) else { continue }
                if a.intersects(b) { found.append((first, second)) }
            }
        }
        return found
    }

    /// Whether a rectangle laid over the keypad would take taps away from these keys. The reported failure
    /// was an overlay that covered the bottom of the screen, so covering is checked here as arithmetic
    /// rather than left to be discovered on a watch.
    func keys(coveredBy overlays: [CGRect]) -> [Key] {
        Key.allCases.filter { key in
            guard let rect = frame(for: key) else { return true }
            return overlays.contains { $0.intersects(rect) }
        }
    }
}
