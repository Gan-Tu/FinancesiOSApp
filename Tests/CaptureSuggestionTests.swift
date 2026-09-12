import XCTest
@testable import FinancesClone

@MainActor
final class CaptureSuggestionTests: XCTestCase {
    private var stores: [MobileLedgerStore] = []
    private var storeDirectories: [URL] = []
    override func tearDown() async throws {
        for store in stores { await store.waitForCloudKitSyncIdle() }
        stores.removeAll()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for directory in storeDirectories { try FileManager.default.removeItem(at: directory) }
        storeDirectories.removeAll()
        try await super.tearDown()
    }
    private func suggestion(amount: Decimal = Decimal(string: "12.34")!, currency: String = "USD") -> CaptureSuggestion {
        .init(source: .applePay, date: Date(timeIntervalSince1970: 1_788_858_000), amount: amount,
            currencyCode: currency, merchant: "Test Merchant", card: "Test Card", note: "", journalID: nil)
    }

    func testInboxPersistsDecimalCurrencyAndIndependentCapturesAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CaptureSuggestionRepository(directory: directory)
        let first = suggestion()
        var second = first; second.id = UUID(); second.currencyCode = "EUR"
        try await repository.add(first)
        try await repository.add(first)
        try await repository.add(second)
        let reopened = CaptureSuggestionRepository(directory: directory)
        let saved = try await reopened.all()
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(Set(saved.map(\.currencyCode)), ["USD", "EUR"])
        XCTAssertEqual(saved.first?.amount, Decimal(string: "12.34"))
        try await reopened.remove(first.id)
        let remaining = try await repository.all()
        XCTAssertEqual(remaining.map(\.id), [second.id])
    }

    func testInvalidCapturedMoneyIsRejectedBeforeWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CaptureSuggestionRepository(directory: directory)
        for value in [suggestion(amount: -1), suggestion(amount: 0), suggestion(currency: ""), suggestion(currency: "$"), suggestion(amount: .nan)] {
            do { try await repository.add(value); XCTFail("Invalid amount/currency accepted") }
            catch { XCTAssertTrue(error is ValidationError) }
        }
        let saved = try await repository.all()
        XCTAssertTrue(saved.isEmpty)
    }

    @MainActor
    func testIncomingDraftPreservesAmountDateAndRequiresUnknownCardSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storeDirectories.append(directory)
        let dependencies = CloudKitSyncDependencies(configuration: { nil }, makeClient: { _ in
            throw ValidationError(message: "Synthetic captures never connect to CloudKit.")
        }, automaticTriggersEnabled: false)
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.fixture(), cloudKitSyncDependencies: dependencies)
        stores.append(store)
        let capture = suggestion()
        let original = store.data
        let request = IncomingTransactionRequest(suggestion: capture)
        let draft = IncomingTransactionDraftFactory.make(request: request, store: store)
        XCTAssertEqual(draft.saveOperationID, capture.id)
        XCTAssertEqual(draft.payee, capture.merchant)
        XCTAssertEqual(draft.date, capture.date)
        XCTAssertFalse(draft.cleared)
        XCTAssertEqual(decimalFromInput(draft.postings[0].amount), -capture.amount!)
        XCTAssertEqual(decimalFromInput(draft.postings[1].amount), capture.amount)
        XCTAssertNil(draft.postings[0].accountID, "An unknown Wallet card must not silently charge a different account")
        XCTAssertEqual(store.data.transactions, original.transactions, "Opening a capture must not post a transaction")
        let hidden = JournalVisibility(rawValue: store.data.ledgers.map { $0.id.uuidString }.joined(separator: ","))
        let hiddenDraft = IncomingTransactionDraftFactory.make(request: request, store: store, visibility: hidden)
        XCTAssertNil(hiddenDraft.ledgerID)
        XCTAssertTrue(hiddenDraft.postings.allSatisfy { $0.accountID == nil }, "A nil choice must not fall back to hidden journal accounts")
        try await store.flushLocalChangesAsync()
    }

    @MainActor
    func testRouterRetainsSeparateIncomingActionsUntilConsumed() {
        let router = SystemEntryRouter()
        let templateID = UUID()
        router.openTemplate(templateID)
        router.openNewTransaction(suggestion())
        router.openSuggestions()
        XCTAssertEqual(router.requests.count, 3)
        guard case .template(let id) = router.takeNext()?.destination else { return XCTFail("First entry was replaced") }
        XCTAssertEqual(id, templateID)
        guard case .incoming = router.takeNext()?.destination else { return XCTFail("Draft was lost") }
        guard case .suggestions = router.takeNext()?.destination else { return XCTFail("Suggestions route was lost") }
        XCTAssertNil(router.takeNext())
    }

    func testReceiptDraftDefaultsToFundingCurrencyWhileWalletKeepsExplicitCurrency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storeDirectories.append(directory)
        var data = DemoData.fixture()
        data.transactions = []
        let ledgerID = data.ledgers[0].id
        let euros = Commodity(ledgerID: ledgerID, symbol: "EUR", name: "Euro")
        data.commodities.append(euros)
        for index in data.accounts.indices where data.accounts[index].ledgerID == ledgerID && data.accounts[index].kind == .asset {
            data.accounts[index].commodityID = euros.id
        }
        var dependencies = CloudKitSyncDependencies.live; dependencies.automaticTriggersEnabled = false
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data, cloudKitSyncDependencies: dependencies)
        stores.append(store)
        let receipt = IncomingTransactionDraftFactory.make(request: .init(), store: store)
        XCTAssertEqual(receipt.postings.map(\.commodityID), [euros.id, euros.id])
        let wallet = IncomingTransactionDraftFactory.make(request: .init(suggestion: suggestion()), store: store)
        let dollars = try XCTUnwrap(data.commodities.first { $0.ledgerID == ledgerID && $0.symbol == "USD" })
        XCTAssertEqual(wallet.postings.map(\.commodityID), [dollars.id, dollars.id])
    }

    @MainActor
    func testNestedEditorLeaseKeepsIncomingRequestQueued() {
        let router = SystemEntryRouter()
        let editorID = UUID()
        router.beginEditor(editorID)
        router.openNewTransaction(suggestion())
        XCTAssertNil(router.takeNext())
        XCTAssertEqual(router.requests.count, 1)
        router.endEditor(editorID)
        XCTAssertNotNil(router.takeNext())
    }

    @MainActor
    func testConcurrentReceiptDeliveryQueuesOneDraftAndLateDeliveryStaysDismissed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("synthetic.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1kAAAAASUVORK5CYII=")!.write(to: image)
        let inbox = SharedReceiptInbox(directory: directory.appendingPathComponent("inbox"))
        let entry = try await inbox.stage([image])
        let router = SystemEntryRouter(receiptInbox: inbox)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await router.openSharedReceipt(entry) } }
            try await group.waitForAll()
        }
        XCTAssertEqual(router.requests.count, 1)
        _ = router.takeNext()
        router.finishSharedReceipt(entry.id)
        try await router.openSharedReceipt(entry)
        XCTAssertTrue(router.requests.isEmpty)
        try await inbox.discard(entry.id)
    }

    @MainActor
    func testFailedPostingKeepsDurableSuggestionUntilSuccessfulRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storeDirectories.append(directory)
        let repository = CaptureSuggestionRepository(directory: directory.appendingPathComponent("suggestions"))
        let capture = suggestion()
        try await repository.add(capture)
        let dependencies = CloudKitSyncDependencies(configuration: { nil }, makeClient: { _ in
            throw ValidationError(message: "Synthetic captures never connect to CloudKit.")
        }, automaticTriggersEnabled: false)
        let store = MobileLedgerStore(supportDirectory: directory.appendingPathComponent("ledger"), initialData: DemoData.fixture(), cloudKitSyncDependencies: dependencies)
        stores.append(store)
        let router = SystemEntryRouter(suggestionRepository: repository)
        var draft = store.draft(for: store.data.transactions[0])
        draft.id = nil; draft.saveOperationID = capture.id; draft.repeatFrequency = .never; draft.recurrenceRuleID = nil
        draft.postings = draft.postings.map { PostingDraft(accountID: $0.accountID, amount: $0.amount, commodityID: $0.commodityID) }
        draft.attachments = []; draft.attachmentContainer = nil
        try SQLiteWriteAudit.execute("CREATE TRIGGER reject_capture BEFORE INSERT ON transactions BEGIN SELECT RAISE(ABORT, 'Synthetic capture write failure'); END", at: store.cloudKitSQLiteStore.databaseURL)
        let saved = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertFalse(saved)
        XCTAssertNotNil(store.transaction(capture.id), "The failure fixture must contain an optimistic unpublished row")
        await router.reloadSuggestions(store: store)
        let pending = try await repository.all()
        XCTAssertEqual(pending.map(\.id), [capture.id])
        XCTAssertEqual(router.suggestions.map(\.id), [capture.id])
        try SQLiteWriteAudit.execute("DROP TRIGGER reject_capture", at: store.cloudKitSQLiteStore.databaseURL)
        let retry = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(retry, store.validationError?.message ?? "Retry should commit the capture")
        await router.reloadSuggestions(store: store)
        let completed = try await repository.all()
        XCTAssertTrue(completed.isEmpty)
        XCTAssertTrue(router.suggestions.isEmpty)
        await MobileLedgerStore.drainPersistenceQueueForTesting()
    }

    func testCatalogRoundTripContainsOnlyProvidedVisibleEntities() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SystemIntegrationCatalogRepository(url: directory.appendingPathComponent("catalog.json"))
        let journalID = UUID()
        let catalog = SystemIntegrationCatalog(journals: [.init(id: journalID, name: "Test Journal")], templates: [.init(id: UUID(), journalID: journalID, name: "Test Expense", journalName: "Test Journal")])
        try await repository.save(catalog)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded, catalog)
        try await repository.save(.init())
        let cleared = try await repository.load()
        XCTAssertTrue(cleared.journals.isEmpty)
        XCTAssertTrue(cleared.templates.isEmpty)
    }
}
