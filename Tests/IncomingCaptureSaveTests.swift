import XCTest
@testable import FinancesClone

@MainActor
final class IncomingCaptureSaveTests: XCTestCase {
    private var stores: [MobileLedgerStore] = []
    private var directories: [URL] = []
    override func tearDown() async throws {
        for store in stores { await store.waitForCloudKitSyncIdle() }
        stores.removeAll()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func makeStore(_ directory: URL, initialData: JournalData? = nil) -> MobileLedgerStore {
        let dependencies = CloudKitSyncDependencies(configuration: { nil }, makeClient: { _ in
            throw ValidationError(message: "Synthetic captures never connect to CloudKit.")
        }, automaticTriggersEnabled: false)
        let store = MobileLedgerStore(supportDirectory: directory, initialData: initialData, cloudKitSyncDependencies: dependencies)
        stores.append(store)
        return store
    }

    private func fixture() throws -> (MobileLedgerStore, URL, IncomingTransactionRequest) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(root)
        let store = makeStore(root, initialData: DemoData.fixture())
        let suggestion = CaptureSuggestion(source: .applePay, date: Date(timeIntervalSince1970: 1_788_858_000), amount: 12,
            currencyCode: "USD", merchant: "Synthetic purchase", card: "", note: "original", journalID: store.selectedLedgerID)
        return (store, root, IncomingTransactionRequest(suggestion: suggestion))
    }

    func testStaleCaptureCannotOverwriteCommittedNotesAmountsOrReceiptsEvenAfterReopen() async throws {
        let (store, root, request) = try fixture()
        var corrected = IncomingTransactionDraftFactory.make(request: request, store: store)
        let stale = IncomingTransactionDraftFactory.make(request: request, store: store)
        XCTAssertEqual(corrected.saveOperationID, stale.saveOperationID)
        XCTAssertNotEqual(corrected.incomingEditorSessionID, stale.incomingEditorSessionID)
        corrected.payee = "Corrected merchant"; corrected.note = "User's corrected notes"
        corrected.postings[0].amount = "-23.45"; corrected.postings[1].amount = "23.45"
        let receiptURL = root.appendingPathComponent("synthetic-receipt.txt")
        try Data("Synthetic retained receipt".utf8).write(to: receiptURL)
        corrected.attachments = [try store.importAttachment(from: receiptURL)]
        let saved = await store.saveTransactionAndFlushAsync(corrected)
        XCTAssertTrue(saved, store.validationError?.message ?? "")
        let committed = try XCTUnwrap(store.transaction(corrected.saveOperationID))
        let staleSave = await store.saveTransactionAndFlushAsync(stale)
        XCTAssertFalse(staleSave)
        XCTAssertEqual(store.transaction(committed.id), committed)
        XCTAssertTrue(store.validationError?.message.contains("already saved") == true)

        let persisted = try XCTUnwrap(store.cloudKitSQLiteStore.loadData()?.transactions.first { $0.id == committed.id })
        let reopened = makeStore(root)
        let staleAfterReopen = await reopened.saveTransactionAndFlushAsync(stale)
        XCTAssertFalse(staleAfterReopen)
        XCTAssertEqual(reopened.transaction(committed.id), persisted)
        XCTAssertEqual(try Data(contentsOf: reopened.attachmentURL(for: XCTUnwrap(committed.attachment?.assets.first))), Data("Synthetic retained receipt".utf8))
    }

    func testIncomingCaptureRemainsCreateOnceWhenPersistenceBaselineWasInvalidated() async throws {
        let (store, _, request) = try fixture()
        let initial = IncomingTransactionDraftFactory.make(request: request, store: store)
        var stale = IncomingTransactionDraftFactory.make(request: request, store: store)
        stale.note = "Must not replace the committed note"
        let saved = await store.saveTransactionAndFlushAsync(initial)
        XCTAssertTrue(saved)
        let original = try XCTUnwrap(store.transaction(initial.saveOperationID))
        try SQLiteWriteAudit.execute("CREATE TRIGGER reject_other_change BEFORE INSERT ON transactions BEGIN SELECT RAISE(ABORT, 'Synthetic unrelated failure'); END; CREATE TRIGGER reject_other_update BEFORE UPDATE ON transactions BEGIN SELECT RAISE(ABORT, 'Synthetic unrelated failure'); END", at: store.cloudKitSQLiteStore.databaseURL)
        let other = try XCTUnwrap(store.data.transactions.first { $0.id != original.id })
        store.setTransactionCleared(other.id, cleared: !other.cleared)
        do { try await store.flushLocalChangesAsync(); XCTFail("Expected the unrelated write to fail") } catch {}
        try SQLiteWriteAudit.execute("DROP TRIGGER reject_other_change; DROP TRIGGER reject_other_update", at: store.cloudKitSQLiteStore.databaseURL)
        let staleSave = await store.saveTransactionAndFlushAsync(stale)
        XCTAssertFalse(staleSave)
        XCTAssertEqual(store.transaction(original.id), original)
        try await store.flushLocalChangesAsync()
    }

    func testStaleCaptureCannotRecreateAnIntentionallyDeletedConversion() async throws {
        let (store, root, request) = try fixture()
        let initial = IncomingTransactionDraftFactory.make(request: request, store: store)
        let stale = IncomingTransactionDraftFactory.make(request: request, store: store)
        let saved = await store.saveTransactionAndFlushAsync(initial)
        XCTAssertTrue(saved)
        store.deleteTransaction(initial.saveOperationID)
        try await store.flushLocalChangesAsync()
        XCTAssertTrue(try store.cloudKitSQLiteStore.hasRecordedTransaction(initial.saveOperationID))
        let reopened = makeStore(root)
        let recreated = await reopened.saveTransactionAndFlushAsync(stale)
        XCTAssertFalse(recreated)
        XCTAssertNil(reopened.transaction(initial.saveOperationID))
    }

    func testConcurrentCaptureEditorsDoNotReportTwoSuccessfulSaves() async throws {
        let (store, _, request) = try fixture()
        var first = IncomingTransactionDraftFactory.make(request: request, store: store)
        var second = IncomingTransactionDraftFactory.make(request: request, store: store)
        first.note = "First editor"; second.note = "Second editor"
        let firstTask = Task { await store.saveTransactionAndFlushAsync(first) }
        let secondTask = Task { await store.saveTransactionAndFlushAsync(second) }
        let results = [await firstTask.value, await secondTask.value]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(store.transaction(first.saveOperationID)?.note, results[0] ? first.note : second.note)
        XCTAssertEqual(store.data.transactions.filter { $0.id == first.saveOperationID }.count, 1)
    }
}
