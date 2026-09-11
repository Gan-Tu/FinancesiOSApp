import Foundation
import XCTest
@testable import FinancesClone

@MainActor
final class AccountBalanceAndImportedEditTests: XCTestCase {
    private var stores: [MobileLedgerStore] = []
    private var folders: [URL] = []
    override func tearDown() async throws {
        for store in stores { await store.waitForCloudKitSyncIdle() }
        stores.removeAll()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for folder in folders { try FileManager.default.removeItem(at: folder) }
        try await super.tearDown()
    }
    private func makeStore(_ data: JournalData) -> MobileLedgerStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Review-" + UUID().uuidString)
        var dependencies = CloudKitSyncDependencies.live
        dependencies.automaticTriggersEnabled = false
        let store = MobileLedgerStore(supportDirectory: folder, initialData: data, cloudKitSyncDependencies: dependencies)
        folders.append(folder); stores.append(store)
        return store
    }
    func testMovingFundedAccountUpdatesBothParentBalances() async throws {
        let ledger = Ledger(name: "Review", listIndex: 0)
        let usd = Commodity(ledgerID: ledger.id, symbol: "USD", name: "US Dollar")
        let root = Account(ledgerID: ledger.id, commodityID: usd.id, name: "Assets", kind: .asset)
        let oldParent = Account(ledgerID: ledger.id, parentID: root.id, commodityID: usd.id, name: "Old Group", kind: .asset)
        let newParent = Account(ledgerID: ledger.id, parentID: root.id, commodityID: usd.id, name: "New Group", kind: .asset)
        let child = Account(ledgerID: ledger.id, parentID: oldParent.id, commodityID: usd.id, name: "Funded", kind: .asset)
        let sibling = Account(ledgerID: ledger.id, parentID: newParent.id, commodityID: usd.id, name: "Sibling", kind: .asset)
        let expense = Account(ledgerID: ledger.id, commodityID: usd.id, name: "Expense", kind: .expense)
        let tx = LedgerTransaction(ledgerID: ledger.id, date: Date(timeIntervalSince1970: 1_700_000_000), payee: "", note: "", number: "", cleared: true, postings: [
            Posting(accountID: child.id, commodityID: usd.id, amount: -100, listIndex: 0),
            Posting(accountID: expense.id, commodityID: usd.id, amount: 100, listIndex: 1)
        ])
        var data = JournalData()
        data.ledgers = [ledger]; data.commodities = [usd]
        data.accounts = [root, oldParent, newParent, child, sibling, expense]
        data.transactions = [tx]; data.selectedLedgerID = ledger.id; data.syncEnabled = false
        let store = makeStore(data)
        func balance(_ id: UUID) -> Decimal { store.balanceRows(for: id).reduce(.zero) { $0 + $1.amount } }
        XCTAssertFalse(store.requiresJournalRecovery)
        XCTAssertEqual(balance(oldParent.id), -100)
        XCTAssertEqual(balance(newParent.id), 0)
        store.moveAccount(child.id, relativeTo: sibling.id, placement: .before)
        try await store.flushLocalChangesAsync()
        XCTAssertNil(store.validationError)
        XCTAssertEqual(store.account(child.id)?.parentID, newParent.id)
        XCTAssertEqual(balance(oldParent.id), 0, "Old parent must lose the moved balance")
        XCTAssertEqual(balance(newParent.id), -100, "New parent must gain the moved balance")
        let deleted = await store.deleteTransactionAsync(tx.id)
        XCTAssertTrue(deleted)
        XCTAssertEqual(balance(oldParent.id), 0, "After deleting the only transaction all groups should be zero")
        XCTAssertEqual(balance(newParent.id), 0, "Deletion must not leave a phantom positive balance")
    }
    func testEditingImportedNonzeroTransactionPreservesZeroSplit() async throws {
        var data = DemoData.fixture()
        let first = data.transactions[0].postings[0]
        data.transactions[0].postings.append(Posting(accountID: first.accountID, commodityID: first.commodityID, amount: 0, listIndex: 2))
        data.syncEnabled = false
        let store = makeStore(data)
        let original = try XCTUnwrap(store.transaction(data.transactions[0].id))
        var draft = store.draft(for: original)
        draft.note = "Metadata-only edit to imported transaction"
        XCTAssertFalse(draft.isDuplicate)
        let saved = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(saved, "Valid imported zero split should not prevent a note edit")
        XCTAssertNil(store.validationError)
        XCTAssertEqual(store.transaction(original.id)?.note, draft.note)
        XCTAssertEqual(store.transaction(original.id)?.postings.map(\.amount), original.postings.map(\.amount))
    }

    func testMovingMultiCurrencySubtreeBetweenRootsMatchesFreshProjection() async throws {
        let ledger = Ledger(name: "Subtree")
        let usd = Commodity(ledgerID: ledger.id, symbol: "USD", name: "Dollar")
        let eur = Commodity(ledgerID: ledger.id, symbol: "EUR", name: "Euro")
        let oldRoot = Account(ledgerID: ledger.id, name: "Old Root", kind: .asset)
        let newRoot = Account(ledgerID: ledger.id, name: "New Root", kind: .asset)
        let subtree = Account(ledgerID: ledger.id, parentID: oldRoot.id, name: "Subtree", kind: .asset)
        let child = Account(ledgerID: ledger.id, parentID: subtree.id, name: "Child", kind: .asset)
        let sibling = Account(ledgerID: ledger.id, parentID: newRoot.id, name: "Sibling", kind: .asset)
        let expense = Account(ledgerID: ledger.id, name: "Expense", kind: .expense)
        func transaction(_ account: Account, _ currency: Commodity, _ amount: Decimal, future: Bool = false) -> LedgerTransaction {
            LedgerTransaction(ledgerID: ledger.id, date: Date(timeIntervalSince1970: future ? 4_102_444_800 : 1_700_000_000),
                payee: "", note: "", number: "", cleared: true, postings: [
                    Posting(accountID: account.id, commodityID: currency.id, amount: amount),
                    Posting(accountID: expense.id, commodityID: currency.id, amount: -amount, listIndex: 1)
                ])
        }
        var data = JournalData()
        data.ledgers = [ledger]; data.commodities = [usd, eur]
        data.accounts = [oldRoot, newRoot, subtree, child, sibling, expense]
        data.transactions = [transaction(subtree, usd, 10), transaction(child, eur, 20), transaction(child, usd, 999, future: true)]
        data.selectedLedgerID = ledger.id; data.syncEnabled = false
        let store = makeStore(data)
        store.moveAccount(subtree.id, relativeTo: sibling.id, placement: .before)
        try await store.flushLocalChangesAsync()
        XCTAssertNil(store.validationError)
        let cutoff = try XCTUnwrap(Calendar.current.dateInterval(of: .day, for: Date())?.end)
        let expected = AccountBalanceProjection.build(data: store.data, rows: store.data.transactions, cutoff: cutoff)
        func values(_ rows: [MobileBalanceRow]) -> [UUID?: Decimal] {
            var result: [UUID?: Decimal] = [:]
            for row in rows where row.amount != .zero { result[row.commodityID] = row.amount }
            return result
        }
        for account in data.accounts { XCTAssertEqual(values(store.balanceRows(for: account.id)), values(expected.balances[account.id] ?? []), account.name) }
        // A second move only reorders within the new parent and must not double-transfer totals.
        store.moveAccount(subtree.id, relativeTo: sibling.id, placement: .after)
        try await store.flushLocalChangesAsync()
        for account in data.accounts { XCTAssertEqual(values(store.balanceRows(for: account.id)), values(expected.balances[account.id] ?? []), account.name) }
    }

    func testZeroSplitPreservationStillRejectsNewAndEntirelyZeroPostings() async throws {
        var data = DemoData.fixture()
        let first = data.transactions[0].postings[0]
        data.transactions[0].postings.append(Posting(accountID: first.accountID, commodityID: first.commodityID, amount: 0, listIndex: 2))
        data.syncEnabled = false
        let store = makeStore(data)
        let original = try XCTUnwrap(store.transaction(data.transactions[0].id))
        var draft = store.draft(for: original)
        for index in draft.postings.indices { draft.postings[index].amount = "0" }
        let allZeroSaved = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertFalse(allZeroSaved)
        XCTAssertEqual(store.transaction(original.id), original)
        draft = store.draft(for: original)
        draft.postings.append(PostingDraft(accountID: first.accountID, amount: "0", commodityID: first.commodityID))
        let newZeroSaved = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertFalse(newZeroSaved)
        XCTAssertEqual(store.transaction(original.id), original)
    }
}
