import XCTest

@MainActor
final class HistoricalTextSuggestionUITests: XCTestCase {
    private let longNote = "A complete multiword historical note whose full text is deliberately wider than one suggestion chip"

    private func launch(_ app: XCUIApplication, reset: Bool = true) {
        continueAfterFailure = false
        app.launchArguments = ["--demo", "--demo-text-suggestions"] + (reset ? ["--reset-demo"] : [])
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
    }
    @discardableResult
    private func openJournal(_ app: XCUIApplication, _ name: String) -> String {
        let journal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTHETIC \(name),")).firstMatch
        XCTAssertTrue(journal.waitForExistence(timeout: 5))
        let label = journal.label
        journal.tap()
        XCTAssertTrue(app.buttons["New Transaction"].waitForExistence(timeout: 5))
        return label
    }
    private func newTransaction(_ app: XCUIApplication) {
        app.buttons["New Transaction"].tap()
        app.sheets.buttons["Income"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("25")
        XCTAssertEqual(app.textFields["Amount for SYNTHETIC Bank"].value as? String, "-25")
        XCTAssertEqual(app.textFields["Amount for SYNTHETIC Expense"].value as? String, "25.00")
        app.buttons["Done"].tap()
    }
    private func textField(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.textFields[name].exists ? app.textFields[name] : app.textViews[name]
    }
    private func focus(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let field = textField(app, name)
        for _ in 0..<4 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.isHittable); field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        return field
    }
    private func chips(_ app: XCUIApplication, _ field: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history-\(field)-suggestion-"))
    }
    private func expectChips(_ app: XCUIApplication, field: String, labels: [String]) {
        let matching = chips(app, field)
        let count = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", labels.count), object: matching)
        XCTAssertEqual(XCTWaiter.wait(for: [count], timeout: 5), .completed)
        XCTAssertEqual(matching.allElementsBoundByIndex.map(\.label), labels)
    }
    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists { app.buttons["Done"].tap() }
    }

    func testEmptyNotesShowFiveCompleteChipsAndSelectionKeepsKeyboardWithoutSaving() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app)
        let originalJournal = openJournal(app, "Alpha")
        newTransaction(app)
        let originalPayee = app.textFields["Payee"].value as? String
        let notes = focus(app, "Notes")
        expectChips(app, field: "note", labels: ["Airport parking receipt", "Annual membership renewal", "Apartment utilities payment", "Art supply purchase", longNote])
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Historical Notes Suggestions Above Keyboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(chips(app, "payee").count, 0)
        XCTAssertFalse(app.buttons["Alpha sixth note"].exists)
        let first = app.buttons["history-note-suggestion-0"]
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)
        let long = app.buttons["history-note-suggestion-4"]
        XCTAssertEqual(long.label, longNote, "Accessibility must keep text truncated in the visual chip")
        XCTAssertLessThanOrEqual(long.frame.width, 220)
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        first.tap()
        XCTAssertEqual(notes.value as? String, "Airport parking receipt")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.keyboards.firstMatch.frame.minY, keyboardTop, accuracy: 1, "Suggestions must not add a form dropdown or another keyboard row")
        app.typeText("!")
        XCTAssertEqual(notes.value as? String, "Airport parking receipt!", "A chip must preserve editing focus")
        XCTAssertEqual(app.textFields["Payee"].value as? String, originalPayee)
        XCTAssertEqual(app.textFields["Amount for SYNTHETIC Bank"].value as? String, "-25")
        XCTAssertEqual(app.textFields["Amount for SYNTHETIC Expense"].value as? String, "25.00")
        XCTAssertTrue(app.navigationBars["New Transaction"].exists)
        app.navigationBars["New Transaction"].buttons["Cancel"].tap()
        app.terminate(); launch(app, reset: false)
        let journal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTHETIC Alpha,")).firstMatch
        XCTAssertEqual(journal.label, originalJournal, "Choosing suggestions must not commit a new transaction")
    }

    func testPayeePrefixRankingAndSelectionOnlyChangesPayeeAndPreservesAmountKeyboard() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app); openJournal(app, "Alpha"); newTransaction(app)
        let notes = focus(app, "Notes"); notes.typeText("Unsaved private note")
        let payee = focus(app, "Payee")
        expectChips(app, field: "payee", labels: ["Aster Coffee Roasters", "Atlas Grocery Market", "Arcadia Community Gym", "Arbor Books and Stationery", "Alpine Outdoor Supply"])
        payee.typeText("Ast")
        expectChips(app, field: "payee", labels: ["Aster Coffee Roasters", "Astral Sixth Merchant"])
        XCTAssertEqual(chips(app, "note").count, 0)
        app.buttons["history-payee-suggestion-0"].tap()
        XCTAssertEqual(payee.value as? String, "Aster Coffee Roasters")
        app.typeText("!")
        XCTAssertEqual(payee.value as? String, "Aster Coffee Roasters!")
        XCTAssertEqual(notes.value as? String, "Unsaved private note")
        dismissKeyboard(app)
        let bank = app.textFields["Amount for SYNTHETIC Bank"]
        for _ in 0..<3 where !bank.isHittable { app.swipeDown() }
        bank.tap()
        for symbol in ["±", "÷", "×", "−", "+", "="] {
            let key = app.buttons["amount-key-\(symbol)"]
            XCTAssertTrue(key.isHittable)
            XCTAssertGreaterThanOrEqual(key.frame.width, 44)
            XCTAssertGreaterThanOrEqual(key.frame.height, 44)
        }
        XCTAssertEqual(chips(app, "payee").count, 0)
        XCTAssertEqual(chips(app, "note").count, 0)
        XCTAssertEqual(bank.value as? String, "-25")
        XCTAssertEqual(app.textFields["Amount for SYNTHETIC Expense"].value as? String, "25.00")
    }

    func testTemplateSuggestionsUseSameFieldAndCurrentJournalAndExcludeFutureEntries() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app); openJournal(app, "Alpha")
        app.buttons["New Transaction"].tap(); app.buttons["Customize Templates…"].tap()
        XCTAssertTrue(app.navigationBars["Templates"].waitForExistence(timeout: 5))
        app.buttons["New Template"].tap()
        XCTAssertTrue(app.navigationBars["New Template"].waitForExistence(timeout: 5))
        let payee = focus(app, "Payee")
        expectChips(app, field: "payee", labels: ["Aster Coffee Roasters", "Atlas Grocery Market", "Arcadia Community Gym", "Arbor Books and Stationery", "Alpine Outdoor Supply"])
        app.buttons["history-payee-suggestion-0"].tap()
        XCTAssertEqual(payee.value as? String, "Aster Coffee Roasters")
        let note = focus(app, "Note")
        expectChips(app, field: "note", labels: ["Airport parking receipt", "Annual membership renewal", "Apartment utilities payment", "Art supply purchase", longNote])
        note.typeText("FUTURE")
        expectChips(app, field: "note", labels: [])
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.navigationBars["New Template"].buttons["Cancel"].tap()
        app.terminate(); launch(app, reset: false); openJournal(app, "Beta"); newTransaction(app)
        _ = focus(app, "Notes")
        expectChips(app, field: "note", labels: ["Beta private historical note"])
        _ = focus(app, "Payee")
        expectChips(app, field: "payee", labels: ["Beta Private Merchant"])
        XCTAssertFalse(app.buttons["Aster Coffee Roasters"].exists)
        XCTAssertFalse(app.buttons["Airport parking receipt"].exists)
    }
}
