import XCTest

/// Opt-in end-to-end timings include XCTest event injection/idleness overhead.
/// Use the matching model benchmarks to attribute application CPU reductions.
final class LargeJournalInteractionBenchmarks: XCTestCase {
    @MainActor func testLargeJournalNavigationAndMutationFlows() throws {
        guard ProcessInfo.processInfo.environment["FINANCES_PERFORMANCE_RUN"] == "1" else {
            throw XCTSkip("Opt-in large-journal UI comparison")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-demo", "--demo-performance"]
        app.launch()
        defer { app.terminate() }
        let journal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Performance Journal,")).firstMatch
        XCTAssertTrue(journal.waitForExistence(timeout: 60))
        let rowID = "register-row-00000000-0000-0000-0000-0000000186A0"
        for iteration in 0..<3 {
            record("journal-navigation", iteration) {
                journal.tap()
                XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 10))
            }
            record("register-navigation", iteration) {
                app.buttons["All"].tap()
                XCTAssertTrue(app.buttons[rowID].waitForExistence(timeout: 20))
            }
            record("transaction-detail-navigation", iteration) {
                app.buttons[rowID].tap()
                XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 10))
            }
            record("transaction-editor-navigation", iteration) {
                app.buttons["Edit"].tap()
                XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForExistence(timeout: 10))
            }
            record("transaction-editor-cancel", iteration) {
                app.navigationBars["Edit Transaction"].buttons["Cancel"].tap()
                XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 10))
            }
            app.navigationBars["Details"].buttons.element(boundBy: 0).tap()
            record("swipe-clear", iteration) {
                app.buttons[rowID].swipeRight()
                let clear = app.buttons["Cleared"].firstMatch
                let unclear = app.buttons["Uncleared"].firstMatch
                if clear.exists { clear.tap() } else { unclear.tap() }
                XCTAssertTrue(app.buttons[rowID].waitForExistence(timeout: 10))
            }
            record("template-menu", iteration) {
                app.buttons["New Transaction"].tap()
                XCTAssertTrue(app.buttons["Template 0"].waitForExistence(timeout: 10))
            }
            record("template-editor", iteration) {
                app.buttons["Template 0"].tap()
                XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 10))
            }
            app.navigationBars["New Transaction"].buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars["New Transaction"].waitForNonExistence(timeout: 10))
            record("register-back-navigation", iteration) {
                let back = app.navigationBars["All"].buttons.element(boundBy: 0)
                wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: back)], timeout: 10)
                back.tap()
                XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 10))
            }
            app.navigationBars["Performance Journal"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(journal.waitForExistence(timeout: 10))
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Large journal after navigation and mutation flows"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.press(.home)
    }

    @MainActor private func record(_ name: String, _ iteration: Int, body: () -> Void) {
        let start = ContinuousClock.now
        body()
        let duration = start.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        print("FINANCES_UI_PERF name=\(name) rows=10000 iteration=\(iteration) elapsed_ms=\(milliseconds)")
    }
}
