import XCTest

/// The live test is deliberately opt-in: ordinary full-suite/CI runs must not
/// depend on a developer's local server, API key, or paid inference.
@MainActor
final class AssistantInteractionTests: XCTestCase {
    func testSyncTitleAndCenteredAssistantAcrossNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let sync = app.buttons["navigation.sync"]
        let ask = app.buttons["assistant.open"]
        func checkChrome(title: String, journalActive: Bool) {
            XCTAssertTrue(sync.waitForExistence(timeout: 10))
            XCTAssertTrue((sync.value as? String)?.hasPrefix(title + ",") == true)
            XCTAssertLessThan(sync.frame.maxY, app.frame.height * 0.25)
            XCTAssertTrue(ask.isHittable)
            XCTAssertEqual(ask.label, "Ask AI")
            XCTAssertEqual(ask.frame.midX, app.frame.midX, accuracy: 4)
            XCTAssertGreaterThan(ask.frame.minY, app.frame.height * 0.75)
            XCTAssertTrue(app.buttons[journalActive ? "Quick Search" : "Settings"].isHittable)
            if journalActive { XCTAssertTrue(app.buttons["New Transaction"].isHittable) }
            let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Sync title and Ask AI — \(title)"; capture.lifetime = .keepAlways; add(capture)
            sync.tap()
            XCTAssertTrue(app.navigationBars["Cloud Sync"].waitForExistence(timeout: 5))
            app.navigationBars["Cloud Sync"].buttons["Done"].tap()
        }
        checkChrome(title: "Journals", journalActive: false)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Personal,")).firstMatch.tap()
        checkChrome(title: "Personal", journalActive: true)
        app.buttons["All"].tap()
        XCTAssertTrue(app.buttons["Show Chart"].waitForExistence(timeout: 10))
        checkChrome(title: "All", journalActive: true)
        ask.tap()
        XCTAssertTrue(app.buttons["Assistant Options"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close"].isHittable)
        app.buttons["Close"].tap()
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
    }

    func testLocalHistorySwipeRenamePersists() throws {
        guard ProcessInfo.processInfo.environment["FINANCES_LIVE_ASSISTANT_TESTS"] == "1" else {
            throw XCTSkip("Run the local assistant UI test script with its backend.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--assistant-api-url", "http://127.0.0.1:5184"]
        func openAssistant() {
            let open = app.buttons["assistant.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
            let consent = app.buttons["assistant.consent"]
            if consent.waitForExistence(timeout: 1) { consent.tap() }
            XCTAssertTrue(app.textFields["assistant.composer"].waitForExistence(timeout: 10))
        }
        func openHistory() {
            app.buttons["Assistant Options"].tap()
            app.buttons["History"].tap()
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        }
        app.launch(); openAssistant()
        app.buttons["Assistant Options"].tap(); app.buttons["New Chat"].tap()
        XCTAssertTrue(app.staticTexts["What do you need help with?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Find transactions, check balances, review spending, add or edit entries, and attach receipts."].exists)
        let welcomeViewport = app.scrollViews["assistant.welcome"]
        let welcomeBounds = app.staticTexts["What do you need help with?"].frame.union(app.staticTexts["Find transactions, check balances, review spending, add or edit entries, and attach receipts."].frame)
        XCTAssertTrue(welcomeViewport.exists)
        if welcomeBounds.height < welcomeViewport.frame.height {
            XCTAssertEqual(welcomeBounds.midY, welcomeViewport.frame.midY, accuracy: 8, "Welcome should be centered between the header and composer.")
        }
        XCTAssertTrue(app.buttons["Start Voice Chat"].isHittable)
        XCTAssertTrue(app.buttons["Attach Files"].isHittable)
        for suggestion in ["Summarize this month", "Find recent receipts", "Show my account balances"] {
            XCTAssertFalse(app.buttons[suggestion].exists)
        }
        let welcome = XCTAttachment(screenshot: app.screenshot()); welcome.name = "Assistant welcome"; welcome.lifetime = .keepAlways; add(welcome)
        app.buttons["Close"].tap()
        openAssistant(); openHistory()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant.history."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        let row = rows.firstMatch
        let identifier = row.identifier
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Delete"].exists)
        app.buttons["Rename"].tap()
        let alert = app.alerts["Rename Conversation"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        // SwiftUI's native alert does not preserve the field's custom identifier.
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(alert.textFields.count, 1)
        field.tap()
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + "Rename UI Test")
        app.alerts.buttons["Save"].tap()
        let renamed = app.buttons[identifier]
        let titleMatches = NSPredicate(format: "label CONTAINS %@", "Rename UI Test")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: titleMatches, object: renamed)], timeout: 5), .completed)
        app.terminate(); app.launch(); openAssistant(); openHistory()
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        XCTAssertTrue(renamed.label.contains("Rename UI Test"))
        let history = XCTAttachment(screenshot: app.screenshot()); history.name = "History text colors"; history.lifetime = .keepAlways; add(history)
        // The unoccupied trailing portion must still select a plain-styled row.
        renamed.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["History"])], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["What do you need help with?"].exists)
        openHistory()
        renamed.swipeLeft()
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "History Rename and Delete swipe actions"; screenshot.lifetime = .keepAlways; add(screenshot)
        // Remove only this test's newly created, uniquely identified conversation.
        app.buttons["Delete"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: renamed)], timeout: 5), .completed)
    }

    func testLocalAssistantRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["FINANCES_LIVE_ASSISTANT_TESTS"] == "1" else {
            throw XCTSkip("Run scripts/test-assistant-local.sh with the local backend for live verification.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--assistant-api-url", "http://127.0.0.1:5184"]
        app.launch()
        let open = app.buttons["assistant.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let consent = app.buttons["assistant.consent"]
        if consent.waitForExistence(timeout: 2) { consent.tap() }
        app.buttons["Assistant Options"].tap(); app.buttons["New Chat"].tap()
        XCTAssertTrue(app.buttons["Start Voice Chat"].exists)
        XCTAssertFalse(app.buttons["assistant.send"].isEnabled)
        let composer = app.textFields["assistant.composer"]
        let multiline = app.textViews["assistant.composer"]
        let input = composer.waitForExistence(timeout: 5) ? composer : multiline
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Use the finance tools to report the Checking balance in Personal. Do not change any records.")
        let send = app.buttons["assistant.send"]
        let enabled = NSPredicate(format: "exists == true AND enabled == true")
        expectation(for: enabled, evaluatedWith: send)
        waitForExpectations(timeout: 20)
        send.tap()
        let reply = app.descendants(matching: .any).matching(identifier: "assistant.message.assistant").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90), app.debugDescription)
        let balanceText = reply.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Checking'")).firstMatch
        XCTAssertTrue(balanceText.waitForExistence(timeout: 60))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["assistant.stop"])], timeout: 60), .completed)
        app.buttons["Close"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(app.staticTexts["What do you need help with?"].waitForExistence(timeout: 5))
        XCTAssertFalse(reply.exists)
        app.buttons["Assistant Options"].tap(); app.buttons["History"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant.history.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        let savedIdentifier = saved.identifier
        XCTAssertTrue(saved.label.hasPrefix("Use the finance tools to report the Checking"))
        saved.tap()
        XCTAssertTrue(balanceText.waitForExistence(timeout: 5))
        let actions = app.buttons["assistant.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        XCTAssertEqual(actions.value as? String, "Expanded")
        actions.tap()
        XCTAssertEqual(actions.value as? String, "Collapsed")
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Native assistant live answer"; capture.lifetime = .keepAlways; add(capture)
        // Relaunch opens fresh, while History restores the saved conversation.
        app.terminate(); app.launch()
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        XCTAssertTrue(app.staticTexts["What do you need help with?"].waitForExistence(timeout: 5))
        XCTAssertFalse(reply.exists)
        app.buttons["Assistant Options"].tap(); app.buttons["History"].tap()
        XCTAssertTrue(app.buttons[savedIdentifier].waitForExistence(timeout: 5))
        app.buttons[savedIdentifier].tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        XCTAssertTrue(balanceText.waitForExistence(timeout: 10))
    }
}
