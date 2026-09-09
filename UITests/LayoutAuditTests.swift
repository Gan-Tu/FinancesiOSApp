import XCTest

@MainActor
final class LayoutAuditTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
    }

    func testJournalRegisterAndDetailScreens() throws {
        capture("01 Journals")
        tap("New Journal")
        capture("02 New Journal")
        tapPrefix("Currency")
        capture("03 Currency Catalog")
        back("Currency")
        tap("Cancel")
        openJournal()
        capture("04 Journal")
        tapPrefix("Assets")
        tap("Expenses")
        capture("05 Expanded Accounts")
        tap("All")
        capture("06 Register")
        tap("Show Chart")
        capture("07 Cash Flow Chart")
        app.buttons["Monthly Summary"].firstMatch.tap()
        capture("08 Monthly Summary")
        app.navigationBars.buttons["Done"].tap()
        tap("Hide Chart")
        tapPrefix("Weekly groceries")
        capture("09 Transaction Details")
        app.swipeUp()
        capture("10 Transaction Receipt")
    }

    func testTransactionAndPickerScreens() throws {
        openJournal()
        tap("New Transaction"); tap("Expense")
        capture("11 New Transaction")
        tap("transaction-date-toggle")
        let datePicker = app.descendants(matching: .any).matching(identifier: "transaction-date-picker").firstMatch
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5), "Date should expand inline")
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["New Transaction"].exists, "Opening Date should keep the transaction editor visible")
        let keyboardHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)
        capture("12 Inline Transaction Date")
        let selectedDate = try XCTUnwrap(app.buttons["transaction-date-toggle"].value as? String)
        XCTAssertFalse(selectedDate.isEmpty)
        tap("transaction-date-toggle")
        let pickerHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: datePicker)
        XCTAssertEqual(XCTWaiter.wait(for: [pickerHidden], timeout: 5), .completed, "A second tap should collapse Date")
        XCTAssertEqual(app.buttons["transaction-date-toggle"].value as? String, selectedDate, "Collapsing Date should preserve its value")
        tapPrefix("Repeat,")
        capture("13 Repeat")
        tap("Custom")
        capture("14 Custom Repeat")
        back("Custom Repeat")
        tap("Every Month")
        tapPrefix("End Repeat")
        capture("15 End Repeat")
        tap("On Date")
        capture("16 End Date")
        tap("After")
        capture("17 Occurrence Count")
        back("End Repeat")
        tap("Checking")
        capture("18 Selected Account")
        tap("New Account")
        capture("19 New Account")
        tapPrefix("Group In")
        capture("20 Account Group")
        back("Group In")
        tapPrefix("Currency")
        capture("21 Account Currency")
        back("Currency")
        app.swipeUp()
        capture("22 Account Colors")
        tap("Cancel")
        back("Choose Account")
        app.swipeUp()
        tap("Add Attachment")
        capture("23 Receipt Actions")
    }

    func testSettingsScreens() throws {
        tap("Settings")
        capture("24 Settings")
        for (label, title, number) in [("iCloud Sync", "Cloud Sync", "25"), ("Security", "Security", "26"), ("Backup", "Backup", "27"), ("Finances for Mac", "Finances for Mac", "28"), ("Help", "Help", "29"), ("Display", "Display", "30")] {
            app.collectionViews.buttons[label].tap()
            capture("\(number) \(title)")
            if title == "Backup" || title == "Help" {
                app.swipeUp(); capture("\(number)b \(title) Lower")
            }
            back(title)
        }
        app.swipeUp()
        capture("31 Settings Data Management")
    }

    func testLongAccountLabelsKeepSelectionInsideCard() throws {
        openJournal()
        tap("New Transaction"); tap("Expense")
        tap("Checking"); tap("New Account")
        let name = "Household essentials and everyday grocery shopping"
        app.textFields["Name"].tap(); app.textFields["Name"].typeText(name)
        app.textFields["Description"].tap()
        app.textFields["Description"].typeText("Groceries, meal preparation, pantry supplies, and cooking ingredients for the whole household.")
        tap("Save")
        tapPrefix(name)
        tap(name)
        let check = app.images["account-selection-checkmark"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        let cell = app.cells.containing(.image, identifier: "account-selection-checkmark").firstMatch
        XCTAssertTrue(cell.exists)
        XCTAssertGreaterThanOrEqual(cell.frame.maxX - check.frame.maxX, 16)
        capture("39 Long Selected Account")
    }

    func testCurrencyTemplateAndSearchScreens() throws {
        openJournal()
        tap("section-action-Currencies"); tap("New Currency")
        capture("32 New Currency")
        tap("Cancel")
        tap("section-action-Transactions"); tap("Templates")
        capture("33 Empty Templates")
        tap("New Template")
        capture("34 New Template")
        tap("Posting")
        capture("35 Template Postings")
        let name = app.textFields["Name"]
        name.tap(); name.typeText("Household shopping and supplies")
        tap("Save")
        capture("36 Saved Template")
        back("Templates")
        tap("Quick Search")
        capture("37 Quick Search")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("groceries")
        capture("38 Search Results")
    }

    private func openJournal() {
        tapPrefix("Personal,")
        XCTAssertTrue(app.navigationBars["Personal"].waitForExistence(timeout: 5))
    }

    private func tap(_ name: String) {
        let button = app.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 5), name)
        button.tap()
    }

    private func tapPrefix(_ prefix: String) {
        let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), prefix)
        button.tap()
    }

    private func back(_ title: String) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), title)
        bar.buttons.element(boundBy: 0).tap()
    }

    private func capture(_ name: String) {
        // Modal routes are presented after their action sheet dismisses. XCTest
        // can report idle between those two animations; capture the settled UI.
        Thread.sleep(forTimeInterval: 1.0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
