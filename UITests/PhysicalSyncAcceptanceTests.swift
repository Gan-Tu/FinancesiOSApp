import XCTest

/// Opt-in physical-device acceptance. A Mac producer must prepare the same
/// isolated Development run, then send its push after BACKGROUND_READY appears.
@MainActor
final class PhysicalSyncAcceptanceTests: XCTestCase {
    func testBackgroundCloudKitDelivery() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical iPhone and the isolated Mac producer.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["FINANCES_PEER_RUN_ID"] ?? environment["TEST_RUNNER_FINANCES_PEER_RUN_ID"],
              let runID = UUID(uuidString: value) else {
            throw XCTSkip("Set FINANCES_PEER_RUN_ID to an already prepared Development QA run.")
        }
        let app = XCUIApplication()
        defer {
            app.terminate()
            app.launchArguments = []
            app.launch()
        }
        app.launchArguments = ["--verify-cloudkit-peer", "--run-id", runID.uuidString, "--phase", "consumer-await-push"]
        app.launch()
        let ready = app.staticTexts["READY awaiting producer push"]
        XCTAssertTrue(ready.waitForExistence(timeout: 60), "The receiver must finish its baseline and register for APNs first.")
        guard ready.exists else { return }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        NSLog("FINANCES_BACKGROUND_READY %@", runID.uuidString)

        // Keep the receiver backgrounded while the host sends its fresh nonce.
        // Foregrounding afterward permits the ordinary return upload; only the
        // OS delegate's recorded background context can satisfy the assertion.
        Thread.sleep(forTimeInterval: 60)
        app.activate()
        let report = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "{", runID.uuidString)).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 60))
        let bytes = try XCTUnwrap(report.label.data(using: .utf8))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "PASS", report.label)
        XCTAssertEqual(result["backgroundPushDeliveryVerified"] as? Bool, true, report.label)
        XCTAssertEqual(result["matchingPushDeliveryVerified"] as? Bool, true, report.label)
        XCTAssertEqual(result["automaticConvergenceVerified"] as? Bool, true, report.label)
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = "Physical background CloudKit report"
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }
}
