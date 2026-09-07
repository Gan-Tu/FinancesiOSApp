import Foundation
import XCTest
@testable import FinancesClone

final class RecurrenceContinuationTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }
    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    private func fixture(count: Int? = nil, end: Date? = nil, frequency: RecurrenceFrequency = .monthly, workdays: Bool = false) -> JournalData {
        let ledger = Ledger(name: "Continuation")
        let currency = Commodity(ledgerID: ledger.id, symbol: "USD", name: "Dollar")
        let bank = Account(ledgerID: ledger.id, commodityID: currency.id, name: "Bank", kind: .asset)
        let expense = Account(ledgerID: ledger.id, commodityID: currency.id, name: "Expense", kind: .expense)
        let start = frequency == .daily ? day(2026, 3, 6) : day(2026, 1, 31)
        var row = LedgerTransaction(ledgerID: ledger.id, date: start, payee: "Base payee", note: "Base note", number: "42", cleared: true,
            postings: [Posting(accountID: bank.id, commodityID: currency.id, amount: -10), Posting(accountID: expense.id, commodityID: currency.id, amount: 10, listIndex: 1)],
            recurrenceRule: RecurrenceRule(frequency: frequency, occurrenceCount: count, endDate: end, onWorkdays: workdays))
        let template = RecurrenceTransactionTemplate(transaction: row)
        row.recurrenceRule?.templateHistory = RecurrenceTemplateHistory(baseTemplate: template, scheduleAnchorDate: start)
        row.recurrenceRule?.continuation = RecurrenceContinuation(anchorDate: start, calendar: calendar)
        return JournalData(ledgers: [ledger], commodities: [currency], accounts: [bank, expense], transactions: [row], selectedLedgerID: ledger.id)
    }
    private func encodedRestore(_ data: JournalData, deleted: Set<UUID> = []) throws -> JournalData {
        let prepared = RecurringJournalEditor.preparingRecurrencesForBackup(data, referenceDate: day(2026, 2, 1), calendar: calendar, deletedIDs: deleted)
        let decoded = try JSONDecoder.appDecoder.decode(JournalData.self, from: JSONEncoder.appEncoder.encode(prepared))
        return RecurringJournalEditor.resumingRecurrencesFromBackup(decoded, referenceDate: day(2026, 2, 1), calendar: calendar)
    }
    private func preservedContent(_ row: LedgerTransaction) -> LedgerTransaction {
        var copy = row
        copy.recurrenceRule?.continuation = nil
        copy.recurrenceRule?.preservesImportedMaterializations = nil
        return copy
    }

    func testUnlimitedRestoreContinuesPastSavedHorizonWithoutReopeningExceptions() throws {
        var data = RecurringJournalEditor.materialized(fixture(), referenceDate: day(2026, 2, 1), calendar: calendar)
        let initial = data.transactions.sorted { $0.date < $1.date }
        var deleted = Set<UUID>()
        for row in [initial[0], initial[20], initial.last!] {
            let result = try RecurringJournalEditor.deleting(row.id, scope: .occurrence, in: data, calendar: calendar)
            data = result.journal; deleted.formUnion(result.deletedIDs)
        }
        var moved = initial[5]
        moved.date = calendar.date(byAdding: .day, value: 2, to: moved.date)!
        moved.note = "One occurrence only"; moved.postings[0].amount = -17; moved.postings[1].amount = 17
        data = try RecurringJournalEditor.apply(moved, replacing: moved.id, in: data, referenceDate: day(2026, 2, 1), calendar: calendar, deletedIDs: deleted)
        var future = initial[9]
        future.note = "Future template"; future.payee = "New payee"; future.number = "99"
        future.postings[0].amount = -22; future.postings[1].amount = 22
        data = try RecurringJournalEditor.apply(future, replacing: future.id, in: data, scope: .future, referenceDate: day(2026, 2, 1), calendar: calendar, deletedIDs: deleted)
        let restored = try encodedRestore(data, deleted: deleted)
        let extended = RecurringJournalEditor.materialized(restored, referenceDate: day(2033, 2, 1), calendar: calendar)
        let oldIDs = Set(data.transactions.map(\.id))
        for old in data.transactions {
            XCTAssertEqual(preservedContent(try XCTUnwrap(extended.transactions.first { $0.id == old.id })), preservedContent(old))
        }
        XCTAssertTrue(deleted.isDisjoint(with: Set(extended.transactions.map(\.id))))
        let additions = extended.transactions.filter { !oldIDs.contains($0.id) }
        XCTAssertFalse(additions.isEmpty)
        XCTAssertTrue(additions.allSatisfy { $0.date > initial.last!.date })
        XCTAssertTrue(additions.allSatisfy { $0.note == "Future template" && $0.payee == "New payee" && $0.number == "99" && $0.postings[0].amount == -22 })
        XCTAssertTrue(additions.allSatisfy { calendar.component(.day, from: $0.date) == calendar.range(of: .day, in: .month, for: $0.date)!.count })
        XCTAssertEqual(Set(extended.transactions.map(\.id)).count, extended.transactions.count)
    }

    func testFiniteAndEndedSchedulesResumeButNeverExceedTheirRules() throws {
        let partial = try encodedRestore(fixture(count: 5))
        let complete = RecurringJournalEditor.materialized(partial, referenceDate: day(2035, 1, 1), calendar: calendar)
        XCTAssertEqual(complete.transactions.count, 5)
        XCTAssertEqual(complete.transactions.map(\.date).sorted(), [day(2026,1,31), day(2026,2,28), day(2026,3,31), day(2026,4,30), day(2026,5,31)])
        let last = try XCTUnwrap(complete.transactions.max { $0.date < $1.date })
        let deleted = try RecurringJournalEditor.deleting(last.id, scope: .occurrence, in: complete, calendar: calendar)
        let restored = try encodedRestore(deleted.journal, deleted: deleted.deletedIDs)
        XCTAssertEqual(RecurringJournalEditor.materialized(restored, referenceDate: day(2040,1,1), calendar: calendar).transactions.count, 4)
        let ended = try encodedRestore(fixture(end: day(2026, 4, 30)))
        let endedResult = RecurringJournalEditor.materialized(ended, referenceDate: day(2040,1,1), calendar: calendar)
        XCTAssertEqual(endedResult.transactions.count, 4)
        XCTAssertTrue(endedResult.transactions.allSatisfy { $0.date <= day(2026,4,30) })
    }

    func testCalendarAndProgressSurviveSQLiteAndFreshRuleIdentities() throws {
        let original = RecurringJournalEditor.materialized(fixture(frequency: .daily, workdays: true), referenceDate: day(2026,3,6), calendar: calendar)
        var restored = try encodedRestore(original)
        let newRuleID = UUID()
        for index in restored.transactions.indices {
            restored.transactions[index].id = UUID()
            restored.transactions[index].recurrenceRule?.id = newRuleID
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sqlite = SQLiteJournalStore(databaseURL: folder.appendingPathComponent("journal.sqlite"))
        try sqlite.replaceData(restored, trackSyncChanges: false)
        let disk = try XCTUnwrap(sqlite.loadData())
        XCTAssertEqual(disk.transactions.first?.recurrenceRule?.continuation, restored.transactions.first?.recurrenceRule?.continuation)
        var elsewhere = Calendar(identifier: .gregorian); elsewhere.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let extended = RecurringJournalEditor.materialized(disk, referenceDate: day(2034,3,6), calendar: elsewhere)
        let ids = Set(disk.transactions.map(\.id))
        let newRows = extended.transactions.filter { !ids.contains($0.id) }
        XCTAssertFalse(newRows.isEmpty)
        XCTAssertTrue(newRows.allSatisfy { calendar.component(.hour, from: $0.date) == 12 && !calendar.isDateInWeekend($0.date) })
        XCTAssertEqual(Set(extended.transactions.map(\.date)).count, extended.transactions.count)
    }

    func testOlderSnapshotResumesAfterItsCoveredRange() throws {
        var data = fixture()
        data.transactions[0].recurrenceRule?.continuation = nil
        data.preservesImportedRecurringMaterializations = true
        var march = data.transactions[0]; march.id = UUID(); march.date = day(2026,3,31)
        data.transactions.append(march)
        let restored = RecurringJournalEditor.resumingRecurrencesFromBackup(data, referenceDate: day(2026,4,1), calendar: calendar)
        let result = RecurringJournalEditor.materialized(restored, referenceDate: day(2026,4,1), calendar: calendar)
        XCTAssertFalse(result.transactions.contains { calendar.isDate($0.date, inSameDayAs: day(2026,2,28)) })
        XCTAssertTrue(result.transactions.contains { calendar.isDate($0.date, inSameDayAs: day(2026,4,30)) })
        XCTAssertGreaterThan(result.transactions.count, 2)
    }
}
