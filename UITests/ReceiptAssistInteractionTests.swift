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
}
