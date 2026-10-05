import XCTest

/// Runs against the real watchOS view hierarchy, not the dialpad model or computed rectangles.
@MainActor
final class WatchDialerUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.vkapps.wifisecurecall.watchkitapp")
    // A handoff is awaiting owner confirmation, never evidence of a connected call or audio.
    private let awaitingOwnerConfirmationText = "Номер передано Телефону. Натисніть «Виклик» на екрані — до цього дзвінок ще не йде."

    override func setUpWithError() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            if alert.buttons["OK"].exists { alert.buttons["OK"].tap(); return true }
            if alert.buttons["Allow"].isHittable { alert.buttons["Allow"].tap(); return true }
            alert.swipeUp()
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        app.launch()
        let board = XCUIApplication(bundleIdentifier: "com.apple.Carousel")
        if board.alerts.firstMatch.waitForExistence(timeout: 2) {
            if board.buttons["OK"].exists {
                board.buttons["OK"].tap()
            } else {
                board.alerts.firstMatch.swipeUp()
                if board.buttons["Allow"].exists { board.buttons["Allow"].tap() }
            }
            app.activate()
        }
    }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement? = nil) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        for _ in 0..<12 {
            let rect = element.frame
            if rect.midY >= 55 && rect.midY <= app.frame.height - 25 && element.isHittable { return }
            // A short drag with a hold avoids flick inertia overshooting a small Watch row.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
            let end = start.withOffset(CGVector(dx: 0, dy: rect.midY < 55 ? 45 : -45))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        }
        XCTAssertTrue(element.isHittable)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = (app.launchArguments.isEmpty ? "standard-" : "large-") + name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func press(_ key: String, atEdge: Bool = false) {
        let button = app.buttons["dialpad.\(key)"]
        reveal(button)
        if atEdge {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        } else { button.tap() }
    }

    private func expectNumber(_ value: String) {
        XCTAssertEqual(app.textFields["dialpad.edit-number"].value as? String, value)
    }

    func testPrimaryDialerAllKeysAndVisibleEdges() {
        app.buttons["Call number"].tap()
        XCTAssertTrue(app.buttons["dialpad.1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["dialpad.call"].isEnabled)
        snapshot("primary-top")
        if !app.launchArguments.isEmpty {
            XCTAssertEqual(app.buttons["dialpad.call"].value as? String, "xxxLarge", "Large Dynamic Type was not applied")
        }
        XCTAssertEqual(app.buttons.matching(identifier: "dialpad.call").count, 1)
        XCTAssertFalse(app.buttons["dialpad.call-top"].exists)
        XCTAssertFalse(app.buttons["Call app user"].exists)
        press("plus", atEdge: true)
        var expected = "+"
        for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
            press(digit, atEdge: true)
            expected += digit
            expectNumber(expected)
        }
        snapshot("primary-bottom-keys")
        press("delete", atEdge: true)
        expectNumber("+123456789")
        press("0", atEdge: true)
        expectNumber("+1234567890")
        press("0", atEdge: true)
        expectNumber("+12345678900")
        press("delete", atEdge: true)
        press("delete", atEdge: true)
        expectNumber("+123456789")
        print("WATCH_FIXED_DIALPAD\n\(app.debugDescription)")
        app.buttons.matching(identifier: "close-sheet").firstMatch.tap()
        app.buttons["Call number"].tap()
        expectNumber("Ввести номер")
        press("0", atEdge: true)
        expectNumber("0")
        XCTAssertFalse(app.buttons["dialpad.call"].isEnabled)
    }

    func testCarrierHandsetInvokesSystemHandoffWithoutAccount() {
        // Reserved fictional NANPA number; no real recipient and no carrier service in Simulator.
        let cellular = app.buttons["Cellular call"]
        reveal(cellular, in: app.scrollViews.firstMatch)
        cellular.tap()
        for digit in ["1", "2", "0", "2", "5", "5", "5", "0", "1", "0", "0"] { press(digit) }
        XCTAssertTrue(app.buttons["dialpad.call"].isEnabled)
        press("call", atEdge: true)
        XCTAssertTrue(app.staticTexts["dialpad.status"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["dialpad.status"].label, awaitingOwnerConfirmationText)
        snapshot("carrier-handset-handoff-only")
        // This verifies the action was invoked, NOT ringing, connection or two-way telephone audio.
    }

    func testNumberRowOpensSystemInputAndDoesNotDialAutomatically() {
        app.buttons["Call number"].tap()
        let number = app.textFields["dialpad.edit-number"]
        XCTAssertTrue(number.waitForExistence(timeout: 3))
        number.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 8))
        snapshot("system-number-input")
        let editor = app.textViews.element(boundBy: 1)
        XCTAssertTrue(editor.exists)
        editor.typeText("+1 202 555 0100") // Reserved fictitious number, entered through real system UI.
        app.buttons["Done"].tap()
        expectNumber("+12025550100")
        XCTAssertEqual(app.staticTexts["dialpad.review-number"].label, "+12025550100")
        XCTAssertEqual(app.staticTexts["dialpad.status"].label, "Перевірте номер і натисніть трубку.")
        XCTAssertFalse(app.staticTexts[awaitingOwnerConfirmationText].exists)
        let call = app.buttons["dialpad.call"]
        XCTAssertEqual(app.buttons.matching(identifier: "dialpad.call").count, 1)
        reveal(call)
        XCTAssertTrue(call.isEnabled)
        XCTAssertTrue(call.isHittable)
        snapshot("review-number-before-call")
        // Cancelled system input retains the number and still does not place a call.
        number.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        expectNumber("+12025550100")
        call.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertEqual(app.staticTexts["dialpad.status"].label, awaitingOwnerConfirmationText)
        snapshot("upper-call-action-handoff-only")
        // A refused system call must not permanently latch the handset or erase the recipient.
        XCTAssertTrue(call.isEnabled)
        press("delete", atEdge: true)
        expectNumber("+1202555010")
        XCTAssertEqual(app.staticTexts["dialpad.status"].label, "Перевірте номер і натисніть трубку.")
        press("0", atEdge: true)
        expectNumber("+12025550100")
        press("call", atEdge: true)
        XCTAssertEqual(app.staticTexts["dialpad.status"].label, awaitingOwnerConfirmationText)
    }

    func testSystemInputRejectsWrongRecipientAndRequiresExplicitCall() {
        app.buttons["Call number"].tap()
        let number = app.textFields["dialpad.edit-number"]
        number.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 8))
        app.textViews.element(boundBy: 1).typeText("+1 (202) 555-0100")
        app.buttons["Done"].tap()
        expectNumber("+12025550100")

        // Type invalid input through watchOS, not directly into the model.
        number.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 8))
        app.textViews.element(boundBy: 1).typeText("x")
        app.buttons["Done"].tap()
        expectNumber("+12025550100")
        XCTAssertEqual(app.staticTexts["dialpad.status"].label,
                       "Номер не змінено. Диктуйте по одній цифрі; плюс — лише на початку.")
        XCTAssertFalse(app.staticTexts[awaitingOwnerConfirmationText].exists)
        press("delete", atEdge: true)
        expectNumber("+1202555010")
        XCTAssertEqual(app.staticTexts["dialpad.status"].label, "Перевірте номер і натисніть трубку.")
        snapshot("invalid-edit-preserves-recipient")
    }

    func testSystemInputOffersDictation() {
        app.buttons["Call number"].tap()
        app.textFields["dialpad.edit-number"].tap()
        XCTAssertTrue(app.buttons["Change input method"].waitForExistence(timeout: 5))
        app.buttons["Change input method"].tap()
        print("WATCH_INPUT_METHODS\n\(app.debugDescription)")
        snapshot("system-input-methods")
        XCTAssertTrue(app.buttons["Dictation"].waitForExistence(timeout: 3))
        app.buttons["Dictation"].tap()
        snapshot("system-dictation")
        XCTAssertFalse(app.staticTexts[awaitingOwnerConfirmationText].exists)
    }

    func testAppleSignInButtonReachesAuthorizationCoordinator() {
        let account = app.buttons["Link Account"]
        reveal(account, in: app.scrollViews.firstMatch)
        account.tap()
        print("WATCH_ACCOUNT_BEFORE\n\(app.debugDescription)")
        snapshot("apple-account-page")
        // watchOS exposes this WKInterfaceObject's label, but not its identifier, to XCUIAutomation.
        let apple = app.buttons["Sign in with Apple"]
        XCTAssertTrue(apple.waitForExistence(timeout: 3))
        reveal(apple, in: app.scrollViews.firstMatch)
        snapshot("apple-signin-before")
        apple.tap()
        let changed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Apple sign-in' OR label CONTAINS[c] 'Waiting for Apple'")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 10), "Apple button did not invoke the coordinator")
        let board = XCUIApplication(bundleIdentifier: "com.apple.Carousel")
        if board.alerts.firstMatch.waitForExistence(timeout: 20) {
            print("WATCH_APPLE_SYSTEM_RESULT\n\(board.alerts.firstMatch.debugDescription)")
            snapshot("apple-system-result")
            if board.buttons["OK"].exists { board.buttons["OK"].tap() }
        }
        print("WATCH_APPLE_RUNTIME_RESULT\n\(app.debugDescription)")
        snapshot("apple-signin-result")
        // Credential delivery and persisted authorized session require an actual Apple account.
    }

    func testLargeTextPrimaryDialerAllKeysAndVisibleEdges() {
        app.launchArguments = ["--uitest-large-text"]
        app.launch()
        testPrimaryDialerAllKeysAndVisibleEdges()
    }
}
