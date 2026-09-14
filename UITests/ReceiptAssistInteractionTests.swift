import XCTest

@MainActor final class ReceiptAssistInteractionTests: XCTestCase {
    func testReceiptSettingsAreSeparateFromTheTransactionEditor() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let link = app.buttons["Receipt Suggestions"]
        for _ in 0..<3 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars["Receipt Suggestions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["API server URL"].exists)
        XCTAssertTrue(app.staticTexts["Additional instructions"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Native receipt suggestion settings"
        shot.lifetime = .keepAlways
        add(shot)
    }
    func testTwoCardsKeepTheirControlsInSeparateRows() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        defer { app.terminate() }
        let journal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch
        XCTAssertTrue(journal.waitForExistence(timeout: 10))
        journal.tap()
        let checking = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Checking")).firstMatch
        if !checking.exists {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Assets")).firstMatch.tap()
        }
        XCTAssertTrue(checking.waitForExistence(timeout: 5))
        checking.press(forDuration: 1)
        app.buttons["Edit Account"].tap()
        XCTAssertTrue(app.navigationBars["Edit Account"].waitForExistence(timeout: 5))
        let addCard = app.buttons["Add card"]
        for _ in 0..<4 where !addCard.isHittable { app.swipeUp() }
        XCTAssertTrue(addCard.isHittable)
        addCard.tap()
        addCard.tap()
        let labels = app.textFields.matching(identifier: "Card label")
        let networks = app.buttons.matching(identifier: "Card network")
        let digits = app.textFields.matching(identifier: "Last four digits")
        for _ in 0..<3 where !digits.element(boundBy: 1).isHittable { app.swipeUp() }
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(networks.count, 2)
        XCTAssertEqual(digits.count, 2)
        XCTAssertLessThanOrEqual(
            labels.element(boundBy: 0).frame.maxY, networks.element(boundBy: 0).frame.minY)
        XCTAssertLessThanOrEqual(
            networks.element(boundBy: 0).frame.maxY, digits.element(boundBy: 0).frame.minY)
        XCTAssertLessThanOrEqual(digits.element(boundBy: 0).frame.maxY, labels.element(boundBy: 1).frame.minY)
        XCTAssertLessThanOrEqual(digits.element(boundBy: 1).frame.maxY, app.buttons["Save cards"].frame.minY)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Two aligned card editors"
        shot.lifetime = .keepAlways
        add(shot)
        app.navigationBars["Edit Account"].buttons["Cancel"].tap()
    }

}
