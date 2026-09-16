import XCTest

/// Opt-in: requires the explicitly prepared synthetic PNG in Photos and PDF in
/// On My iPhone/FinancesShareQA. Never launches the normal journal store.
@MainActor
final class NativeShareUITests: XCTestCase {
    func testPhotoShareOpensEditableDraftAndCancelDoesNotPost() throws {
        let app = try launch()
        let photos = sharePhoto(returnTo: app)
        assertReceipt(in: photos, extension: ".PNG")
        photos.buttons["receipt-share-cancel"].tap()
        app.activate()
        checkBaseline(app)
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
        completeExtensionShare(in: files, returnTo: app)
        assertReceipt(in: files, extension: ".pdf")
        files.buttons["receipt-share-cancel"].tap()
        app.activate()
        checkBaseline(app)
    }

    func testPhotoShareKeepsExistingAppDraftAndCancelDoesNotReplaceIt() throws {
        let app = try launch(wallet: true)
        let photos = sharePhoto(returnTo: app)
        assertReceipt(in: photos, extension: ".PNG")
        photos.buttons["receipt-share-cancel"].tap()
        app.activate()
        XCTAssertEqual(app.textFields["Payee"].value as? String, "SYNTHETIC Wallet Store")
        app.navigationBars["New Transaction"].buttons["Cancel"].tap()
        checkBaseline(app)
    }

    private func launch(wallet: Bool = false) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["FINANCES_NATIVE_SHARE_QA"] == "1" else {
            throw XCTSkip("Set FINANCES_NATIVE_SHARE_QA=1 only on the prepared synthetic simulator.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-system-entry", "--demo-native-share", "--reset-demo"] + (wallet ? ["--demo-wallet-draft"] : [])
        app.launch()
        XCTAssertTrue(app.navigationBars[wallet ? "New Transaction" : "Journals"].waitForExistence(timeout: 10))
        return app
    }

    private func shareCell(in app: XCUIApplication) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier == %@ AND label == %@", "shareCell", "Finances")).firstMatch
    }

    private func sharePhoto(returnTo app: XCUIApplication) -> XCUIApplication {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 5))
        // A failed prior run can leave a share controller whose activity target
        // belongs to the previous installation. Always export a fresh item.
        if shareCell(in: photos).exists { photos.buttons["header.closeButton"].tap() }
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
        completeExtensionShare(in: photos, returnTo: app)
        return photos
    }

    private func completeExtensionShare(in host: XCUIApplication, returnTo app: XCUIApplication) {
        XCTAssertTrue(host.buttons["receipt-share-save"].waitForExistence(timeout: 10), "Sharing must open the transaction editor directly")
        XCTAssertFalse(host.buttons["receipt-share-open-finances"].exists)
        XCTAssertFalse(app.state == .runningForeground, "The extension should stay in the source app")
    }

    private func receipt(in app: XCUIApplication, extension suffix: String) -> XCUIElement {
        // Photos adds a numeric suffix when exporting the same image again.
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@ AND label ENDSWITH[c] %@",
            "shared-transaction-receipt", "SYNTHETIC-Receipt", suffix)).firstMatch
    }

    private func assertReceipt(in app: XCUIApplication, extension suffix: String) {
        XCTAssertTrue(app.buttons["incoming-journal-picker"].waitForExistence(timeout: 10))
        let attachment = receipt(in: app, extension: suffix)
        XCTAssertTrue(attachment.waitForExistence(timeout: 10))
        for _ in 0..<4 where !attachment.isHittable { app.swipeUp() }
        capture(app, "Editable incoming receipt draft \(suffix)")
        XCTAssertTrue(attachment.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["New Transaction"].buttons["Save"].isEnabled)
        XCTAssertEqual(app.switches["Cleared"].value as? String, "1")
        attachment.tap()
        let previewDone = app.buttons["editor-receipt-preview-done"]
        XCTAssertTrue(previewDone.waitForExistence(timeout: 5), "Shared images and PDFs must open the attachment preview")
        XCTAssertTrue(app.otherElements["QLPreviewControllerView"].waitForExistence(timeout: 5), "The sheet must contain the native document preview")
        XCTAssertFalse(app.alerts["Receipt Unavailable"].exists)
        capture(app, "Shared receipt Quick Look \(suffix)")
        previewDone.tap()
        XCTAssertTrue(previewDone.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        XCTAssertTrue(attachment.exists, "Closing the preview must preserve the unsaved receipt")
    }

    private func checkBaseline(_ app: XCUIApplication) {
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
