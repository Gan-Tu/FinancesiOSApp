import XCTest

@MainActor
final class JournalVisibilityAndSearchUITests: XCTestCase {
    func testHideJournalSurvivesRelaunchAndCanBeRestoredInSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        let personal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch
        let start = personal.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = personal.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        let hide = app.buttons["Hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5)); hide.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: personal)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        app.terminate(); app.launchArguments = ["--demo"]; app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        XCTAssertFalse(personal.exists)
        app.buttons["Settings"].tap()
        let hiddenJournals = app.buttons["Hidden Journals"]
        for _ in 0..<4 where !hiddenJournals.isHittable { app.swipeUp() }
        XCTAssertTrue(hiddenJournals.isHittable); hiddenJournals.tap()
        XCTAssertTrue(app.navigationBars["Hidden Journals"].waitForExistence(timeout: 5))
        let show = app.buttons["Show journal Personal"]
        XCTAssertTrue(show.waitForExistence(timeout: 5)); show.tap()
        XCTAssertTrue(app.staticTexts["No Hidden Journals"].waitForExistence(timeout: 5))
        app.navigationBars["Hidden Journals"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        XCTAssertTrue(personal.label.contains("24 Transactions"))
    }

    func testReturnKeepsQuickSearchAndAccountMatchesAboveSuggestions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["All"].tap()
        XCTAssertTrue(app.navigationBars["All"].waitForExistence(timeout: 5))
        app.buttons["Quick Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Checking\n")
        let keyboardHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Quick Search"].exists)
        XCTAssertEqual(search.value as? String, "Checking")
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "search-account-", "Assets:Checking")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-transaction-")).firstMatch.exists)
        let note = app.buttons["search-filter-note"]
        XCTAssertLessThan(account.frame.minY, note.frame.minY)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Quick Search accounts and keyboard dismissed"; image.lifetime = .keepAlways; add(image)
        account.tap()
        XCTAssertTrue(app.navigationBars["Checking"].waitForExistence(timeout: 5))
    }

    func testFutureRecurringSearchIsOptInInQuickAndFullResults() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo", "--demo-recurring"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["Quick Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Repeating sample\n")
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-transaction-"))
        XCTAssertTrue(previews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(previews.count, 1)
        app.buttons["search-future-toggle"].tap()
        let allPreviews = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: previews)
        XCTAssertEqual(XCTWaiter.wait(for: [allPreviews], timeout: 5), .completed)
        app.buttons["search-filter-note"].tap()
        XCTAssertTrue(app.navigationBars["Note: Repeating sample"].waitForExistence(timeout: 5))
        let toggle = app.buttons["search-future-toggle"]
        XCTAssertTrue(toggle.exists)
        XCTAssertEqual(toggle.value as? String, "All dates")
        toggle.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "register-row-"))
        let recentRows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [recentRows], timeout: 5), .completed)
        XCTAssertEqual(toggle.value as? String, "Recent entries")
    }
    func testAccountMatchesCollapseAndTransactionsMatchTheirOwnFields() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo", "--demo-search-matches"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["Quick Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("son\n")
        let accounts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-account-"))
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-transaction-"))
        let toggle = app.buttons["search-accounts-toggle"]
        XCTAssertTrue(app.buttons["Show All 5 Accounts"].waitForExistence(timeout: 5))
        XCTAssertEqual(accounts.count, 3)
        XCTAssertEqual(previews.count, 3)
        XCTAssertTrue(previews.firstMatch.isHittable, "Collapsed accounts should leave room for transactions")
        XCTAssertFalse(previews.matching(NSPredicate(format: "label CONTAINS %@", "Unrelated entry")).firstMatch.exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Three account matches and relevant transactions"; image.lifetime = .keepAlways; add(image)
        toggle.tap()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 5"), object: accounts)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
        XCTAssertEqual(toggle.value as? String, "Expanded")
        XCTAssertFalse(accounts.matching(NSPredicate(format: "label CONTAINS %@", "Groceries")).firstMatch.exists)
        toggle.tap()
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: accounts)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
        toggle.tap()
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "Personal\n")
        XCTAssertTrue(app.buttons["Show All 4 Accounts"].waitForExistence(timeout: 5))
        XCTAssertEqual(accounts.count, 3)
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "son\n")
        XCTAssertTrue(app.buttons["Show All 5 Accounts"].waitForExistence(timeout: 5))
        app.buttons["search-filter-anywhere"].tap()
        XCTAssertTrue(app.navigationBars["Search: son"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "register-row-"))
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 5), .completed)
        XCTAssertFalse(rows.matching(NSPredicate(format: "label CONTAINS %@", "Unrelated entry")).firstMatch.exists)
    }

}
