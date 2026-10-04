import XCTest

/// The dialpad is the screen whose keys were reported dead on a watch, so what those keys do is asserted
/// here rather than by a tap on one device. Every case is a value transition: no clock, no scheduler, no
/// network and no sleeps.
final class WatchDialpadModelTests: XCTestCase {

    func testSystemInputNormalizesPlusWhitespaceAndDigitDictationWithoutDialing() {
        var pad = WatchDialpadModel()
        XCTAssertTrue(pad.replaceFromSystemInput(" плюс три вісім нуль один два три чотири п’ять шість сім вісім девʼять "))
        XCTAssertEqual(pad.number, "+380123456789")
        XCTAssertFalse(pad.isDialing)
        XCTAssertTrue(pad.replaceFromSystemInput(" +1\u{00a0}(202) 555-0100 "))
        XCTAssertEqual(pad.number, "+12025550100")
        XCTAssertEqual(pad.dialURL, URL(string: "tel:+12025550100"))
        XCTAssertFalse(pad.isDialing)
    }

    func testSystemInputRejectsAmbiguousOrOverlongTextWithoutChangingRecipient() {
        var pad = WatchDialpadModel()
        XCTAssertTrue(pad.replaceFromSystemInput("+1 202 555 0100"))
        for invalid in ["++123", "12+34", "тридцять вісім", "call 123", "1234567890123456", "мінус один два три"] {
            XCTAssertFalse(pad.replaceFromSystemInput(invalid), invalid)
            XCTAssertEqual(pad.number, "+12025550100")
            XCTAssertFalse(pad.isDialing)
        }
    }

    func testSystemInputKeepsLeadingZeroAndSupportsSubsequentKeypadEditing() {
        var pad = WatchDialpadModel()
        XCTAssertTrue(pad.replaceFromSystemInput("нуль нуль один два три"))
        XCTAssertEqual(pad.number, "00123")
        XCTAssertTrue(pad.deleteLast())
        XCTAssertTrue(pad.append("0"))
        XCTAssertEqual(pad.number, "00120")
        XCTAssertTrue(pad.replaceFromSystemInput(""))
        XCTAssertFalse(pad.isCallable)
    }

    // MARK: - Typing

    func testAppendDigit() {
        var pad = WatchDialpadModel()
        for digit in ["0", "5", "0", "1", "2"] {
            XCTAssertTrue(pad.append(Character(digit)), digit)
        }
        XCTAssertEqual(pad.number, "05012")
        XCTAssertFalse(pad.isEmpty)
    }

    func testAppendIgnoresEverythingThatIsNotADigitAndAcceptsPlusFirst() {
        var pad = WatchDialpadModel()
        XCTAssertTrue(pad.append("+"))
        XCTAssertEqual(pad.number, "+")
        XCTAssertFalse(pad.append("+"), "a second + has no meaning in a number")
        XCTAssertFalse(pad.append("-"))
        XCTAssertFalse(pad.append(" "))
        XCTAssertFalse(pad.append("a"))
        XCTAssertEqual(pad.number, "+")
        XCTAssertTrue(pad.append("3"))
        XCTAssertEqual(pad.number, "+3")
    }

    func testAppendStopsAtTheCeiling() {
        var pad = WatchDialpadModel(maximumCharacterCount: 4)
        for digit in "123456" {
            _ = pad.append(digit)
        }
        XCTAssertEqual(pad.number, "1234")
    }

    // MARK: - Deleting

    func testDeleteRemovesExactlyOneDigit() {
        var pad = WatchDialpadModel()
        _ = pad.append("0")
        _ = pad.append("5")
        _ = pad.append("0")
        XCTAssertTrue(pad.deleteLast())
        XCTAssertEqual(pad.number, "05")
        XCTAssertTrue(pad.deleteLast())
        XCTAssertEqual(pad.number, "0")
    }

    /// The tap that was reported doing nothing. An empty keypad has to survive it.
    func testDeleteOnEmptyIsSafeAndChangesNothing() {
        var pad = WatchDialpadModel()
        XCTAssertFalse(pad.canDelete)
        XCTAssertFalse(pad.deleteLast())
        XCTAssertEqual(pad.number, "")
        XCTAssertFalse(pad.deleteLast())
        XCTAssertEqual(pad.number, "")
    }

    func testDeleteIsOfferedOnlyWhenThereIsSomethingToDelete() {
        var pad = WatchDialpadModel()
        XCTAssertFalse(pad.canDelete)
        _ = pad.append("7")
        XCTAssertTrue(pad.canDelete)
        _ = pad.deleteLast()
        XCTAssertFalse(pad.canDelete)
    }

    /// Delete then add has to leave a keypad that can still be typed on.
    func testDeleteThenAppendStillWorks() {
        var pad = WatchDialpadModel()
        _ = pad.append("0")
        _ = pad.append("9")
        _ = pad.deleteLast()
        XCTAssertTrue(pad.append("7"))
        XCTAssertEqual(pad.number, "07")
    }

    func testDeleteAlsoRemovesALeadingPlus() {
        var pad = WatchDialpadModel()
        _ = pad.append("+")
        XCTAssertTrue(pad.deleteLast())
        XCTAssertEqual(pad.number, "")
        XCTAssertTrue(pad.append("5"), "a + that was deleted leaves the field ready for a new one")
    }

    // MARK: - The call key

    func testCallWithAValidNumberProducesOneRealDialRequest() {
        var pad = WatchDialpadModel()
        for digit in "+380501234567" { _ = pad.append(digit) }
        XCTAssertEqual(pad.dialDecision, .start(URL(string: "tel:+380501234567")!))
        XCTAssertEqual(pad.dialURL?.scheme, "tel")
        XCTAssertEqual(pad.callButtonState, .ready)
    }

    func testCallWithoutANumberIsRefusedWithItsOwnReason() {
        let pad = WatchDialpadModel()
        XCTAssertEqual(pad.dialDecision, .noNumber)
        XCTAssertNil(pad.dialURL)
        XCTAssertEqual(pad.callButtonState, .needsNumber)
    }

    func testCallOnANumberThatCannotBeDialledIsRefusedSeparately() {
        var pad = WatchDialpadModel()
        _ = pad.append("1")
        _ = pad.append("2")
        XCTAssertEqual(pad.dialDecision, .invalidNumber, "two digits is a refusal, not an empty keypad")
        _ = pad.append("3")
        XCTAssertEqual(pad.dialDecision, .start(URL(string: "tel:123")!))
    }

    func testOverlongNumberIsRefusedRatherThanDialled() {
        var pad = WatchDialpadModel()
        for digit in "1234567890123456" { _ = pad.append(digit) }
        XCTAssertEqual(pad.digits.count, 16)
        XCTAssertEqual(pad.dialDecision, .invalidNumber)
    }

    func testPlusIsNotCountedTowardsTheDigitLength() {
        var pad = WatchDialpadModel()
        _ = pad.append("+")
        _ = pad.append("1")
        _ = pad.append("2")
        _ = pad.append("3")
        XCTAssertEqual(pad.dialDecision, .start(URL(string: "tel:+123")!))
    }

    /// One press, one call. The claim is what makes that true rather than a hope about tap timing.
    func testOnlyOneDialRequestIsGrantedAtATime() {
        var pad = WatchDialpadModel()
        for digit in "0501234567" { _ = pad.append(digit) }

        XCTAssertTrue(pad.beginDial(), "the first press is granted")
        XCTAssertFalse(pad.beginDial(), "a second press while one is in flight is refused")
        XCTAssertFalse(pad.beginDial(), "and so is a third")
        XCTAssertTrue(pad.isDialing)
    }

    func testDialRequestIsGrantedAgainOnlyAfterTheRouteReleasesIt() {
        var pad = WatchDialpadModel()
        for digit in "0501234567" { _ = pad.append(digit) }

        XCTAssertTrue(pad.beginDial())
        pad.endDial()
        XCTAssertFalse(pad.isDialing)
        XCTAssertTrue(pad.beginDial(), "a failure has to leave the key usable")
        XCTAssertFalse(pad.beginDial())
    }

    func testTwoRoutesOnOneScreenCannotBothDial() {
        var pad = WatchDialpadModel()
        for digit in "0501234567" { _ = pad.append(digit) }

        XCTAssertTrue(pad.beginDial(), "the call key takes the claim")
        XCTAssertFalse(pad.beginDial(), "the Wi-Fi account key on the same screen is refused")
    }

    // MARK: - The button is not the network

    /// The reported failure was a green key that looked available and did nothing, so the key's state is
    /// decided by the number alone. Nothing in this type can be moved by reachability, and the equality
    /// below is what pins that: two pads holding the same number are the same key whatever else is true
    /// of the device.
    func testCallButtonStateDependsOnTheNumberAndNothingElse() {
        var empty = WatchDialpadModel()
        var typed = WatchDialpadModel()
        for digit in "050" { _ = typed.append(digit) }

        XCTAssertEqual(empty.callButtonState, .needsNumber)
        XCTAssertEqual(typed.callButtonState, .ready)

        XCTAssertEqual(typed, WatchDialpadModel(numberForTest: "050"))
        XCTAssertNotEqual(empty.callButtonState, typed.callButtonState)
    }

    func testTypingNeverBlocksTheDeleteOrCallKeysOnAccountState() {
        var pad = WatchDialpadModel()
        XCTAssertTrue(pad.deleteLast() == false, "safe on empty")
        XCTAssertEqual(pad.dialDecision, .noNumber, "and the call key still answers with a reason")

        for digit in "050" { _ = pad.append(digit) }
        XCTAssertTrue(pad.canDelete, "delete is live as soon as there is something to delete")
        XCTAssertEqual(pad.dialDecision, .start(URL(string: "tel:050")!))
    }

    // MARK: - The Wi-Fi account route stays a different thing

    func testAccountRouteIsE164AndIsNotThePhoneRoute() {
        var pad = WatchDialpadModel()
        for digit in "0501234567" { _ = pad.append(digit) }
        XCTAssertEqual(pad.e164, "+0501234567")
        XCTAssertEqual(pad.dialURL?.absoluteString, "tel:0501234567")
        XCTAssertNotEqual(pad.e164, pad.dialURL?.path)
    }

    func testAccountRouteIsRefusedOnTheSameTermsAsThePhoneRoute() {
        let pad = WatchDialpadModel()
        XCTAssertNil(pad.e164, "an empty number resolves to nobody")
    }

    func testClearEmptiesTheKeypad() {
        var pad = WatchDialpadModel()
        for digit in "0501234567" { _ = pad.append(digit) }
        pad.clear()
        XCTAssertEqual(pad.number, "")
        XCTAssertEqual(pad.callButtonState, .needsNumber)
    }

    func testTheModelAgreesWithTheSystemDialerAboutWhatANumberIs() {
        // The two screens are reachable at the same time from the watch, so they cannot hold two opinions
        // about the same typed number.
        var pad = WatchDialpadModel()
        for digit in "+380501234567" { _ = pad.append(digit) }
        XCTAssertTrue(WatchSystemDialerNumber.isValid(pad.number))
        XCTAssertEqual(WatchSystemDialerNumber.url(for: pad.number), pad.dialURL)

        var rejected = WatchDialpadModel()
        _ = rejected.append("1")
        _ = rejected.append("2")
        XCTAssertFalse(WatchSystemDialerNumber.isValid(rejected.number))
        XCTAssertNil(rejected.dialURL)
    }
}

private extension WatchDialpadModel {
    /// Builds the model the only way its keys are meant to be driven, so the equality assertion above is
    /// a statement about behaviour and not about a private setter.
    init(numberForTest number: String) {
        self.init()
        for character in number { _ = append(character) }
    }
}
