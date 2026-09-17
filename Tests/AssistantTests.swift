import XCTest
import AVFAudio
import PDFKit
import UIKit
@preconcurrency import WebRTC
@testable import FinancesClone

@MainActor
final class AssistantTests: XCTestCase {
    func testPhotoBatchStopsBeforeLoadingMoreOversizedImagesAndScansCheckPageCountFirst() async throws {
        var loaded = 0
        do {
            _ = try await AssistantPhotoLoader.load([0, 1, 2], maximumBytes: 40_000_000) { _ in
                loaded += 1
                return (Data(count: 15 * 1024 * 1024 + 1), "oversized.jpg")
            }
            XCTFail("Oversized photo must fail")
        } catch { XCTAssertEqual((error as? AssistantFailure)?.code, "attachment_limit") }
        XCTAssertEqual(loaded, 1)
        loaded = 0
        do {
            _ = try await AssistantPhotoLoader.load([0, 1, 2], maximumBytes: 15) { _ in
                loaded += 1; return (Data(count: 10), "photo.jpg")
            }
            XCTFail("Batch over remaining capacity must fail")
        } catch { XCTAssertEqual((error as? AssistantFailure)?.code, "attachment_limit") }
        XCTAssertEqual(loaded, 2)
        do {
            _ = try await ReceiptScanPDF.shared.makeDocument(pages: Array(repeating: Data([0]), count: 31))
            XCTFail("Too many pages must fail before decoding the invalid image bytes")
        } catch { XCTAssertEqual((error as? AssistantFailure)?.code, "scan_page_limit") }
    }
    func testChatPhotoAndScannedPDFUploadWithoutCreatingLedgerReceipts() async throws {
        let f = try fixture(), subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try f.store.assistantDatabase.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let gateway = TestAssistantGateway(subject: subject)
        var uploads: [(String, Data)] = []
        gateway.uploadHandler = { url, fileID in
            uploads.append((url.lastPathComponent, try Data(contentsOf: url)))
            return .object(["id": .string(UUID().uuidString), "file_id": .string(fileID), "filename": .string(url.lastPathComponent), "size_bytes": .number(Double(uploads.last!.1.count))])
        }
        let coordinator = AssistantCoordinator(store: f.store, gateway: gateway, contract: f.contract)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        let portrait = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        let photo = try await ReceiptScanImage(image: portrait).jpegData()
        let secondPage = try await ReceiptScanImage(image: landscape).jpegData()
        let pdf = try await ReceiptScanPDF.shared.makeDocument(pages: [photo, secondPage])
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertEqual(document.pageCount, 2)
        let firstBounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        let secondBounds = try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertLessThan(firstBounds.width, firstBounds.height)
        XCTAssertGreaterThan(secondBounds.width, secondBounds.height)
        let ledgerBefore = try AssistantJSON.modelDigest(f.store.data)
        let outboxBefore = try f.store.assistantDatabase.recordCounts().outboxRows
        coordinator.attach(context: try XCTUnwrap(coordinator.beginAttachmentSelection())) {
            [.bytes(photo, filename: "Photo.jpg"), .bytes(pdf, filename: "Scan.pdf")]
        }
        XCTAssertFalse(coordinator.canAcceptMessage)
        try await wait { !coordinator.isRunning }
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(uploads.map(\.0), ["Photo.jpg", "Scan.pdf"])
        XCTAssertEqual(uploads.map(\.1), [photo, pdf])
        XCTAssertEqual(coordinator.uploadedFiles.count, 2)
        XCTAssertEqual(try AssistantJSON.modelDigest(f.store.data), ledgerBefore)
        XCTAssertEqual(try f.store.assistantDatabase.recordCounts().outboxRows, outboxBefore)
        XCTAssertTrue(coordinator.send("Read these attachments"))
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(gateway.itemsSeen.first?.first?["attachments"].array.count, 2)
        coordinator.dismiss()
    }

    func testLatePhotoSelectionCannotUploadIntoAnotherConversation() async throws {
        let f = try fixture(), subject = "cloudkit:iCloud.fixture:development:user-a", gate = AssistantTestGate()
        _ = try f.store.assistantDatabase.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let gateway = TestAssistantGateway(subject: subject)
        var uploads = 0
        gateway.uploadHandler = { _, _ in uploads += 1; return .object([:]) }
        let coordinator = AssistantCoordinator(store: f.store, gateway: gateway, contract: f.contract)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        let context = try XCTUnwrap(coordinator.beginAttachmentSelection())
        let loaded = expectation(description: "Old photo provider returned")
        coordinator.attach(context: context) {
            await gate.wait(); loaded.fulfill()
            return [.bytes(Data([1, 2, 3]), filename: "Old photo.jpg")]
        }
        try await wait { gate.waiting }
        try coordinator.beginFreshConversation(context: f.context)
        gate.release()
        await fulfillment(of: [loaded], timeout: 3)
        var retriedOldLoad = false
        coordinator.attach(context: context) { retriedOldLoad = true; return [] }
        XCTAssertFalse(retriedOldLoad)
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(coordinator.uploadedFiles.isEmpty)
        XCTAssertFalse(coordinator.isCurrentAttachmentContext(context))
        coordinator.dismiss()
    }

    func testChatPhotoSizeLimitIsCheckedBeforeUploadAndInvalidScansFailClearly() async throws {
        let f = try fixture(), subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try f.store.assistantDatabase.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let gateway = TestAssistantGateway(subject: subject)
        var uploads = 0
        gateway.uploadHandler = { _, _ in uploads += 1; return .object([:]) }
        let coordinator = AssistantCoordinator(store: f.store, gateway: gateway, contract: f.contract)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        coordinator.attach(context: coordinator.attachmentContext) { [.bytes(Data(count: 15 * 1024 * 1024 + 1), filename: "Too large.jpg")] }
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(coordinator.error?.contains("15 MiB") == true)
        for pages in [[], [Data([0, 1, 2])]] {
            do { _ = try await ReceiptScanPDF.shared.makeDocument(pages: pages); XCTFail("Invalid scans must fail") }
            catch { XCTAssertTrue(error is AssistantFailure) }
        }
        coordinator.dismiss()
    }

    func testRapidSteeringWaitsForOldStreamAndRejectsItsLateCalls() async throws {
        let f = try fixture(), subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try f.store.assistantDatabase.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let gate = AssistantTestGate(), gateway = TestAssistantGateway(subject: subject)
        let obsolete = call("rename_conversation", .object(["title": .string("Obsolete title")]))
        gateway.stepOverride = { index, _, receive in
            if index == 1 {
                try receive(AssistantStepEvent(type: "text_delta", text: "Old partial answer"))
                await gate.wait()
                // Simulate a transport that delivers buffered output after cancellation.
                try? receive(AssistantStepEvent(type: "step_completed", text: "Obsolete answer", continuation: "old", calls: [obsolete]))
            } else {
                try receive(AssistantStepEvent(type: "step_completed", text: "Updated answer", continuation: "updated", calls: []))
            }
        }
        let coordinator = AssistantCoordinator(store: f.store, gateway: gateway, contract: f.contract)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        XCTAssertTrue(coordinator.send("Explain this month"))
        try await wait { gate.waiting }
        XCTAssertTrue(coordinator.send("Only groceries"))
        XCTAssertTrue(coordinator.send("And use Chinese"))
        XCTAssertEqual(gateway.steps, 1)
        XCTAssertEqual(coordinator.conversation.pendingSteering?.count, 2)
        let saved = try JSONDecoder().decode(AssistantConversation.self, from: XCTUnwrap(f.store.assistantDatabase.assistantHistory(scope: subject).first))
        XCTAssertEqual(saved.pendingSteering?.count, 2)
        gate.release()
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(gateway.steps, 2)
        XCTAssertEqual(gateway.itemsSeen.last?.filter { $0["type"].string == "message" }.compactMap { $0["text"].string }, ["Explain this month", "Only groceries", "And use Chinese"])
        XCTAssertNil(coordinator.conversation.pendingSteering)
        XCTAssertFalse(coordinator.conversation.messages.contains { $0.text == "Obsolete answer" })
        XCTAssertNotEqual(coordinator.conversation.title, "Obsolete title")
        XCTAssertTrue(coordinator.conversation.activity.isEmpty)
        coordinator.dismiss()
    }

    func testSteeringPreservesSavedActionsAndSupersedesTheRemainingBatch() async throws {
        let f = try fixture(), subject = "cloudkit:iCloud.fixture:development:user-a", tx = f.store.data.transactions[0]
        _ = try f.store.assistantDatabase.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let gateway = TestAssistantGateway(subject: subject), gate = AssistantTestGate()
        let committed = call("update_transaction", .object(["id": .string(tx.id.uuidString), "if_revision": .string(try AssistantJSON.modelDigest(tx)), "note": .string("Already saved")]))
        let pending = call("select_files", .object(["purpose": .string("receipts")]))
        let obsolete = call("rename_conversation", .object(["title": .string("Must not execute")]))
        gateway.firstCalls = [committed, pending, obsolete]
        let coordinator = AssistantCoordinator(store: f.store, gateway: gateway, contract: f.contract)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        coordinator.tools?.selectFiles = { _ in await gate.wait(); return [] }
        XCTAssertTrue(coordinator.send("Update and attach a receipt"))
        try await wait { gate.waiting }
        XCTAssertEqual(f.store.transaction(tx.id)?.note, "Already saved")
        XCTAssertTrue(coordinator.send("Leave the saved transaction as-is and just summarize it"))
        XCTAssertEqual(gateway.steps, 1)
        gate.release()
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(f.store.transaction(tx.id)?.note, "Already saved")
        let results = coordinator.conversation.activity
        XCTAssertEqual(results.map(\.operationID), [committed.operationID, pending.operationID, obsolete.operationID])
        XCTAssertEqual(results.first?.result, try f.store.assistantDatabase.assistantAction(scope: subject, id: committed.operationID, digest: committed.digest))
        for result in results.dropFirst() {
            let value = try JSONDecoder().decode(AssistantJSON.self, from: Data(XCTUnwrap(result.result).utf8))
            XCTAssertEqual(value["error"]["code"].string, "superseded")
        }
        XCTAssertNotEqual(coordinator.conversation.title, "Must not execute")
        let input = try XCTUnwrap(gateway.itemsSeen.last)
        XCTAssertEqual(input.last?["text"].string, "Leave the saved transaction as-is and just summarize it")
        XCTAssertEqual(input.filter { $0["type"].string == "tool_result" }.count, 3)
        coordinator.dismiss()
    }

    func testSteeringInvalidatesAnOutstandingDeleteApproval() async throws {
        let f = try fixture(), subject = "cloudkit:iCloud.fixture:development:user-a", tx = f.store.data.transactions[0]
        _ = try f.store.assistantDatabase.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let gateway = TestAssistantGateway(subject: subject)
        gateway.firstCalls = [call("delete_transaction", .object(["id": .string(tx.id.uuidString), "if_revision": .string(try AssistantJSON.modelDigest(tx)), "snapshot_revision": .string(f.snapshot)]))]
        let coordinator = AssistantCoordinator(store: f.store, gateway: gateway, contract: f.contract)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        XCTAssertTrue(coordinator.send("Delete this transaction"))
        try await wait { coordinator.approval != nil && !coordinator.isRunning }
        XCTAssertTrue(coordinator.send("Actually keep it and explain it"))
        XCTAssertNil(coordinator.approval)
        coordinator.approve(true) // A stale confirmation must not authorize the old deletion.
        try await wait { !coordinator.isRunning }
        XCTAssertNotNil(f.store.transaction(tx.id))
        XCTAssertEqual(gateway.steps, 2)
        XCTAssertTrue(coordinator.conversation.calls.isEmpty)
        coordinator.dismiss()
    }

    func testSteeringSurvivesBackgroundAndHistoryRestoreWithoutAutomaticExecution() async throws {
        let f = try fixture(), subject = "cloudkit:iCloud.fixture:development:user-a", gate = AssistantTestGate()
        _ = try f.store.assistantDatabase.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let gateway = TestAssistantGateway(subject: subject)
        gateway.stepOverride = { _, _, _ in await gate.wait() }
        let coordinator = AssistantCoordinator(store: f.store, gateway: gateway, contract: f.contract)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        XCTAssertTrue(coordinator.send("Explain spending"))
        try await wait { gate.waiting }
        XCTAssertTrue(coordinator.send("Only this week"))
        coordinator.setForeground(false)
        gate.release()
        let saved = try JSONDecoder().decode(AssistantConversation.self, from: XCTUnwrap(f.store.assistantDatabase.assistantHistory(scope: subject).first))
        XCTAssertTrue(saved.canResume)
        XCTAssertEqual(saved.pendingSteering?.first?["text"].string, "Only this week")
        XCTAssertEqual(gateway.steps, 1)
        let replacement = TestAssistantGateway(subject: subject)
        let restored = AssistantCoordinator(store: f.store, gateway: replacement, contract: f.contract)
        restored.consented = true; restored.setForeground(true); restored.present()
        try await wait { restored.connected }
        restored.selectConversation(saved)
        XCTAssertEqual(replacement.steps, 0)
        restored.resume()
        try await wait { !restored.isRunning }
        XCTAssertEqual(replacement.itemsSeen.first?.filter { $0["text"].string == "Only this week" }.count, 1)
        XCTAssertNil(restored.conversation.pendingSteering)
        restored.dismiss()
    }

    func testFailedSteeringCheckpointRetainsOriginalHistoryAndStopsOldWork() async throws {
        let f = try fixture(), subject = "cloudkit:iCloud.fixture:development:user-a", gate = AssistantTestGate()
        let db = f.store.assistantDatabase
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let gateway = TestAssistantGateway(subject: subject)
        gateway.stepOverride = { index, _, receive in
            if index == 1 { await gate.wait() }
            else { try receive(AssistantStepEvent(type: "step_completed", text: "Resumed", continuation: "resumed", calls: [])) }
        }
        let coordinator = AssistantCoordinator(store: f.store, gateway: gateway, contract: f.contract)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        XCTAssertTrue(coordinator.send("Original request"))
        try await wait { gate.waiting }
        try SQLiteWriteAudit.execute("CREATE TRIGGER reject_steer BEFORE INSERT ON assistant_history BEGIN SELECT RAISE(ABORT, 'Synthetic disk failure'); END", at: db.databaseURL)
        XCTAssertFalse(coordinator.send("Unsaved correction"))
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(coordinator.conversation.pendingSteering)
        XCTAssertFalse(coordinator.conversation.messages.contains { $0.text == "Unsaved correction" })
        XCTAssertNotNil(coordinator.error)
        try SQLiteWriteAudit.execute("DROP TRIGGER reject_steer", at: db.databaseURL)
        gate.release()
        coordinator.resume()
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(gateway.itemsSeen.last?.filter { $0["type"].string == "message" }.compactMap { $0["text"].string }, ["Original request"])
        coordinator.dismiss()
    }

    func testNewChatKeepsTheRetirementBarrierAndLeavesSteeringInItsOriginalHistory() async throws {
        let f = try fixture(), subject = "cloudkit:iCloud.fixture:development:user-a", gate = AssistantTestGate()
        let db = f.store.assistantDatabase
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let gateway = TestAssistantGateway(subject: subject)
        gateway.stepOverride = { index, _, receive in
            if index == 1 { await gate.wait() }
            else { try receive(AssistantStepEvent(type: "step_completed", text: "New chat answer", continuation: "new", calls: [])) }
        }
        let coordinator = AssistantCoordinator(store: f.store, gateway: gateway, contract: f.contract)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        XCTAssertTrue(coordinator.send("Original chat request"))
        let originalID = coordinator.conversation.id
        try await wait { gate.waiting }
        XCTAssertTrue(coordinator.send("Original chat correction"))
        try coordinator.beginFreshConversation(context: AssistantContext(journalID: UUID()))
        XCTAssertTrue(coordinator.send("Separate chat request"))
        XCTAssertEqual(gateway.steps, 1)
        gate.release()
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(gateway.itemsSeen.last?.compactMap { $0["text"].string }, ["Separate chat request"])
        XCTAssertNotEqual(coordinator.conversation.id, originalID)
        let original = try db.assistantHistory(scope: subject).map { try JSONDecoder().decode(AssistantConversation.self, from: $0) }.first { $0.id == originalID }
        XCTAssertEqual(original?.pendingSteering?.first?["text"].string, "Original chat correction")
        XCTAssertTrue(original?.canResume == true)
        coordinator.dismiss()
    }

    func testInterruptedVoiceResponsesCannotDispatchFinanceActions() {
        func event(responseStatus: String, callStatus: String) -> AssistantJSON {
            .object(["type": .string("response.done"), "response": .object([
                "status": .string(responseStatus), "output": .array([.object([
                    "type": .string("function_call"), "name": .string("run_finance_task"),
                    "status": .string(callStatus), "call_id": .string("call-1"),
                    "arguments": .string("{\"request\":\"Create the transaction\"}")
                ])])
            ])])
        }
        for status in ["cancelled", "failed", "incomplete", "in_progress"] {
            XCTAssertTrue(AssistantVoiceSession.completedRealtimeRequests(in: event(responseStatus: status, callStatus: "completed")).isEmpty)
        }
        XCTAssertTrue(AssistantVoiceSession.completedRealtimeRequests(in: event(responseStatus: "completed", callStatus: "incomplete")).isEmpty)
        let completed = AssistantVoiceSession.completedRealtimeRequests(in: event(responseStatus: "completed", callStatus: "completed"))
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.request, "Create the transaction")
    }

    func testRealtimePlaybackDoesNotFlipWithLateTranscriptsOrGenerationEvents() {
        var activity = AssistantRealtimeAudioActivity()
        func event(_ type: String, response: String = "reply", item: String = "user") -> AssistantJSON {
            .object(["type": .string(type), "response_id": .string(response), "item_id": .string(item)])
        }
        XCTAssertEqual(activity.receive(event("output_audio_buffer.started"))?.status, "Speaking")
        let interruption = activity.receive(event("input_audio_buffer.speech_started"))
        XCTAssertEqual(interruption?.status, "Speaking") // Still audible until the server clears playback.
        XCTAssertEqual(interruption?.beganUserSpeech, true)
        XCTAssertNil(activity.receive(event("input_audio_buffer.speech_started"))) // Don't pause twice.
        XCTAssertEqual(activity.receive(event("output_audio_buffer.cleared"))?.status, "Listening")
        for type in ["response.output_audio_transcript.delta", "response.output_audio.done", "response.done"] {
            XCTAssertNil(activity.receive(event(type)))
        }
        XCTAssertEqual(activity.receive(event("input_audio_buffer.speech_stopped"))?.status, "Listening")
        XCTAssertEqual(activity.receive(event("output_audio_buffer.started", response: "next"))?.status, "Speaking")
        XCTAssertNil(activity.receive(event("output_audio_buffer.stopped", response: "reply")))
        XCTAssertEqual(activity.receive(event("output_audio_buffer.stopped", response: "next"))?.status, "Listening")
    }

    func testVoiceKeepsSpeakerDefaultWhenWebRTCReconfiguresAndReconnects() throws {
        let voice = AssistantVoiceSession()
        let audio = RTCAudioSession.sharedInstance()
        let previousConfiguration = RTCAudioSessionConfiguration.webRTC()
        defer {
            voice.stop()
            RTCAudioSessionConfiguration.setWebRTC(previousConfiguration)
        }
        for _ in 0..<2 {
            try voice.activateAudioSession()
            try voice.activateAudioSession() // Repeated setup must not leak an activation.
            XCTAssertTrue(audio.isActive)
            // Exercise the same configuration WebRTC reapplies at audio-unit startup.
            do {
                let configuration = RTCAudioSessionConfiguration.webRTC()
                audio.lockForConfiguration()
                defer { audio.unlockForConfiguration() }
                try audio.setConfiguration(configuration)
                XCTAssertEqual(audio.category, AVAudioSession.Category.playAndRecord.rawValue)
                XCTAssertEqual(audio.mode, AVAudioSession.Mode.voiceChat.rawValue)
                XCTAssertTrue(audio.categoryOptions.contains(.defaultToSpeaker))
                XCTAssertTrue(audio.categoryOptions.contains(.allowBluetoothHFP))
            }
            voice.stop()
            XCTAssertFalse(audio.isActive)
        }
    }

    private var stores: [MobileLedgerStore] = []
    private var directories: [URL] = []
    override func tearDown() async throws {
        for store in stores { await store.waitForCloudKitSyncIdle() }
        stores = []; await MobileLedgerStore.drainPersistenceQueueForTesting()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }
    private func fixture() throws -> AssistantTools {
        let ledger = Ledger(name: "Synthetic"), currency = Commodity(ledgerID: ledger.id, symbol: "USD", name: "Dollar")
        let assets = Account(ledgerID: ledger.id, name: "Assets", kind: .asset)
        let cash = Account(ledgerID: ledger.id, parentID: assets.id, name: "Cash", kind: .asset)
        let expenses = Account(ledgerID: ledger.id, name: "Expenses", kind: .expense)
        let food = Account(ledgerID: ledger.id, parentID: expenses.id, name: "Food", kind: .expense)
        let tx = LedgerTransaction(ledgerID: ledger.id, date: Date(timeIntervalSince1970: 1_700_000_000), payee: "Original", note: "Preserve me", number: "", cleared: false, postings: [Posting(accountID: cash.id, amount: -12.34), Posting(accountID: food.id, amount: 12.34)])
        let data = JournalData(ledgers: [ledger], commodities: [currency], accounts: [assets, cash, expenses, food], transactions: [tx], selectedLedgerID: ledger.id)
        let directory = FileManager.default.temporaryDirectory.appending(path: "AssistantTests-\(UUID())")
        directories.append(directory)
        let dependencies = CloudKitSyncDependencies(configuration: { nil }, makeClient: { _ in throw AssistantFailure("test", "No real CloudKit in tests.") }, automaticTriggersEnabled: false)
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data, cloudKitSyncDependencies: dependencies)
        stores.append(store); try store.flushLocalChanges()
        return AssistantTools(store: store, scope: "user-a", context: AssistantContext(journalID: ledger.id), contract: try AssistantContract.load())
    }
    private func call(_ name: String, _ args: AssistantJSON, id: String = UUID().uuidString) -> AssistantToolCall {
        AssistantToolCall(id: "call-" + UUID().uuidString, name: name, arguments: args.jsonString, operationID: id)
    }
    func testAtomicWriteRollsBackGraphOutboxAndReceiptThenRetriesOnce() async throws {
        let tools = try fixture(), tx = tools.store.data.transactions[0]
        let args: AssistantJSON = .object(["id": .string(tx.id.uuidString), "if_revision": .string(try AssistantJSON.modelDigest(tx)), "note": .string("Committed note")])
        let action = call("update_transaction", args)
        let countBefore = try tools.store.assistantDatabase.recordCounts().outboxRows
        tools.store.assistantBeforeCommit = { throw AssistantFailure("injected", "Disk failure at COMMIT boundary") }
        do { _ = try await tools.execute(action); XCTFail("Expected injected failure") } catch { XCTAssertEqual((error as? AssistantFailure)?.code, "injected") }
        XCTAssertEqual(tools.store.transaction(tx.id)?.note, "Preserve me")
        XCTAssertEqual(try tools.store.assistantDatabase.loadData()?.transactions.first?.note, "Preserve me")
        XCTAssertNil(try tools.store.assistantDatabase.assistantAction(scope: tools.scope, id: action.operationID, digest: action.digest))
        XCTAssertEqual(try tools.store.assistantDatabase.recordCounts().outboxRows, countBefore)
        tools.store.assistantBeforeCommit = nil
        let saved = try await tools.execute(action)
        XCTAssertTrue(saved["ok"].bool == true)
        XCTAssertEqual(tools.store.transaction(tx.id)?.note, "Committed note")
        // The original revision is stale now, but the same operation replays.
        let replay = try await tools.execute(action)
        XCTAssertEqual(replay, saved)
        XCTAssertEqual(tools.store.data.transactions.count, 1)
        var different = action; different.arguments = args.setting("note", .string("Different intent")).jsonString
        do { _ = try await tools.execute(different); XCTFail("Reused operation must fail") } catch {}
    }
    func testCommittedCreateSurvivesMissingReplyAndReopen() async throws {
        let tools = try fixture(), data = tools.store.data
        let cash = data.accounts.first { $0.name == "Cash" }!, food = data.accounts.first { $0.name == "Food" }!
        let action = call("create_transaction", .object(["journal": .string(data.ledgers[0].id.uuidString), "date": .string("2026-01-02"), "payee": .string("Retry fixture"), "postings": .array([.object(["account": .string(cash.id.uuidString), "amount": .string("-0.123456789012345678")]), .object(["account": .string(food.id.uuidString), "amount": .string("0.123456789012345678")])])]))
        let result = try await tools.execute(action)
        let persisted = try XCTUnwrap(tools.store.assistantDatabase.loadData())
        XCTAssertEqual(persisted.transactions.count, 2)
        let reopened = MobileLedgerStore(supportDirectory: directories[0], cloudKitSyncDependencies: .init(configuration: { nil }, makeClient: { _ in throw CancellationError() }, automaticTriggersEnabled: false))
        stores.append(reopened)
        let other = AssistantTools(store: reopened, scope: tools.scope, context: tools.context, contract: tools.contract)
        let replay = try await other.execute(action)
        XCTAssertEqual(replay, result)
        XCTAssertEqual(reopened.data.transactions.count, 2)
        XCTAssertEqual(reopened.transaction(UUID(uuidString: action.operationID))?.postings.first?.amount, Decimal(string: "-0.123456789012345678"))
    }
    func testBalanceAggregatesDescendantsAndUsesLedgerCurrencyFallback() throws {
        let tools = try fixture(), currency = tools.store.data.commodities[0]
        let result = try tools.balances(.object(["account": .string("Assets")]))
        let account = try XCTUnwrap(result["accounts"].array.first)
        XCTAssertEqual(account["name"].string, "Assets")
        XCTAssertEqual(account["balances"].array.first?["amount"].string, "-12.34")
        XCTAssertEqual(account["balances"].array.first?["currency_id"].string, currency.id.uuidString)
        let filtered = try tools.filtered(.object(["currency": .string("USD")]))
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(try tools.transactionValue(filtered[0])["postings"].array.first?["currency_symbol"].string, "USD")
    }
    func testStructuralEditsPublishFreshNativeCachesAndResult() async throws {
        let tools = try fixture(), old = tools.store.data.accounts.first { $0.name == "Cash" }!
        let action = call("update_account", .object(["id": .string(old.id.uuidString), "if_revision": .string(try AssistantJSON.modelDigest(old)), "parent": .null, "position": .number(9)]))
        let result = try await tools.execute(action)
        XCTAssertNil(tools.store.account(old.id)?.parentID)
        XCTAssertEqual(tools.store.account(old.id)?.listIndex, 9)
        XCTAssertEqual(result["result"]["listIndex"].int, 9)
    }
    func testStaleRevisionAndUnbalancedMoneyNeverCommit() async throws {
        let tools = try fixture(), tx = tools.store.data.transactions[0]
        let stale = call("update_transaction", .object(["id": .string(tx.id.uuidString), "if_revision": .string("stale"), "note": .string("bad")]))
        do { _ = try await tools.execute(stale); XCTFail("Stale write must fail") } catch { XCTAssertEqual((error as? AssistantFailure)?.code, "revision_conflict") }
        let action = call("create_transaction", .object(["journal": .string(tx.ledgerID.uuidString), "date": .string("2026-02-01"), "postings": .array(tx.postings.map { .object(["account": .string($0.accountID.uuidString), "amount": .string("1.00")]) })]))
        do { _ = try await tools.execute(action); XCTFail("Unbalanced transaction must fail") } catch {}
        XCTAssertEqual(tools.store.data.transactions.count, 1)
        XCTAssertEqual(tools.store.transaction(tx.id)?.note, tx.note)
    }
    func testHistoryExpiresPerUserWithoutDeletingActionReceipts() throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, now = Date()
        try db.saveAssistantHistory(scope: "a", id: "expired", payload: Data("old".utf8), now: now.addingTimeInterval(-31 * 86400))
        try db.saveAssistantHistory(scope: "a", id: "current", payload: Data("current".utf8), now: now)
        try db.saveAssistantHistory(scope: "b", id: "private", payload: Data("private".utf8), now: now)
        XCTAssertEqual(try db.assistantHistory(scope: "a", now: now), [Data("current".utf8)])
        XCTAssertEqual(try db.assistantHistory(scope: "b", now: now), [Data("private".utf8)])
        let receipt = SQLiteAssistantActionReceipt(scope: "a", id: "operation", digest: "digest", result: "committed")
        try db.persistAssistant(tools.store.data, previous: tools.store.data, scope: receipt.scope, id: receipt.id, digest: receipt.digest, result: receipt.result)
        try db.deleteAssistantHistory(scope: "a", id: "current")
        XCTAssertEqual(try db.assistantAction(scope: "a", id: "operation", digest: "digest"), "committed")
        XCTAssertNil(try db.assistantAction(scope: "b", id: "operation", digest: "digest"))
    }
    func testAllContractToolsHaveNativeCoverageAndStrictSchemas() throws {
        let contract = try AssistantContract.load()
        XCTAssertEqual(contract.tools.count, 44)
        XCTAssertEqual(Set(contract.tools.map(\.name)).count, 44)
        let tool = try XCTUnwrap(contract.tools.first { $0.name == "create_transaction" })
        XCTAssertThrowsError(try AssistantContract.validate(.object(["unexpected": .bool(true)]), schema: tool.inputSchema))
        XCTAssertThrowsError(try AssistantContract.validate(.object(["journal": .string("x"), "date": .string("2026-01-01"), "request_id": .string("id"), "postings": .array([])]), schema: tool.inputSchema))
    }
    func testLiveAppendChunksPreserveChineseAndEmojiWithinTheTokenByteBound() {
        let text = String(repeating: "已保存十五美元的午餐 🍜👨‍👩‍👧‍👦。", count: 90)
        let chunks = AssistantVoiceSession.liveChunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 400 })
    }
    func testConflictPreviewShowsClearedAndAccountParentDifferences() throws {
        let tools = try fixture(), tx = tools.store.data.transactions[0]
        var changed = tx; changed.cleared.toggle(); changed.number = "Changed number"
        func record<T: Encodable>(_ type: String, _ value: T, id: UUID) throws -> CloudKitSyncRecord {
            CloudKitSyncRecord(recordType: type, recordID: id.uuidString, operation: "upsert", contentHash: try AssistantJSON.modelDigest(value), payloadJSON: String(decoding: try JSONEncoder.appEncoder.encode(value), as: UTF8.self))
        }
        let conflict = CloudKitSyncConflict(id: "tx", local: try record("transaction", tx, id: tx.id), remote: try record("transaction", changed, id: tx.id))
        let description = tools.conflictComparison(conflict)
        XCTAssertTrue(description.contains("Cleared")); XCTAssertTrue(description.contains("Changed number"))
        let account = tools.store.data.accounts.first { $0.name == "Cash" }!
        var moved = account; moved.parentID = nil
        let hierarchy = CloudKitSyncConflict(id: "account", local: try record("account", account, id: account.id), remote: try record("account", moved, id: account.id))
        XCTAssertTrue(tools.conflictComparison(hierarchy).contains("Parent account"))
    }
    func testSummaryMatchesWebCurrencyGroupingWithoutCountingTransfers() throws {
        let tools = try fixture()
        let result = try tools.summary(.object([:]))
        let usd = try XCTUnwrap(result["currencies"].array.first)
        XCTAssertEqual(usd["symbol"].string, "USD")
        XCTAssertEqual(usd["income"].string, "0")
        XCTAssertEqual(usd["expenses"].string, "12.34")
        XCTAssertEqual(usd["net"].string, "-12.34")
        XCTAssertEqual(usd["categories"].array.first?["name"].string, "Food")
    }
    func testCancelAfterCommitBeforeCheckpointPreservesTheVerifiedResult() async throws {
        let tools = try fixture(), tx = tools.store.data.transactions[0]
        let subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try tools.store.assistantDatabase.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let ownedTools = AssistantTools(store: tools.store, scope: subject, context: tools.context, contract: tools.contract)
        let action = call("update_transaction", .object(["id": .string(tx.id.uuidString), "if_revision": .string(try AssistantJSON.modelDigest(tx)), "note": .string("Committed before crash")]))
        let saved = try await ownedTools.execute(action)
        let interrupted = AssistantConversation(calls: [action], context: tools.context, paused: true, hasPendingInference: true)
        try tools.store.assistantDatabase.saveAssistantHistory(scope: subject, id: interrupted.id.uuidString, payload: JSONEncoder().encode(interrupted))
        let gateway = TestAssistantGateway(subject: subject)
        let coordinator = AssistantCoordinator(store: tools.store, gateway: gateway, contract: tools.contract)
        try coordinator.beginFreshConversation(context: tools.context)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        coordinator.selectConversation(try XCTUnwrap(coordinator.history.first { $0.id == interrupted.id }))
        coordinator.cancelRemaining()
        XCTAssertFalse(coordinator.conversation.canResume)
        XCTAssertEqual(coordinator.conversation.activity.first?.result, saved.jsonString)
        XCTAssertEqual(tools.store.transaction(tx.id)?.note, "Committed before crash")
        XCTAssertEqual(gateway.steps, 0)
        coordinator.dismiss()
    }
    func testCheckpointFailureCannotExecuteAnUnrecordedIntentOnResume() async throws {
        let tools = try fixture(), tx = tools.store.data.transactions[0], db = tools.store.assistantDatabase
        let subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let action = call("update_transaction", .object(["id": .string(tx.id.uuidString), "if_revision": .string(try AssistantJSON.modelDigest(tx)), "note": .string("Resumed once")]))
        let gateway = TestAssistantGateway(subject: subject)
        gateway.firstCalls = [action]
        gateway.beforeFirstStep = { try SQLiteWriteAudit.execute("CREATE TRIGGER assistant_disk_full BEFORE INSERT ON assistant_history BEGIN SELECT RAISE(ABORT, 'Synthetic disk full'); END", at: db.databaseURL) }
        let coordinator = AssistantCoordinator(store: tools.store, gateway: gateway, contract: tools.contract)
        try coordinator.beginFreshConversation(context: tools.context)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        XCTAssertTrue(coordinator.send("Update the note"))
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(tools.store.transaction(tx.id)?.note, tx.note)
        XCTAssertTrue(coordinator.conversation.canResume)
        try SQLiteWriteAudit.execute("DROP TRIGGER assistant_disk_full", at: db.databaseURL)
        let requireActive = try XCTUnwrap(coordinator.tools).requireActive
        var sawDurableIntent = false
        coordinator.tools?.requireActive = {
            try requireActive()
            let history = try db.assistantHistory(scope: subject)
            let checkpoint = try JSONDecoder().decode(AssistantConversation.self, from: XCTUnwrap(history.first))
            XCTAssertEqual(checkpoint.calls.first?.operationID, action.operationID)
            sawDurableIntent = true
        }
        coordinator.resume()
        try await wait { !coordinator.isRunning }
        XCTAssertTrue(sawDurableIntent)
        XCTAssertEqual(tools.store.transaction(tx.id)?.note, "Resumed once")
        XCTAssertFalse(coordinator.conversation.canResume)
        coordinator.dismiss()
    }
    func testHistoryRemainsReadableWhenGatewayIsOfflineAfterIdentityVerification() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let saved = AssistantConversation(title: "Offline history", messages: [AssistantMessage(role: "user", text: "Saved locally")], context: tools.context)
        try db.saveAssistantHistory(scope: subject, id: saved.id.uuidString, payload: JSONEncoder().encode(saved))
        let gateway = TestAssistantGateway(subject: subject); gateway.offline = true
        let coordinator = AssistantCoordinator(store: tools.store, gateway: gateway, contract: tools.contract)
        try coordinator.beginFreshConversation(context: tools.context)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { !coordinator.isConnecting }
        XCTAssertFalse(coordinator.connected)
        XCTAssertTrue(coordinator.conversation.messages.isEmpty)
        coordinator.selectConversation(try XCTUnwrap(coordinator.history.first { $0.id == saved.id }))
        XCTAssertEqual(coordinator.conversation.messages.first?.text, "Saved locally")
        coordinator.dismiss()
    }
    func testRenamingCurrentAndOlderConversationPreservesCheckpointAndOrdering() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let originalDate = Date().addingTimeInterval(-3600)
        let pending = call("get_balances", .object([:]))
        let current = AssistantConversation(title: "Original", updated: originalDate,
            messages: [AssistantMessage(role: "user", text: "Keep my messages")], calls: [pending], context: tools.context, paused: true, hasPendingInference: true)
        let older = AssistantConversation(title: "Older", updated: originalDate.addingTimeInterval(-3600), context: tools.context)
        for value in [current, older] { try db.saveAssistantHistory(scope: subject, id: value.id.uuidString, payload: JSONEncoder().encode(value), now: value.updated) }
        let coordinator = AssistantCoordinator(store: tools.store, gateway: TestAssistantGateway(subject: subject), contract: tools.contract)
        try coordinator.beginFreshConversation(context: tools.context)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        coordinator.selectConversation(try XCTUnwrap(coordinator.history.first { $0.id == current.id }))
        let order = coordinator.history.map(\.id)
        try coordinator.renameConversation(current.id, title: "  九月 Spending  ")
        XCTAssertEqual(coordinator.conversation.title, "九月 Spending")
        XCTAssertEqual(coordinator.conversation.calls, [pending])
        XCTAssertTrue(coordinator.conversation.canResume)
        XCTAssertEqual(coordinator.conversation.updated, originalDate)
        try coordinator.renameConversation(older.id, title: "Travel Plans")
        XCTAssertEqual(coordinator.history.map(\.id), order)
        XCTAssertEqual(coordinator.conversation.title, "九月 Spending")
        let reloaded = try db.assistantHistory(scope: subject).map { try JSONDecoder().decode(AssistantConversation.self, from: $0) }
        XCTAssertEqual(reloaded.map(\.title), ["九月 Spending", "Travel Plans"])
        XCTAssertEqual(reloaded[0].messages, current.messages)
        XCTAssertEqual(reloaded[0].calls, [pending])
        XCTAssertEqual(reloaded[0].updated, originalDate)
        XCTAssertThrowsError(try coordinator.renameConversation(current.id, title: " \n "))
        XCTAssertThrowsError(try coordinator.renameConversation(current.id, title: String(repeating: "x", count: 81)))
        try SQLiteWriteAudit.execute("CREATE TRIGGER reject_assistant_rename BEFORE INSERT ON assistant_history BEGIN SELECT RAISE(ABORT, 'Synthetic disk failure'); END", at: db.databaseURL)
        XCTAssertThrowsError(try coordinator.renameConversation(current.id, title: "Must not publish"))
        XCTAssertEqual(coordinator.conversation.title, "九月 Spending")
        XCTAssertEqual(coordinator.history[0].title, "九月 Spending")
        try SQLiteWriteAudit.execute("DROP TRIGGER reject_assistant_rename", at: db.databaseURL)
        coordinator.dismiss()
    }
    func testConversationTitleToolsSaveOnlyCurrentChatAndReplayWithoutOverwritingManualRename() async throws {
        let fixture = try fixture(), db = fixture.store.assistantDatabase
        let subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let current = AssistantConversation(title: "Original", customTitle: true, context: fixture.context)
        let other = AssistantConversation(title: "Other", context: fixture.context)
        for conversation in [current, other] {
            try db.saveAssistantHistory(scope: subject, id: conversation.id.uuidString, payload: JSONEncoder().encode(conversation))
        }
        let action = call("rename_conversation", .object(["title": .string("  九月 Budget  ")]))
        let gateway = TestAssistantGateway(subject: subject)
        gateway.firstCalls = [call("get_conversation_title", .object([:])), action]
        let coordinator = AssistantCoordinator(store: fixture.store, gateway: gateway, contract: fixture.contract)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        coordinator.selectConversation(current)
        let tools = try XCTUnwrap(coordinator.tools)
        let before = try db.recordCounts().outboxRows
        XCTAssertTrue(coordinator.send("Please rename this conversation."))
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(coordinator.conversation.activity.map(\.name), ["get_conversation_title", "rename_conversation"])
        let read = try JSONDecoder().decode(AssistantJSON.self, from: Data(XCTUnwrap(coordinator.conversation.activity.first?.result).utf8))
        XCTAssertEqual(read["result"]["title"].string, "Original")
        XCTAssertEqual(read["result"]["conversation_id"].string, current.id.uuidString)
        let saved = try JSONDecoder().decode(AssistantJSON.self, from: Data(XCTUnwrap(coordinator.conversation.activity.last?.result).utf8))
        XCTAssertEqual(saved["result"]["title"].string, "九月 Budget")
        XCTAssertEqual(coordinator.conversation.title, "九月 Budget")
        XCTAssertEqual(coordinator.conversation.customTitle, true)
        XCTAssertEqual(try db.recordCounts().outboxRows, before)
        let history = try db.assistantHistory(scope: subject).map { try JSONDecoder().decode(AssistantConversation.self, from: $0) }
        XCTAssertEqual(history.first { $0.id == current.id }?.title, "九月 Budget")
        XCTAssertEqual(history.first { $0.id == other.id }?.title, "Other")
        XCTAssertTrue(try db.assistantHistory(scope: "another-user").isEmpty)
        try coordinator.renameConversation(current.id, title: "Manual correction")
        let replay = try await tools.execute(action)
        XCTAssertEqual(replay, saved)
        XCTAssertEqual(coordinator.conversation.title, "Manual correction")

        let failed = call("rename_conversation", .object(["title": .string("Must roll back")]))
        try SQLiteWriteAudit.execute("CREATE TRIGGER reject_assistant_title BEFORE INSERT ON assistant_history BEGIN SELECT RAISE(ABORT, 'Synthetic disk failure'); END", at: db.databaseURL)
        do { _ = try await tools.execute(failed); XCTFail("Expected history save failure") } catch { }
        XCTAssertNil(try db.assistantAction(scope: subject, id: failed.operationID, digest: failed.digest))
        XCTAssertEqual(coordinator.conversation.title, "Manual correction")
        try SQLiteWriteAudit.execute("DROP TRIGGER reject_assistant_title", at: db.databaseURL)
        for title in [" \n ", String(repeating: "x", count: 81)] {
            do { _ = try await tools.execute(call("rename_conversation", .object(["title": .string(title)]))); XCTFail("Expected invalid title") } catch { }
        }
        coordinator.dismiss()
    }
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Assistant did not reach the expected state")
    }
    func testManualNameSurvivesFirstMessageAndLegacyHistoryStillDecodes() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let empty = AssistantConversation(context: tools.context)
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as! [String: Any]
        XCTAssertNil(legacy["customTitle"])
        let decoded = try JSONDecoder().decode(AssistantConversation.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.customTitle)
        try db.saveAssistantHistory(scope: subject, id: empty.id.uuidString, payload: JSONEncoder().encode(empty))
        let coordinator = AssistantCoordinator(store: tools.store, gateway: TestAssistantGateway(subject: subject), contract: tools.contract)
        try coordinator.beginFreshConversation(context: tools.context)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        coordinator.selectConversation(try XCTUnwrap(coordinator.history.first { $0.id == empty.id }))
        try coordinator.renameConversation(empty.id, title: "My Budget")
        XCTAssertTrue(coordinator.send("This message should not replace the name"))
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(coordinator.conversation.title, "My Budget")
        let stored = try JSONDecoder().decode(AssistantConversation.self, from: XCTUnwrap(db.assistantHistory(scope: subject).first))
        XCTAssertEqual(stored.title, "My Budget")
        XCTAssertEqual(stored.customTitle, true)
        coordinator.dismiss()
    }

    func testFreshLauncherKeepsPausedActionsInHistoryAndUsesNewScope() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let pending = call("get_balances", .object([:]))
        var completed = call("get_app_context", .object([:]))
        completed.result = "{\"ok\":true,\"result\":{}}"
        let old = AssistantConversation(title: "Paused work", messages: [AssistantMessage(role: "user", text: "Check balances")], calls: [pending], activity: [completed], context: tools.context, paused: true, hasPendingInference: true, settings: AssistantSettings(effort: "low", customInstructions: "My preferences"))
        try db.saveAssistantHistory(scope: subject, id: old.id.uuidString, payload: JSONEncoder().encode(old))
        let gateway = TestAssistantGateway(subject: subject)
        let coordinator = AssistantCoordinator(store: tools.store, gateway: gateway, contract: tools.contract)
        let newContext = AssistantContext(journalID: UUID(), accountID: UUID())
        try coordinator.beginFreshConversation(context: newContext)
        let initialID = coordinator.conversation.id
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        XCTAssertEqual(coordinator.conversation.id, initialID)
        XCTAssertTrue(coordinator.conversation.messages.isEmpty)
        XCTAssertEqual(coordinator.conversation.context, newContext)
        XCTAssertEqual(coordinator.conversation.settings, old.settings)
        coordinator.selectConversation(try XCTUnwrap(coordinator.history.first))
        coordinator.uploadedFiles = [.object(["id": .string("old-upload")])]
        coordinator.artifact = URL(fileURLWithPath: "/tmp/old-export.csv")
        coordinator.needsAttachmentRecovery = true
        coordinator.navigationRequest = .object(["view": .string("register")])
        try coordinator.beginFreshConversation(context: newContext)
        XCTAssertNotEqual(coordinator.conversation.id, old.id)
        XCTAssertTrue(coordinator.conversation.messages.isEmpty)
        XCTAssertTrue(coordinator.conversation.calls.isEmpty)
        XCTAssertFalse(coordinator.conversation.canResume)
        XCTAssertEqual(coordinator.tools?.context, newContext)
        XCTAssertTrue(coordinator.uploadedFiles.isEmpty)
        XCTAssertNil(coordinator.artifact)
        XCTAssertFalse(coordinator.needsAttachmentRecovery)
        XCTAssertNil(coordinator.navigationRequest)
        let preserved = try XCTUnwrap(coordinator.history.first { $0.id == old.id })
        XCTAssertEqual(preserved.calls, [pending])
        XCTAssertEqual(preserved.activity, [completed])
        XCTAssertTrue(preserved.canResume)
        XCTAssertEqual(gateway.steps, 0)
        coordinator.selectConversation(preserved)
        coordinator.present() // Returning from an auxiliary sheet.
        try await wait { !coordinator.isConnecting }
        XCTAssertEqual(coordinator.conversation.id, old.id)
        XCTAssertEqual(coordinator.conversation.context, old.context)
        XCTAssertEqual(coordinator.conversation.calls.first?.operationID, pending.operationID)
        coordinator.resume()
        try await wait { !coordinator.isRunning }
        XCTAssertFalse(coordinator.conversation.canResume)
        XCTAssertTrue(coordinator.conversation.activity.contains { $0.operationID == pending.operationID })
        XCTAssertEqual(coordinator.conversation.activity.first?.result, completed.result)
        coordinator.dismiss()
    }

    func testFreshLauncherRetainsUnsavedRunWhenCheckpointFails() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let coordinator = AssistantCoordinator(store: tools.store, gateway: TestAssistantGateway(subject: subject), contract: tools.contract)
        try coordinator.beginFreshConversation(context: tools.context)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        let pending = call("get_balances", .object([:]))
        coordinator.conversation.messages = [AssistantMessage(role: "user", text: "Keep this request")]
        coordinator.conversation.calls = [pending]
        coordinator.conversation.hasPendingInference = true
        let oldID = coordinator.conversation.id
        try SQLiteWriteAudit.execute("CREATE TRIGGER fail_fresh_checkpoint BEFORE INSERT ON assistant_history BEGIN SELECT RAISE(ABORT, 'Synthetic disk full'); END", at: db.databaseURL)
        XCTAssertThrowsError(try coordinator.beginFreshConversation(context: AssistantContext()))
        XCTAssertEqual(coordinator.conversation.id, oldID)
        XCTAssertEqual(coordinator.conversation.calls, [pending])
        XCTAssertEqual(coordinator.conversation.messages.first?.text, "Keep this request")
        XCTAssertTrue(coordinator.conversation.canResume)
        try SQLiteWriteAudit.execute("DROP TRIGGER fail_fresh_checkpoint", at: db.databaseURL)
        try coordinator.beginFreshConversation(context: AssistantContext())
        XCTAssertEqual(coordinator.history.first?.id, oldID)
        XCTAssertNotEqual(coordinator.conversation.id, oldID)
        coordinator.dismiss()
    }

    func testUnmodifiedWelcomeDoesNotCreateHistoryButExplicitNewChatDoes() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let coordinator = AssistantCoordinator(store: tools.store, gateway: TestAssistantGateway(subject: subject), contract: tools.contract)
        coordinator.consented = true; coordinator.setForeground(true)
        for _ in 0..<3 {
            try coordinator.beginFreshConversation(context: tools.context)
            coordinator.present()
            try await wait { coordinator.connected && !coordinator.isConnecting }
            coordinator.dismiss()
        }
        XCTAssertTrue(coordinator.history.isEmpty)
        XCTAssertTrue(try db.assistantHistory(scope: subject).isEmpty)
        coordinator.present()
        try await wait { !coordinator.isConnecting }
        coordinator.newConversation()
        try await wait { !coordinator.isConnecting }
        XCTAssertEqual(coordinator.history.map(\.id), [coordinator.conversation.id])
        coordinator.dismiss()
    }

    func testFreshColdStartOnlyRestoresVerifiedUserSettings() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let foreign = AssistantConversation(settings: AssistantSettings(customInstructions: "Foreign settings"))
        try db.saveAssistantHistory(scope: "another-user", id: foreign.id.uuidString, payload: JSONEncoder().encode(foreign))
        let coordinator = AssistantCoordinator(store: tools.store, gateway: TestAssistantGateway(subject: subject), contract: tools.contract)
        coordinator.conversation.settings.customInstructions = "Stale in-memory settings"
        try coordinator.beginFreshConversation(context: tools.context)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        XCTAssertTrue(coordinator.history.isEmpty)
        XCTAssertEqual(coordinator.conversation.settings, AssistantSettings())
        XCTAssertEqual(coordinator.conversation.context, tools.context)
        coordinator.dismiss()
    }

    func testReturningToEmptyNamedHistoryNeverRebindsItsJournal() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let named = AssistantConversation(title: "Budget notes", customTitle: true, context: tools.context)
        try db.saveAssistantHistory(scope: subject, id: named.id.uuidString, payload: JSONEncoder().encode(named))
        let coordinator = AssistantCoordinator(store: tools.store, gateway: TestAssistantGateway(subject: subject), contract: tools.contract)
        try coordinator.beginFreshConversation(context: AssistantContext(journalID: UUID()))
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        coordinator.selectConversation(try XCTUnwrap(coordinator.history.first))
        coordinator.present()
        try await wait { !coordinator.isConnecting }
        XCTAssertEqual(coordinator.conversation.id, named.id)
        XCTAssertEqual(coordinator.conversation.context, tools.context)
        XCTAssertEqual(coordinator.tools?.context, tools.context)
        coordinator.dismiss()
    }

    func testDiscoveryOnlyStepIsCheckpointedAndContinuesBeforeLocalExecution() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let gateway = TestAssistantGateway(subject: subject)
        gateway.discoveryFirst = true
        gateway.firstCalls = [call("get_balances", .object([:]))]
        let coordinator = AssistantCoordinator(store: tools.store, gateway: gateway, contract: tools.contract)
        try coordinator.beginFreshConversation(context: tools.context)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        gateway.beforeSecondStep = {
            let saved = try JSONDecoder().decode(AssistantConversation.self, from: XCTUnwrap(db.assistantHistory(scope: subject).first))
            XCTAssertTrue(saved.hasPendingInference)
            XCTAssertTrue(saved.calls.isEmpty)
            XCTAssertTrue(saved.activity.isEmpty)
            XCTAssertEqual(saved.items.last?["value"].string, "discovery-checkpoint")
        }
        XCTAssertTrue(coordinator.send("Show balances"))
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(gateway.steps, 3)
        XCTAssertEqual(coordinator.conversation.activity.map(\.name), ["get_balances"])
        XCTAssertFalse(coordinator.conversation.canResume)
        XCTAssertNil(coordinator.error)
        coordinator.dismiss()
    }

    func testAppPreferencesApplyAtNewTurnWithoutChangingRunningSettings() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase, subject = "cloudkit:iCloud.fixture:development:user-a"
        _ = try db.bindCloudKitAccount(contextKey: "iCloud.fixture|Development|Journal", accountID: "user-a")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); directories.append(directory)
        let preferences = AssistantPreferencesStore(directory: directory, offlineSubject: subject)
        await preferences.refresh()
        let first = AssistantSettings(effort: "low", customInstructions: "First turn")
        let next = AssistantSettings(effort: "high", customInstructions: "Next turn")
        try preferences.edit(first, expected: preferences.value)
        let gateway = TestAssistantGateway(subject: subject)
        gateway.firstCalls = [call("get_balances", .object([:]))]
        gateway.beforeFirstStep = { try preferences.edit(next, expected: preferences.value) }
        let coordinator = AssistantCoordinator(store: tools.store, gateway: gateway, contract: tools.contract, preferences: preferences)
        try coordinator.beginFreshConversation(context: tools.context)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        XCTAssertTrue(coordinator.send("First request")); try await wait { !coordinator.isRunning }
        XCTAssertEqual(gateway.settingsSeen, [first, first])
        XCTAssertTrue(coordinator.send("Next request")); try await wait { !coordinator.isRunning }
        XCTAssertEqual(gateway.settingsSeen.last, next)
        XCTAssertEqual(preferences.settings, next)
        coordinator.dismiss(); preferences.disconnect()
    }

    func testNewTurnWaitsForRestoredAppPreferences() async throws {
        let tools = try fixture(), db = tools.store.assistantDatabase
        let restored = AssistantSettings(effort: "low", customInstructions: "Restored from iCloud")
        let cloud = DelayedAssistantPreferencesCloud(record: try AssistantPreferences(restored).record(previous: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); directories.append(directory)
        let preferences = AssistantPreferencesStore(directory: directory, network: cloud)
        let refresh = Task { await preferences.refresh() }
        try await wait { !preferences.subject.isEmpty }
        let subject = preferences.subject
        let fields = subject.split(separator: ":")
        _ = try db.bindCloudKitAccount(contextKey: "\(fields[1])|\(fields[2])|Journal", accountID: "user-a")
        let gateway = TestAssistantGateway(subject: subject)
        let coordinator = AssistantCoordinator(store: tools.store, gateway: gateway, contract: tools.contract, preferences: preferences)
        try coordinator.beginFreshConversation(context: tools.context)
        coordinator.consented = true; coordinator.setForeground(true); coordinator.present()
        try await wait { coordinator.connected }
        XCTAssertFalse(coordinator.send("Keep this draft until settings load"))
        XCTAssertTrue(coordinator.conversation.messages.isEmpty)
        XCTAssertEqual(gateway.steps, 0)
        await cloud.release()
        await refresh.value
        XCTAssertTrue(coordinator.send("Keep this draft until settings load"))
        try await wait { !coordinator.isRunning }
        XCTAssertEqual(gateway.settingsSeen, [restored])
        coordinator.dismiss(); preferences.disconnect()
    }
}

private actor DelayedAssistantPreferencesCloud: CloudKitSyncTransport {
    let record: CloudKitSyncRecord
    private var released = false
    init(record: CloudKitSyncRecord) { self.record = record }
    func accountIdentifier() async throws -> String { "user-a" }
    func prepareZone() async throws {}
    func fetchChanges(since: Data?) async throws -> CloudKitSyncPage {
        while !released { try await Task.sleep(for: .milliseconds(10)) }
        return .init(records: [record], changeToken: nil, moreComing: false)
    }
    func modifyRecords(_ records: [CloudKitSyncRecord]) async throws -> CloudKitSyncModifyResult { .init(saved: records, conflicts: []) }
    func release() { released = true }
    nonisolated func cancel() {}
}

@MainActor
private final class TestAssistantGateway: AssistantGatewayProtocol {
    let subject: String
    var firstCalls: [AssistantToolCall] = []
    var beforeFirstStep: (() throws -> Void)?
    var beforeSecondStep: (() throws -> Void)?
    var discoveryFirst = false
    var settingsSeen: [AssistantSettings] = []
    var itemsSeen: [[AssistantJSON]] = []
    var stepOverride: ((Int, [AssistantJSON], @escaping @MainActor (AssistantStepEvent) throws -> Void) async throws -> Void)?
    var uploadHandler: ((URL, String) async throws -> AssistantJSON)?
    var steps = 0
    var offline = false
    init(subject: String) { self.subject = subject }
    func localIdentity() async throws -> String? { subject }
    func connect() async throws -> String { if offline { throw URLError(.notConnectedToInternet) }; return subject }
    func options() async throws -> AssistantJSON { .object(["version": .number(1), "models": .array([])]) }
    func step(items: [AssistantJSON], settings: AssistantSettings, receive: @escaping @MainActor (AssistantStepEvent) throws -> Void) async throws {
        steps += 1
        settingsSeen.append(settings)
        itemsSeen.append(items)
        if let stepOverride { try await stepOverride(steps, items, receive); return }
        if steps == 1 { try beforeFirstStep?() }
        if steps == 2 { try beforeSecondStep?() }
        if discoveryFirst && steps == 1 {
            try receive(AssistantStepEvent(type: "step_completed", continuation: "discovery-checkpoint", calls: [], needsFollowUp: true))
            return
        }
        let emitsCalls = steps == (discoveryFirst ? 2 : 1)
        try receive(AssistantStepEvent(type: "step_completed", text: emitsCalls ? "" : "Saved", continuation: "synthetic-continuation", calls: emitsCalls ? firstCalls : []))
    }
    func upload(url: URL, fileID: String) async throws -> AssistantJSON {
        if let uploadHandler { return try await uploadHandler(url, fileID) }
        throw AssistantFailure("test", "No uploads in this fixture")
    }
    func voice(sdp: String, provider: String, context: String) async throws -> AssistantJSON { throw AssistantFailure("test", "No voice network in this fixture") }
}

@MainActor
private final class AssistantTestGate {
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}
