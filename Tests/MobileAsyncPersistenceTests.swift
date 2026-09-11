import Foundation
import SQLite3
import XCTest
@testable import FinancesClone

@MainActor
final class MobileAsyncPersistenceTests: XCTestCase {
    private var fixtureStores: [MobileLedgerStore] = []
    private var fixtureDirectories: [URL] = []

    override func tearDown() async throws {
        // An explicit writer barrier precedes release. Releasing every retained
        // store makes remaining status callbacks inert, then a final static
        // barrier closes any already-enqueued SQLite connection before unlink.
        for store in fixtureStores { await store.waitForCloudKitSyncIdle() }
        fixtureStores.removeAll()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for directory in fixtureDirectories { try FileManager.default.removeItem(at: directory) }
        fixtureDirectories.removeAll()
        try await super.tearDown()
    }

    func testAsyncSaveKeepsMainActorResponsiveAndDoesNotOverwriteLaterEdits() async throws {
        let f = try fixture()
        let original = try XCTUnwrap(f.store.data.transactions.first)
        await f.store.waitForCloudKitSyncIdle()
        let lock = try AsyncPersistenceTestLock(url: f.url)
        defer { lock.release() }
        var draft = f.store.draft(for: original)
        draft.note = "Saved asynchronously"
        var saveFinished = false
        let task = Task { let result = await f.store.saveTransactionAndFlushAsync(draft); saveFinished = true; return result }
        for _ in 0..<100 where f.store.transaction(original.id)?.note != draft.note {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(lock.isHeld)
        XCTAssertFalse(saveFinished, "Durable Save must wait for the SQLite transaction")
        XCTAssertEqual(f.store.transaction(original.id)?.note, draft.note, "UI state is published before disk completion")
        f.store.setTransactionCleared(original.id, cleared: !original.cleared)
        lock.release()
        let savedSuccessfully = await task.value
        XCTAssertTrue(savedSuccessfully)
        try await f.store.flushLocalChangesAsync()
        let saved = try XCTUnwrap(SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.first { $0.id == original.id })
        XCTAssertEqual(saved.note, draft.note)
        XCTAssertEqual(saved.cleared, !original.cleared)
        XCTAssertEqual(f.store.transaction(original.id), saved)
    }

    func testBackgroundTransitionQueuesDurableSnapshotWithoutBlockingAndResumesLatestState() async throws {
        let f = try fixture()
        let sceneID = UUID()
        f.store.setSceneActive(true, sceneID: sceneID)
        let row = try XCTUnwrap(f.store.data.transactions.first)
        await f.store.waitForCloudKitSyncIdle()
        let lock = try AsyncPersistenceTestLock(url: f.url)
        defer { lock.release() }
        // A broken synchronous transition can still finish and fail assertions
        // instead of stalling the test for SQLite's full busy timeout.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) { lock.release() }
        var draft = f.store.draft(for: row)
        draft.note = "Accepted before background"
        f.store.saveTransaction(draft)
        f.store.setSceneActive(false, sceneID: sceneID)
        XCTAssertTrue(lock.isHeld, "Scene transition must return before the blocked SQLite writer")
        XCTAssertEqual(f.store.transaction(row.id)?.note, draft.note)
        lock.release()
        await f.store.waitForCloudKitSyncIdle()
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.first { $0.id == row.id }?.note, draft.note)
        f.store.setSceneActive(true, sceneID: sceneID)
        draft.note = "Newer foreground edit"
        f.store.saveTransaction(draft)
        f.store.setSceneActive(false, sceneID: sceneID)
        await f.store.waitForCloudKitSyncIdle()
        XCTAssertEqual(f.store.transaction(row.id)?.note, draft.note)
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.first { $0.id == row.id }?.note, draft.note)
    }

    func testAsyncFlushReportsPreflightFailureWithoutTouchingUnreadableDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "UnreadableAsyncWriteTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixtureDirectories.append(directory)
        let url = directory.appending(path: "journal.sqlite")
        let original = Data("Unreadable synthetic journal".utf8)
        try original.write(to: url)
        let store = MobileLedgerStore(supportDirectory: directory)
        fixtureStores.append(store)
        XCTAssertTrue(store.requiresJournalRecovery)
        store.validationError = nil
        do { try await store.flushLocalChangesAsync(); XCTFail("Expected recovery preflight failure") }
        catch { XCTAssertNotNil(store.validationError) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testNewDraftDiskFailureRetriesSameTransactionAndOutboxIdentity() async throws {
        let f = try fixture()
        var draft = f.store.draft(for: try XCTUnwrap(f.store.data.transactions.first))
        draft.id = nil
        draft.note = "Retry only once"
        draft.postings = draft.postings.map { var copy = $0; copy.id = UUID(); return copy }
        let count = f.store.data.transactions.count
        try await rejectOutbox(for: f.store)
        let failedSave = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertFalse(failedSave)
        XCTAssertNotNil(f.store.validationError)
        XCTAssertNotNil(f.store.localPersistenceError)
        f.store.validationError = nil
        XCTAssertNotNil(f.store.localPersistenceError, "Another screen cannot erase a pending disk failure")
        XCTAssertEqual(f.store.data.transactions.count, count + 1)
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.count, count)
        try await allowOutbox(for: f.store)
        draft.note = "Retried with more notes"
        let successfulSave = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(successfulSave)
        XCTAssertNil(f.store.validationError)
        XCTAssertNil(f.store.localPersistenceError)
        XCTAssertEqual(f.store.data.transactions.count, count + 1)
        let saved = try XCTUnwrap(SQLiteJournalStore(databaseURL: f.url).loadData())
        XCTAssertEqual(saved.transactions.count, count + 1)
        XCTAssertEqual(saved.transactions.first { $0.id == draft.saveOperationID }?.note, draft.note)
        let versions = try SQLiteJournalStore(databaseURL: f.url).claimPendingSyncChanges(limit: 1_000).filter { $0.recordID == draft.saveOperationID.uuidString }
        XCTAssertEqual(versions.count, 1)
    }

    func testDuplicateReceiptCopySurvivesDiskFailureAndIsReusedOnRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MobileDuplicateWriteTests-\(UUID())")
        let attachments = directory.appending(path: "Attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        fixtureDirectories.append(directory)
        let bytes = Data(repeating: 73, count: 1_024 * 1_024)
        try bytes.write(to: attachments.appending(path: "original.bin"))
        var data = DemoData.fixture()
        let originalAsset = AttachmentAsset(originalFilename: "original.bin", storedPath: "Attachments/original.bin", mimeType: "application/octet-stream", sizeBytes: Int64(bytes.count))
        data.transactions[0].attachment = AttachmentContainer(assets: [originalAsset])
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        fixtureStores.append(store)
        let url = store.cloudKitSQLiteStore.databaseURL
        var draft = try XCTUnwrap(store.duplicateTransactionDraft(data.transactions[0].id, useToday: true))
        try await rejectOutbox(for: store)
        let first = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertFalse(first)
        let copied = try XCTUnwrap(store.transaction(draft.saveOperationID)?.attachment?.assets.first)
        XCTAssertNotEqual(copied.id, originalAsset.id)
        XCTAssertNotEqual(copied.storedPath, originalAsset.storedPath)
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(for: copied)), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: attachments.path).count, 2)
        try await allowOutbox(for: store)
        draft.note = "Retried duplicate"
        let second = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(second)
        XCTAssertEqual(store.transaction(draft.saveOperationID)?.attachment?.assets, [copied])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: attachments.path).count, 2)
        let reloaded = try XCTUnwrap(SQLiteJournalStore(databaseURL: url).loadData())
        XCTAssertEqual(reloaded.transactions.count, data.transactions.count + 1)
        XCTAssertEqual(reloaded.transactions.first { $0.id == draft.saveOperationID }?.attachment?.assets, [copied])
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(for: originalAsset)), bytes)
    }

    func testDuplicateReceiptIdentifiersFailBeforeAnyCopyOrMutation() async throws {
        let f = try fixture()
        let row = try XCTUnwrap(f.store.data.transactions.first)
        var draft = try XCTUnwrap(f.store.duplicateTransactionDraft(row.id, useToday: true))
        let asset = AttachmentAsset(originalFilename: "missing.bin", storedPath: "Attachments/missing.bin", mimeType: nil, sizeBytes: 0)
        draft.attachments = [asset, asset]
        let count = f.store.data.transactions.count
        let result = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertFalse(result)
        XCTAssertTrue(f.store.validationError?.message.contains("duplicate receipt identifiers") == true)
        XCTAssertEqual(f.store.data.transactions.count, count)
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.count, count)
        XCTAssertNil(f.store.transaction(draft.saveOperationID))
    }

    func testPersistenceOutcomesIgnoreOlderFailureAfterNewerSuccess() {
        var outcomes = MobilePersistenceOutcomeState()
        let failure = ValidationError(message: "First disk failure")
        XCTAssertTrue(outcomes.record(sequence: 1, error: failure))
        XCTAssertEqual(outcomes.error?.id, failure.id)
        XCTAssertTrue(outcomes.record(sequence: 3, error: nil))
        XCTAssertFalse(outcomes.record(sequence: 2, error: ValidationError(message: "Late older failure")))
        XCTAssertEqual(outcomes.sequence, 3)
        XCTAssertNil(outcomes.error)
        XCTAssertTrue(outcomes.record(sequence: 4, error: failure))
        XCTAssertEqual(outcomes.error?.id, failure.id)
    }

    func testReceiptFreeDuplicateCanAddReceiptAfterFailedSave() async throws {
        let f = try fixture()
        let original = try XCTUnwrap(f.store.data.transactions.first)
        XCTAssertNil(original.attachment)
        var draft = try XCTUnwrap(f.store.duplicateTransactionDraft(original.id, useToday: false))
        let count = f.store.data.transactions.count
        try await rejectOutbox(for: f.store)
        let first = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertFalse(first)
        let input = f.url.deletingLastPathComponent().appending(path: "late-receipt.txt")
        try Data("Receipt added while retrying".utf8).write(to: input)
        let asset = try f.store.importAttachment(from: input)
        draft.attachments = [asset]
        try await allowOutbox(for: f.store)
        let retried = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(retried)
        XCTAssertNil(f.store.validationError)
        XCTAssertEqual(f.store.data.transactions.count, count + 1)
        let saved = try XCTUnwrap(SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.first { $0.id == draft.saveOperationID })
        XCTAssertEqual(saved.attachment?.assets, [asset])
        XCTAssertEqual(try Data(contentsOf: f.store.attachmentURL(for: asset)), Data("Receipt added while retrying".utf8))
    }

    func testAsyncDeleteFailureCanRetryWithoutResurrectingRow() async throws {
        let f = try fixture()
        let row = try XCTUnwrap(f.store.data.transactions.first)
        try await rejectOutbox(for: f.store)
        let failedDelete = await f.store.deleteTransactionAsync(row.id, expected: row)
        XCTAssertFalse(failedDelete)
        XCTAssertNil(f.store.transaction(row.id))
        XCTAssertNotNil(try SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.first { $0.id == row.id })
        try await allowOutbox(for: f.store)
        let successfulDelete = await f.store.deleteTransactionAsync(row.id, expected: row)
        XCTAssertTrue(successfulDelete)
        XCTAssertNil(f.store.validationError)
        XCTAssertNil(try SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.first { $0.id == row.id })
        XCTAssertTrue(try SQLiteJournalStore(databaseURL: f.url).deletedTransactionIDs().contains(row.id))
    }

    func testConcurrentSaveAndCancelledCallerHaveOneDurableOutcome() async throws {
        let f = try fixture()
        var draft = f.store.draft(for: try XCTUnwrap(f.store.data.transactions.first))
        draft.id = nil
        draft.postings = draft.postings.map { var copy = $0; copy.id = UUID(); return copy }
        let count = f.store.data.transactions.count
        let first = Task { await f.store.saveTransactionAndFlushAsync(draft) }
        let second = Task { await f.store.saveTransactionAndFlushAsync(draft) }
        first.cancel()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(f.store.data.transactions.count, count + 1)
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.count, count + 1)
    }

    func testExplicitFlushSealsOlderDeferredBatchBeforeLaterEdits() async throws {
        let f = try fixture()
        let row = try XCTUnwrap(f.store.data.transactions.first)
        await f.store.waitForCloudKitSyncIdle()
        let lock = try AsyncPersistenceTestLock(url: f.url)
        defer { lock.release() }
        var first = f.store.draft(for: row); first.note = "First pending"
        f.store.saveTransaction(first)
        var atBarrier = first; atBarrier.note = "Durable barrier"
        f.store.saveTransaction(atBarrier)
        var barrierStarted = false
        let barrier = Task { barrierStarted = true; try await f.store.flushLocalChangesAsync() }
        while !barrierStarted { await Task.yield() }
        var last = first; last.note = "Latest after barrier"
        f.store.saveTransaction(last)
        lock.release()
        try await barrier.value
        try await f.store.flushLocalChangesAsync()
        XCTAssertEqual(f.store.transaction(row.id)?.note, last.note)
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.first { $0.id == row.id }?.note, last.note)
        // The synchronous API is also a seal and shares the committed baseline.
        f.store.setTransactionCleared(row.id, cleared: !row.cleared)
        try f.store.flushLocalChanges()
        try await f.store.flushLocalChangesAsync()
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: f.url).loadData()?.transactions.first { $0.id == row.id }?.cleared, !row.cleared)
    }

    func testMetadataCreateIdentitiesSurviveFailedDurableSaveRetries() async throws {
        let f = try fixture()
        let ledgerID = try XCTUnwrap(f.store.selectedLedgerID)
        let original = f.store.data
        var account = f.store.newAccountDraft(ledgerID: ledgerID)
        account.name = "New retry account"
        try await rejectOutbox(for: f.store)
        account.id = try XCTUnwrap(f.store.saveAccount(account))
        await expectFlushFailure(f.store)
        XCTAssertEqual(f.store.data.accounts.count, original.accounts.count + 1)
        try await allowOutbox(for: f.store)
        account.name = "Renamed after failed save"
        XCTAssertEqual(f.store.saveAccount(account), account.id)
        try await f.store.flushLocalChangesAsync()
        XCTAssertEqual(f.store.data.accounts.count, original.accounts.count + 1)

        var currency = f.store.newCurrencyDraft(ledgerID: ledgerID)
        currency.symbol = "ZZZ"; currency.name = "Retry currency"
        try await rejectOutbox(for: f.store)
        currency.id = try XCTUnwrap(f.store.saveCurrency(currency))
        await expectFlushFailure(f.store)
        try await allowOutbox(for: f.store)
        currency.name = "Renamed retry currency"
        XCTAssertEqual(f.store.saveCurrency(currency), currency.id)
        try await f.store.flushLocalChangesAsync()
        XCTAssertEqual(f.store.data.commodities.count, original.commodities.count + 1)

        var template = TransactionTemplateDraft(ledgerID: ledgerID, name: "Retry template")
        try await rejectOutbox(for: f.store)
        template.id = try XCTUnwrap(f.store.saveTransactionTemplate(template))
        await expectFlushFailure(f.store)
        try await allowOutbox(for: f.store)
        template.name = "Renamed retry template"
        XCTAssertEqual(f.store.saveTransactionTemplate(template), template.id)
        try await f.store.flushLocalChangesAsync()
        XCTAssertEqual(f.store.data.transactionTemplates.count, original.transactionTemplates.count + 1)
        let reloaded = try XCTUnwrap(SQLiteJournalStore(databaseURL: f.url).loadData())
        XCTAssertEqual(reloaded.accounts.first { $0.id == account.id }?.name, account.name)
        XCTAssertEqual(reloaded.commodities.first { $0.id == currency.id }?.name, currency.name)
        XCTAssertEqual(reloaded.transactionTemplates.first { $0.id == template.id }?.name, template.name)
    }

    func testNewJournalRetryRenamesCapturedIdentityWithoutReseedingAccounts() async throws {
        let f = try fixture()
        let count = f.store.data.ledgers.count
        try await rejectOutbox(for: f.store)
        let createdID = try XCTUnwrap(f.store.addJournal(name: "Retry journal"))
        let createdAccounts = f.store.data.accounts.count
        let createdTemplates = f.store.data.transactionTemplates.count
        await expectFlushFailure(f.store)
        try await allowOutbox(for: f.store)
        f.store.renameJournal(createdID, name: "Retried journal")
        try await f.store.flushLocalChangesAsync()
        let reloaded = try XCTUnwrap(SQLiteJournalStore(databaseURL: f.url).loadData())
        XCTAssertEqual(reloaded.ledgers.count, count + 1)
        XCTAssertEqual(reloaded.ledgers.first { $0.id == createdID }?.name, "Retried journal")
        XCTAssertEqual(reloaded.accounts.count, createdAccounts)
        XCTAssertEqual(reloaded.transactionTemplates.count, createdTemplates)
    }

    private func expectFlushFailure(_ store: MobileLedgerStore) async {
        do { try await store.flushLocalChangesAsync(); XCTFail("Expected injected durable failure") }
        catch { XCTAssertNotNil(store.localPersistenceError) }
    }

    func testDeferredBatchNeverCrossesTrackSyncChangesBoundaryOrSeal() {
        let initial = MobileDeferredPersistenceBatch.Request(snapshot: JournalData(), sequence: 1, trackSyncChanges: true, validateSnapshot: false, scheduleCloudAfterSuccess: false, refreshCloudStateAfterSuccess: false)
        let batch = MobileDeferredPersistenceBatch(initial)
        var latest = initial; latest.sequence = 2; latest.validateSnapshot = true
        XCTAssertTrue(batch.replacePending(with: latest))
        var localOnly = latest; localOnly.trackSyncChanges = false
        XCTAssertFalse(batch.replacePending(with: localOnly))
        batch.seal()
        XCTAssertFalse(batch.replacePending(with: latest))
        XCTAssertEqual(batch.take().sequence, 2)
        XCTAssertTrue(batch.take().validateSnapshot)
        XCTAssertTrue(batch.take().trackSyncChanges)
    }

    private func rejectOutbox(for store: MobileLedgerStore) async throws {
        await store.waitForCloudKitSyncIdle()
        try SQLiteWriteAudit.execute("CREATE TRIGGER test_reject_async_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'Synthetic disk failure'); END", at: store.cloudKitSQLiteStore.databaseURL)
    }

    private func allowOutbox(for store: MobileLedgerStore) async throws {
        // Do not change failure injection while an earlier save is still
        // executing. No retry or timeout adjustment is made to the writer.
        await store.waitForCloudKitSyncIdle()
        try SQLiteWriteAudit.execute("DROP TRIGGER test_reject_async_outbox", at: store.cloudKitSQLiteStore.databaseURL)
    }

    private func fixture() throws -> (store: MobileLedgerStore, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MobileAsyncWriteTests-\(UUID())")
        var dependencies = CloudKitSyncDependencies.live
        dependencies.automaticTriggersEnabled = false
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.fixture(referenceDate: Date(timeIntervalSince1970: 1_800_000_000)), cloudKitSyncDependencies: dependencies)
        fixtureDirectories.append(directory)
        fixtureStores.append(store)
        XCTAssertNil(store.validationError)
        return (store, directory.appending(path: "journal.sqlite"))
    }
}

private final class AsyncPersistenceTestLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var database: OpaquePointer?
    var isHeld: Bool { mutex.lock(); defer { mutex.unlock() }; return database != nil }
    init(url: URL) throws {
        // Contention while acquiring the synthetic lock is fixture setup, not
        // the responsiveness interval. Match production's bounded busy policy;
        // all assertions still run while this connection actually holds it.
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              sqlite3_busy_timeout(database, 8_000) == SQLITE_OK,
              sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw SQLiteJournalStoreError.openFailed("Async persistence lock fixture")
        }
    }
    func release() {
        mutex.lock(); defer { mutex.unlock() }
        guard let database else { return }
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        sqlite3_close(database)
        self.database = nil
    }
}
