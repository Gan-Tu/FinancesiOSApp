import XCTest

@MainActor
final class ShareTransactionUITests: XCTestCase {
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

    private func assertReturnedToHost(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["receipt-share-save"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Share Unsaved QA Screenshot"].isHittable)
        XCTAssertFalse(app.cells.matching(identifier: "shareCell").firstMatch.exists, "No second share menu should remain")
    }

    private func launchShare() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo", "--demo-native-share", "--demo-share-sheet"]
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
    }
}
