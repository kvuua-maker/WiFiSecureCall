import CoreGraphics
import XCTest

/// The dialpad's last row was reported drawn and untappable on a real watch: delete, zero and the call key
/// were all dead while the three rows above them worked.
///
/// These tests are about reachability rather than about behaviour. What a key does is asserted against
/// `WatchDialpadModel`, and what a key *is* is asserted here: that it has a rectangle, that the rectangle
/// is on screen and out of the inset the system reserves at the bottom, that no key overlaps another, and
/// that the centre of each of the three bottom keys lands on that key and on nothing else. A point inside
/// the screen that belongs to no key is the signature of the defect, and `key(at:)` returning nil there is
/// what these tests forbid.
final class WatchDialpadLayoutTests: XCTestCase {

    /// The 45 mm Apple Watch Series 5, which is the device the reports come from.
    private let series5 = CGSize(width: 396, height: 484)

    /// The 41 mm case, the smallest screen the app supports, because a layout that only fits the large one
    /// is not a layout.
    private let series5Small = CGSize(width: 352, height: 430)

    private func layout(for size: CGSize, bottomInset: CGFloat = 0) -> WatchDialpadLayout {
        WatchDialpadLayout(size: size, bottomInset: bottomInset)
    }

    // MARK: - The reported row is still there

    func testTheBottomRowIsDeleteZeroAndCall() {
        XCTAssertEqual(WatchDialpadLayout.bottomRow, [.delete, .zero, .call])
        XCTAssertEqual(WatchDialpadLayout.rows.count, 4)
        XCTAssertEqual(WatchDialpadLayout.rows.flatMap { $0 }.count, 12)
    }

    func testEveryKeyHasAKeyInTheFirstNineRowsAndTheBottomRow() {
        XCTAssertEqual(WatchDialpadLayout.rows[0], [.one, .two, .three])
        XCTAssertEqual(WatchDialpadLayout.rows[1], [.four, .five, .six])
        XCTAssertEqual(WatchDialpadLayout.rows[2], [.seven, .eight, .nine])
    }

    func testTheDigitsStillTypeWhatTheyAlwaysDid() {
        XCTAssertEqual(WatchDialpadLayout.Key.allCases.filter(\.isDigit).count, 10)
        XCTAssertEqual(WatchDialpadLayout.Key.zero.digit, "0")
        XCTAssertNil(WatchDialpadLayout.Key.delete.digit)
        XCTAssertNil(WatchDialpadLayout.Key.call.digit)
    }

    // MARK: - The bottom row is reachable

    /// The regression itself: on the screen the reports came from, no key may be unreachable.
    func testNoKeyIsUnreachableOnTheReportedDevice() {
        XCTAssertEqual(layout(for: series5).unreachableKeys, [], "every key, including the last row")
    }

    func testNoKeyIsUnreachableWhenTheSystemKeepsTheBottomOfTheScreen() {
        // watchOS reserves a band at the bottom of a screen for the system, and the row nearest it is the
        // row that stopped responding.
        let inset = layout(for: series5, bottomInset: 44)
        XCTAssertEqual(inset.unreachableKeys, [], "a bottom inset must not put the last row out of reach")
    }

    func testNoKeyIsUnreachableOnTheSmallestSupportedScreen() {
        XCTAssertEqual(layout(for: series5Small, bottomInset: 44).unreachableKeys, [])
    }

    func testTheCentreOfEveryKeyLandsOnThatKey() {
        for size in [series5, series5Small] {
            let subject = layout(for: size, bottomInset: 44)
            for key in WatchDialpadLayout.Key.allCases {
                guard let rect = subject.frame(for: key) else {
                    XCTFail("\(key) has no rectangle on \(size)")
                    continue
                }
                let centre = CGPoint(x: rect.midX, y: rect.midY)
                XCTAssertEqual(
                    subject.key(at: centre),
                    key,
                    "the centre of \(key) on \(size.width)x\(size.height) does not reach \(key)"
                )
            }
        }
    }

    /// The three keys that were reported dead, checked one at a time by their own centres.
    func testTheCentreOfEachBottomRowKeyReachesThatKey() {
        let subject = layout(for: series5, bottomInset: 44)
        for key in WatchDialpadLayout.bottomRow {
            guard let rect = subject.frame(for: key) else {
                XCTFail("\(key) has no rectangle")
                continue
            }
            XCTAssertEqual(
                subject.key(at: CGPoint(x: rect.midX, y: rect.midY)),
                key,
                "a tap at the centre of \(key) does not reach \(key)"
            )
        }
    }

    func testTheThreeBottomKeysAreDistinctRegions() {
        let subject = layout(for: series5)
        let rects = WatchDialpadLayout.bottomRow.compactMap(subject.frame(for:))
        XCTAssertEqual(rects.count, 3)
        for (index, first) in rects.enumerated() {
            for second in rects[(index + 1)...] {
                XCTAssertFalse(first.intersects(second), "two bottom keys share screen space")
            }
        }
    }

    func testNoTwoKeysOverlapAnywhere() {
        XCTAssertEqual(layout(for: series5).overlappingKeyPairs(), [])
        XCTAssertEqual(layout(for: series5Small).overlappingKeyPairs(), [])
    }

    func testEveryPointOnEveryKeyBelongsToThatKey() {
        // A key whose corners fall on a neighbour would be partly untappable, which is a smaller version
        // of the same defect.
        let subject = layout(for: series5)
        for key in WatchDialpadLayout.Key.allCases {
            guard let rect = subject.frame(for: key) else { continue }
            let probes = [
                CGPoint(x: rect.minX + 1, y: rect.midY),
                CGPoint(x: rect.maxX - 1, y: rect.midY),
                CGPoint(x: rect.midX, y: rect.minY + 1),
                CGPoint(x: rect.midX, y: rect.maxY - 1),
            ]
            for probe in probes {
                XCTAssertEqual(subject.key(at: probe), key, "\(key) is not hittable at \(probe)")
            }
        }
    }

    // MARK: - Nothing can be laid over the bottom row

    /// The defect as an overlay: something transparent drawn across the lower half of the screen.
    func testAnOverlayAcrossTheBottomOfTheScreenCoversTheBottomRow() {
        let subject = layout(for: series5)
        let overlay = CGRect(x: 0, y: series5.height / 2, width: series5.width, height: series5.height / 2)
        let covered = subject.keys(coveredBy: [overlay])
        XCTAssertEqual(Set(covered), Set(WatchDialpadLayout.bottomRow))
        XCTAssertFalse(covered.contains(.one), "the rows that worked must not be reported as covered")
    }

    /// And the check that keeps that overlay honest: a key's own background is not an overlay, so the
    /// common mistake of treating one as the other does not report every key as covered.
    func testKeysAreNotCoveredByTheirOwnBackground() {
        let subject = layout(for: series5)
        for key in WatchDialpadLayout.Key.allCases {
            guard let rect = subject.frame(for: key) else { continue }
            XCTAssertEqual(subject.keys(coveredBy: [rect]), [], "\(key) covers only itself")
        }
    }

    func testAnOverlayThatMissesTheKeypadCoversNothing() {
        let subject = layout(for: series5)
        let above = CGRect(x: 0, y: 0, width: series5.width, height: 10)
        XCTAssertEqual(subject.keys(coveredBy: [above]), [])
    }

    // MARK: - The arrangement is sized, not guessed

    func testTheGridFillsTheWidthItIsGiven() {
        let subject = layout(for: series5, columnSpacing: 3)
        let lastColumn = try? XCTUnwrap(subject.frame(for: .call))
        XCTAssertNotNil(lastColumn)
        guard let rect = subject.frame(for: .call) else { return }
        XCTAssertEqual(rect.maxX, series5.width, accuracy: 0.5, "the right column reaches the edge")
        XCTAssertEqual(rect.minX, 0, accuracy: 0.5, "the left column starts at the edge")
    }

    func testAGridWithNoWidthHasNoReachableKeys() {
        // The other end of the same question: a size that leaves a key no rectangle must say so rather than
        // silently produce keys that cannot be tapped.
        let collapsed = WatchDialpadLayout(size: CGSize(width: 0, height: 484))
        XCTAssertEqual(collapsed.unreachableKeys.count, 12)
        XCTAssertNil(collapsed.frame(for: .delete))
    }

    func testTheRowsAreStackedInReadingOrder() {
        let subject = layout(for: series5)
        let top = subject.frame(for: .one)
        let middle = subject.frame(for: .four)
        let bottom = subject.frame(for: .delete)
        XCTAssertNotNil(top); XCTAssertNotNil(middle); XCTAssertNotNil(bottom)
        guard let top, let middle, let bottom else { return }
        XCTAssertLessThan(top.minY, middle.minY)
        XCTAssertLessThan(middle.minY, bottom.minY)
        XCTAssertEqual(top.minY, middle.minY, "each row starts at the same height")
        XCTAssertEqual(middle.minY, bottom.minY)
    }

    func testKeysLineUpInColumns() {
        let subject = layout(for: series5)
        XCTAssertEqual(subject.frame(for: .one)?.minX, subject.frame(for: .delete)?.minX)
        XCTAssertEqual(subject.frame(for: .two)?.minX, subject.frame(for: .zero)?.minX)
        XCTAssertEqual(subject.frame(for: .three)?.minX, subject.frame(for: .call)?.minX)
    }
}
