import XCTest
@testable import FinancesClone

@MainActor
final class SharedTransactionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for root in roots { try FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func fixture(emptyTransactions: Bool = false) async throws -> (MobileLedgerStore, SharedReceiptInbox, SharedReceiptEntry, SharedTransactionCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        let dependencies = CloudKitSyncDependencies(configuration: { nil }, makeClient: { _ in
            throw ValidationError(message: "Synthetic share never connects to CloudKit")
        }, automaticTriggersEnabled: false)
        var data = DemoData.fixture()
        if emptyTransactions { data.transactions = []; data.transactionTemplates = [] }
        let store = MobileLedgerStore(supportDirectory: root, initialData: data, cloudKitSyncDependencies: dependencies)
        let inbox = SharedReceiptInbox(directory: root.appendingPathComponent("ShareInbox"))
        let catalog = SharedTransactionCatalog(data: store.data, hiddenLedgerIDs: [])
        try await inbox.publishCatalog(catalog)
        let image = root.appendingPathComponent("Unsaved screenshot.png")
        try Data("Synthetic receipt bytes".utf8).write(to: image)
        let entry = try await inbox.stage([image], awaitsHandoff: true)
        try FileManager.default.removeItem(at: image)
        return (store, inbox, entry, catalog)
    }

    func testDefaultsToClearedAndCurrentInstantWithoutReadingReceiptMetadata() async throws {
        let (_, _, _, catalog) = try await fixture()
        let now = Date()
        let draft = SharedTransaction(catalog: catalog, now: now)
        XCTAssertEqual(draft.date, now)
        XCTAssertTrue(draft.cleared)
        XCTAssertEqual(draft.journalID, catalog.selectedJournalID)
    }

    func testSavePersistsCompleteDraftAndReceiptThenImportsExactlyOnce() async throws {
        let (store, inbox, entry, catalog) = try await fixture()
        let baseline = store.data.transactions.count
        var draft = SharedTransaction(catalog: catalog)
        draft.setAmount("-12.50", at: 0)
        draft.note = "Edited in screenshot view"; draft.payee = "Synthetic merchant"; draft.number = "INV-17"
        try await inbox.saveTransaction(draft, for: entry)
        try await inbox.saveTransaction(draft, for: entry)
        let saved = try await inbox.pendingEntries()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.transaction, draft)
        let router = SystemEntryRouter(receiptInbox: inbox, extensionReceiptInbox: nil, publishShortcutParameters: {})
        await router.restoreSharedReceipts(store: store)
        XCTAssertNil(router.error)
        XCTAssertTrue(router.requests.isEmpty, "Saved shares must not open a second editor")
        XCTAssertEqual(store.data.transactions.count, baseline + 1)
        let transaction = try XCTUnwrap(store.transaction(entry.id))
        XCTAssertEqual(transaction.note, draft.note)
        XCTAssertEqual(transaction.payee, draft.payee)
        XCTAssertEqual(transaction.number, draft.number)
        XCTAssertEqual(transaction.date, draft.date)
        XCTAssertTrue(transaction.cleared)
        let receipt = try XCTUnwrap(transaction.attachment?.assets.first)
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(for: receipt)), Data("Synthetic receipt bytes".utf8))
        await router.restoreSharedReceipts(store: store)
        XCTAssertEqual(store.data.transactions.count, baseline + 1)
        let pending = try await inbox.pendingEntries()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCancelOrAbandonedEditorDoesNotPublishTransaction() async throws {
        let (store, inbox, entry, _) = try await fixture()
        let pending = try await inbox.pendingEntries()
        XCTAssertTrue(pending.isEmpty)
        let baseline = store.data.transactions.count
        try await inbox.discard(entry.id)
        let router = SystemEntryRouter(receiptInbox: inbox, extensionReceiptInbox: nil, publishShortcutParameters: {})
        await router.restoreSharedReceipts(store: store)
        XCTAssertTrue(router.requests.isEmpty)
        XCTAssertEqual(store.data.transactions.count, baseline)
    }

    func testInvalidAndCrossJournalPostingsCannotBeSaved() async throws {
        let (_, inbox, entry, catalog) = try await fixture()
        var draft = SharedTransaction(catalog: catalog)
        XCTAssertThrowsError(try draft.validate(in: catalog))
        draft.setAmount("-9", at: 0)
        try draft.validate(in: catalog)
        draft.postings[1].accountID = UUID()
        do { try await inbox.saveTransaction(draft, for: entry); XCTFail("Invalid account was accepted") } catch {}
        let pending = try await inbox.pendingEntries()
        XCTAssertTrue(pending.isEmpty)
    }

    func testSaveRevalidatesLatestCatalogAndPreservesDraftOnFailure() async throws {
        let (_, inbox, entry, catalog) = try await fixture()
        var draft = SharedTransaction(catalog: catalog)
        draft.setAmount("-9", at: 0)
        var removed = catalog; removed.accounts.removeAll { $0.id == draft.postings[0].accountID }
        try await inbox.publishCatalog(removed)
        do { try await inbox.saveTransaction(draft, for: entry); XCTFail("Deleted account was accepted") } catch {}
        let files = try await inbox.fileURLs(for: entry)
        XCTAssertEqual(files.count, 1)
        try await inbox.publishCatalog(catalog)
        try await inbox.saveTransaction(draft, for: entry)
    }

    func testHiddenAndPasswordProtectedJournalsAreNotExposed() {
        var data = DemoData.fixture()
        let hidden = Set(data.ledgers.map(\.id))
        let catalog = SharedTransactionCatalog(data: data, hiddenLedgerIDs: hidden)
        XCTAssertTrue(catalog.journals.isEmpty); XCTAssertTrue(catalog.accounts.isEmpty)
        data.security = SecuritySettings(passwordHash: "synthetic", passwordSalt: "synthetic")
        let locked = SharedTransactionCatalog(data: data, hiddenLedgerIDs: [])
        XCTAssertTrue(locked.locked); XCTAssertTrue(locked.journals.isEmpty); XCTAssertTrue(locked.accounts.isEmpty)
    }

    func testRemovedAccountAtImportPreservesSavedEditsForReview() async throws {
        let (store, inbox, entry, catalog) = try await fixture(emptyTransactions: true)
        var draft = SharedTransaction(catalog: catalog)
        draft.setAmount("-19", at: 0); draft.note = "Keep these saved edits"
        try await inbox.saveTransaction(draft, for: entry)
        store.deleteAccount(try XCTUnwrap(draft.postings[0].accountID))
        let router = SystemEntryRouter(receiptInbox: inbox, extensionReceiptInbox: nil, publishShortcutParameters: {})
        await router.restoreSharedReceipts(store: store)
        XCTAssertNotNil(router.error)
        guard case .incoming(let request) = router.takeNext()?.destination else { return XCTFail("Expected a recoverable editor") }
        XCTAssertEqual(request.sharedTransaction, draft)
        XCTAssertEqual(request.receiptURLs.count, 1)
        XCTAssertNil(store.transaction(entry.id))
        let pending = try await inbox.pendingEntries()
        XCTAssertEqual(pending.first?.transaction, draft)
    }
}
