import XCTest

@MainActor
final class ShareTransactionUITests: XCTestCase {
    override func tearDown() async throws {
        XCUIApplication().terminate()
        try await super.tearDown()
    }

    func testJournalsTitleIsVisibleAndCompact() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        let bar = app.navigationBars["Journals"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        let title = bar.staticTexts["Journals"]
        XCTAssertTrue(title.exists)
        XCTAssertFalse(title.frame.isEmpty)
        XCTAssertLessThan(bar.frame.height, 100, "The root should not reserve an empty large-title region")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Visible compact Journals title"; shot.lifetime = .keepAlways; add(shot)
    }

    func testUnsavedImageShareOpensTransactionEditorAndCancelDoesNotSave() {
        let app = launchShare()
        let baseline = app.staticTexts["share-qa-transaction-count"].label
        openExtension(app)
        XCTAssertTrue(app.buttons["incoming-journal-picker"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["shared-transaction-amount-0"].exists)
        XCTAssertFalse(app.buttons["receipt-share-open-finances"].exists)
        XCTAssertFalse(app.buttons["receipt-share-save"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Direct screenshot transaction editor"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["receipt-share-cancel"].tap()
        assertReturnedToHost(app)
        XCTAssertEqual(app.staticTexts["share-qa-transaction-count"].label, baseline)
    }

    func testUnsavedImageSaveDoesNotOpenAnotherShareMenuOrEditor() {
        let app = launchShare()
        let baseline = Int(app.staticTexts["share-qa-transaction-count"].label.split(separator: " ").first!)!
        openExtension(app)
        let amount = app.textFields["shared-transaction-amount-0"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        amount.tap(); amount.typeText("12.50")
        let save = app.buttons["receipt-share-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        assertReturnedToHost(app)
        let count = app.staticTexts["share-qa-transaction-count"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "\(baseline + 1) transactions"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        XCTAssertFalse(app.navigationBars["New Transaction"].exists)
    }

    func testCompactAccountAmountAndCurrencyShareOneRow() {
        let app = launchShare()
        openExtension(app)
        let account = app.buttons["shared-transaction-account-0"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        let amount = app.textFields["shared-transaction-amount-0"]
        let currency = app.buttons["shared-transaction-currency-0"]
        XCTAssertTrue(amount.exists); XCTAssertTrue(currency.exists)
        XCTAssertEqual(account.frame.midY, amount.frame.midY, accuracy: 3)
        XCTAssertEqual(currency.frame.midY, amount.frame.midY, accuracy: 3)
        XCTAssertLessThan(account.frame.maxX, amount.frame.maxX)
        XCTAssertLessThan(amount.frame.maxX, currency.frame.maxX)
        XCTAssertLessThan(currency.frame.width, 60)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Compact account amount currency share rows"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["receipt-share-cancel"].tap()
        assertReturnedToHost(app)
    }

    func testReceiptAIAutofillsPopupAndPreservesEditedNotes() {
        let app = launchShare(ai: true)
        let baseline = Int(app.staticTexts["share-qa-transaction-count"].label.split(separator: " ").first!)!
        openExtension(app)
        let notes = app.descendants(matching: .any).matching(identifier: "shared-transaction-note").firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.tap(); notes.typeText("Keep my own notes")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let analyze = app.buttons["share-receipt-ai"]
        for _ in 0..<5 where !analyze.isHittable { app.swipeUp() }
        XCTAssertTrue(analyze.isHittable)
        analyze.tap()
        let replacement = app.buttons["share-receipt-replace-note"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["share-receipt-ai-error"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Receipt AI autofill and protected note review"; shot.lifetime = .keepAlways; add(shot)
        for _ in 0..<4 { app.swipeDown() }
        XCTAssertEqual(app.textFields["Payee"].value as? String, "QA Receipt Cafe")
        XCTAssertEqual(app.textFields["Number"].value as? String, "QA-123")
        XCTAssertEqual(app.textFields["shared-transaction-amount-0"].value as? String, "-18.75")
        XCTAssertEqual(notes.value as? String, "Keep my own notes")
        XCTAssertEqual(app.switches["Cleared"].value as? String, "1")
        XCTAssertTrue(app.buttons["receipt-share-save"].isEnabled)
        app.buttons["receipt-share-save"].tap()
        assertReturnedToHost(app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "\(baseline + 1) transactions"), object: app.staticTexts["share-qa-transaction-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
    }

    func testReceiptAIFailureKeepsEditorUsable() {
        let app = launchShare(ai: true, failure: true)
        openExtension(app)
        let analyze = app.buttons["share-receipt-ai"]
        for _ in 0..<5 where !analyze.isHittable { app.swipeUp() }
        XCTAssertTrue(analyze.isHittable); analyze.tap()
        let error = app.staticTexts["share-receipt-ai-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("offline"), error.label)
        XCTAssertTrue(analyze.isEnabled)
        app.buttons["receipt-share-cancel"].tap()
        assertReturnedToHost(app)
    }

    private func assertReturnedToHost(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["receipt-share-save"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Share Unsaved QA Screenshot"].isHittable)
        XCTAssertFalse(app.cells.matching(identifier: "shareCell").firstMatch.exists, "No second share menu should remain")
    }

    private func launchShare(ai: Bool = false, failure: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo", "--demo-native-share", "--demo-share-sheet"]
            + (ai ? ["--demo-share-ai"] : []) + (failure ? ["--demo-share-ai-failure"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["Share Unsaved QA Screenshot"].waitForExistence(timeout: 10))
        return app
    }
    private func openExtension(_ app: XCUIApplication) {
        app.buttons["Share Unsaved QA Screenshot"].tap()
        let cell = app.cells.matching(NSPredicate(format: "identifier == %@ AND (label == %@ OR label == %@)", "shareCell", "Finances", "Add to Finances")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), app.debugDescription)
        // Wait for the system's activity cell to finish moving after discovery.
        // Existence alone includes the transient first-launch placeholder.
        var previous = CGRect.zero
        var stableSince = Date()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = cell.frame
            guard cell.isHittable, !current.isEmpty else { return false }
            if current != previous { previous = current; stableSince = Date(); return false }
            return Date().timeIntervalSince(stableSince) >= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        cell.tap()
        XCTAssertTrue(app.buttons["receipt-share-save"].waitForExistence(timeout: 10), "Wait for the extension editor before interacting with its fields")
    }
}
