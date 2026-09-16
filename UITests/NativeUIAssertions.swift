import XCTest

extension XCTestCase {
    /// Confirmation dialogs can be sheets with Cancel or popovers dismissed by
    /// tapping outside. Both paths must leave the destructive action unchosen.
    @MainActor
    func dismissFinanceConfirmation(in app: XCUIApplication, action: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let dialog = app.sheets.containing(.button, identifier: action).firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), file: file, line: line)
        guard dialog.exists else { return }
        let cancel = app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.first(where: \.isHittable)
        if let cancel {
            cancel.tap()
        } else if app.otherElements["PopoverDismissRegion"].isHittable {
            app.otherElements["PopoverDismissRegion"].tap()
        } else {
            let bounds = app.frame
            let dialogBounds = dialog.frame.insetBy(dx: -8, dy: -8)
            let points = [CGVector(dx: 0.1, dy: 0.15), CGVector(dx: 0.9, dy: 0.15),
                          CGVector(dx: 0.1, dy: 0.85), CGVector(dx: 0.9, dy: 0.85)]
            guard let point = points.first(where: {
                !dialogBounds.contains(CGPoint(x: bounds.minX + bounds.width * $0.dx,
                                               y: bounds.minY + bounds.height * $0.dy))
            }) else {
                XCTFail("Confirmation has neither a visible Cancel action nor an outside dismissal area.\n\(app.debugDescription)", file: file, line: line)
                return
            }
            app.coordinate(withNormalizedOffset: point).tap()
        }
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5), "Cancel must dismiss the confirmation", file: file, line: line)
    }

    @MainActor
    func assertFinanceChartVisible(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        assertFinanceChartPreference(in: app, shown: true, file: file, line: line)
        let panel = app.otherElements["register-chart-panel"].firstMatch
        let title = app.staticTexts["Cash Flow"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: title)
        let result = XCTWaiter.wait(for: [visible], timeout: 10)
        if result != .completed { captureFinanceUIFailure(app, name: "Chart visibility") }
        XCTAssertEqual(result, .completed,
                       "The chart heading must be visible after the preference updates", file: file, line: line)
        XCTAssertTrue(panel.exists, "The chart panel must be rendered", file: file, line: line)
    }

    @MainActor
    func assertFinanceChartPreference(in app: XCUIApplication, shown: Bool,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.buttons["toggle-transaction-chart"]
        // iOS 27's toolbar bridge exposes the button's label but drops its
        // custom accessibility value. The visible action still encodes state.
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", shown ? "Hide Chart" : "Show Chart"), object: toggle)
        let result = XCTWaiter.wait(for: [expected], timeout: 10)
        if result != .completed { captureFinanceUIFailure(app, name: "Chart preference") }
        XCTAssertEqual(result, .completed,
                       "The chart preference must match the requested state", file: file, line: line)
    }

    @MainActor
    private func captureFinanceUIFailure(_ app: XCUIApplication, name: String) {
        print("FINANCE_UI_FAILURE \(name)\n\(app.debugDescription)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// List rows are materialized on demand. Visit the filtered list rather
    /// than treating one accessibility snapshot as its complete result count.
    @MainActor
    func collectFinanceRegisterRows(in app: XCUIApplication) -> [String: String] {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "register-row-"))
        var found: [String: String] = [:]
        var previous: Set<String>?
        for _ in 0..<8 {
            let visible = rows.allElementsBoundByIndex
            let ids = Set(visible.map(\.identifier))
            for row in visible { found[row.identifier] = row.label }
            if ids == previous { break }
            previous = ids
            app.swipeUp()
        }
        return found
    }
}
