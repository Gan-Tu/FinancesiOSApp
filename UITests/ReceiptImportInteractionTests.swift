import XCTest

@MainActor
final class ReceiptImportInteractionTests: XCTestCase {
    private func openDuplicate() throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo", "--demo-delayed-receipt-import"]
        app.launch()
        let journal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch
        XCTAssertTrue(journal.waitForExistence(timeout: 10)); journal.tap()
        app.buttons["All"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "register-row-", "Weekly groceries")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.swipeLeft()
        app.buttons["Duplicate"].tap()
        app.alerts.buttons["Duplicate With Today's Date"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        return app
    }

    func testSaveWaitsForAcceptedReceiptImportAndPersistsThatReceipt() throws {
        let app = try openDuplicate()
        defer { app.terminate() }
        let save = app.navigationBars["New Transaction"].buttons["Save"]
        XCTAssertFalse(save.isEnabled, "Amounts are already valid, but the accepted receipt has not reached the draft")
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 15), .completed)
        save.tap()
        XCTAssertTrue(app.navigationBars["All"].waitForExistence(timeout: 5))
        let newest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "register-row-", "Weekly groceries")).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 5)); newest.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delayed Receipt.txt"].waitForExistence(timeout: 5), "The receipt selected before Save must belong to the saved duplicate")
    }

    func testCancelDuringAcceptedImportDoesNotCreateDuplicateOrDeliverLater() throws {
        let app = try openDuplicate()
        defer { app.terminate() }
        XCTAssertFalse(app.navigationBars["New Transaction"].buttons["Save"].isEnabled)
        app.navigationBars["New Transaction"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["All"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 6.5) // Let the controlled provider delay expire after Cancel.
        XCTAssertFalse(app.navigationBars["New Transaction"].exists)
        app.terminate(); app.launchArguments = ["--demo"]; app.launch()
        let journal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch
        XCTAssertTrue(journal.waitForExistence(timeout: 10))
        XCTAssertTrue(journal.label.contains("24 Transactions"), "Cancel must not create a persisted duplicate")
        journal.tap(); app.buttons["All"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "register-row-", "Weekly groceries")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Delayed Receipt.txt"].exists)
    }
    func testDetailsDisableConflictingEditWhileAcceptedImportFinishesAfterBackNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo", "--demo-delayed-receipt-import"]
        app.launch()
        let journal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch
        XCTAssertTrue(journal.waitForExistence(timeout: 10)); journal.tap(); app.buttons["All"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "register-row-", "Train ticket")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Details"].buttons["Edit"].isEnabled)
        XCTAssertFalse(app.buttons["Delete Transaction"].isEnabled)
        XCTAssertFalse(app.buttons["Transaction Actions"].isEnabled)
        app.navigationBars["Details"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["All"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 6.5)
        row.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delayed Receipt.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Details"].buttons["Edit"].isEnabled)
    }

}
