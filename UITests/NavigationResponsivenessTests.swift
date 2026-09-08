import XCTest

@MainActor
final class NavigationResponsivenessTests: XCTestCase {
    func testEdgeBackWorksDuringLoadingAndOnWarmRegisterWithoutLosingRowSwipeActions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo", "--demo-future", "--demo-slow-register", "--demo-edge-loading"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Personal"].waitForExistence(timeout: 5))
        app.buttons["All"].tap()
        XCTAssertTrue(app.navigationBars["All"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["register-loading"].waitForExistence(timeout: 1))
        swipeBack(app)
        XCTAssertTrue(app.navigationBars["Personal"].waitForExistence(timeout: 5), "One edge swipe should return while the register is loading")
        app.buttons["All"].tap()
        XCTAssertTrue(app.navigationBars["All"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "register-row-", "Weekly groceries")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertTrue(app.navigationBars["All"].exists, "An interior row swipe must not navigate back")
        let clear = app.buttons["Uncleared"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3), "Leading cleared-status action remains available")
        swipeBack(app)
        XCTAssertTrue(app.navigationBars["Personal"].waitForExistence(timeout: 5), "An edge swipe must win over an open row swipe")
    }

    func testReturningDuringFilterRefreshAppliesTheNewPresentation() throws {
        let app = openRecurringSearch()
        defer { app.terminate() }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "register-row-"))
        app.buttons["search-future-toggle"].tap()
        rows.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2.2) // Controlled two-second slow-render fixture.
        app.navigationBars["Details"].buttons.element(boundBy: 0).tap()
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 8), .completed)
    }

    func testRapidFilterToggleCannotApplyAnObsoleteResult() throws {
        let app = openRecurringSearch()
        defer { app.terminate() }
        let toggle = app.buttons["search-future-toggle"]
        toggle.tap(); toggle.tap()
        Thread.sleep(forTimeInterval: 2.2) // Let the superseded fixture render finish.
        XCTAssertEqual(toggle.value as? String, "Recent entries")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "register-row-"))
        XCTAssertEqual(rows.count, 1)
    }

    private func openRecurringSearch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo", "--demo-recurring", "--demo-slow-register"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["Quick Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Repeating sample\n")
        app.buttons["search-filter-note"].tap()
        XCTAssertTrue(app.navigationBars["Note: Repeating sample"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "register-row-"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        return app
    }

    private func swipeBack(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
