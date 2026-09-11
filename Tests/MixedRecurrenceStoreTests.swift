import CryptoKit
import Foundation
import XCTest
@testable import FinancesClone

@MainActor
final class MixedRecurrenceStoreTests: XCTestCase {
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

    func testRealStartupAndOccurrenceEditPreserveMixedRuleVersionsWithoutSyntheticWrites() async throws {
        let f = try fixture()
        let store = reopen(f.directory)
        await store.waitForCloudKitSyncIdle()
        XCTAssertFalse(store.requiresJournalRecovery)
        XCTAssertEqual(store.data.transactions, f.partial.transactions)
        XCTAssertTrue(try store.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: f.context).isEmpty)
        let selected = try XCTUnwrap(store.transaction(SQLiteRecurrenceWriteFixture.id(1_025)))
        var draft = store.draft(for: selected)
        draft.note = "One occurrence edited locally"
        let saved = await store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.transaction(selected.id)?.recurrenceRule, selected.recurrenceRule)
        for row in f.partial.transactions where row.id != selected.id {
            XCTAssertEqual(store.transaction(row.id), row)
        }
        XCTAssertEqual(try store.cloudKitSQLiteStore.loadData()?.transactions, store.data.transactions)
        XCTAssertEqual(try store.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: f.context).count, 1)
    }

    func testMixedAnchorOccurrenceDeletionPreservesVariantsAcrossRealBackupRestore() async throws {
        let f = try fixture()
        let store = reopen(f.directory)
        let anchor = try XCTUnwrap(store.transaction(SQLiteRecurrenceWriteFixture.id(1_000)))
        let deleted = await store.deleteTransactionAsync(anchor.id, scope: .occurrence, expected: anchor)
        XCTAssertTrue(deleted)
        for row in f.partial.transactions where row.id != anchor.id {
            XCTAssertEqual(store.transaction(row.id), row)
        }
        let backup = try await store.exportBackupFileAsync(progress: Progress(totalUnitCount: 1))
        let destination = try newDirectory()
        let restored = reopen(destination, initial: JournalData())
        try await restored.importBackupAsync(from: backup, progress: Progress(totalUnitCount: 1))
        XCTAssertNil(restored.transaction(anchor.id))
        let restoredRows = restored.data.transactions
        for row in store.data.transactions {
            let actual = try XCTUnwrap(restored.transaction(row.id))
            XCTAssertEqual(actual.postings, row.postings)
            XCTAssertEqual(actual.recurrenceRule?.templateHistory, row.recurrenceRule?.templateHistory)
            XCTAssertEqual(actual.recurrenceRule?.continuation, row.recurrenceRule?.continuation)
        }
        let launchedAgain = reopen(destination)
        await launchedAgain.waitForCloudKitSyncIdle()
        XCTAssertEqual(launchedAgain.data.transactions, restoredRows)
        XCTAssertNil(launchedAgain.transaction(anchor.id))
    }

    func testDeletingLastLegacyOccurrenceRetainsConsumedSlotThroughBackupAndExplicitFutureEdit() async throws {
        let f = try fixture(legacyCursor: true)
        let store = reopen(f.directory)
        let last = try XCTUnwrap(store.transaction(SQLiteRecurrenceWriteFixture.id(1_099)))
        XCTAssertTrue(store.data.transactions.filter { $0.recurrenceRule != nil }.allSatisfy { $0.recurrenceRule?.continuation == nil })
        let deleted = await store.deleteTransactionAsync(last.id, scope: .occurrence, expected: last)
        XCTAssertTrue(deleted)
        XCTAssertTrue(store.data.transactions.filter { $0.recurrenceRule != nil }.allSatisfy {
            $0.recurrenceRule?.continuation?.consumedOccurrences == 100
        })
        let backup = try await store.exportBackupFileAsync(progress: Progress(totalUnitCount: 1))
        let restored = reopen(try newDirectory(), initial: JournalData())
        try await restored.importBackupAsync(from: backup, progress: Progress(totalUnitCount: 1))
        XCTAssertNil(restored.transaction(last.id))
        let selected = try XCTUnwrap(restored.transaction(SQLiteRecurrenceWriteFixture.id(1_025)))
        var draft = restored.draft(for: selected)
        draft.note = "Explicit future terms after restore"
        let saved = await restored.saveTransactionAndFlushAsync(draft, scope: .future)
        XCTAssertTrue(saved)
        XCTAssertTrue(RecurringJournalEditor.mixedRuleIDs(in: restored.data.transactions).isEmpty)
        let projected = RecurringJournalEditor.materialized(restored.data, referenceDate: last.date, calendar: SQLiteRecurrenceWriteFixture.calendar)
        XCTAssertFalse(projected.transactions.contains { $0.id == last.id || SQLiteRecurrenceWriteFixture.calendar.isDate($0.date, inSameDayAs: last.date) })
    }

    private func fixture(legacyCursor: Bool = false) throws -> (directory: URL, partial: JournalData, context: String) {
        var original = SQLiteRecurrenceWriteFixture.make()
        for index in original.transactions.indices where original.transactions[index].recurrenceRule != nil {
            original.transactions[index].recurrenceRule?.occurrenceCount = nil
            if legacyCursor { original.transactions[index].recurrenceRule?.continuation = nil }
        }
        var source = try SQLiteRecurrenceWriteFixture.futureNoteEdit(original)
        if legacyCursor {
            for index in source.transactions.indices { source.transactions[index].recurrenceRule?.continuation = nil }
        }
        let changedRows = Array(source.transactions.filter { $0.recurrenceRule != nil }[1...50])
        let records = try changedRows.map { row -> CloudKitSyncRecord in
            let payload = try JSONEncoder.appEncoder.encode(row)
            return CloudKitSyncRecord(recordType: "transaction", recordID: row.id.uuidString, parentRecordID: row.ledgerID.uuidString,
                contentHash: SHA256.hash(data: payload).map { String(format: "%02x", Int($0)) }.joined(),
                payloadJSON: String(decoding: payload, as: UTF8.self), clientChangeID: UUID().uuidString, systemFields: Data([1]))
        }
        let partial = try CloudKitJournalMerger.applying(records, to: original)
        let directory = try newDirectory()
        let sqlite = SQLiteJournalStore(databaseURL: directory.appending(path: "journal.sqlite"))
        try sqlite.replaceData(original, trackSyncChanges: false)
        let context = "synthetic-mixed-series"
        _ = try sqlite.bindCloudKitAccount(contextKey: context, accountID: "Synthetic")
        try sqlite.persistCloudKitPull(records, data: partial, previous: original, contextKey: context, changeToken: Data([1]))
        return (directory, partial, context)
    }

    private func reopen(_ directory: URL, initial: JournalData? = nil) -> MobileLedgerStore {
        var dependencies = CloudKitSyncDependencies.live
        dependencies.automaticTriggersEnabled = false
        let store = MobileLedgerStore(supportDirectory: directory, initialData: initial, cloudKitSyncDependencies: dependencies)
        stores.append(store)
        return store
    }

    private func newDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MixedRecurrenceStore-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }
}
