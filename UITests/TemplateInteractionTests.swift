import XCTest

@MainActor
final class TemplateInteractionTests: XCTestCase {
    func testTemplateMinusMovesToMoreAndOnlyIncludedTemplatesAppearInAddMenu() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        XCTAssertTrue(app.buttons["New Transaction"].waitForExistence(timeout: 5))
        app.buttons["New Transaction"].tap()
        app.buttons["Customize Templates…"].tap()
        XCTAssertTrue(app.navigationBars["Templates"].waitForExistence(timeout: 5))
        app.buttons["Exclude Expense"].tap()
        XCTAssertTrue(app.buttons["Include Expense"].waitForExistence(timeout: 5))
        app.buttons["Edit template Expense"].tap()
        XCTAssertTrue(app.navigationBars["Edit Template"].waitForExistence(timeout: 5))
        let name = app.textFields["Name"]
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "Spending")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Include Spending"].waitForExistence(timeout: 5))
        app.buttons["Include Spending"].tap()
        XCTAssertTrue(app.buttons["Exclude Spending"].waitForExistence(timeout: 5))
        app.buttons["Exclude Income"].tap()
        let listImage = XCTAttachment(screenshot: app.screenshot())
        listImage.name = "Included and more templates"; listImage.lifetime = .keepAlways; add(listImage)
        app.navigationBars.buttons["Done"].tap()
        app.buttons["New Transaction"].tap()
        XCTAssertTrue(app.buttons["Spending"].waitForExistence(timeout: 5))
        let choices = app.sheets.firstMatch
        XCTAssertTrue(choices.buttons["Spending"].exists)
        XCTAssertFalse(choices.buttons["Expense"].exists)
        XCTAssertFalse(choices.buttons["Income"].exists)
        app.buttons["Customize Templates…"].tap()
        XCTAssertTrue(app.navigationBars["Templates"].waitForExistence(timeout: 5))
        app.buttons["Edit template Spending"].tap()
        XCTAssertTrue(app.navigationBars["Edit Template"].waitForExistence(timeout: 5))
        let detailImage = XCTAttachment(screenshot: app.screenshot())
        detailImage.name = "Template detail with permanent delete"; detailImage.lifetime = .keepAlways; add(detailImage)
        let delete = app.buttons["Delete Template"]
        if !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        let confirmation = app.sheets.buttons["Delete Template"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        XCTAssertTrue(app.navigationBars["Templates"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Edit template Spending"].exists)
    }

    func testTemplateAccountSelectionPrecedesEditorAndCompleteTemplatesSkipIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["New Transaction"].tap(); app.sheets.buttons["Income"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Choose Account"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons["Cancel"].tap()

        app.buttons["New Transaction"].tap(); app.buttons["Expense"].tap()
        XCTAssertTrue(app.navigationBars["Choose Account"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["New Transaction"].exists, "Account selection should appear before the detailed editor")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Do not focus an amount underneath the account picker")
        let pickerImage = XCTAttachment(screenshot: app.screenshot())
        pickerImage.name = "Template chooses expense account first"; pickerImage.lifetime = .keepAlways; add(pickerImage)
        app.chooseTemplateAccount()
        XCTAssertTrue(app.buttons["Checking"].exists, "Keep the source account specified by the template")
        XCTAssertTrue(app.buttons["Groceries"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Start amount entry after choosing the account")
    }

    func testAmountAutoFocusAndLargeCalculatorKeys() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["New Transaction"].tap(); app.buttons["Expense"].tap(); app.chooseTemplateAccount()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "A new transaction should focus its first amount automatically")
        let amount = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "Amount for")).firstMatch
        app.typeText("25")
        XCTAssertEqual(amount.value as? String, "-25")
        for symbol in ["±", "÷", "×", "−", "+", "="] {
            let key = app.buttons["amount-key-\(symbol)"]
            XCTAssertTrue(key.isHittable)
            XCTAssertGreaterThanOrEqual(key.frame.width, 44)
            XCTAssertGreaterThanOrEqual(key.frame.height, 44)
        }
        app.buttons["amount-key-+"].tap(); app.typeText("3"); app.buttons["amount-key-="].tap()
        XCTAssertEqual(amount.value as? String, "-22.00")
        app.buttons["amount-key-±"].tap()
        XCTAssertEqual(amount.value as? String, "22.00")
        // Tap before the right-aligned number, then insert a unary minus there.
        amount.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        app.buttons["amount-key-−"].tap()
        XCTAssertEqual(amount.value as? String, "-22.00")
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(amount.value as? String, "22.00", "Deleting the sign must keep the amount positive")
        app.typeText("5")
        XCTAssertEqual(amount.value as? String, "522.00", "Continue typing at the cursor without restoring the sign")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Large calculator keys and focused amount"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["Done"].tap()
        let payee = app.textFields["Payee"]
        payee.tap(); payee.typeText("Keyboard dismissal")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed, "Done should dismiss the keyboard from Payee too")
    }

    func testInitialAmountSignCanBeOverriddenBeforeTyping() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["New Transaction"].tap(); app.sheets.buttons["Income"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let amounts = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "Amount for"))
        XCTAssertEqual(amounts.firstMatch.value as? String, "-")
        app.buttons["amount-key-±"].tap()
        app.typeText("5")
        XCTAssertEqual(amounts.firstMatch.value as? String, "5")
        XCTAssertEqual(amounts.element(boundBy: 1).value as? String, "-5.00")
        app.buttons["amount-key-±"].tap()
        XCTAssertEqual(amounts.firstMatch.value as? String, "-5.00")
        XCTAssertEqual(amounts.element(boundBy: 1).value as? String, "5.00")
    }

    func testInvoiceTemplateRequestsReceiptScanning() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Physical camera capture requires an intentionally positioned test receipt.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["section-action-Transactions"].tap()
        app.buttons["Templates"].tap()
        XCTAssertTrue(app.buttons["Edit template Expense"].waitForExistence(timeout: 5))
        app.buttons["New Template"].tap()
        XCTAssertTrue(app.navigationBars["New Template"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Scan Invoice"].waitForExistence(timeout: 5))
        app.switches["Scan Invoice"].tap()
        app.textFields["Name"].tap()
        app.textFields["Name"].typeText("Scan template")
        app.buttons["Save"].tap()
        let template = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Scan template")).firstMatch
        XCTAssertTrue(template.waitForExistence(timeout: 5))
        app.navigationBars["Templates"].buttons.element(boundBy: 0).tap()
        app.buttons["New Transaction"].tap()
        app.buttons["Scan template"].tap(); app.chooseTemplateAccount(expectEditor: false)
        // Recent Simulator runtimes expose the document scanner even without
        // a real camera. Verify the actual UI rather than assuming unsupported.
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            XCTAssertTrue(permission.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Camera")).firstMatch.exists)
            permission.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Don")).firstMatch.tap()
        } else if app.alerts["Couldn’t Add Receipt"].exists {
            let alert = app.alerts["Couldn’t Add Receipt"]
            XCTAssertTrue(alert.staticTexts["Receipt scanning is unavailable on this device. Choose a file or photo instead."].exists)
            alert.buttons["OK"].tap()
            XCTAssertTrue(app.navigationBars["New Transaction"].exists)
        } else {
            XCTAssertTrue(app.buttons["Auto"].waitForExistence(timeout: 5), "The template should present the native document scanner.")
        }
        #endif
    }
}

@MainActor
extension XCUIApplication {
    /// The demo Expense template uses the Food category and now starts with its account picker.
    func chooseTemplateAccount(expectEditor: Bool = true) {
        XCTAssertTrue(navigationBars["Choose Account"].waitForExistence(timeout: 5))
        let account = buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Groceries")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        if expectEditor { XCTAssertTrue(navigationBars["New Transaction"].waitForExistence(timeout: 5)) }
    }
}
