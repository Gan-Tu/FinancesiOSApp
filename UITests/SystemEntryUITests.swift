import XCTest

@MainActor
final class SystemEntryUITests: XCTestCase {
    private func launch(_ app: XCUIApplication, reset: Bool = true, wallet: Bool = false) {
        continueAfterFailure = false
        app.launchArguments = ["--demo", "--demo-system-entry"]
            + (reset ? ["--reset-demo"] : []) + (wallet ? ["--demo-wallet-draft"] : [])
        app.launch()
        XCTAssertTrue(app.navigationBars[wallet ? "New Transaction" : "Journals"].waitForExistence(timeout: 10))
    }
    private func journal(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTHETIC \(name),")).firstMatch
    }
    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists, app.buttons["Done"].exists { app.buttons["Done"].tap() }
    }
    private func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.textFields[label].exists ? app.textFields[label] : app.textViews[label]
    }
    private func enter(_ value: String, into field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + value)
    }
    private func assertAmount(_ field: XCUIElement, _ amount: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let input = try XCTUnwrap(field.value as? String, file: file, line: line)
        XCTAssertEqual(Decimal(string: input), Decimal(string: amount), file: file, line: line)
    }
    private func openShortcutSettings(_ app: XCUIApplication) {
        app.buttons["Settings"].tap()
        app.buttons["Quick Entry & Shortcuts"].tap()
        app.buttons["Home Screen Quick Actions"].tap()
        XCTAssertTrue(app.navigationBars["Home Screen Shortcuts"].waitForExistence(timeout: 5))
    }
    private func openPurchase(_ app: XCUIApplication) {
        journal(app, "Alpha").tap(); app.buttons["All"].tap()
        let row = app.buttons["register-row-00000000-0000-0000-0000-000000000064"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
    }
    private func openRefund(_ app: XCUIApplication) {
        openPurchase(app)
        let tracking = app.buttons["Refund or Reimbursement"]
        for _ in 0..<3 where !tracking.isHittable { app.swipeUp() }
        XCTAssertTrue(tracking.isHittable); tracking.tap()
        XCTAssertTrue(app.navigationBars["Refund / Reimbursement"].waitForExistence(timeout: 5))
    }

    func testConfigureReorderAndReplaceHomeScreenTemplateAction() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app); openShortcutSettings(app)
        let reorder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder"))
        XCTAssertEqual(reorder.count, 4, "A fresh install seeds four templates from the selected journal")
        let beta = app.buttons["Add Coffee, SYNTHETIC Beta"]
        XCTAssertTrue(beta.exists); XCTAssertFalse(beta.isEnabled)
        let first = reorder.element(boundBy: 0), last = reorder.element(boundBy: 3)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        // UIKit labels each handle "Reorder Remove". Verify the actual row
        // contents, not a template name that the handle does not expose.
        let included = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove, "))
        XCTAssertEqual(included.allElementsBoundByIndex.map(\.label),
            ["Lunch", "Transit", "Groceries", "Coffee"].map { "Remove, \($0), SYNTHETIC Alpha" },
            "Dragging must change the complete visible order")
        let remove = app.images["minus.circle.fill"].firstMatch
        XCTAssertTrue(remove.isHittable); remove.tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        for _ in 0..<3 where !beta.isHittable { app.swipeUp() }
        XCTAssertTrue(beta.isEnabled); beta.tap()
        let added = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in reorder.count == 4 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 5), .completed, "Adding the template must restore four configured actions")
        XCTAssertEqual(reorder.count, 4)
        XCTAssertFalse(beta.exists, "Adding a template removes it from More Templates")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Configured Home Screen Template Actions"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); launch(app, reset: false); openShortcutSettings(app)
        XCTAssertEqual(reorder.count, 4)
        XCTAssertFalse(app.buttons["Add Coffee, SYNTHETIC Beta"].exists)
        XCTAssertTrue(app.buttons["Add Lunch, SYNTHETIC Alpha"].exists, "The removed action stays removed after relaunch")
    }

    func testWalletSuggestionIsEditableAndCancelDoesNotPostIt() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app, wallet: true)
        XCTAssertTrue(app.buttons["incoming-journal-picker"].exists)
        try assertAmount(app.textFields["Amount for SYNTHETIC Bank"], "-42.5")
        XCTAssertEqual(text(app, "Payee").value as? String, "SYNTHETIC Wallet Store")
        dismissKeyboard(app)
        let notes = text(app, "Notes")
        enter("SYNTHETIC cancelled Wallet capture", into: notes)
        XCTAssertTrue(app.navigationBars["New Transaction"].exists)
        app.navigationBars["New Transaction"].buttons["Cancel"].tap()
        app.terminate(); launch(app, reset: false)
        XCTAssertTrue(journal(app, "Alpha").label.contains("2 Transactions"))
        XCTAssertTrue(journal(app, "Beta").label.contains("0 Transactions"))
        journal(app, "Alpha").tap(); app.buttons["All"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "register-row-", "Wallet")).firstMatch.exists)
    }

    func testWalletDraftJournalChangeRequiresNewAccountsAndOnlySavePostsToChosenJournal() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app, wallet: true); dismissKeyboard(app)
        app.buttons["incoming-journal-picker"].tap()
        app.buttons["SYNTHETIC Beta"].tap()
        let choose = app.buttons.matching(NSPredicate(format: "label == %@", "Choose Account"))
        XCTAssertEqual(choose.count, 2, "Changing journals must not reuse accounts from the old journal")
        XCTAssertFalse(app.navigationBars["New Transaction"].buttons["Save"].isEnabled)
        for name in ["SYNTHETIC Beta Bank", "SYNTHETIC Beta Expense"] {
            choose.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Choose Account"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTHETIC Bank,")).firstMatch.exists)
            let account = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            for _ in 0..<3 where !account.isHittable { app.swipeUp() }
            XCTAssertTrue(account.isHittable); account.tap()
            XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        }
        enter("-43.75", into: app.textFields["Amount for SYNTHETIC Beta Bank"])
        try assertAmount(app.textFields["Amount for SYNTHETIC Beta Expense"], "43.75")
        dismissKeyboard(app)
        enter("SYNTHETIC Wallet approved", into: text(app, "Notes"))
        app.navigationBars["New Transaction"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.terminate(); launch(app, reset: false)
        XCTAssertTrue(journal(app, "Alpha").label.contains("2 Transactions"))
        XCTAssertTrue(journal(app, "Beta").label.contains("1 Transactions"))
        journal(app, "Beta").tap(); app.buttons["All"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "register-row-", "SYNTHETIC Wallet approved")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        app.navigationBars["Details"].buttons["Edit"].tap()
        try assertAmount(app.textFields["Amount for SYNTHETIC Beta Bank"], "-43.75")
        try assertAmount(app.textFields["Amount for SYNTHETIC Beta Expense"], "43.75")
        XCTAssertEqual(text(app, "Payee").value as? String, "SYNTHETIC Wallet Store")
    }

    func testTrackPurchaseAndLinkExistingPartialRefundWithoutChangingTransactions() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app); openRefund(app)
        try assertAmount(app.textFields["refund-expected-amount"], "100")
        let start = app.buttons["refund-save-tracking"]
        for _ in 0..<3 where !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.isEnabled); start.tap()
        let link = app.buttons["refund-link-payment"]
        for _ in 0..<3 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
        XCTAssertTrue(app.navigationBars["Link Received Payment"].waitForExistence(timeout: 5))
        let received = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTHETIC Partial Refund")).firstMatch
        XCTAssertTrue(received.waitForExistence(timeout: 5)); received.tap()
        try assertAmount(app.textFields["refund-link-amount"], "40")
        app.buttons["Link Payment"].tap()
        XCTAssertTrue(app.navigationBars["Link Received Payment"].waitForExistence(timeout: 5))
        app.navigationBars["Link Received Payment"].buttons.element(boundBy: 0).tap()
        let waiting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Waiting for", "60.00")).firstMatch
        for _ in 0..<4 where !waiting.isHittable { app.swipeDown() }
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        app.terminate(); launch(app, reset: false)
        XCTAssertTrue(journal(app, "Alpha").label.contains("2 Transactions"), "Tracking links an existing payment; it must not create another")
        openRefund(app)
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "The remaining expected amount must persist")
        let linkedPayment = app.buttons["SYNTHETIC Partial Refund"]
        for _ in 0..<4 where !linkedPayment.isHittable { app.swipeUp() }
        XCTAssertTrue(linkedPayment.isHittable); linkedPayment.tap()
        XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForExistence(timeout: 5))
        try assertAmount(app.textFields["Amount for SYNTHETIC Bank"], "40")
        try assertAmount(app.textFields["Amount for SYNTHETIC Expense"], "-40")
    }
}
