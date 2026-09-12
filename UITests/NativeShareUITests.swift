import XCTest

/// Opt-in: requires the explicitly prepared synthetic PNG in Photos and PDF in
/// On My iPhone/FinancesShareQA. Never launches the normal journal store.
@MainActor
final class NativeShareUITests: XCTestCase {
    func testPhotoShareOpensEditableDraftAndCancelDoesNotPost() throws {
        let app = try launch()
        sharePhoto()
        assertReceipt(in: app, extension: ".PNG")
        cancelAndCheckBaseline(app)
    }

    func testPDFShareOpensEditableDraftAndCancelDoesNotPost() throws {
        let app = try launch()
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.activate()
        files.tabBars.buttons["Browse"].tap()
        let folder = files.cells["FinancesShareQA, Folder"]
        if !folder.exists {
            let local = files.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "On My iPhone")).firstMatch
            if local.exists { local.tap() }
            else if files.buttons["On My iPhone"].exists { files.buttons["On My iPhone"].tap() }
        }
        capture(files, "Files synthetic receipt folder")
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.tap()
        let pdf = files.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTHETIC-Receipt")).firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 5)); pdf.press(forDuration: 1)
        capture(files, "Files PDF context menu")
        let share = files.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        capture(files, "Files PDF share sheet")
        let finances = shareCell(in: files)
        XCTAssertTrue(finances.waitForExistence(timeout: 5)); finances.tap()
        assertReceipt(in: app, extension: ".pdf")
        cancelAndCheckBaseline(app)
    }

    func testPhotoShareWaitsForExistingDraftWithoutReplacingIt() throws {
        let app = try launch(wallet: true)
        let payee = app.textFields["Payee"]
        XCTAssertEqual(payee.value as? String, "SYNTHETIC Wallet Store")
        sharePhoto()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertEqual(payee.value as? String, "SYNTHETIC Wallet Store", "An incoming share must preserve the existing draft")
        XCTAssertFalse(receipt(in: app, extension: ".PNG").exists)
        capture(app, "Existing Wallet draft preserved after share")
        app.navigationBars["New Transaction"].buttons["Cancel"].tap()
        assertReceipt(in: app, extension: ".PNG")
        cancelAndCheckBaseline(app)
    }

    private func launch(wallet: Bool = false) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["FINANCES_NATIVE_SHARE_QA"] == "1" else {
            throw XCTSkip("Set FINANCES_NATIVE_SHARE_QA=1 only on the prepared synthetic simulator.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-system-entry", "--reset-demo"] + (wallet ? ["--demo-wallet-draft"] : [])
        app.launch()
        XCTAssertTrue(app.navigationBars[wallet ? "New Transaction" : "Journals"].waitForExistence(timeout: 10))
        return app
    }

    private func shareCell(in app: XCUIApplication) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier == %@ AND label == %@", "shareCell", "Finances v2")).firstMatch
    }

    private func sharePhoto() {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 5))
        if !shareCell(in: photos).exists {
            if photos.buttons["Continue"].exists { photos.buttons["Continue"].tap() }
            let share = photos.buttons["PUOneUpBarButtonItemIdentifierShare"]
            if !share.exists {
                let images = photos.images.matching(identifier: "PXGGridLayout-Info")
                XCTAssertTrue(images.firstMatch.waitForExistence(timeout: 5))
                // Photos reports the visible thumbnail frame but no AX hit point.
                images.element(boundBy: images.count - 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        }
        capture(photos, "Photos native Finances share cell")
        let finances = shareCell(in: photos)
        XCTAssertTrue(finances.waitForExistence(timeout: 5)); finances.tap()
    }

    private func receipt(in app: XCUIApplication, extension suffix: String) -> XCUIElement {
        // Photos adds a numeric suffix when exporting the same image again.
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH[c] %@", "SYNTHETIC-Receipt", suffix)).firstMatch
    }

    private func assertReceipt(in app: XCUIApplication, extension suffix: String) {
        XCTAssertTrue(app.buttons["incoming-journal-picker"].waitForExistence(timeout: 10))
        let attachment = receipt(in: app, extension: suffix)
        XCTAssertTrue(attachment.waitForExistence(timeout: 10))
        for _ in 0..<4 where !attachment.isHittable { app.swipeUp() }
        capture(app, "Editable incoming receipt draft \(suffix)")
        XCTAssertTrue(attachment.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["receipt-import-picker"].value as? String, "Ready")
        XCTAssertFalse(app.navigationBars["New Transaction"].buttons["Save"].isEnabled)
    }

    private func cancelAndCheckBaseline(_ app: XCUIApplication) {
        app.navigationBars["New Transaction"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Journals"].waitForExistence(timeout: 5))
        let alpha = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SYNTHETIC Alpha,")).firstMatch
        XCTAssertTrue(alpha.label.contains("2 Transactions"), "Cancelling a receipt draft must not post it")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        print("NATIVE_SHARE_QA \(name)\n\(app.debugDescription)")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
