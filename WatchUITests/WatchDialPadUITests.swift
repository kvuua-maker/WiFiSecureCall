import XCTest

/// Drives the dialpad the way a wrist does: press digits, delete one, place the
/// call. It exists because the previous layout had three controls sharing a row,
/// and a tap that lands on the wrong one is invisible to a unit test.
final class WatchDialPadUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Signed out is the only state a simulator can reach without an Apple ID,
        // so the app is told to present the dialpad as if it were signed in.
        app.launchArguments = ["-uiTesting", "-uiTestingDialPad"]
        app.launch()
    }

    func testDigitsAppendInOrder() throws {
        let display = app.staticTexts["dialpad.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 30), "the dialpad did not appear")

        for digit in ["1", "2", "3"] {
            let key = app.buttons["dialpad.key.\(digit)"]
            XCTAssertTrue(key.waitForExistence(timeout: 5), "key \(digit) is missing")
            key.tap()
        }

        XCTAssertEqual(display.value as? String, "123")
    }

    func testZeroKeyAppendsZero() throws {
        let display = app.staticTexts["dialpad.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 30))

        app.buttons["dialpad.key.1"].tap()
        app.buttons["dialpad.key.0"].tap()
        app.buttons["dialpad.key.0"].tap()

        XCTAssertEqual(display.value as? String, "100", "the 0 key must append, not replace")
    }

    func testDeleteRemovesOnlyTheLastDigit() throws {
        let display = app.staticTexts["dialpad.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 30))

        for digit in ["4", "5", "6"] {
            app.buttons["dialpad.key.\(digit)"].tap()
        }
        XCTAssertEqual(display.value as? String, "456")

        app.buttons["dialpad.key.delete"].tap()
        XCTAssertEqual(display.value as? String, "45", "delete removed more than one digit")

        app.buttons["dialpad.key.delete"].tap()
        app.buttons["dialpad.key.delete"].tap()
        XCTAssertEqual(display.value as? String, "", "delete must empty the field")
    }

    func testCallIsDisabledUntilTheNumberIsLongEnough() throws {
        let display = app.staticTexts["dialpad.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 30))

        let call = app.buttons["dialpad.call"]
        XCTAssertTrue(call.waitForExistence(timeout: 5))
        XCTAssertFalse(call.isEnabled, "call must stay disabled for an empty number")

        app.buttons["dialpad.key.1"].tap()
        app.buttons["dialpad.key.2"].tap()
        XCTAssertFalse(call.isEnabled, "two digits are not a number")

        app.buttons["dialpad.key.3"].tap()
        XCTAssertTrue(call.isEnabled, "call must enable at three digits")
    }

    func testCallOpensTheSystemDialler() throws {
        let display = app.staticTexts["dialpad.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 30))

        for digit in ["9", "8", "7"] {
            app.buttons["dialpad.key.\(digit)"].tap()
        }
        app.buttons["dialpad.call"].tap()

        // Mode B hands the number to watchOS. The simulator cannot place the call,
        // so the screen says what it is doing and stays put for the assertion.
        let feedback = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Phone app'")).firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 10), "no dial feedback was shown")
    }

    func testHomeOffersBothCallModes() throws {
        app.terminate()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let appCall = app.buttons["home.callApp"]
        XCTAssertTrue(appCall.waitForExistence(timeout: 30), "the app-to-app call button is missing")
        XCTAssertTrue(app.buttons["home.dialNumber"].exists, "the dial-a-number button is missing")
        XCTAssertNotEqual(appCall.frame, app.buttons["home.dialNumber"].frame, "the two actions overlap")
    }
}
