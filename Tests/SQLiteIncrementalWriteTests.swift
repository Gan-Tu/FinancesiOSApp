import Foundation
import XCTest
@testable import FinancesClone

final class SQLiteIncrementalWriteTests: XCTestCase {
    func testClearedAndTextEditsWriteOnlyTransactionAndSyncVersions() throws {
        let f = try fixture()
        try f.store.markAttachmentUploaded(assetID: f.data.transactions[0].attachment!.assets[0].id, serverRevision: 42)
        try SQLiteWriteAudit.install(at: f.store.databaseURL)
        var previous = f.data
        for index in 0..<4 {
            var next = previous
            switch index {
            case 0: next.transactions[0].cleared.toggle()
            case 1: next.transactions[0].note = "Updated note"
            case 2: next.transactions[0].number = "Updated number"
            default: next.transactions[0].payee = "Updated payee"
            }
            try SQLiteWriteAudit.reset(at: f.store.databaseURL)
            try f.store.persist(next, previous: previous)
            XCTAssertEqual(try SQLiteWriteAudit.counts(at: f.store.databaseURL), ["transactions": 1, "sync_records": 1, "sync_outbox": 1])
            XCTAssertEqual(try f.store.loadData()?.transactions, next.transactions)
            XCTAssertTrue(try f.store.pendingAttachmentUploads().isEmpty, "Changing a label must not invalidate an uploaded receipt")
            let changes = try f.store.claimPendingSyncChanges(limit: 1_000)
            let transactionChange = try XCTUnwrap(changes.last { $0.recordType == "transaction" })
            let payload = try XCTUnwrap(transactionChange.payloadJSON?.data(using: .utf8))
            XCTAssertEqual(try JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: payload), next.transactions[0])
            XCTAssertEqual(try f.store.claimPendingSyncChanges(limit: 1_000), changes, "An in-flight claim must replay its frozen payload")
            try f.store.markSyncChangesAccepted(changes.map {
                SQLiteAcceptedSyncChange(clientChangeID: $0.clientChangeID, recordType: $0.recordType, recordID: $0.recordID, serverRevision: Int64(100 + index))
            })
            previous = next
        }
        try SQLiteWriteAudit.reset(at: f.store.databaseURL)
        try f.store.persist(previous, previous: previous)
        XCTAssertTrue(try SQLiteWriteAudit.counts(at: f.store.databaseURL).isEmpty, "Repeated durable flush is a write-free no-op")
    }

    func testBulkClearingDoesNotFallBackToReplacingAllRows() throws {
        let f = try fixture(count: 100)
        try SQLiteWriteAudit.install(at: f.store.databaseURL)
        var next = f.data
        for index in next.transactions.indices { next.transactions[index].cleared = true }
        try f.store.persist(next, previous: f.data)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: f.store.databaseURL), ["transactions": 100, "sync_records": 100, "sync_outbox": 100])
        XCTAssertEqual(try f.store.loadData()?.transactions, next.transactions)
    }

    func testTemplateFieldsAndLocalMetadataDoNotRewriteRelatedRows() throws {
        let f = try fixture()
        try SQLiteWriteAudit.install(at: f.store.databaseURL)
        var next = f.data
        next.transactionTemplates[0].enabled.toggle()
        next.transactionTemplates[0].name = "Renamed template"
        try f.store.persist(next, previous: f.data)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: f.store.databaseURL), ["transaction_templates": 1, "sync_records": 1, "sync_outbox": 1])
        XCTAssertEqual(try f.store.loadData()?.transactionTemplates, next.transactionTemplates)
        var selected = next
        selected.selectedLedgerID = selected.ledgers[0].id
        selected.lastSyncedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try SQLiteWriteAudit.reset(at: f.store.databaseURL)
        try f.store.persist(selected, previous: next)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: f.store.databaseURL), ["app_metadata": 1])
        XCTAssertEqual(try f.store.loadData()?.selectedLedgerID, selected.selectedLedgerID)
        var preferences = selected
        preferences.appearance = .dark
        try SQLiteWriteAudit.reset(at: f.store.databaseURL)
        try f.store.persist(preferences, previous: selected)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: f.store.databaseURL), ["app_metadata": 1, "sync_records": 1, "sync_outbox": 1])
        XCTAssertEqual(try f.store.loadData()?.appearance, .dark)
    }

    func testChangedPostingsRecurrenceAndAttachmentsStillRoundTripAndDelete() throws {
        let f = try fixture()
        try SQLiteWriteAudit.install(at: f.store.databaseURL)
        var next = f.data
        next.transactions[0].postings[0].amount = -25
        next.transactions[0].postings[1].amount = 25
        next.transactions[0].recurrenceRule?.occurrenceCount = 8
        next.transactions[0].attachment?.assets[0].originalFilename = "renamed.txt"
        next.transactionTemplates[0].postings.reverse()
        try f.store.persist(next, previous: f.data)
        let writes = try SQLiteWriteAudit.counts(at: f.store.databaseURL)
        XCTAssertEqual(writes["postings"], 2)
        XCTAssertEqual(writes["recurrence_rules"], 1)
        XCTAssertEqual(writes["recurrence_ends"], 1)
        XCTAssertEqual(writes["attachment_assets"], 2)
        XCTAssertEqual(writes["posting_templates"], 4)
        XCTAssertEqual(try f.store.loadData()?.transactions, next.transactions)
        XCTAssertEqual(try f.store.loadData()?.transactionTemplates, next.transactionTemplates)
        var deleted = next
        deleted.transactions.removeAll()
        try f.store.persist(deleted, previous: next)
        XCTAssertTrue(try XCTUnwrap(f.store.loadData()).transactions.isEmpty)
        let counts = try f.store.recordCounts()
        XCTAssertEqual(counts.postings, 0)
        XCTAssertEqual(counts.recurrenceRules, 0)
        XCTAssertEqual(counts.attachmentAssets, 0)
        let tombstones = try f.store.claimPendingSyncChanges(limit: 1_000).filter { $0.operation == "delete" }
        XCTAssertEqual(Set(tombstones.map(\.recordType)), ["transaction", "attachment_asset"])
    }

    func testPostingDeltasUpdateOnlyChangedIDsAndPreserveInsertDeleteAndOrder() throws {
        let f = try fixture()
        try SQLiteWriteAudit.install(at: f.store.databaseURL)
        var previous = f.data
        var changed = previous
        changed.transactions[0].postings[0].amount = -25
        changed.transactions[0].postings[1].amount = 25
        try f.store.persist(changed, previous: previous)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: f.store.databaseURL), ["postings": 2, "transactions": 1, "sync_records": 1, "sync_outbox": 1])
        XCTAssertEqual(try f.store.loadData()?.transactions, changed.transactions)
        previous = changed
        changed.transactions[0].postings[0].accountID = changed.accounts[1].id
        try SQLiteWriteAudit.reset(at: f.store.databaseURL)
        try f.store.persist(changed, previous: previous)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: f.store.databaseURL)["postings"], 1)
        XCTAssertEqual(try f.store.loadData()?.transactions, changed.transactions)
        previous = changed
        let currency = Commodity(ledgerID: changed.ledgers[0].id, symbol: "EUR", name: "Euro")
        changed.commodities.append(currency)
        for index in changed.transactions[0].postings.indices { changed.transactions[0].postings[index].commodityID = currency.id }
        try SQLiteWriteAudit.reset(at: f.store.databaseURL)
        try f.store.persist(changed, previous: previous)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: f.store.databaseURL)["postings"], 2)
        XCTAssertEqual(try f.store.loadData()?.transactions, changed.transactions)
        previous = changed
        changed.transactions[0].postings[0].listIndex = 1
        changed.transactions[0].postings[1].listIndex = 0
        changed.transactions[0].postings.reverse()
        try SQLiteWriteAudit.reset(at: f.store.databaseURL)
        try f.store.persist(changed, previous: previous)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: f.store.databaseURL)["postings"], 1)
        XCTAssertEqual(try f.store.loadData()?.transactions, changed.transactions)
        previous = changed
        changed.transactions[0].postings[0].id = UUID()
        try SQLiteWriteAudit.reset(at: f.store.databaseURL)
        try f.store.persist(changed, previous: previous)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: f.store.databaseURL)["postings"], 2, "One removed posting and one inserted posting")
        XCTAssertEqual(try f.store.loadData()?.transactions, changed.transactions)
    }

    func testPostingDeltaRejectsDuplicateAndCrossTransactionIDsAtomically() throws {
        let f = try fixture(count: 2)
        try SQLiteWriteAudit.install(at: f.store.databaseURL)
        var duplicate = f.data
        duplicate.transactions[0].postings[1].id = duplicate.transactions[0].postings[0].id
        XCTAssertThrowsError(try f.store.persist(duplicate, previous: f.data))
        XCTAssertTrue(try SQLiteWriteAudit.counts(at: f.store.databaseURL).isEmpty)
        XCTAssertEqual(try f.store.loadData()?.transactions, f.data.transactions)
        var reused = f.data
        reused.transactions[1].postings[0].id = reused.transactions[0].postings[0].id
        XCTAssertThrowsError(try f.store.persist(reused, previous: f.data))
        XCTAssertTrue(try SQLiteWriteAudit.counts(at: f.store.databaseURL).isEmpty)
        XCTAssertEqual(try f.store.loadData()?.transactions, f.data.transactions)
    }

    func testOutboxFailureRollsBackParentAndChildChangesTogether() throws {
        let f = try fixture()
        try SQLiteWriteAudit.install(at: f.store.databaseURL)
        try SQLiteWriteAudit.execute("""
            CREATE TRIGGER test_reject_outbox BEFORE INSERT ON sync_outbox
            BEGIN SELECT RAISE(ABORT, 'Synthetic write failure'); END
            """, at: f.store.databaseURL)
        var next = f.data
        next.transactions[0].cleared = true
        next.transactions[0].postings[0].amount = -11
        next.transactions[0].postings[1].amount = 11
        XCTAssertThrowsError(try f.store.persist(next, previous: f.data))
        XCTAssertEqual(try f.store.loadData()?.transactions, f.data.transactions)
        XCTAssertTrue(try SQLiteWriteAudit.counts(at: f.store.databaseURL).isEmpty)
        try SQLiteWriteAudit.execute("DROP TRIGGER test_reject_outbox", at: f.store.databaseURL)
        try f.store.persist(next, previous: f.data)
        XCTAssertEqual(try f.store.loadData()?.transactions, next.transactions)
    }

    private func fixture(count: Int = 1) throws -> (store: SQLiteJournalStore, data: JournalData) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SQLiteWriteTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("Synthetic receipt".utf8)
        try bytes.write(to: directory.appending(path: "receipt.txt"))
        let ledger = Ledger(name: "Synthetic journal")
        let cash = Account(ledgerID: ledger.id, name: "Cash", kind: .asset)
        let expense = Account(ledgerID: ledger.id, name: "Expense", kind: .expense)
        let postings = [Posting(accountID: cash.id, amount: -10), Posting(accountID: expense.id, amount: 10)]
        var data = JournalData(ledgers: [ledger], accounts: [cash, expense])
        for index in 0..<count {
            data.transactions.append(LedgerTransaction(
                ledgerID: ledger.id, date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), payee: "Synthetic merchant", note: "Synthetic receipt", number: "", cleared: false,
                postings: postings.map { var posting = $0; posting.id = UUID(); return posting },
                recurrenceRule: index == 0 ? RecurrenceRule(frequency: .monthly, intervalValue: 1, occurrenceCount: 4) : nil,
                attachment: index == 0 ? AttachmentContainer(assets: [AttachmentAsset(originalFilename: "receipt.txt", storedPath: "receipt.txt", mimeType: "text/plain", sizeBytes: Int64(bytes.count))], createdAt: Date(timeIntervalSince1970: 1_700_000_000)) : nil
            ))
        }
        data.transactionTemplates = [TransactionTemplate(ledgerID: ledger.id, name: "Expense", postings: [PostingTemplate(accountID: cash.id), PostingTemplate(accountID: expense.id, listIndex: 1)])]
        let store = SQLiteJournalStore(databaseURL: directory.appending(path: "journal.sqlite"))
        try store.replaceData(data, trackSyncChanges: false)
        return (store, data)
    }
}
