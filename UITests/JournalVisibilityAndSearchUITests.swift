import XCTest

@MainActor
final class JournalVisibilityAndSearchUITests: XCTestCase {
    func testQuickSearchSupportsClearDuplicateAndDeleteWithoutLeavingSearch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["Quick Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Weekly")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-transaction-"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        app.buttons["search-filter-anywhere"].tap()
        XCTAssertTrue(app.buttons["Quick Search"].waitForExistence(timeout: 5))
        app.buttons["Quick Search"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "Weekly")
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "Weekly groceries")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        let originalCount = rows.count
        let rowID = rows.firstMatch.identifier
        let row = app.buttons[rowID]
        row.swipeRight()
        let firstAction = app.buttons["Uncleared"].exists ? "Uncleared" : "Cleared"
        XCTAssertTrue(app.buttons[firstAction].waitForExistence(timeout: 5))
        app.buttons[firstAction].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        let oppositeAction = firstAction == "Uncleared" ? "Cleared" : "Uncleared"
        XCTAssertTrue(app.buttons[oppositeAction].waitForExistence(timeout: 5))
        app.buttons[oppositeAction].tap()
        XCTAssertTrue(app.navigationBars["Quick Search"].exists)
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Duplicate"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Quick Search direct swipe actions"; image.lifetime = .keepAlways; add(image)
        app.buttons["Duplicate"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Duplicate With Today's Date"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        app.navigationBars["New Transaction"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Quick Search"].waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "Weekly groceries")
        XCTAssertEqual(rows.count, originalCount)
        row.swipeLeft(); app.buttons["Duplicate"].tap()
        app.alerts.buttons["Duplicate With Today's Date"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        app.navigationBars["New Transaction"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Quick Search"].waitForExistence(timeout: 5))
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", originalCount + 1), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed)
        XCTAssertEqual(search.value as? String, "Weekly groceries")
        row.swipeLeft(); app.buttons["Delete"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Quick Search"].exists)
        XCTAssertEqual(search.value as? String, "Weekly groceries")
        XCTAssertEqual(rows.count, originalCount)
    }

    func testQuickSearchRecurringDeletionSupportsCancelSingleAndFutureScope() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo", "--demo-recurring"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["Quick Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Repeating sample\n")
        app.buttons["Show All Future Entries"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-transaction-"))
        let threeRows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [threeRows], timeout: 5), .completed)
        let earliest = try XCTUnwrap(rows.allElementsBoundByIndex.first)
        let earliestID = earliest.identifier
        earliest.swipeLeft(); app.buttons["Delete"].tap()
        XCTAssertTrue(app.sheets.buttons["Delete Only This Transaction"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].tap()
        XCTAssertEqual(rows.count, 3)
        app.buttons[earliestID].swipeLeft(); app.buttons["Delete"].tap()
        app.sheets.buttons["Delete Only This Transaction"].tap()
        let twoRows = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [twoRows], timeout: 5), .completed)
        try XCTUnwrap(rows.allElementsBoundByIndex.first).swipeLeft(); app.buttons["Delete"].tap()
        app.sheets.buttons["Delete All Future Transactions"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Quick Search"].exists)
        XCTAssertEqual(search.value as? String, "Repeating sample")
    }

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
