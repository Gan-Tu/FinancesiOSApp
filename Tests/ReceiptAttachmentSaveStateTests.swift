import XCTest
import UIKit
@testable import FinancesClone

@MainActor
final class ReceiptAttachmentSaveStateTests: XCTestCase {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    func testConsecutivePickerAppendsRemainCumulativeAndSerializeDurableSaves() async {
        let first = AttachmentAsset(originalFilename: "first.jpg", storedPath: "first.jpg", sizeBytes: 1)
        let second = AttachmentAsset(originalFilename: "second.jpg", storedPath: "second.jpg", sizeBytes: 2)
        let third = AttachmentAsset(originalFilename: "third.jpg", storedPath: "third.jpg", sizeBytes: 3)
        let state = ReceiptAttachmentSaveState()
        let gate = Gate()
        let started = expectation(description: "First save is suspended")
        var snapshots: [[AttachmentAsset]] = []
        var active = 0
        var maximumActive = 0
        let save: @MainActor ([AttachmentAsset]) async -> Bool = { assets in
            active += 1
            maximumActive = max(maximumActive, active)
            snapshots.append(assets)
            if snapshots.count == 1 { started.fulfill(); await gate.wait() }
            active -= 1
            return true
        }
        state.update([first], save: save)
        await fulfillment(of: [started], timeout: 5)
        state.update((state.pendingAssets ?? []) + [second], save: save)
        state.update((state.pendingAssets ?? []) + [third], save: save)
        XCTAssertTrue(state.isSaving)
        XCTAssertEqual(state.pendingAssets, [first, second, third])
        await gate.release()
        await state.waitForPendingSave()
        XCTAssertEqual(snapshots, [[first], [first, second, third]])
        XCTAssertEqual(maximumActive, 1)
        XCTAssertFalse(state.isSaving)
        XCTAssertNil(state.pendingAssets)
    }

    func testRegistryRetainsFailedSelectionsAcrossNavigationAndBoundsIdleStates() async {
        let registry = ReceiptAttachmentSaveRegistry(maximumIdleStates: 2)
        let transactionID = UUID()
        let owner = UUID()
        registry.retainState(for: transactionID, owner: owner)
        let state = registry.state(for: transactionID)
        let asset = AttachmentAsset(originalFilename: "receipt.jpg", storedPath: "receipt.jpg", sizeBytes: 1)
        state.update([asset]) { _ in false }
        await state.waitForPendingSave()
        registry.releaseState(for: transactionID, owner: owner)
        for _ in 0..<20 { _ = registry.state(for: UUID()) }
        XCTAssertTrue(registry.state(for: transactionID) === state)
        XCTAssertEqual(registry.state(for: transactionID).pendingAssets, [asset])
        XCTAssertTrue(registry.state(for: transactionID).needsRetry)
        XCTAssertLessThanOrEqual(registry.retainedStateCount, 3, "Two idle successes plus the failed selection")
        state.retry { _ in true }
        await state.waitForPendingSave()
        XCTAssertLessThanOrEqual(registry.retainedStateCount, 2)
    }

    func testRegistryDoesNotEvictVisibleOrInFlightState() async {
        let registry = ReceiptAttachmentSaveRegistry(maximumIdleStates: 1)
        let visibleID = UUID(), pendingID = UUID(), owner = UUID()
        registry.retainState(for: visibleID, owner: owner)
        let visible = registry.state(for: visibleID)
        let pending = registry.state(for: pendingID)
        let gate = Gate()
        let started = expectation(description: "Save is pending after leaving the screen")
        let asset = AttachmentAsset(originalFilename: "receipt.jpg", storedPath: "receipt.jpg", sizeBytes: 1)
        pending.update([asset]) { _ in started.fulfill(); await gate.wait(); return true }
        await fulfillment(of: [started], timeout: 5)
        for _ in 0..<20 { _ = registry.state(for: UUID()) }
        XCTAssertTrue(registry.state(for: visibleID) === visible)
        XCTAssertTrue(registry.state(for: pendingID) === pending)
        await gate.release()
        await pending.waitForPendingSave()
        registry.releaseState(for: visibleID, owner: owner)
        XCTAssertLessThanOrEqual(registry.retainedStateCount, 1)
    }

    func testRegistryInvalidationStopsQueuedPreImportAttachments() async {
        let registry = ReceiptAttachmentSaveRegistry()
        let transactionID = UUID(), owner = UUID()
        registry.retainState(for: transactionID, owner: owner)
        let state = registry.state(for: transactionID)
        let first = AttachmentAsset(originalFilename: "before.jpg", storedPath: "before.jpg", sizeBytes: 1)
        let queued = AttachmentAsset(originalFilename: "queued.jpg", storedPath: "queued.jpg", sizeBytes: 2)
        let gate = Gate()
        let started = expectation(description: "Accepted save is blocked")
        let committed = expectation(description: "Accepted save finishes independently")
        var snapshots: [[AttachmentAsset]] = []
        let save: @MainActor ([AttachmentAsset]) async -> Bool = { assets in
            snapshots.append(assets)
            started.fulfill()
            await gate.wait()
            committed.fulfill()
            return true
        }
        state.update([first], save: save)
        await fulfillment(of: [started], timeout: 5)
        state.update([first, queued], save: save)
        registry.invalidatePendingSaves()
        XCTAssertTrue(registry.state(for: transactionID) === state, "An active detail keeps its observed object during replacement")
        XCTAssertNil(state.pendingAssets)
        XCTAssertFalse(state.isSaving)
        XCTAssertFalse(state.needsRetry)
        await gate.release()
        await fulfillment(of: [committed], timeout: 5)
        XCTAssertEqual(snapshots, [[first]], "Old queued selections must never be applied after replacement")
        XCTAssertNil(state.pendingAssets)
    }

    func testOldReceiptCompletionCannotClearNewGenerationSaveState() async {
        let state = ReceiptAttachmentSaveState()
        let old = AttachmentAsset(originalFilename: "old.jpg", storedPath: "old.jpg", sizeBytes: 1)
        let fresh = AttachmentAsset(originalFilename: "fresh.jpg", storedPath: "fresh.jpg", sizeBytes: 2)
        let oldGate = Gate(), newGate = Gate()
        let oldStarted = expectation(description: "Old save starts")
        let oldFinished = expectation(description: "Old save finishes")
        let newStarted = expectation(description: "New save starts")
        state.update([old]) { _ in
            oldStarted.fulfill()
            await oldGate.wait()
            oldFinished.fulfill()
            return false
        }
        await fulfillment(of: [oldStarted], timeout: 5)
        state.invalidatePendingSaves()
        state.update([fresh]) { _ in newStarted.fulfill(); await newGate.wait(); return true }
        await fulfillment(of: [newStarted], timeout: 5)
        await oldGate.release()
        await fulfillment(of: [oldFinished], timeout: 5)
        XCTAssertEqual(state.pendingAssets, [fresh])
        XCTAssertTrue(state.isSaving)
        XCTAssertFalse(state.needsRetry, "The obsolete failure cannot mark the new selection failed")
        await newGate.release()
        await state.waitForPendingSave()
        XCTAssertNil(state.pendingAssets)
        XCTAssertFalse(state.isSaving)
    }

    func testAuthoritativeEditorSaveConsumesFailedReceiptSelectionWithoutResurrection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.fixture())
        let row = try XCTUnwrap(store.data.transactions.first)
        let source = directory.appendingPathComponent("source.jpg")
        try Data([1, 2, 3]).write(to: source)
        let first = try store.importAttachment(from: source)
        var initial = store.draft(for: row)
        initial.attachments = [first]
        let initialSaved = await store.saveTransactionAndFlushAsync(initial, supersedesPendingAttachments: true)
        XCTAssertTrue(initialSaved)
        let second = try store.importAttachment(from: source)
        let state = store.receiptAttachmentSaves.state(for: row.id)
        try SQLiteWriteAudit.execute("CREATE TRIGGER test_reject_receipt_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'Synthetic disk failure'); END", at: store.cloudKitSQLiteStore.databaseURL)
        state.update([first, second]) { assets in
            guard let current = store.transaction(row.id) else { return false }
            var draft = store.draft(for: current)
            draft.attachments = assets
            return await store.saveTransactionAndFlushAsync(draft)
        }
        await state.waitForPendingSave()
        XCTAssertEqual(state.pendingAssets, [first, second])
        XCTAssertTrue(state.needsRetry)
        try SQLiteWriteAudit.execute("DROP TRIGGER test_reject_receipt_outbox", at: store.cloudKitSQLiteStore.databaseURL)
        var edited = store.draft(for: try XCTUnwrap(store.transaction(row.id)))
        edited.attachments = [first]
        let saved = await store.saveTransactionAndFlushAsync(edited, supersedesPendingAttachments: true)
        XCTAssertTrue(saved)
        var retried = false
        state.retry { _ in retried = true; return true }
        await state.waitForPendingSave()
        XCTAssertFalse(retried)
        XCTAssertNil(state.pendingAssets)
        XCTAssertFalse(state.needsRetry)
        let reloaded = try XCTUnwrap(SQLiteJournalStore(databaseURL: store.cloudKitSQLiteStore.databaseURL).loadData())
        XCTAssertEqual(reloaded.transactions.first { $0.id == row.id }?.attachment?.assets, [first])
        XCTAssertFalse(reloaded.transactions.flatMap { $0.attachment?.assets ?? [] }.contains { $0.id == second.id })
        try await store.flushLocalChangesAsync()
    }

    func testNoteOnlyEditorSavePreservesReceiptAppendedWhileEarlierSaveFailed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.fixture())
        let row = try XCTUnwrap(store.data.transactions.first)
        let source = directory.appendingPathComponent("source.jpg")
        try Data([1, 2, 3]).write(to: source)
        let first = try store.importAttachment(from: source)
        var initial = store.draft(for: row)
        initial.attachments = [first]
        let initialSaved = await store.saveTransactionAndFlushAsync(initial, supersedesPendingAttachments: true)
        XCTAssertTrue(initialSaved)
        let second = try store.importAttachment(from: source)
        let state = store.receiptAttachmentSaves.state(for: row.id)
        let gate = Gate()
        let writeFailed = expectation(description: "A+B failed after memory application")
        try SQLiteWriteAudit.execute("CREATE TRIGGER test_reject_cumulative_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'Synthetic disk failure'); END", at: store.cloudKitSQLiteStore.databaseURL)
        let save: @MainActor ([AttachmentAsset]) async -> Bool = { assets in
            guard let current = store.transaction(row.id) else { return false }
            var draft = store.draft(for: current)
            draft.attachments = assets
            let saved = await store.saveTransactionAndFlushAsync(draft)
            writeFailed.fulfill()
            await gate.wait()
            return saved
        }
        state.update([first, second], save: save)
        await fulfillment(of: [writeFailed], timeout: 5)
        let third = try store.importAttachment(from: source)
        state.update([first, second, third], save: save)
        await gate.release()
        await state.waitForPendingSave()
        XCTAssertEqual(store.transaction(row.id)?.attachment?.assets, [first, second])
        XCTAssertEqual(state.pendingAssets, [first, second, third])
        XCTAssertTrue(state.needsRetry)
        try SQLiteWriteAudit.execute("DROP TRIGGER test_reject_cumulative_outbox", at: store.cloudKitSQLiteStore.databaseURL)
        var edited = store.receiptAttachmentSaves.draftIncludingPendingAttachments(store.draft(for: try XCTUnwrap(store.transaction(row.id))))
        XCTAssertEqual(edited.attachments, [first, second, third])
        edited.note = "Only changing the note"
        let saved = await store.saveTransactionAndFlushAsync(edited, supersedesPendingAttachments: true)
        XCTAssertTrue(saved)
        XCTAssertNil(state.pendingAssets)
        XCTAssertFalse(state.needsRetry)
        let reloaded = try XCTUnwrap(SQLiteJournalStore(databaseURL: store.cloudKitSQLiteStore.databaseURL).loadData()?.transactions.first { $0.id == row.id })
        XCTAssertEqual(reloaded.note, edited.note)
        XCTAssertEqual(reloaded.attachment?.assets, [first, second, third])
        try await store.flushLocalChangesAsync()
    }

    func testImportInvalidatedDuringCopyRejectsSetterAndRemovesOnlyItsOwnedResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owned = directory.appendingPathComponent("owned-copy.jpg")
        let anotherOperation = directory.appendingPathComponent("another-pending-copy.jpg")
        try Data([9]).write(to: anotherOperation)
        var generation = UUID()
        let originalGeneration = generation
        let gate = Gate()
        let copied = expectation(description: "Copy is finished but not yet delivered")
        var delivered: [AttachmentAsset] = []
        let operation = Task {
            try await ReceiptImportGenerationGuard.run(expected: originalGeneration, current: { generation }, importFile: {
                try Data([1]).write(to: owned)
                copied.fulfill()
                await gate.wait()
                return AttachmentAsset(originalFilename: "owned-copy.jpg", storedPath: owned.path, sizeBytes: 1)
            }, discard: { asset in
                try? FileManager.default.removeItem(atPath: asset.storedPath)
            }, receive: { delivered.append($0) })
        }
        await fulfillment(of: [copied], timeout: 5)
        generation = UUID()
        await gate.release()
        do { _ = try await operation.value; XCTFail("Pre-restore import must be rejected") }
        catch let error as ValidationError { XCTAssertTrue(error.message.contains("restored")) }
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: anotherOperation), Data([9]))
    }

    func testImportGenerationIsCheckedBeforeProviderResultCanStartCopying() async throws {
        var imported = false
        do {
            _ = try await ReceiptImportGenerationGuard.run(expected: UUID(), current: { UUID() }, importFile: {
                imported = true
                return AttachmentAsset(originalFilename: "old.jpg", storedPath: "old.jpg", sizeBytes: 1)
            }, discard: { _ in XCTFail("No file belongs to this rejected operation") }, receive: { _ in XCTFail("No stale setter is allowed") })
            XCTFail("The provider selection belongs to an older journal")
        } catch is ValidationError {}
        XCTAssertFalse(imported)
    }

    func testScannerDismantleCancelsPendingEncodingWithoutLateCompletion() async {
        let gate = Gate()
        let started = expectation(description: "Encoding started")
        var completionCount = 0
        let session = ReceiptScanSession { _ in completionCount += 1 }
        session.start { started.fulfill(); await gate.wait(); return [Data([1])] }
        await fulfillment(of: [started], timeout: 5)
        session.invalidate()
        await gate.release()
        await session.waitForPendingEncoding()
        XCTAssertEqual(completionCount, 0)
        session.cancel()
        session.fail(CocoaError(.fileReadUnknown))
        XCTAssertEqual(completionCount, 0)
    }

    func testScannerCancelCompletesOnceAndIgnoresLateEncoding() async {
        let gate = Gate()
        let started = expectation(description: "Encoding started")
        var results: [Result<[Data], Error>] = []
        let session = ReceiptScanSession { results.append($0) }
        session.start { started.fulfill(); await gate.wait(); return [Data([1])] }
        await fulfillment(of: [started], timeout: 5)
        session.cancel()
        session.cancel()
        await gate.release()
        await session.waitForPendingEncoding()
        XCTAssertEqual(results.count, 1)
        guard case .success(let pages)? = results.first else { XCTFail("Cancel must return an empty successful selection"); return }
        XCTAssertTrue(pages.isEmpty)
    }

    func testReceiptStagingIsIsolatedPerImportAndCleanupPreservesOtherFiles() async throws {
        let bytes = Data(repeating: 0x7f, count: 2_000_000)
        let first = try await ReceiptImportIO.shared.stage(bytes, filename: "receipt.jpg")
        let second = try await ReceiptImportIO.shared.stage(Data([1, 2, 3]), filename: "receipt.jpg")
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(first.url.lastPathComponent, "receipt.jpg")
        XCTAssertEqual(try Data(contentsOf: first.url), bytes)
        await ReceiptImportIO.shared.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try Data(contentsOf: second.url), Data([1, 2, 3]))
        await ReceiptImportIO.shared.remove(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testBackgroundReceiptEncodingKeepsPageDimensionsAndProducesJPEG() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 72)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 72))
        }
        let bytes = try await ReceiptScanImage(image: image).jpegData()
        XCTAssertEqual(Array(bytes.prefix(2)), [0xff, 0xd8])
        let decoded = try XCTUnwrap(UIImage(data: bytes)?.cgImage)
        XCTAssertEqual(decoded.width, image.cgImage?.width)
        XCTAssertEqual(decoded.height, image.cgImage?.height)
    }

    func testFailedSaveKeepsNewerPickerAppendsForExplicitRetry() async {
        let first = AttachmentAsset(originalFilename: "first.jpg", storedPath: "first.jpg", sizeBytes: 1)
        let second = AttachmentAsset(originalFilename: "second.jpg", storedPath: "second.jpg", sizeBytes: 2)
        let state = ReceiptAttachmentSaveState()
        let gate = Gate()
        let started = expectation(description: "First save is suspended before failure")
        let failingSave: @MainActor ([AttachmentAsset]) async -> Bool = { _ in
            started.fulfill()
            await gate.wait()
            return false
        }
        state.update([first], save: failingSave)
        await fulfillment(of: [started], timeout: 5)
        state.update((state.pendingAssets ?? []) + [second], save: failingSave)
        await gate.release()
        await state.waitForPendingSave()
        XCTAssertFalse(state.isSaving)
        XCTAssertTrue(state.needsRetry)
        XCTAssertEqual(state.pendingAssets, [first, second], "A failure must retain selections added during the suspended save")
        var saved: [AttachmentAsset] = []
        state.retry { saved = $0; return true }
        await state.waitForPendingSave()
        XCTAssertEqual(saved, [first, second])
        XCTAssertFalse(state.isSaving)
        XCTAssertFalse(state.needsRetry)
        XCTAssertNil(state.pendingAssets)
    }
}
