import XCTest

@MainActor
final class TemplateInteractionTests: XCTestCase {
    func testInvoiceTemplateRequestsReceiptScanning() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Physical camera capture requires an intentionally positioned test receipt.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--demo", "--reset-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        app.buttons["section-action-Transactions"].tap()
        app.buttons["Templates"].tap()
        XCTAssertTrue(app.staticTexts["No Templates"].waitForExistence(timeout: 5))
        app.buttons["New Template"].tap()
        XCTAssertTrue(app.navigationBars["New Template"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Scan Invoice"].waitForExistence(timeout: 5))
        app.switches["Scan Invoice"].tap()
        app.textFields["Name"].tap()
        app.textFields["Name"].typeText("Scan template")
        app.buttons["Save"].tap()
        let template = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Scan template")).firstMatch
        XCTAssertTrue(template.waitForExistence(timeout: 5))
        template.tap()
        // Recent Simulator runtimes expose the document scanner even without
        // a real camera. Verify the actual UI rather than assuming unsupported.
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            XCTAssertTrue(permission.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Camera")).firstMatch.exists)
            permission.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Don")).firstMatch.tap()
        } else if app.alerts["Couldn’t Add Receipt"].exists {
            let alert = app.alerts["Couldn’t Add Receipt"]
            XCTAssertTrue(alert.staticTexts["Receipt scanning is unavailable on this device. Choose a file or photo instead."].exists)
            alert.buttons["OK"].tap()
            XCTAssertTrue(app.navigationBars["New From Template"].exists)
        } else {
            XCTAssertTrue(app.buttons["Auto"].waitForExistence(timeout: 5), "The template should present the native document scanner.")
        }
        #endif
    }
}
