import XCTest

@MainActor
final class RegisterInteractionTests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        return app
    }

    func testSwipeActionsAndLastRowStayAboveToolbar() throws {
        let app = launch(["--demo-future", "--demo-scroll"])
        app.buttons["All"].tap()
        let oldest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Oldest test transaction")).firstMatch
        for _ in 0..<10 {
            if oldest.exists && oldest.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(oldest.isHittable)
        let id = oldest.identifier
        let row = app.buttons[id]
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(row.isHittable)
        XCTAssertLessThan(row.frame.maxY, app.buttons["iCloud Sync"].frame.minY - 8)
        capture(app, "Last transaction remains above toolbar")
        row.swipeRight()
        XCTAssertTrue(app.buttons["Uncleared"].waitForExistence(timeout: 3))
        app.buttons["Uncleared"].tap()
        row.swipeRight()
        XCTAssertTrue(app.buttons["Cleared"].waitForExistence(timeout: 3))
        app.buttons["Cleared"].tap()
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Duplicate"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
        capture(app, "Gray duplicate and red delete")
        app.buttons["Duplicate"].tap()
        XCTAssertTrue(app.buttons["Duplicate With Today's Date"].waitForExistence(timeout: 3))
        capture(app, "Duplicate date choices")
        app.buttons["Duplicate With Today's Date"].tap()
        row.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 1))
        XCTAssertFalse(app.buttons["Delete Only This Transaction"].exists)
    }

    func testRecurringDeletionOffersSingleAndFutureChoices() throws {
        let app = launch(["--demo-recurring"])
        app.buttons["Repeating"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Repeating sample"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        let row = try XCTUnwrap(rows.allElementsBoundByIndex.last)
        row.swipeLeft(); app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["Delete Only This Transaction"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Delete All Future Transactions"].exists)
        XCTAssertTrue(row.exists, "Swipe Delete must not remove the row before confirmation")
        XCTAssertGreaterThan(row.frame.height, 0)
        app.sheets.buttons["Cancel"].tap()
        XCTAssertEqual(rows.count, 3, "Cancelling must preserve the complete series")
        row.swipeLeft(); app.buttons["Delete"].tap()
        capture(app, "Recurring deletion choices")
        app.buttons["Delete Only This Transaction"].tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        let next = try XCTUnwrap(rows.allElementsBoundByIndex.last)
        next.swipeLeft(); app.buttons["Delete"].tap()
        app.buttons["Delete All Future Transactions"].tap()
        XCTAssertTrue(app.staticTexts["No Transactions"].waitForExistence(timeout: 5))
    }

    func testBackfilledUnclearedDeletionAcrossDayAndMonthBoundaries() throws {
        continueAfterFailure = false
        let app = launch(["--demo-recurring", "--demo-backfilled-recurring"])
        defer { app.terminate() }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Uncleared,")).firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Backfilled recurring entry")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowID = row.identifier
        row.swipeLeft(); app.buttons["Delete"].tap()
        XCTAssertTrue(app.sheets.buttons["Delete Only This Transaction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[rowID].exists)
        XCTAssertGreaterThan(app.buttons[rowID].frame.height, 0)
        app.sheets.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons[rowID].isHittable)
        app.buttons[rowID].swipeLeft(); app.buttons["Delete"].tap()
        app.sheets.buttons["Delete Only This Transaction"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons[rowID])
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Uncleared"].exists)
        let future = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Future recurring entry")).firstMatch
        for _ in 0..<3 { if future.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(future.isHittable)
        let futureID = future.identifier
        future.swipeLeft(); app.buttons["Delete"].tap()
        app.sheets.buttons["Delete All Future Transactions"].tap()
        let futureRemoved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons[futureID])
        XCTAssertEqual(XCTWaiter.wait(for: [futureRemoved], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Uncleared"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dinner with friends")).firstMatch.exists)
    }

    func testJournalEditDeletionWaitsForConfirmation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Edit"].tap()
        let delete = app.buttons["Delete Travel"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(app.sheets.buttons["Delete Travel"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].tap()
        XCTAssertTrue(delete.exists, "Cancel must leave the journal in the editable list")
        delete.tap(); app.sheets.buttons["Delete Travel"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: delete)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.isHittable)
    }

    func testDetailsUseInlinePathsAndBoundedReceipt() throws {
        let app = launch()
        app.buttons["All"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekly groceries")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Assets:Assets"].exists)
        XCTAssertTrue(app.staticTexts["Assets:Checking"].exists)
        let preview = app.buttons["receipt-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(preview.frame.height, 200)
        // UIKit includes the list row's touch insets around the 210-point image.
        XCTAssertLessThanOrEqual(preview.frame.height, 260)
        XCTAssertEqual(app.buttons["Delete Transaction"].frame.midX, app.frame.midX, accuracy: 2)
        XCTAssertTrue(app.buttons["Transaction Actions"].exists)
        capture(app, "Reference-aligned Details and receipt")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
