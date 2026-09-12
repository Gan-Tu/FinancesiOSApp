import XCTest

/// Exercises the actual native fields. Every reload omits --reset-demo, so the
/// reopened editor comes from persisted SQLite, not a freshly reseeded fixture.
@MainActor
final class SplitEditorIntegrityUITests: XCTestCase {
    private let probePrefix = "synthetic-split-amount|"
    private struct Leg: Equatable {
        let account: String
        let currency: String
        let amount: Decimal
    }
    private func id(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012llX", Int64(value))
    }
    private func leg(_ account: Int, _ currency: Int?, _ amount: Int) -> Leg {
        Leg(account: id(account), currency: currency.map(id) ?? "nil", amount: Decimal(amount))
    }
    private var unequal: [Leg] { [leg(20, 2, -27215), leg(21, 2, 27200), leg(22, nil, 15)] }
    private var mixed: [Leg] { [leg(20, 2, -100), leg(21, nil, 100), leg(23, 3, -80), leg(24, nil, 80)] }

    private func launch(_ app: XCUIApplication, reset: Bool = true) {
        continueAfterFailure = false
        app.launchArguments = ["--demo", "--demo-split-editor"] + (reset ? ["--reset-demo"] : [])
        app.launch()
        let journal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTHETIC Split Tests,")).firstMatch
        XCTAssertTrue(journal.waitForExistence(timeout: 10)); journal.tap()
        app.buttons["All"].tap()
        XCTAssertTrue(app.navigationBars["All"].waitForExistence(timeout: 5))
    }
    private func open(_ app: XCUIApplication, transaction: Int) {
        open(app, row: app.buttons["register-row-\(id(transaction))"])
    }
    private func open(_ app: XCUIApplication, row: XCUIElement) {
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        app.navigationBars["Details"].buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForExistence(timeout: 5))
    }
    private func fields(_ app: XCUIApplication) -> XCUIElementQuery {
        app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", probePrefix))
    }
    @discardableResult
    private func assertLegs(_ app: XCUIApplication, _ expected: [Leg], file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let rows = fields(app).allElementsBoundByIndex
        XCTAssertEqual(rows.count, expected.count, file: file, line: line)
        var postingIDs: [String] = []
        var actual: [Leg] = []
        for row in rows {
            let components = row.identifier.components(separatedBy: "|")
            XCTAssertEqual(components.count, 4, file: file, line: line)
            guard components.count == 4 else { continue }
            let text = try XCTUnwrap(row.value as? String, file: file, line: line)
            let amount = try XCTUnwrap(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), file: file, line: line)
            postingIDs.append(components[1])
            actual.append(Leg(account: components[2], currency: components[3], amount: amount))
        }
        XCTAssertEqual(actual, expected, "Each ordered account, literal currency, and native amount must match", file: file, line: line)
        return postingIDs
    }
    private func enter(_ text: String, into field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + text)
    }
    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists { app.buttons["Done"].tap() }
    }
    private func appendNote(_ suffix: String, in app: XCUIApplication) {
        dismissKeyboard(app)
        let notes = app.textFields["Notes"].exists ? app.textFields["Notes"] : app.textViews["Notes"]
        for _ in 0..<3 where !notes.isHittable { app.swipeUp() }
        notes.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        notes.typeText(suffix)
        dismissKeyboard(app)
    }
    private func save(_ app: XCUIApplication, title: String = "Edit Transaction", future: Bool = false) {
        app.navigationBars[title].buttons["Save"].tap()
        if future {
            let choice = app.sheets.buttons["This and Future Occurrences"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        }
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 10))
    }
    private func reload(_ app: XCUIApplication, transaction: Int) {
        app.terminate(); launch(app, reset: false); open(app, transaction: transaction)
    }
    private func removeFee(_ app: XCUIApplication) {
        let fee = app.buttons["SYNTHETIC Fee"]
        XCTAssertTrue(fee.isHittable); fee.press(forDuration: 1)
        let remove = app.buttons["Remove Posting"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
    }

    func testRemovingFeeThenEqualsDoesNotRewriteUntouchedAmount() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app); open(app, transaction: 103)
        try assertLegs(app, [leg(20, 2, -100), leg(21, 2, 90), leg(22, 2, 10)])
        removeFee(app)
        let remaining = [leg(20, 2, -100), leg(21, 2, 90)]
        try assertLegs(app, remaining)
        fields(app).element(boundBy: 1).tap()
        app.buttons["amount-key-="].tap()
        try assertLegs(app, remaining)
        // Equivalent native writeback must also leave the untouched source alone.
        let expense = fields(app).element(boundBy: 1)
        expense.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap(); expense.typeText("0")
        try assertLegs(app, remaining)
        dismissKeyboard(app)
        app.navigationBars["Edit Transaction"].buttons["Save"].tap()
        let alert = app.alerts["Couldn’t Save Transaction"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Removing a nonzero fee requires an explicit correction, not silent redistribution")
        alert.buttons["OK"].tap(); app.navigationBars["Edit Transaction"].buttons["Cancel"].tap()
        reload(app, transaction: 103)
        try assertLegs(app, [leg(20, 2, -100), leg(21, 2, 90), leg(22, 2, 10)])
    }

    func testUnequalThreeLegFocusEquivalentWritebackAccountPickerAndNoteSave() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app); open(app, transaction: 100)
        let originalIDs = try assertLegs(app, unequal)
        for index in 0..<3 {
            fields(app).element(boundBy: index).tap(); app.buttons["amount-key-="].tap()
            dismissKeyboard(app); try assertLegs(app, unequal)
        }
        enter("27200.000", into: fields(app).element(boundBy: 1)); dismissKeyboard(app)
        try assertLegs(app, unequal)
        app.buttons["SYNTHETIC Fee"].tap()
        XCTAssertTrue(app.navigationBars["Choose Account"].waitForExistence(timeout: 5))
        let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTHETIC Alternate")).firstMatch
        for _ in 0..<3 where !choice.isHittable { app.swipeUp() }
        XCTAssertTrue(choice.isHittable); choice.tap()
        XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForExistence(timeout: 5))
        let moved = [leg(20, 2, -27215), leg(21, 2, 27200), leg(25, nil, 15)]
        try assertLegs(app, moved)
        appendNote(" edited without changing split", in: app)
        save(app); reload(app, transaction: 100)
        XCTAssertEqual(try assertLegs(app, moved), originalIDs)
    }

    func testFourLegMixedCurrencyAndDuplicateKeepAllAmountsAndLiteralCurrencies() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app); open(app, transaction: 101)
        let originalIDs = try assertLegs(app, mixed)
        for index in 0..<4 {
            fields(app).element(boundBy: index).tap(); app.buttons["amount-key-="].tap()
            dismissKeyboard(app); try assertLegs(app, mixed)
        }
        enter("80.000", into: fields(app).element(boundBy: 3)); dismissKeyboard(app)
        appendNote(" metadata only", in: app); save(app); reload(app, transaction: 101)
        XCTAssertEqual(try assertLegs(app, mixed), originalIDs)
        app.navigationBars["Edit Transaction"].buttons["Cancel"].tap()
        app.buttons["Transaction Actions"].tap(); app.buttons["Duplicate"].tap()
        let alert = app.alerts["Duplicate Transaction"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); alert.buttons["Duplicate With Today's Date"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        dismissKeyboard(app)
        let copiedIDs = try assertLegs(app, mixed)
        XCTAssertTrue(Set(originalIDs).isDisjoint(with: copiedIDs))
        appendNote(" SYNTHETIC DUPLICATE", in: app); save(app, title: "New Transaction")
        app.terminate(); launch(app, reset: false)
        let duplicate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "register-row-", "SYNTHETIC DUPLICATE")).firstMatch
        open(app, row: duplicate)
        XCTAssertEqual(try assertLegs(app, mixed), copiedIDs)
    }

    func testAddingFeeBeforeChangingDebitPreservesUnequalLegsOnSaveAndReopen() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app); open(app, transaction: 102)
        try assertLegs(app, [leg(20, 2, -100), leg(21, 2, 100)])
        app.buttons["Posting"].tap()
        XCTAssertEqual(fields(app).count, 3)
        // The added row defaults to the first leaf account, so choose Fee using
        // that row's sibling account button rather than an ambiguous bank name.
        let addedAmount = fields(app).element(boundBy: 2)
        addedAmount.coordinate(withNormalizedOffset: CGVector(dx: -1.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Choose Account"].waitForExistence(timeout: 5))
        let fee = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTHETIC Fee")).firstMatch
        for _ in 0..<3 where !fee.isHittable { app.swipeUp() }
        XCTAssertTrue(fee.isHittable); fee.tap()
        XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForExistence(timeout: 5))
        fields(app).element(boundBy: 2).tap(); fields(app).element(boundBy: 2).typeText("15")
        dismissKeyboard(app)
        try assertLegs(app, [leg(20, 2, -100), leg(21, 2, 100), leg(22, nil, 15)])
        enter("-115", into: fields(app).element(boundBy: 0)); dismissKeyboard(app)
        try assertLegs(app, [leg(20, 2, -115), leg(21, 2, 100), leg(22, nil, 15)])
        appendNote(" with explicit fee", in: app); save(app); reload(app, transaction: 102)
        try assertLegs(app, [leg(20, 2, -115), leg(21, 2, 100), leg(22, 2, 15)])
    }

    func testRecurringMetadataSaveKeepsEveryUnequalPostingAcrossOccurrences() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        launch(app); open(app, transaction: 111)
        let selectedIDs = try assertLegs(app, unequal)
        appendNote(" future metadata only", in: app); save(app, future: true)
        reload(app, transaction: 111)
        XCTAssertEqual(try assertLegs(app, unequal), selectedIDs)
        for transaction in [110, 112] {
            reload(app, transaction: transaction)
            let ids = try assertLegs(app, unequal)
            XCTAssertEqual(ids, (0..<3).map { id(transaction * 10 + $0) })
        }
    }
}
