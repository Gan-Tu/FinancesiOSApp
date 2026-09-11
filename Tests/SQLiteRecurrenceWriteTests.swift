import Foundation
import XCTest
@testable import FinancesClone

final class SQLiteRecurrenceWriteTests: XCTestCase {
    func testBroadFutureEditWritesOnlyChangedChildrenAndOneSharedRule() throws {
        var original = SQLiteRecurrenceWriteFixture.make()
        let asset = AttachmentAsset(originalFilename: "receipt.txt", storedPath: "Attachments/receipt.txt", mimeType: "text/plain", sizeBytes: 17)
        original.transactions[0].attachment = AttachmentContainer(assets: [asset], createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let store = try store(original)
        try store.markAttachmentUploaded(assetID: asset.id, serverRevision: 8)
        try SQLiteWriteAudit.install(at: store.databaseURL)
        let changed = try SQLiteRecurrenceWriteFixture.futureNoteEdit(original)
        try store.persist(changed, previous: original)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: store.databaseURL), ["transactions": 100, "recurrence_rules": 1, "sync_records": 100, "sync_outbox": 100])
        XCTAssertTrue(try store.pendingAttachmentUploads().isEmpty)
        let disk = try XCTUnwrap(store.loadData())
        XCTAssertEqual(disk.transactions, changed.transactions.sorted { $0.date < $1.date })
        let extended = RecurringJournalEditor.materialized(disk, referenceDate: Date(timeIntervalSince1970: 2_400_000_000), calendar: SQLiteRecurrenceWriteFixture.calendar)
        XCTAssertEqual(extended.transactions, disk.transactions)
        let claims = try store.claimPendingSyncChanges(limit: 1_000)
        XCTAssertEqual(claims.count, 100)
        let byID = Dictionary(uniqueKeysWithValues: changed.transactions.map { ($0.id.uuidString, $0) })
        for claim in claims {
            let payload = try XCTUnwrap(claim.payloadJSON?.data(using: .utf8))
            XCTAssertEqual(try JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: payload), byID[claim.recordID])
        }
    }

    func testBroadFutureDeleteKeepsEarlierRowsAndUnrelatedParents() throws {
        let original = SQLiteRecurrenceWriteFixture.make()
        let store = try store(original)
        try SQLiteWriteAudit.install(at: store.databaseURL)
        let series = original.transactions.filter { $0.recurrenceRule != nil }
        let deletion = try RecurringJournalEditor.deleting(series[20].id, scope: .future, in: original, calendar: SQLiteRecurrenceWriteFixture.calendar)
        try store.persist(deletion.journal, previous: original)
        let writes = try SQLiteWriteAudit.counts(at: store.databaseURL)
        XCTAssertNil(writes["accounts"])
        XCTAssertNil(writes["ledgers"])
        XCTAssertNil(writes["commodities"])
        XCTAssertEqual(writes["recurrence_rules"], 1)
        XCTAssertEqual(writes["recurrence_ends"], 1, "A genuinely changed end date must still be saved")
        let disk = try XCTUnwrap(store.loadData())
        XCTAssertEqual(disk.transactions, deletion.journal.transactions.sorted { $0.date < $1.date })
        let tombstones = try store.deletedTransactionIDs()
        XCTAssertTrue(deletion.deletedIDs.isSubset(of: tombstones))
        let extended = RecurringJournalEditor.materialized(disk, referenceDate: Date(timeIntervalSince1970: 2_400_000_000), calendar: SQLiteRecurrenceWriteFixture.calendar, deletedIDs: tombstones)
        XCTAssertEqual(extended.transactions, disk.transactions)
    }

    func testSharedRuleDeduplicationPreservesLastWrittenValueOrderForDifferingValues() throws {
        for intervals in [[2, 3, 2], [2, 2, 3]] {
            let original = SQLiteRecurrenceWriteFixture.make(seriesCount: 3, independentCount: 0)
            let store = try store(original)
            try SQLiteWriteAudit.install(at: store.databaseURL)
            var changed = original
            for index in changed.transactions.indices { changed.transactions[index].recurrenceRule?.intervalValue = intervals[index] }
            try store.persist(changed, previous: original)
            XCTAssertEqual(try SQLiteWriteAudit.counts(at: store.databaseURL)["recurrence_rules"], intervals == [2, 3, 2] ? 3 : 2)
            XCTAssertEqual(try store.loadData()?.transactions, changed.transactions, "Embedded rule values remain exact even when shared IDs temporarily differ")
            let expectedLast = changed.transactions.last?.recurrenceRule
            try SQLiteWriteAudit.execute("UPDATE transactions SET payload_json = json_remove(payload_json, '$.recurrenceRule')", at: store.databaseURL)
            XCTAssertTrue(try XCTUnwrap(store.loadData()).transactions.allSatisfy { $0.recurrenceRule == expectedLast }, "Legacy rows without an embedded rule retain the ordered shared-table fallback")
        }
    }

    func testExplicitReplacementStillRewritesParentsButWritesEachSharedRuleOnce() throws {
        let original = SQLiteRecurrenceWriteFixture.make()
        let store = try store(original)
        try SQLiteWriteAudit.install(at: store.databaseURL)
        try store.replaceData(original, trackSyncChanges: false)
        let writes = try SQLiteWriteAudit.counts(at: store.databaseURL)
        XCTAssertEqual(writes["transactions"], 400)
        XCTAssertEqual(writes["accounts"], 4)
        XCTAssertEqual(writes["recurrence_rules"], 2, "One old rule deletion and one new rule insertion")
        XCTAssertEqual(writes["recurrence_ends"], 2)
        XCTAssertEqual(try store.loadData()?.transactions, original.transactions)
    }

    func testLargeParentChangeRetainsReplacementHeuristic() throws {
        let original = SQLiteRecurrenceWriteFixture.make(extraAccounts: 100)
        let store = try store(original)
        try SQLiteWriteAudit.install(at: store.databaseURL)
        var changed = original
        for index in changed.accounts.indices { changed.accounts[index].note = "Updated parent metadata" }
        try store.persist(changed, previous: original)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: store.databaseURL)["transactions"], 400)
        XCTAssertEqual(try store.loadData()?.transactions, original.transactions)
        XCTAssertTrue(try XCTUnwrap(store.loadData()).accounts.allSatisfy { $0.note == "Updated parent metadata" })
    }

    func testBroadTemplatePostingEditDoesNotRewriteTransactionFamilies() throws {
        let original = SQLiteRecurrenceWriteFixture.make(templateCount: 100)
        let store = try store(original)
        try SQLiteWriteAudit.install(at: store.databaseURL)
        var changed = original
        for index in changed.transactionTemplates.indices { changed.transactionTemplates[index].postings[1].accountID = original.accounts[0].id }
        try store.persist(changed, previous: original)
        XCTAssertEqual(try SQLiteWriteAudit.counts(at: store.databaseURL), ["transaction_templates": 100, "posting_templates": 400, "sync_records": 100, "sync_outbox": 100])
        let disk = try XCTUnwrap(store.loadData())
        XCTAssertEqual(disk.transactions, original.transactions)
        XCTAssertEqual(disk.transactionTemplates, changed.transactionTemplates)
    }

    func testBroadEditRollbackPreservesAllDataOnOutboxFailureAndPostingOwnershipViolation() throws {
        let original = SQLiteRecurrenceWriteFixture.make()
        let store = try store(original)
        try SQLiteWriteAudit.install(at: store.databaseURL)
        let changed = try SQLiteRecurrenceWriteFixture.futureNoteEdit(original)
        try SQLiteWriteAudit.execute("CREATE TRIGGER test_reject_recurrence_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'Synthetic outbox failure'); END", at: store.databaseURL)
        XCTAssertThrowsError(try store.persist(changed, previous: original))
        XCTAssertTrue(try SQLiteWriteAudit.counts(at: store.databaseURL).isEmpty)
        XCTAssertEqual(try store.loadData()?.transactions, original.transactions)
        try SQLiteWriteAudit.execute("DROP TRIGGER test_reject_recurrence_outbox", at: store.databaseURL)
        var invalid = changed
        invalid.transactions[0].postings[0].id = original.transactions[1].postings[0].id
        XCTAssertThrowsError(try store.persist(invalid, previous: original))
        XCTAssertTrue(try SQLiteWriteAudit.counts(at: store.databaseURL).isEmpty)
        XCTAssertEqual(try store.loadData()?.transactions, original.transactions)
    }

    private func store(_ data: JournalData) throws -> SQLiteJournalStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SQLiteRecurrenceWriteTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appending(path: "Attachments"), withIntermediateDirectories: true)
        try Data("Synthetic receipt".utf8).write(to: directory.appending(path: "Attachments/receipt.txt"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteJournalStore(databaseURL: directory.appending(path: "journal.sqlite"))
        try store.replaceData(data, trackSyncChanges: false)
        return store
    }
}
