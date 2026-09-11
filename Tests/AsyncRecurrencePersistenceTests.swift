import Foundation
import XCTest
@testable import FinancesClone

@MainActor
final class AsyncRecurrencePersistenceTests: XCTestCase {
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

    func testAsyncOccurrenceEditReloadsExactRuleAndPostingIdentitiesWithoutChangingOtherOccurrences() async throws {
        let f = try fixture(count: 5)
        let original = rows(f.initial)
        let occurrence = original[1]
        var draft = f.store.draft(for: occurrence)
        draft.note = "Only this occurrence"
        draft.payee = "Exception payee"
        draft.number = "ONE-99"
        draft.postings[0].amount = "-99"
        draft.postings[1].amount = "99"
        let saved = await f.store.saveTransactionAndFlushAsync(draft, scope: .occurrence)
        XCTAssertTrue(saved)
        XCTAssertNil(f.store.validationError)
        let disk = try reload(f)
        XCTAssertEqual(rows(disk), rows(f.store.data), "The async commit must persist exact rule and posting identities")
        XCTAssertEqual(rows(disk).map(\.id), original.map(\.id))
        let changed = try XCTUnwrap(disk.transactions.first { $0.id == occurrence.id })
        XCTAssertEqual(changed.note, draft.note)
        XCTAssertEqual(changed.payee, draft.payee)
        XCTAssertEqual(changed.number, draft.number)
        XCTAssertEqual(changed.postings.map(\.amount), [-99, 99])
        XCTAssertEqual(changed.postings.map(\.id), occurrence.postings.map(\.id))
        for untouched in original where untouched.id != occurrence.id {
            XCTAssertEqual(disk.transactions.first { $0.id == untouched.id }, untouched)
        }
        let projected = RecurringJournalEditor.materialized(disk, referenceDate: f.day(2036, 1, 1), calendar: f.calendar)
        XCTAssertEqual(rows(projected), rows(disk), "An occurrence override cannot extend a completed finite schedule")
    }

    func testAsyncFutureEditReloadsBoundaryHistoryAndPreservesEarlierAmountsAndDates() async throws {
        let f = try fixture(count: 6)
        let original = rows(f.initial)
        let boundary = original[2]
        var draft = f.store.draft(for: boundary)
        draft.note = "Future terms"
        draft.payee = "Future payee"
        draft.number = "FUTURE-44"
        draft.postings[0].amount = "-44"
        draft.postings[1].amount = "44"
        let saved = await f.store.saveTransactionAndFlushAsync(draft, scope: .future)
        XCTAssertTrue(saved)
        XCTAssertNil(f.store.validationError)
        let disk = try reload(f)
        let reloadedRows = rows(disk)
        XCTAssertEqual(reloadedRows, rows(f.store.data))
        XCTAssertEqual(reloadedRows.map(\.id), original.map(\.id))
        XCTAssertEqual(reloadedRows.map(\.date), original.map(\.date))
        XCTAssertEqual(reloadedRows.map(\.cleared), original.map(\.cleared))
        XCTAssertEqual(reloadedRows.map(\.externalTransactionID), original.map(\.externalTransactionID))
        for index in reloadedRows.indices {
            if index < 2 {
                XCTAssertEqual(reloadedRows[index].postings, original[index].postings)
                XCTAssertEqual(reloadedRows[index].note, "Base note")
            } else {
                XCTAssertEqual(reloadedRows[index].note, draft.note)
                XCTAssertEqual(reloadedRows[index].payee, draft.payee)
                XCTAssertEqual(reloadedRows[index].number, draft.number)
                XCTAssertEqual(reloadedRows[index].postings.map(\.amount), [-44, 44])
            }
        }
        let rule = try XCTUnwrap(reloadedRows.first?.recurrenceRule)
        XCTAssertEqual(rule.id, f.ruleID)
        XCTAssertEqual(rule.frequency, .monthly)
        XCTAssertEqual(rule.occurrenceCount, 6)
        XCTAssertEqual(rule.templateHistory?.changes.count, 1)
        XCTAssertEqual(rule.templateHistory?.changes.first?.effectiveDate, f.calendar.startOfDay(for: boundary.date))
        XCTAssertTrue(reloadedRows.allSatisfy { $0.recurrenceRule == rule })
        let projected = RecurringJournalEditor.materialized(disk, referenceDate: f.day(2036, 1, 1), calendar: f.calendar)
        XCTAssertEqual(rows(projected), reloadedRows)
    }

    func testAsyncFirstUnclearedAnchorDeletionPreservesMonthEndCadenceAndFiniteLimit() async throws {
        let f = try fixture(count: 4)
        let original = rows(f.initial)
        let anchor = original[0]
        XCTAssertFalse(anchor.cleared)
        let deleted = await f.store.deleteTransactionAsync(anchor.id, scope: .occurrence, expected: anchor)
        XCTAssertTrue(deleted)
        XCTAssertNil(f.store.validationError)
        let disk = try reload(f)
        let remaining = rows(disk)
        XCTAssertEqual(remaining, rows(f.store.data))
        XCTAssertEqual(remaining.map(\.id), original.dropFirst().map(\.id))
        XCTAssertEqual(remaining.map(\.date), [f.day(2026, 2, 28), f.day(2026, 3, 31), f.day(2026, 4, 30)])
        let rule = try XCTUnwrap(remaining.first?.recurrenceRule)
        XCTAssertEqual(rule.templateHistory?.scheduleAnchorDate, anchor.date)
        XCTAssertEqual(rule.occurrenceCount, 4)
        let tombstones = try f.store.cloudKitSQLiteStore.deletedTransactionIDs()
        XCTAssertTrue(tombstones.contains(anchor.id))
        let projected = RecurringJournalEditor.materialized(disk, referenceDate: f.day(2040, 1, 1), calendar: f.calendar, deletedIDs: tombstones)
        XCTAssertEqual(rows(projected), remaining)
        XCTAssertFalse(projected.transactions.contains { $0.id == anchor.id })
    }

    func testAsyncBackfilledFutureDeletionPersistsStopDateAndNeverRecreatesDeletedTail() async throws {
        let f = try fixture(count: 6, restoredUnlimited: true)
        let original = rows(f.initial)
        let boundary = original[3]
        let removedIDs = Set(original.dropFirst(3).map(\.id))
        let deleted = await f.store.deleteTransactionAsync(boundary.id, scope: .future, expected: boundary)
        XCTAssertTrue(deleted)
        XCTAssertNil(f.store.validationError)
        let disk = try reload(f)
        XCTAssertEqual(rows(disk), rows(f.store.data))
        XCTAssertEqual(rows(disk).map(\.id), original.prefix(3).map(\.id))
        let cutoff = try XCTUnwrap(f.calendar.date(byAdding: .day, value: -1, to: f.calendar.startOfDay(for: boundary.date)))
        XCTAssertTrue(rows(disk).allSatisfy { $0.recurrenceRule?.endDate == cutoff && $0.recurrenceRule?.preservesImportedMaterializations == true })
        let tombstones = try f.store.cloudKitSQLiteStore.deletedTransactionIDs()
        XCTAssertTrue(removedIDs.isSubset(of: tombstones))
        let projected = RecurringJournalEditor.materialized(disk, referenceDate: f.day(2040, 1, 1), calendar: f.calendar, deletedIDs: tombstones)
        XCTAssertEqual(rows(projected), rows(disk))
        XCTAssertTrue(removedIDs.isDisjoint(with: Set(projected.transactions.map(\.id))))
    }

    func testAsyncBackfilledAnchorDeletionKeepsContinuationLiveWithoutResurrectingCoveredSlots() async throws {
        let f = try fixture(count: 6, restoredUnlimited: true)
        let original = rows(f.initial)
        let anchor = original[0]
        XCTAssertFalse(anchor.cleared)
        let deleted = await f.store.deleteTransactionAsync(anchor.id, scope: .occurrence, expected: anchor)
        XCTAssertTrue(deleted)
        XCTAssertNil(f.store.validationError)
        let disk = try reload(f)
        XCTAssertEqual(rows(disk), rows(f.store.data))
        XCTAssertEqual(rows(disk).map(\.id), original.dropFirst().map(\.id))
        let rule = try XCTUnwrap(rows(disk).first?.recurrenceRule)
        XCTAssertNil(rule.occurrenceCount)
        XCTAssertEqual(rule.continuation?.anchorDate, anchor.date)
        XCTAssertEqual(rule.continuation?.consumedOccurrences, 6)
        XCTAssertEqual(rule.continuation?.nextOccurrenceIndex, 6)
        XCTAssertEqual(rule.continuation?.allowsAutomaticExtension, true)
        XCTAssertEqual(rule.preservesImportedMaterializations, true)
        let tombstones = try f.store.cloudKitSQLiteStore.deletedTransactionIDs()
        let projected = RecurringJournalEditor.materialized(disk, referenceDate: f.day(2033, 1, 1), calendar: f.calendar, deletedIDs: tombstones)
        let savedIDs = Set(disk.transactions.map(\.id))
        let additions = projected.transactions.filter { !savedIDs.contains($0.id) }
        XCTAssertFalse(additions.isEmpty, "Deleting only the first entry must leave its unlimited continuation active")
        XCTAssertFalse(projected.transactions.contains { $0.id == anchor.id || $0.date == anchor.date })
        XCTAssertTrue(additions.allSatisfy { $0.date > original.last!.date && $0.note == "Base note" && $0.postings.map(\.amount) == [-10, 10] })
        XCTAssertTrue(additions.allSatisfy { f.calendar.component(.day, from: $0.date) == f.calendar.range(of: .day, in: .month, for: $0.date)!.count })
        for old in disk.transactions {
            let current = try XCTUnwrap(projected.transactions.first { $0.id == old.id })
            XCTAssertEqual(current.date, old.date)
            XCTAssertEqual(current.postings, old.postings)
            XCTAssertEqual(current.cleared, old.cleared)
            XCTAssertEqual(current.externalTransactionID, old.externalTransactionID)
        }
    }

    func testAsyncDeletingBackfilledSeriesFromAnchorPersistsAllTombstones() async throws {
        let f = try fixture(count: 6, restoredUnlimited: true)
        let anchor = rows(f.initial)[0]
        let deleted = await f.store.deleteTransactionAsync(anchor.id, scope: .future, expected: anchor)
        XCTAssertTrue(deleted)
        let disk = try reload(f)
        XCTAssertTrue(disk.transactions.isEmpty)
        XCTAssertEqual(try f.store.cloudKitSQLiteStore.recordCounts().recurrenceRules, 0)
        let tombstones = try f.store.cloudKitSQLiteStore.deletedTransactionIDs()
        XCTAssertTrue(Set(f.initial.transactions.map(\.id)).isSubset(of: tombstones))
        XCTAssertTrue(RecurringJournalEditor.materialized(disk, referenceDate: f.day(2040, 1, 1), calendar: f.calendar, deletedIDs: tombstones).transactions.isEmpty)
    }

    private struct Fixture {
        var store: MobileLedgerStore
        var initial: JournalData
        var ruleID: UUID
        var calendar: Calendar
        func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        }
    }

    private func fixture(count: Int, restoredUnlimited: Bool = false) throws -> Fixture {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!
        let ledger = Ledger(name: "Async recurrence fixture")
        let currency = Commodity(ledgerID: ledger.id, symbol: "USD", name: "US Dollar")
        let bank = Account(ledgerID: ledger.id, commodityID: currency.id, name: "Bank", kind: .asset)
        let expense = Account(ledgerID: ledger.id, commodityID: currency.id, name: "Expense", kind: .expense)
        var anchor = LedgerTransaction(ledgerID: ledger.id, date: start, payee: "Base payee", note: "Base note", number: "BASE-10", cleared: false,
            postings: [Posting(accountID: bank.id, commodityID: currency.id, amount: -10, listIndex: 0), Posting(accountID: expense.id, commodityID: currency.id, amount: 10, listIndex: 1)],
            recurrenceRule: RecurrenceRule(frequency: .monthly, occurrenceCount: count, preservesImportedMaterializations: false))
        let baseTemplate = RecurrenceTransactionTemplate(transaction: anchor)
        anchor.recurrenceRule?.templateHistory = RecurrenceTemplateHistory(baseTemplate: baseTemplate, scheduleAnchorDate: start)
        anchor.recurrenceRule?.continuation = RecurrenceContinuation(anchorDate: start, calendar: calendar)
        var data = JournalData(ledgers: [ledger], commodities: [currency], accounts: [bank, expense], transactions: [anchor], selectedLedgerID: ledger.id)
        data = RecurringJournalEditor.materialized(data, referenceDate: start, calendar: calendar)
        data.transactions.sort { $0.date < $1.date }
        for index in data.transactions.indices {
            data.transactions[index].externalTransactionID = "synthetic-backfill-\(index)"
            data.transactions[index].cleared = index == 2
        }
        if restoredUnlimited {
            data.preservesImportedRecurringMaterializations = true
            for index in data.transactions.indices {
                data.transactions[index].recurrenceRule?.occurrenceCount = nil
                data.transactions[index].recurrenceRule?.preservesImportedMaterializations = true
                data.transactions[index].recurrenceRule?.continuation?.allowsAutomaticExtension = true
            }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "AsyncRecurrenceTests-\(UUID())")
        var dependencies = CloudKitSyncDependencies.live
        dependencies.automaticTriggersEnabled = false
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data, cloudKitSyncDependencies: dependencies)
        stores.append(store)
        directories.append(directory)
        XCTAssertNil(store.validationError)
        XCTAssertEqual(data.transactions.count, count)
        return Fixture(store: store, initial: data, ruleID: try XCTUnwrap(anchor.recurrenceRule?.id), calendar: calendar)
    }

    private func rows(_ data: JournalData) -> [LedgerTransaction] { data.transactions.sorted { $0.date < $1.date } }
    private func reload(_ f: Fixture) throws -> JournalData { try XCTUnwrap(f.store.cloudKitSQLiteStore.loadData()) }
}
