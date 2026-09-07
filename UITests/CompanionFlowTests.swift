import XCTest

final class CompanionFlowTests: XCTestCase {
    @MainActor func testPasswordLockCoversOpenEditorAndPreservesDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        app.buttons["Security"].tap()
        app.secureTextFields["New Password"].tap()
        app.secureTextFields["New Password"].typeText("review-password")
        app.secureTextFields["Verify Password"].tap()
        app.secureTextFields["Verify Password"].typeText("review-password")
        app.buttons["Set Password"].tap()
        app.navigationBars["Security"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Settings"].buttons["Done"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["New Transaction"].tap()
        app.buttons["Expense"].tap()
        let cleared = app.switches["Cleared"]
        XCTAssertTrue(cleared.waitForExistence(timeout: 5))
        cleared.tap()
        let draftCleared = cleared.value as? String
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        app.activate()
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        XCTAssertTrue(password.isHittable)
        password.tap(); password.typeText("review-password")
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.switches["Cleared"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Cleared"].value as? String, draftCleared)
    }

    @MainActor func testCloudSyncSheetMatchesCompactReferenceAndOpensHelp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        app.buttons["iCloud Sync"].tap()
        XCTAssertTrue(app.navigationBars["Cloud Sync"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["cloud-sync-toggle"].exists)
        XCTAssertTrue(app.staticTexts["Sync Disabled"].exists)
        XCTAssertFalse(app.buttons["Synchronize Now"].isEnabled)
        XCTAssertFalse(app.buttons["Reset..."].isEnabled)
        XCTAssertFalse(app.buttons["About iCloud Sync"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cloud Sync reference layout"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Cloud Sync Help"].tap()
        XCTAssertTrue(app.navigationBars["About iCloud Sync"].waitForExistence(timeout: 5))
        app.navigationBars["About iCloud Sync"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Cloud Sync"].waitForExistence(timeout: 5))
        app.navigationBars["Cloud Sync"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 5))
    }

    @MainActor func testRegisterLandsNearTodayAndKeepsFutureEntriesReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo", "--demo-future"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        let uncleared = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Uncleared,")).firstMatch
        XCTAssertTrue(uncleared.label.contains("6"), uncleared.label)
        app.buttons["All"].tap()
        let current = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekly groceries")).firstMatch
        let visible = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: current)
        wait(for: [visible], timeout: 10)
        XCTAssertTrue(app.staticTexts["TODAY"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Today with five years of scheduled entries above"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.swipeDown()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Scheduled groceries 1 ")).firstMatch.isHittable)
        app.buttons["Show Chart"].tap()
        let chart = app.staticTexts["Cash Flow"]
        wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: chart)], timeout: 5)
    }

    @MainActor func testJournalRegisterChartAndEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["All"].tap()
        XCTAssertTrue(app.navigationBars["All"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Weekly groceries")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Show Chart"].tap()
        XCTAssertTrue(app.staticTexts["Cash Flow"].waitForExistence(timeout: 5))
        app.buttons["New Transaction"].tap()
        app.buttons["Expense"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        let amount = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "Amount for")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "25")
        XCTAssertEqual(amount.value as? String, "25")
        XCTAssertEqual(app.textFields["Amount for Checking"].value as? String, "-25.00")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let notes = app.textFields["Notes"]
        notes.tap(); notes.typeText("UI acceptance lunch")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["All"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI acceptance lunch")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("-$25.00"), row.label)
        row.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI acceptance lunch"].exists)
        app.terminate(); app.launchArguments = ["--demo"]; app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["All"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI acceptance lunch")).firstMatch.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Transaction persisted after relaunch"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testNewJournalAndSearchableAccountPicker() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        app.buttons["New Journal"].tap()
        XCTAssertTrue(app.navigationBars["New Journal"].waitForExistence(timeout: 5))
        let name = app.textFields.firstMatch
        name.tap(); name.typeText("Household")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Household")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Household")).firstMatch.tap()
        app.buttons["New Transaction"].tap(); app.buttons["Expense"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Amount for Checking"].waitForExistence(timeout: 5))
        app.buttons["Checking"].tap()
        XCTAssertTrue(app.navigationBars["Choose Account"].waitForExistence(timeout: 5))
        let search = revealSearch(in: app)
        search.tap(); search.typeText("Cash")
        let cashChoice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Cash,")).firstMatch
        XCTAssertTrue(cashChoice.waitForExistence(timeout: 5))
        cashChoice.tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cash"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Account selection"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testCurrencySearchAndInvalidAccountFeedback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        app.buttons["New Journal"].tap()
        XCTAssertTrue(app.navigationBars["New Journal"].waitForExistence(timeout: 5))
        let name = app.textFields["Name"]
        name.tap(); name.typeText("Euro Journal")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Currency")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Currency"].waitForExistence(timeout: 5))
        let search = revealSearch(in: app)
        search.tap(); search.typeText("EUR")
        let euro = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Euro")).firstMatch
        XCTAssertTrue(euro.waitForExistence(timeout: 5)); euro.tap()
        XCTAssertTrue(app.navigationBars["New Journal"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        let journal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Euro Journal,")).firstMatch
        XCTAssertTrue(journal.waitForExistence(timeout: 5)); journal.tap()
        app.buttons["section-action-Accounts"].tap()
        app.buttons["New Account"].tap()
        XCTAssertTrue(app.navigationBars["New Account"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        XCTAssertTrue(app.textFields["Description"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Group In")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Gray"].exists)
        XCTAssertTrue(app.buttons["Green"].exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Group In")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Group In"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["account-group-picker"].buttons["Income"].tap()
        XCTAssertTrue(app.navigationBars["New Account"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        let form = XCTAttachment(screenshot: app.screenshot()); form.name = "New Account reference layout"; form.lifetime = .keepAlways; add(form)
        app.textFields["Name"].tap(); app.textFields["Name"].typeText("UI Income")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Currency")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Currency"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["account-currency-picker"].buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Euro")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Account"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Euro Journal"].waitForExistence(timeout: 5))
        app.buttons["Income"].tap()
        XCTAssertTrue(app.staticTexts["UI Income"].waitForExistence(timeout: 5))
    }

    @MainActor func testSplitPostingBalanceAndRemoval() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["New Transaction"].tap(); app.buttons["Expense"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        let amounts = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "Amount for"))
        XCTAssertTrue(amounts.firstMatch.waitForExistence(timeout: 5))
        amounts.element(boundBy: 0).tap(); amounts.element(boundBy: 0).typeText("25")
        app.buttons["Done"].tap()
        app.buttons["Posting"].tap()
        XCTAssertEqual(amounts.count, 3)
        amounts.element(boundBy: 2).tap(); amounts.element(boundBy: 2).typeText("15")
        app.buttons["Done"].tap()
        app.buttons["Balance"].tap()
        XCTAssertEqual(amounts.count, 3, "Balance must not also invoke Add Posting")
        XCTAssertEqual(amounts.element(boundBy: 2).value as? String, "0.00")
        app.buttons["Checking"].firstMatch.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Remove Posting"].waitForExistence(timeout: 5))
        app.buttons["Remove Posting"].tap()
        XCTAssertEqual(amounts.count, 2)
        app.buttons["Balance"].tap()
        XCTAssertEqual(amounts.element(boundBy: 1).value as? String, "-25.00")
        let notes = app.textFields["Notes"]
        notes.tap(); notes.typeText("Split control acceptance")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Personal"].waitForExistence(timeout: 5))
        app.buttons["All"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Split control acceptance")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testCompactTransactionFormAlignment() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["New Transaction"].tap(); app.buttons["Expense"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        let fields = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "Amount for"))
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 5))
        let first = fields.element(boundBy: 0).frame, second = fields.element(boundBy: 1).frame
        XCTAssertEqual(first.maxX, second.maxX, accuracy: 1, "Amount columns must share a trailing edge")
        XCTAssertEqual(second.midY - first.midY, 47, accuracy: 2, "Posting rows should match the recording’s compact rhythm")
        let notes = app.textFields["Notes"].frame, payee = app.textFields["Payee"].frame, number = app.textFields["Number"].frame
        XCTAssertEqual(notes.minX, payee.minX, accuracy: 1)
        XCTAssertEqual(payee.minX, number.minX, accuracy: 1)
        XCTAssertEqual(payee.midY - notes.midY, 47, accuracy: 2)
        XCTAssertEqual(number.midY - payee.midY, 47, accuracy: 2)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Compact transaction form"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func revealSearch(in app: XCUIApplication) -> XCUIElement {
        let search = app.searchFields.firstMatch
        if !search.exists || !search.isHittable {
            if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeDown() }
            else if app.tables.firstMatch.exists { app.tables.firstMatch.swipeDown() }
            else { app.swipeDown() }
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        return search
    }

    @MainActor func testTransactionIndicatorsDoNotIndentText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["All"].tap()
        let receipt = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Weekly groceries")).firstMatch
        let uncleared = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Dinner with friends")).firstMatch
        let plain = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Train ticket")).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertTrue(uncleared.exists); XCTAssertTrue(plain.exists)
        let receiptX = receipt.staticTexts["transaction-title"].frame.minX
        XCTAssertEqual(receiptX, uncleared.staticTexts["transaction-title"].frame.minX, accuracy: 1)
        XCTAssertEqual(receiptX, plain.staticTexts["transaction-title"].frame.minX, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Transaction gutter alignment"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testAccountHierarchyUsesWholeRowIndentation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["New Transaction"].tap(); app.buttons["Expense"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        app.buttons["Checking"].tap()
        XCTAssertTrue(app.navigationBars["Choose Account"].waitForExistence(timeout: 5))
        let parent = app.staticTexts["Food & Dining"]
        let child = app.staticTexts["Groceries"]
        XCTAssertTrue(parent.waitForExistence(timeout: 5)); XCTAssertTrue(child.exists)
        XCTAssertEqual(child.frame.minX - parent.frame.minX, 22, accuracy: 2)
        XCTAssertTrue(app.staticTexts["Pantry essentials and everyday food."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Nested account indentation"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

}
