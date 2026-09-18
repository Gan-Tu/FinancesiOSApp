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

    func testPickerPreservesSectionsHierarchySiblingOrderAndDescriptions() throws {
        var data = DemoData.fixture()
        let journalID = try XCTUnwrap(data.selectedLedgerID)
        let root = try XCTUnwrap(data.accounts.first { $0.ledgerID == journalID && $0.kind == .asset && $0.isGroup })
        let bank = Account(ledgerID: journalID, parentID: root.id, commodityID: root.commodityID,
            name: "Bank", note: "Deposit accounts", kind: .asset, listIndex: 0)
        let savings = Account(ledgerID: journalID, parentID: bank.id, commodityID: root.commodityID,
            name: "Savings", kind: .asset, listIndex: 0)
        let reserve = Account(ledgerID: journalID, parentID: savings.id, commodityID: root.commodityID,
            name: "Reserve", kind: .asset, listIndex: 0)
        data.accounts += [reserve, bank, savings]
        data.accounts.reverse()
        let catalog = SharedTransactionCatalog(data: data, hiddenLedgerIDs: [])
        XCTAssertFalse(catalog.accounts.contains { $0.id == root.id }, "Root accounts are section headers")
        let assets = catalog.accountPickerNodes(journalID: journalID, kind: .asset)
        XCTAssertEqual(assets.map(\.account.name), ["Bank", "Savings", "Reserve", "Checking", "Cash"])
        XCTAssertEqual(assets.map(\.depth), [0, 1, 2, 0, 0])
        XCTAssertTrue(assets.allSatisfy { $0.account.ledgerID == journalID && $0.account.kind == .asset })
        XCTAssertEqual(assets.first?.account.note, "Deposit accounts")
        XCTAssertEqual(assets.first?.account.commodityID, root.commodityID)
        let expenses = catalog.accountPickerNodes(journalID: journalID, kind: .expense)
        XCTAssertEqual(expenses.map(\.account.name), ["Food & Dining", "Groceries", "Transportation"])
        XCTAssertEqual(expenses.map(\.depth), [0, 1, 0])
        XCTAssertEqual(expenses.map(\.account.colorName), ["blue", "blue", "orange"])
        let search = catalog.accountPickerNodes(journalID: journalID, kind: .expense, search: "pantry")
        XCTAssertEqual(search.map(\.account.name), ["Groceries"])
        XCTAssertEqual(search.map(\.depth), [1], "Search preserves the account's hierarchy depth")
        let income = catalog.accountPickerNodes(journalID: journalID, kind: .income)
        XCTAssertEqual(income.map(\.account.name), ["Salary"])
        XCTAssertEqual(income.first?.account.colorName, "green")
        XCTAssertTrue(catalog.accountPickerNodes(journalID: nil, kind: .expense).isEmpty)
    }

    func testPickerReadsLegacyCatalogWithoutNewPresentationFields() throws {
        let catalog = SharedTransactionCatalog(data: DemoData.fixture(), hiddenLedgerIDs: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any])
        json["accounts"] = try XCTUnwrap(json["accounts"] as? [[String: Any]]).map { row in
            var row = row
            for key in ["parentID", "colorName", "note", "listIndex"] { row.removeValue(forKey: key) }
            return row
        }
        let legacy = try JSONDecoder().decode(SharedTransactionCatalog.self, from: JSONSerialization.data(withJSONObject: json))
        let nodes = AccountKind.allCases.flatMap { legacy.accountPickerNodes(journalID: legacy.selectedJournalID, kind: $0) }
        XCTAssertEqual(nodes.count, legacy.accounts.filter { $0.journalID == legacy.selectedJournalID }.count)
        XCTAssertTrue(nodes.allSatisfy { $0.depth == 0 && $0.account.note.isEmpty })
        XCTAssertEqual(try JSONDecoder().decode(SharedTransactionCatalog.self, from: JSONEncoder().encode(catalog)), catalog)
    }

    func testSharedPickerCanSaveToParentAccountLikeTheNormalPicker() async throws {
        let (store, inbox, entry, catalog) = try await fixture()
        let food = try XCTUnwrap(catalog.accounts.first { $0.name == "Food & Dining" })
        var draft = SharedTransaction(catalog: catalog)
        XCTAssertEqual(catalog.accounts.first { $0.id == draft.postings[1].accountID }?.name, "Groceries",
            "The initial draft still defaults to a leaf account")
        draft.postings[1].accountID = food.id
        draft.setAmount("-12.50", at: 0)
        try await inbox.saveTransaction(draft, for: entry)
        let saved = try await inbox.pendingEntries()
        try await SharedTransactionImport.save(XCTUnwrap(saved.first), inbox: inbox, store: store)
        XCTAssertEqual(store.transaction(entry.id)?.postings.last?.accountID, food.id)
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

    func testSharedRepeatControlsSurviveImportIntoTheJournal() async throws {
        let (store, inbox, entry, catalog) = try await fixture()
        var draft = SharedTransaction(catalog: catalog)
        draft.setAmount("-15", at: 0)
        draft.recurrence = RecurrenceRule(frequency: .monthly, intervalValue: 2, occurrenceCount: 3, onWorkdays: true)
        try await inbox.saveTransaction(draft, for: entry)
        let saved = try await inbox.pendingEntries()
        try await SharedTransactionImport.save(XCTUnwrap(saved.first), inbox: inbox, store: store)
        let rule = try XCTUnwrap(store.transaction(entry.id)?.recurrenceRule)
        XCTAssertEqual(rule.frequency, .monthly); XCTAssertEqual(rule.intervalValue, 2)
        XCTAssertEqual(rule.occurrenceCount, 3); XCTAssertTrue(rule.onWorkdays)
    }
}
