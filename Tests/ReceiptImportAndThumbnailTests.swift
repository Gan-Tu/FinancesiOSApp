import XCTest
import Combine
import UIKit
@testable import FinancesClone

@MainActor
final class ReceiptImportAndThumbnailTests: XCTestCase {
    private var stores: [MobileLedgerStore] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for store in stores { await store.waitForCloudKitSyncIdle() }
        stores.removeAll()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    private func fixture() -> (MobileLedgerStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.fixture())
        stores.append(store); directories.append(directory)
        return (store, directory)
    }

    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
        func release() { released = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    }

    func testAcceptedImportBlocksSaveBeforeTaskStartsAndUntilDraftReceivesAllAssets() async throws {
        let session = ReceiptImportSession()
        let first = AttachmentAsset(originalFilename: "first.jpg", storedPath: "first.jpg", sizeBytes: 1)
        let second = AttachmentAsset(originalFilename: "second.jpg", storedPath: "second.jpg", sizeBytes: 2)
        let gate = Gate()
        var draftAssets: [AttachmentAsset] = []
        session.start { operation in
            await gate.wait()
            try session.accept(first, for: operation); draftAssets.append(first)
            try session.accept(second, for: operation); draftAssets.append(second)
        }
        XCTAssertFalse(session.canSave, "The toolbar uses this gate before snapshotting its draft")
        XCTAssertTrue(session.isImporting)
        XCTAssertTrue(draftAssets.isEmpty)
        await gate.release()
        await session.waitForPendingImports()
        XCTAssertTrue(session.canSave)
        XCTAssertEqual(draftAssets, [first, second])
    }

    func testEditorDismantleRejectsLateImportedAssetAndDiscardsOnlyThatCopy() async throws {
        let session = ReceiptImportSession()
        let gate = Gate()
        let started = expectation(description: "Owned copy is ready but delivery is suspended")
        let asset = AttachmentAsset(originalFilename: "owned.jpg", storedPath: "owned.jpg", sizeBytes: 1)
        let generation = UUID()
        var delivered: [AttachmentAsset] = [], discarded: [AttachmentAsset] = []
        session.start { operation in
            _ = try await ReceiptImportGenerationGuard.run(expected: generation, current: { generation }, importFile: {
                started.fulfill(); await gate.wait(); return asset
            }, discard: { discarded.append($0) }, receive: {
                try session.accept($0, for: operation); delivered.append($0)
            })
        }
        await fulfillment(of: [started], timeout: 5)
        var teardownNotifications = 0
        let subscription = session.objectWillChange.sink { teardownNotifications += 1 }
        ReceiptImportLifetimeAnchor.dismantleUIView(UIView(), coordinator: session)
        XCTAssertEqual(teardownNotifications, 0, "Teardown must not publish into the SwiftUI graph being destroyed")
        XCTAssertFalse(session.isAccepting, "Reject providers synchronously rather than on a later actor turn")
        XCTAssertNil(session.start { _ in XCTFail("A removed editor cannot start another import") })
        subscription.cancel()
        await gate.release()
        await session.waitForPendingImports()
        XCTAssertFalse(session.canSave)
        XCTAssertFalse(session.isImporting)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(discarded, [asset])
        XCTAssertNil(session.errorMessage)
    }

    func testRejectedDeliveryAlsoDiscardsItsOwnedCopyWithoutAppending() async throws {
        let session = ReceiptImportSession()
        session.cancel()
        let asset = AttachmentAsset(originalFilename: "late.jpg", storedPath: "late.jpg", sizeBytes: 1)
        let generation = UUID()
        var discarded = false, delivered = false
        do {
            _ = try await ReceiptImportGenerationGuard.run(expected: generation, current: { generation }, importFile: { asset },
                discard: { _ in discarded = true }, receive: { asset in
                    try session.accept(asset, for: UUID()); delivered = true
                })
            XCTFail("A closed editor cannot receive a late copy")
        } catch is CancellationError {}
        XCTAssertTrue(discarded)
        XCTAssertFalse(delivered)
    }

    func testCancelCleansOnlyThisEditorsUnreferencedImports() async throws {
        let (store, directory) = fixture()
        let source = directory.appendingPathComponent("source.bin")
        try Data([1, 2, 3]).write(to: source)
        let anotherEditorsAsset = try store.importAttachment(from: source)
        let session = ReceiptImportSession()
        session.configureDiscard { store.discardUnreferencedImportedAttachments($0) }
        var owned: AttachmentAsset?
        session.start { operation in
            _ = try await store.importAttachmentAsync(from: source) { asset in
                try session.accept(asset, for: operation); owned = asset
            }
        }
        await session.waitForPendingImports()
        let imported = try XCTUnwrap(owned)
        session.cancel()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.attachmentURL(for: imported).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.attachmentURL(for: anotherEditorsAsset).path))
        await store.waitForCloudKitSyncIdle()
    }

    func testCancelAfterFailedSavePreservesReceiptAcceptedIntoMemoryForRetry() async throws {
        let (store, directory) = fixture()
        let source = directory.appendingPathComponent("source.bin")
        try Data([1, 2, 3]).write(to: source)
        let row = try XCTUnwrap(store.data.transactions.first)
        let session = ReceiptImportSession()
        session.configureDiscard { store.discardUnreferencedImportedAttachments($0) }
        var owned: AttachmentAsset?
        session.start { operation in
            _ = try await store.importAttachmentAsync(from: source) { asset in
                try session.accept(asset, for: operation); owned = asset
            }
        }
        await session.waitForPendingImports()
        let asset = try XCTUnwrap(owned)
        let url = store.cloudKitSQLiteStore.databaseURL
        try SQLiteWriteAudit.execute("CREATE TRIGGER test_reject_editor_receipt BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'Synthetic disk failure'); END", at: url)
        var draft = store.draft(for: row); draft.attachments = [asset]
        let saved = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.transaction(row.id)?.attachment?.assets, [asset])
        session.cancel()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.attachmentURL(for: asset).path))
        try SQLiteWriteAudit.execute("DROP TRIGGER test_reject_editor_receipt", at: url)
        try await store.flushLocalChangesAsync()
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: url).loadData()?.transactions.first { $0.id == row.id }?.attachment?.assets, [asset])
        await store.waitForCloudKitSyncIdle()
    }

    func testSuccessfulSaveReleasesOwnedFilesThroughReferenceProtectedCleanupOnce() async throws {
        let session = ReceiptImportSession()
        let asset = AttachmentAsset(originalFilename: "saved.jpg", storedPath: "saved.jpg", sizeBytes: 1)
        var discarded: [AttachmentAsset] = []
        session.configureDiscard { discarded.append(contentsOf: $0) }
        session.start { try session.accept(asset, for: $0) }
        await session.waitForPendingImports()
        session.didCommit()
        session.cancel()
        XCTAssertEqual(discarded, [asset])
        XCTAssertFalse(session.canSave)
    }

    func testDuplicateSaveCleansUnusedFreshImportSourceAndKeepsSavedCopy() async throws {
        let (store, directory) = fixture()
        let source = directory.appendingPathComponent("source.bin")
        let bytes = Data([1, 2, 3]); try bytes.write(to: source)
        let row = try XCTUnwrap(store.data.transactions.first)
        let session = ReceiptImportSession()
        session.configureDiscard { store.discardUnreferencedImportedAttachments($0) }
        var draft = try XCTUnwrap(store.duplicateTransactionDraft(row.id, useToday: true))
        var imported: AttachmentAsset?
        session.start { operation in
            _ = try await store.importAttachmentAsync(from: source) { asset in
                try session.accept(asset, for: operation)
                imported = asset; draft.attachments.append(asset)
            }
        }
        await session.waitForPendingImports()
        let saved = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(saved)
        let originalImport = try XCTUnwrap(imported)
        let copy = try XCTUnwrap(store.transaction(draft.saveOperationID)?.attachment?.assets.first)
        XCTAssertNotEqual(originalImport.storedPath, copy.storedPath)
        session.didCommit()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.attachmentURL(for: originalImport).path))
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(for: copy)), bytes)
        await store.waitForCloudKitSyncIdle()
    }

    func testSuccessfulSaveCleansRemovedImportAndPreservesIncludedReceipt() async throws {
        let (store, directory) = fixture()
        let source = directory.appendingPathComponent("source.bin")
        let bytes = Data([1, 2, 3]); try bytes.write(to: source)
        let row = try XCTUnwrap(store.data.transactions.first)
        let session = ReceiptImportSession()
        session.configureDiscard { store.discardUnreferencedImportedAttachments($0) }
        var imported: [AttachmentAsset] = []
        session.start { operation in
            for _ in 0..<2 {
                _ = try await store.importAttachmentAsync(from: source) { asset in
                    try session.accept(asset, for: operation); imported.append(asset)
                }
            }
        }
        await session.waitForPendingImports()
        XCTAssertEqual(imported.count, 2)
        var draft = store.draft(for: row); draft.attachments = [imported[1]]
        let saved = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(saved)
        session.didCommit()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.attachmentURL(for: imported[0]).path))
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(for: imported[1])), bytes)
        XCTAssertEqual(store.transaction(row.id)?.attachment?.assets, [imported[1]])
    }

    func testContentRevisionObserversReceiveReplacementAndRestoreNotifications() {
        let revisions = ReceiptContentRevisions()
        var notifications = 0
        let subscription = revisions.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        revisions.didReplaceContents(of: [])
        XCTAssertEqual(notifications, 0)
        revisions.didReplaceContents(of: [UUID()])
        XCTAssertEqual(notifications, 1)
        revisions.invalidateAll()
        XCTAssertEqual(notifications, 2, "The same subscribed publisher must notify mounted receipt previews")
    }

    func testSameMetadataByteReplacementAndRestoreChangeThumbnailKeys() async {
        let revisions = ReceiptContentRevisions()
        let asset = AttachmentAsset(originalFilename: "same.jpg", storedPath: "same.jpg", sizeBytes: 123)
        let unrelated = UUID()
        func key(_ asset: AttachmentAsset) -> ReceiptThumbnailKey {
            ReceiptThumbnailKey(asset: asset, fileURL: URL(fileURLWithPath: "/tmp/" + asset.storedPath), contentVersion: revisions.version(for: asset.id))
        }
        let initial = key(asset)
        revisions.didReplaceContents(of: [unrelated])
        XCTAssertEqual(key(asset), initial, "Unrelated downloads must not regenerate this preview")
        revisions.didReplaceContents(of: [asset.id])
        let replaced = key(asset)
        XCTAssertNotEqual(replaced, initial, "Identical ID/path/name/size can have different file bytes")
        var metadataChanged = asset; metadataChanged.storedPath = "new.jpg"
        XCTAssertNotEqual(key(metadataChanged), replaced)
        revisions.invalidateAll()
        XCTAssertNotEqual(key(asset), replaced)
        let model = ReceiptThumbnailModel()
        var generations = 0
        await model.load(initial) { _ in generations += 1; return self.image(.red) }
        await model.load(replaced) { _ in generations += 1; return self.image(.blue) }
        XCTAssertEqual(generations, 2)
    }

    func testObsoleteThumbnailCannotPublishAfterContentVersionChanges() async {
        let revisions = ReceiptContentRevisions()
        let asset = AttachmentAsset(originalFilename: "same.jpg", storedPath: "same.jpg", sizeBytes: 123)
        let key = ReceiptThumbnailKey(asset: asset, fileURL: URL(fileURLWithPath: "/tmp/same.jpg"), contentVersion: revisions.version(for: asset.id))
        let model = ReceiptThumbnailModel()
        let gate = Gate()
        let started = expectation(description: "Old thumbnail started")
        let task = Task {
            await model.load(key, isCurrent: { revisions.version(for: $0.asset.id) == $0.contentVersion }) { _ in
                started.fulfill(); await gate.wait(); return self.image(.red)
            }
        }
        await fulfillment(of: [started], timeout: 5)
        revisions.didReplaceContents(of: [asset.id])
        await gate.release(); await task.value
        XCTAssertNil(model.image, "Reject obsolete bytes even before SwiftUI starts the replacement task")
    }

    func testLateThumbnailCannotOverwriteNewerImageAndFailureClearsOldImage() async {
        let revisions = ReceiptContentRevisions()
        let asset = AttachmentAsset(originalFilename: "same.jpg", storedPath: "same.jpg", sizeBytes: 123)
        let key = ReceiptThumbnailKey(asset: asset, fileURL: URL(fileURLWithPath: "/tmp/same.jpg"), contentVersion: revisions.version(for: asset.id))
        let model = ReceiptThumbnailModel()
        let gate = Gate()
        let started = expectation(description: "Old request started")
        let old = Task { await model.load(key) { _ in started.fulfill(); await gate.wait(); return self.image(.red) } }
        await fulfillment(of: [started], timeout: 5)
        let newer = image(.blue)
        await model.load(key) { _ in newer }
        await gate.release(); await old.value
        XCTAssertTrue(model.image === newer)
        await model.load(key) { _ in throw CocoaError(.fileReadNoSuchFile) }
        XCTAssertNil(model.image)
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }
}
