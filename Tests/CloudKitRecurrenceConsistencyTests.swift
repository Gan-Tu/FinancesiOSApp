import CryptoKit
import Foundation
import XCTest
@testable import FinancesClone

final class CloudKitRecurrenceConsistencyTests: XCTestCase {
    private let context = "synthetic-recurring-consistency"

    func testPartialUploadRoundTripsExactPerRecordRulesThenCompleteRetryConverges() throws {
        let f = try fixture()
        let partialRecords = Array(f.records[1...50])
        let partial = try CloudKitJournalMerger.applying(partialRecords, to: f.original)
        let reverse = try CloudKitJournalMerger.applying(Array(partialRecords.reversed()), to: f.original)
        XCTAssertEqual(partial.transactions, reverse.transactions)
        XCTAssertEqual(updatedRuleCount(partial), 50)
        XCTAssertEqual(updatedRuleCount(f.original), 0, "The merger must not mutate the caller's current snapshot")
        try f.store.persistCloudKitPull(partialRecords, data: partial, previous: f.original, contextKey: context, changeToken: Data([8]))
        let disk = try XCTUnwrap(f.store.loadData())
        XCTAssertEqual(disk.transactions, partial.transactions)
        XCTAssertEqual(updatedRuleCount(disk), 50)
        XCTAssertEqual(try f.store.loadData(maximumReadBufferBytes: 0)?.transactions, partial.transactions)
        XCTAssertEqual(try f.store.cloudKitChangeToken(contextKey: context), Data([8]))
        XCTAssertEqual(projectedAmounts(disk), projectedAmounts(partial), "Relaunch must not select a different shared-table rule")

        let complete = try CloudKitJournalMerger.applying(f.records, to: partial)
        try f.store.persistCloudKitPull(f.records, data: complete, previous: partial, contextKey: context, changeToken: Data([9]))
        let completeDisk = try XCTUnwrap(f.store.loadData())
        XCTAssertEqual(completeDisk.transactions, complete.transactions)
        XCTAssertEqual(completeDisk.transactions, f.source.transactions)
        XCTAssertEqual(updatedRuleCount(completeDisk), 100)
        XCTAssertFalse(projectedAmounts(completeDisk).isEmpty)
        XCTAssertTrue(projectedAmounts(completeDisk).allSatisfy { $0 == -25 })
        XCTAssertEqual(projectedAmounts(completeDisk), projectedAmounts(complete))
    }

    func testCompleteLegacyUploadPreservesHistoricalAndOccurrenceOverrides() throws {
        let f = try fixture()
        let merged = try CloudKitJournalMerger.applying(Array(f.records.reversed()), to: f.original)
        try f.store.persistCloudKitPull(f.records, data: merged, previous: f.original, contextKey: context, changeToken: Data([8]))
        let disk = try XCTUnwrap(f.store.loadData())
        XCTAssertEqual(disk.transactions, f.source.transactions)
        XCTAssertEqual(disk.transactions.first { $0.id == SQLiteRecurrenceWriteFixture.id(1_005) }?.postings[0].amount, -55)
        XCTAssertEqual(disk.transactions.first { $0.id == SQLiteRecurrenceWriteFixture.id(1_040) }?.postings[0].amount, -77)
        XCTAssertEqual(disk.transactions.first { $0.id == SQLiteRecurrenceWriteFixture.id(1_005) }?.note, "Historical exception")
        XCTAssertEqual(disk.transactions.first { $0.id == SQLiteRecurrenceWriteFixture.id(1_040) }?.note, "One occurrence override")
    }

    func testUseICloudConflictResolutionWorksForOneSharedRuleOccurrence() throws {
        let f = try fixture()
        let local = try localConflict(f)
        let chosen = try CloudKitJournalMerger.applying([local.remote], to: local.data)
        try f.store.resolveCloudKitConflict(id: local.conflictID, keepLocal: false, contextKey: context, data: chosen, previous: local.data)
        XCTAssertEqual(try f.store.loadData()?.transactions, chosen.transactions)
        XCTAssertTrue(try f.store.unresolvedCloudKitConflicts(contextKey: context).isEmpty)
        XCTAssertTrue(try f.store.pendingCloudKitRecords(contextKey: context).isEmpty)
        let complete = try CloudKitJournalMerger.applying(f.records, to: chosen)
        try f.store.persistCloudKitPull(f.records, data: complete, previous: chosen, contextKey: context, changeToken: Data([9]))
        XCTAssertEqual(try f.store.loadData()?.transactions, f.source.transactions)
        XCTAssertTrue(projectedAmounts(complete).allSatisfy { $0 == -25 })
    }

    func testKeepLocalCanPullOtherOccurrencesAndRetainsRebasedPendingMutation() throws {
        let f = try fixture()
        let local = try localConflict(f)
        try f.store.resolveCloudKitConflict(id: local.conflictID, keepLocal: true, contextKey: context, data: local.data, previous: local.data)
        // The coordinator filters the known base replay for this pending item;
        // other remote occurrences must remain independently mergeable.
        let applicable = f.records.filter { $0.recordID != local.pending.recordID }
        let candidate = try CloudKitJournalMerger.applying(applicable, to: local.data)
        try f.store.persistCloudKitPull(f.records, data: candidate, previous: local.data, contextKey: context, changeToken: Data([9]))
        XCTAssertEqual(try f.store.loadData()?.transactions, candidate.transactions)
        let pending = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context, limit: 1_000).first)
        XCTAssertEqual(pending.clientChangeID, local.pending.clientChangeID)
        XCTAssertEqual(pending.payloadJSON, local.pending.payloadJSON)
        XCTAssertEqual(pending.systemFields, local.remote.systemFields, "Keep Local must use the newly observed remote CAS base")
        XCTAssertEqual(try decode(pending).note, "Unsent local edit")
        XCTAssertEqual(updatedRuleCount(candidate), 99)
    }

    func testDirectPullStillCannotOverwritePendingLocalMutation() throws {
        let f = try fixture()
        let local = try localConflict(f)
        let before = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        let overwrite = try CloudKitJournalMerger.applying(f.records, to: local.data)
        XCTAssertThrowsError(try f.store.persistCloudKitPull(f.records, data: overwrite, previous: local.data, contextKey: context, changeToken: Data([9])))
        XCTAssertEqual(try f.store.loadData()?.transactions, local.data.transactions)
        XCTAssertEqual(try f.store.cloudKitChangeToken(contextKey: context), Data([7]))
        XCTAssertEqual(try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000), before)
    }

    func testLegacyRowsArePinnedBeforePartialSharedRuleReplacement() throws {
        let f = try fixture()
        try SQLiteWriteAudit.execute("UPDATE transactions SET payload_json = json_remove(payload_json, '$.recurrenceRule') WHERE recurrence_rule_id IS NOT NULL", at: f.store.databaseURL)
        let records = Array(f.records[1...50])
        let partial = try CloudKitJournalMerger.applying(records, to: f.original)
        try f.store.persistCloudKitPull(records, data: partial, previous: f.original, contextKey: context, changeToken: Data([8]))
        XCTAssertEqual(try f.store.loadData()?.transactions, partial.transactions)
        XCTAssertEqual(try f.store.loadData(maximumReadBufferBytes: 0)?.transactions, partial.transactions)
        XCTAssertTrue(try f.store.pendingCloudKitRecords(contextKey: context).isEmpty, "Backfilling old header payloads is not a new user edit")
    }

    func testLegacyMissingEmbeddedRuleUsesSharedTableInBothReaders() throws {
        let f = try fixture()
        try SQLiteWriteAudit.execute("UPDATE transactions SET payload_json = json_remove(payload_json, '$.recurrenceRule') WHERE recurrence_rule_id IS NOT NULL", at: f.store.databaseURL)
        XCTAssertEqual(try f.store.loadData()?.transactions, f.original.transactions)
        XCTAssertEqual(try f.store.loadData(maximumReadBufferBytes: 0)?.transactions, f.original.transactions)
    }

    func testMalformedOrMismatchedEmbeddedRuleFailsRatherThanFallingBack() throws {
        for value in ["'malformed'", "json('null')", "json_object('id', '\(UUID().uuidString)', 'frequency', 'monthly', 'intervalValue', 1, 'onWorkdays', json('false'))"] {
            let f = try fixture()
            try SQLiteWriteAudit.execute("UPDATE transactions SET payload_json = json_set(payload_json, '$.recurrenceRule', \(value)) WHERE id = '\(SQLiteRecurrenceWriteFixture.id(1_000).uuidString)'", at: f.store.databaseURL)
            XCTAssertThrowsError(try f.store.loadData())
            XCTAssertThrowsError(try f.store.loadData(maximumReadBufferBytes: 0))
        }
    }

    func testMixedContinuationPayloadsSurviveBothReadersExactly() throws {
        let f = try fixture()
        var advanced = f.original
        for index in advanced.transactions.indices where advanced.transactions[index].recurrenceRule != nil {
            advanced.transactions[index].recurrenceRule?.continuation?.nextOccurrenceIndex += 1
            advanced.transactions[index].recurrenceRule?.continuation?.consumedOccurrences += 1
            let last = advanced.transactions[index].recurrenceRule!.continuation!.lastScheduledDay
            advanced.transactions[index].recurrenceRule?.continuation?.lastScheduledDay = SQLiteRecurrenceWriteFixture.calendar.date(byAdding: .month, value: 1, to: last)!
        }
        let partialRecords = try Array(advanced.transactions.filter { $0.recurrenceRule != nil }.prefix(50)).map(record)
        let partial = try CloudKitJournalMerger.applying(partialRecords, to: f.original)
        try f.store.persistCloudKitPull(partialRecords, data: partial, previous: f.original, contextKey: context, changeToken: Data([8]))
        XCTAssertEqual(try f.store.loadData()?.transactions, partial.transactions)
        XCTAssertEqual(try f.store.loadData(maximumReadBufferBytes: 0)?.transactions, partial.transactions)
    }

    private func updatedRuleCount(_ data: JournalData) -> Int {
        data.transactions.filter { $0.recurrenceRule?.templateHistory?.changes.count == 1 }.count
    }

    private func projectedAmounts(_ data: JournalData) -> [Decimal] {
        let future = SQLiteRecurrenceWriteFixture.calendar.date(from: DateComponents(year: 2040, month: 1, day: 1, hour: 12))!
        let ids = Set(data.transactions.map(\.id))
        return RecurringJournalEditor.materialized(data, referenceDate: future, calendar: SQLiteRecurrenceWriteFixture.calendar).transactions
            .filter { !ids.contains($0.id) }.map { $0.postings[0].amount }
    }

    private func localConflict(_ f: Fixture) throws -> (data: JournalData, pending: CloudKitSyncRecord, remote: CloudKitSyncRecord, conflictID: String) {
        var local = f.original
        let id = SQLiteRecurrenceWriteFixture.id(1_005)
        local.transactions[local.transactions.firstIndex { $0.id == id }!].note = "Unsent local edit"
        try f.store.persist(local, previous: f.original)
        let pending = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context, limit: 1_000).first)
        let remote = try XCTUnwrap(f.records.first { $0.recordID == id.uuidString })
        try f.store.saveCloudKitConflict(local: pending, remote: remote, contextKey: context)
        let conflictID = try XCTUnwrap(f.store.unresolvedCloudKitConflicts(contextKey: context).first?.id)
        return (local, pending, remote, conflictID)
    }

    private struct Fixture {
        let original: JournalData
        let source: JournalData
        let records: [CloudKitSyncRecord]
        let store: SQLiteJournalStore
    }

    private func fixture() throws -> Fixture {
        var original = SQLiteRecurrenceWriteFixture.make()
        for index in original.transactions.indices where original.transactions[index].recurrenceRule != nil {
            original.transactions[index].recurrenceRule?.occurrenceCount = nil
        }
        let historicalIndex = original.transactions.firstIndex { $0.id == SQLiteRecurrenceWriteFixture.id(1_005) }!
        original.transactions[historicalIndex].note = "Historical exception"
        original.transactions[historicalIndex].postings[0].amount = -55
        original.transactions[historicalIndex].postings[1].amount = 55
        let boundary = original.transactions.first { $0.id == SQLiteRecurrenceWriteFixture.id(1_020) }!
        var update = boundary
        update.note = "Changed future terms"
        update.postings[0].amount = -25
        update.postings[1].amount = 25
        var source = try RecurringJournalEditor.apply(update, replacing: update.id, in: original, scope: .future,
            referenceDate: original.transactions.last!.date, calendar: SQLiteRecurrenceWriteFixture.calendar)
        let exception = source.transactions.first { $0.id == SQLiteRecurrenceWriteFixture.id(1_040) }!
        var override = exception
        override.note = "One occurrence override"
        override.postings[0].amount = -77
        override.postings[1].amount = 77
        source = try RecurringJournalEditor.apply(override, replacing: override.id, in: source,
            referenceDate: original.transactions.last!.date, calendar: SQLiteRecurrenceWriteFixture.calendar)
        let records = try source.transactions.filter { $0.recurrenceRule != nil }.map(record)
        let directory = FileManager.default.temporaryDirectory.appending(path: "CloudKitRecurrenceConsistency-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteJournalStore(databaseURL: directory.appending(path: "journal.sqlite"))
        try store.replaceData(original, trackSyncChanges: false)
        _ = try store.bindCloudKitAccount(contextKey: context, accountID: "Synthetic")
        try store.persistCloudKitPull([], data: original, previous: original, contextKey: context, changeToken: Data([7]))
        return Fixture(original: original, source: source, records: records, store: store)
    }

    private func record(_ transaction: LedgerTransaction) throws -> CloudKitSyncRecord {
        let payload = try JSONEncoder.appEncoder.encode(transaction)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", Int($0)) }.joined()
        return CloudKitSyncRecord(recordType: "transaction", recordID: transaction.id.uuidString,
            parentRecordID: transaction.ledgerID.uuidString, contentHash: hash,
            payloadJSON: String(decoding: payload, as: UTF8.self), clientChangeID: UUID().uuidString, systemFields: Data([1]))
    }

    private func decode(_ record: CloudKitSyncRecord) throws -> LedgerTransaction {
        try JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: XCTUnwrap(record.payloadJSON?.data(using: .utf8)))
    }
}
