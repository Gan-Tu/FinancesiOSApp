import Foundation
import XCTest
@testable import FinancesClone

final class RecurringJournalEditorTests: XCTestCase {
    func testDeletingFirstOccurrencePreservesMonthEndCadenceAndFiniteCount() throws {
        let f = Fixture()
        let initial = try f.series(count: 4)
        var first = f.rows(initial)[0]; first.date = f.day(2026, 1, 31)
        let original = try RecurringJournalEditor.apply(first, replacing: first.id, in: initial, scope: .future, referenceDate: f.day(2026, 1, 1), calendar: f.calendar)
        let rows = f.rows(original)
        let deletion = try RecurringJournalEditor.deleting(rows[0].id, scope: .occurrence, in: original, calendar: f.calendar)
        let reopened = try roundTrip(deletion.journal)
        let projected = RecurringJournalEditor.materialized(reopened, referenceDate: f.day(2030, 1, 1), calendar: f.calendar, deletedIDs: deletion.deletedIDs)
        XCTAssertEqual(f.rows(projected).map(\.date), [f.day(2026, 2, 28), f.day(2026, 3, 31), f.day(2026, 4, 30)])
        XCTAssertEqual(Set(f.rows(projected).map(\.id)), Set(rows.dropFirst().map(\.id)))
        XCTAssertEqual(f.rows(projected).first?.recurrenceRule?.templateHistory?.scheduleAnchorDate, first.date)
    }

    func testDeletingFutureOccurrencesStopsProjectionAndKeepsEarlierRows() throws {
        let f = Fixture()
        let original = try f.series(count: 5)
        let rows = f.rows(original)
        let deletion = try RecurringJournalEditor.deleting(rows[2].id, scope: .future, in: original, calendar: f.calendar)
        XCTAssertEqual(deletion.deletedIDs, Set(rows.dropFirst(2).map(\.id)))
        let projected = RecurringJournalEditor.materialized(try roundTrip(deletion.journal), referenceDate: f.day(2034, 1, 1), calendar: f.calendar, deletedIDs: deletion.deletedIDs)
        XCTAssertEqual(f.rows(projected).map(\.id), rows.prefix(2).map(\.id))
        XCTAssertTrue(f.rows(projected).allSatisfy { $0.recurrenceRule?.endDate == f.calendar.startOfDay(for: f.day(2026, 3, 9)) })
    }

    func testOneOccurrenceKeepsBaseHistoryAndEveryOtherOccurrenceAfterRoundTrip() throws {
        let f = Fixture()
        let original = try f.series(count: 4)
        let rows = f.rows(original)
        var edit = rows[1]
        edit.payee = "Exception"; edit.postings[0].amount = -99; edit.postings[1].amount = 99
        let changed = try RecurringJournalEditor.apply(edit, replacing: edit.id, in: original, calendar: f.calendar)
        let reloaded = try roundTrip(changed)
        XCTAssertEqual(f.rows(reloaded).map(\.payee), ["Base", "Exception", "Base", "Base"])
        XCTAssertEqual(f.rows(reloaded).map { $0.postings[0].amount }, [-10, -99, -10, -10])
        XCTAssertEqual(f.rows(reloaded).map(\.id), rows.map(\.id))
        XCTAssertEqual(f.rows(reloaded)[0], rows[0])
        XCTAssertEqual(f.rows(reloaded)[2], rows[2])
        XCTAssertEqual(f.rows(reloaded)[3], rows[3])
        XCTAssertEqual(f.runningCash(reloaded), [-10, -109, -119, -129])
    }

    func testFutureBoundarySurvivesReloadAndOneOffDoesNotLeakIntoFarProjection() throws {
        let f = Fixture()
        var original = try f.series(count: 4)
        for index in original.transactions.indices { original.transactions[index].recurrenceRule?.occurrenceCount = nil }
        for index in original.transactions.indices {
            original.transactions[index].externalTransactionID = "existing-\(index)"
            original.transactions[index].cleared = index.isMultiple(of: 2)
        }
        original.transactions[2].attachment = AttachmentContainer(assets: [AttachmentAsset(originalFilename: "Later receipt", storedPath: "Attachments/later.txt", mimeType: "text/plain", sizeBytes: 1)])
        let oldRows = f.rows(original)
        var future = oldRows[1]
        future.payee = "Future terms"; future.note = "From February"
        future.postings[0].amount = -20; future.postings[1].amount = 20
        var changed = try RecurringJournalEditor.apply(future, replacing: future.id, in: original, scope: .future, calendar: f.calendar)
        let futureRows = f.rows(changed)
        XCTAssertEqual(futureRows.map(\.payee), ["Base", "Future terms", "Future terms", "Future terms"])
        for (old, new) in zip(oldRows.dropFirst(), futureRows.dropFirst()) {
            XCTAssertEqual(new.id, old.id); XCTAssertEqual(new.date, old.date)
            XCTAssertEqual(new.sourceID, old.sourceID); XCTAssertEqual(new.externalTransactionID, old.externalTransactionID)
            XCTAssertEqual(new.attachment, old.attachment); XCTAssertEqual(new.cleared, old.cleared)
        }
        changed = try roundTrip(changed)
        var exception = f.rows(changed)[2]
        exception.payee = "One-off"; exception.postings[0].amount = -77; exception.postings[1].amount = 77
        changed = try RecurringJournalEditor.apply(exception, replacing: exception.id, in: changed, calendar: f.calendar)
        changed = try roundTrip(changed)
        let extended = RecurringJournalEditor.materialized(changed, referenceDate: f.day(2028, 1, 1), calendar: f.calendar)
        let newRows = f.rows(extended).filter { $0.date > f.day(2026, 4, 10) }
        XCTAssertFalse(newRows.isEmpty)
        XCTAssertTrue(newRows.allSatisfy { $0.payee == "Future terms" && $0.postings[0].amount == -20 && !$0.cleared && $0.attachment == nil })
        XCTAssertEqual(extended.transactions.first { $0.id == exception.id }?.payee, "One-off")
        XCTAssertEqual(f.rows(extended).first?.recurrenceRule?.templateHistory?.changes.count, 1)
    }

    func testAnchorDateRequiresConfirmationAndMovesFiniteSeriesWithoutOldSlots() throws {
        let f = Fixture()
        let original = try f.series(count: 4)
        let oldRows = f.rows(original)
        var edit = oldRows[0]
        edit.date = f.day(2026, 1, 5); edit.payee = "Moved schedule"
        XCTAssertThrowsError(try RecurringJournalEditor.apply(edit, replacing: edit.id, in: original, calendar: f.calendar))
        let changed = try RecurringJournalEditor.apply(edit, replacing: edit.id, in: original, scope: .future, referenceDate: f.day(2026, 1, 1), calendar: f.calendar)
        XCTAssertEqual(f.rows(changed).map(\.date), [1, 2, 3, 4].map { f.day(2026, $0, 5) })
        XCTAssertEqual(f.rows(changed).map(\.payee), Array(repeating: "Moved schedule", count: 4))
        XCTAssertEqual(f.rows(changed).first?.externalTransactionID, oldRows.first?.externalTransactionID)
        XCTAssertEqual(f.rows(changed).first?.attachment, oldRows.first?.attachment)
        let extended = RecurringJournalEditor.materialized(try roundTrip(changed), referenceDate: f.day(2033, 1, 1), calendar: f.calendar)
        XCTAssertEqual(f.rows(extended), f.rows(changed))
        XCTAssertTrue(Set(f.rows(extended).dropFirst().map(\.id)).isDisjoint(with: oldRows.dropFirst().map(\.id)))
        XCTAssertEqual(f.runningCash(extended), [-10, -20, -30, -40])
    }

    func testAnchorFrequencyIntervalWorkdaysEndAndCountUseOriginalAnchorCalculation() throws {
        let f = Fixture()
        let original = try f.series(count: 5)
        var edit = f.rows(original)[0]
        edit.date = f.day(2026, 1, 31) // Saturday
        edit.recurrenceRule?.frequency = .weekly
        edit.recurrenceRule?.intervalValue = 2
        edit.recurrenceRule?.onWorkdays = true
        edit.recurrenceRule?.endDate = f.day(2026, 3, 16)
        let changed = try RecurringJournalEditor.apply(edit, replacing: edit.id, in: original, scope: .future, referenceDate: f.day(2026, 1, 1), calendar: f.calendar)
        XCTAssertEqual(f.rows(changed).map(\.date), [f.day(2026, 1, 31), f.day(2026, 2, 16), f.day(2026, 3, 2), f.day(2026, 3, 16)])
        XCTAssertEqual(f.rows(changed).count, 4) // end date wins over count=5
        XCTAssertTrue(f.rows(changed).allSatisfy { $0.recurrenceRule?.frequency == .weekly && $0.recurrenceRule?.intervalValue == 2 })
    }

    func testGeneratedDateMoveKeepsIDAndDoesNotResurrectOriginalScheduledSlot() throws {
        let f = Fixture()
        let original = try f.series(count: 4)
        let rows = f.rows(original)
        var edit = rows[1]; edit.date = f.day(2026, 2, 13)
        let changed = try RecurringJournalEditor.apply(edit, replacing: edit.id, in: original, calendar: f.calendar)
        let extended = RecurringJournalEditor.materialized(try roundTrip(changed), referenceDate: f.day(2029, 1, 1), calendar: f.calendar)
        XCTAssertEqual(f.rows(extended).count, 4)
        XCTAssertEqual(extended.transactions.filter { $0.id == edit.id }.count, 1)
        XCTAssertEqual(extended.transactions.first { $0.id == edit.id }?.date, edit.date)
        XCTAssertFalse(extended.transactions.contains { $0.date == f.day(2026, 2, 10) })
        XCTAssertEqual(extended.transactions.first { $0.id == rows[2].id }, rows[2])
    }

    func testGeneratedRepeatChangesAreRejectedRatherThanMutatingSharedRule() throws {
        let f = Fixture(); let original = try f.series(count: 4)
        var edit = f.rows(original)[1]; edit.recurrenceRule?.frequency = .daily
        XCTAssertThrowsError(try RecurringJournalEditor.apply(edit, replacing: edit.id, in: original, scope: .future, calendar: f.calendar))
        var collision = f.rows(original)[1]; collision.date = f.rows(original)[2].date
        XCTAssertThrowsError(try RecurringJournalEditor.apply(collision, replacing: collision.id, in: original, calendar: f.calendar))
    }

    func testLegacyHistoryIsCapturedBeforeAnchorOneOffAndImportedRowsStayAuthoritative() throws {
        let f = Fixture(); var original = try f.series(count: 1)
        original.preservesImportedRecurringMaterializations = true
        // Legacy imports predate the per-series override now set for new rules.
        for index in original.transactions.indices { original.transactions[index].recurrenceRule?.preservesImportedMaterializations = nil }
        original.transactions[0].recurrenceRule?.templateHistory = nil
        original.transactions[0].recurrenceRule?.occurrenceCount = nil
        var edit = original.transactions[0]; edit.payee = "Anchor exception"
        let changed = try RecurringJournalEditor.apply(edit, replacing: edit.id, in: original, referenceDate: f.day(2030, 1, 1), calendar: f.calendar)
        XCTAssertEqual(changed.transactions.count, 1)
        XCTAssertEqual(changed.transactions[0].recurrenceRule?.templateHistory?.baseTemplate.payee, "Base")
        XCTAssertEqual(RecurringJournalEditor.materialized(changed, referenceDate: f.day(2040, 1, 1), calendar: f.calendar).transactions, changed.transactions)
        XCTAssertEqual(changed.transactions[0].sourceID, original.transactions[0].sourceID)
        XCTAssertEqual(changed.transactions[0].externalTransactionID, original.transactions[0].externalTransactionID)
    }

    func testStoppingAnchorRemovesFollowingOccurrencesOnlyAfterSeriesConfirmation() throws {
        let f = Fixture(); let original = try f.series(count: 4)
        var edit = f.rows(original)[0]; edit.recurrenceRule = nil
        XCTAssertThrowsError(try RecurringJournalEditor.apply(edit, replacing: edit.id, in: original, calendar: f.calendar))
        let changed = try RecurringJournalEditor.apply(edit, replacing: edit.id, in: original, scope: .future, calendar: f.calendar)
        XCTAssertEqual(changed.transactions, [edit])
        XCTAssertNil(changed.transactions[0].recurrenceRule)
    }

    func testDeletedGeneratedSlotCountsTowardFiniteLimitAfterReload() throws {
        let f = Fixture(); var original = try f.series(count: 4)
        let removed = f.rows(original)[1]
        original.transactions.removeAll { $0.id == removed.id }
        let topped = RecurringJournalEditor.materialized(try roundTrip(original), referenceDate: f.day(2030, 1, 1), calendar: f.calendar, deletedIDs: [removed.id])
        XCTAssertEqual(f.rows(topped).map(\.date), [f.day(2026, 1, 10), f.day(2026, 3, 10), f.day(2026, 4, 10)])
        XCTAssertFalse(topped.transactions.contains { $0.id == removed.id })
    }

    func testFarFutureOneOffExtendsNormalProjectionButNotImportedRows() throws {
        let f = Fixture(); var original = try f.series(count: 2)
        for index in original.transactions.indices { original.transactions[index].recurrenceRule?.occurrenceCount = nil }
        var oneOff = f.anchor; oneOff.id = UUID(); oneOff.recurrenceRule = nil; oneOff.date = f.day(2034, 5, 12)
        oneOff.attachment = nil; oneOff.sourceID = nil; oneOff.externalTransactionID = nil
        oneOff.postings = oneOff.postings.map { posting in var copy = posting; copy.id = UUID(); return copy }
        let normal = try RecurringJournalEditor.apply(oneOff, replacing: nil, in: original, referenceDate: f.day(2026, 1, 1), calendar: f.calendar)
        XCTAssertGreaterThan(normal.transactions.count, 80)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(f.rows(normal).last?.date), f.day(2034, 5, 10))
        original.preservesImportedRecurringMaterializations = true
        // Legacy imports predate the per-series override now set for new rules.
        for index in original.transactions.indices { original.transactions[index].recurrenceRule?.preservesImportedMaterializations = nil }
        let imported = try RecurringJournalEditor.apply(oneOff, replacing: nil, in: original, referenceDate: f.day(2026, 1, 1), calendar: f.calendar)
        XCTAssertEqual(imported.transactions.count, 3)
    }

    func testAnchorDeletionSelectsWholeSeriesAndGeneratedDeletionOnlyOneID() throws {
        let f = Fixture(); let original = try f.series(count: 4)
        let rows = f.rows(original)
        XCTAssertEqual(try RecurringJournalEditor.deleting(rows[0].id, scope: .future, in: original).deletedIDs, Set(rows.map(\.id)))
        XCTAssertEqual(try RecurringJournalEditor.deleting(rows[1].id, scope: .occurrence, in: original).deletedIDs, [rows[1].id])
        XCTAssertThrowsError(try RecurringJournalEditor.deleting(UUID(), scope: .occurrence, in: original))
    }

    func testMonthEndAndLeapDayCalculationsRemainAnchoredToOriginalDate() throws {
        let f = Fixture(); var monthly = f.anchor
        monthly.date = f.day(2026, 1, 31); monthly.recurrenceRule?.occurrenceCount = 4
        let months = try RecurringJournalEditor.apply(monthly, replacing: nil, in: f.journal, referenceDate: f.day(2026, 1, 1), calendar: f.calendar)
        XCTAssertEqual(f.rows(months).map(\.date), [f.day(2026, 1, 31), f.day(2026, 2, 28), f.day(2026, 3, 31), f.day(2026, 4, 30)])
        var yearly = f.anchor; yearly.date = f.day(2024, 2, 29)
        yearly.recurrenceRule?.frequency = .yearly; yearly.recurrenceRule?.occurrenceCount = 4
        let years = try RecurringJournalEditor.apply(yearly, replacing: nil, in: f.journal, referenceDate: f.day(2026, 1, 1), calendar: f.calendar)
        XCTAssertEqual(f.rows(years).map(\.date), [f.day(2024, 2, 29), f.day(2025, 2, 28), f.day(2026, 2, 28), f.day(2027, 2, 28)])
    }

    func testReplacingFutureBoundaryKeepsOneBoundaryAndIndependentPostingIDs() throws {
        let f = Fixture(); let original = try f.series(count: 4)
        var edit = f.rows(original)[1]; edit.payee = "First terms"
        var changed = try RecurringJournalEditor.apply(edit, replacing: edit.id, in: original, scope: .future, calendar: f.calendar)
        edit = f.rows(changed)[1]; edit.payee = "Replacement terms"
        changed = try RecurringJournalEditor.apply(edit, replacing: edit.id, in: changed, scope: .future, calendar: f.calendar)
        XCTAssertEqual(f.rows(changed).map(\.payee), ["Base", "Replacement terms", "Replacement terms", "Replacement terms"])
        XCTAssertEqual(f.rows(changed)[0].recurrenceRule?.templateHistory?.changes.count, 1)
        let ids = changed.transactions.flatMap { $0.postings.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDateMoveCannotSilentlyReanchorAndUnknownCustomPatternIsPreserved() throws {
        let f = Fixture(); var original = try f.series(count: 4)
        var early = f.rows(original)[1]; early.date = f.day(2025, 12, 10)
        XCTAssertThrowsError(try RecurringJournalEditor.apply(early, replacing: early.id, in: original, calendar: f.calendar))
        original.preservesImportedRecurringMaterializations = true
        // Legacy imports predate the per-series override now set for new rules.
        for index in original.transactions.indices { original.transactions[index].recurrenceRule?.preservesImportedMaterializations = nil }
        for index in original.transactions.indices { original.transactions[index].recurrenceRule?.frequency = .custom }
        var anchor = f.rows(original)[0]; anchor.date = f.day(2026, 1, 5)
        XCTAssertThrowsError(try RecurringJournalEditor.apply(anchor, replacing: anchor.id, in: original, scope: .future, calendar: f.calendar))
        var detail = f.rows(original)[1]; detail.payee = "Custom-pattern exception"
        let changed = try RecurringJournalEditor.apply(detail, replacing: detail.id, in: original, calendar: f.calendar)
        XCTAssertEqual(f.rows(changed).map(\.date), f.rows(original).map(\.date))
        XCTAssertEqual(f.rows(changed).count, 4)
    }

    func testLongFiniteDailyScheduleReachesItsEndAndDoesNotStopAtOldWorkWindow() throws {
        let f = Fixture()
        var anchor = f.anchor
        anchor.date = f.day(2010, 1, 1)
        anchor.recurrenceRule?.frequency = .daily
        anchor.recurrenceRule?.endDate = f.day(2030, 1, 1)
        let reference = f.day(2026, 9, 7)
        let materialized = try RecurringJournalEditor.apply(anchor, replacing: nil, in: f.journal, referenceDate: reference, calendar: f.calendar)
        let expected = try XCTUnwrap(f.calendar.dateComponents([.day], from: anchor.date, to: f.day(2030, 1, 1)).day) + 1
        XCTAssertEqual(f.rows(materialized).count, expected)
        XCTAssertEqual(f.rows(materialized).last?.date, f.day(2030, 1, 1))
        XCTAssertEqual(RecurringJournalEditor.materialized(materialized, referenceDate: f.day(2026, 9, 8), calendar: f.calendar).transactions, materialized.transactions)
    }

    func testLongCountedWorkdaySchedulePreservesDeletedAndMovedSlotsWhenExtended() throws {
        let f = Fixture()
        var anchor = f.anchor
        anchor.recurrenceRule?.frequency = .daily
        anchor.recurrenceRule?.onWorkdays = true
        anchor.recurrenceRule?.occurrenceCount = 3005
        var journal = try RecurringJournalEditor.apply(anchor, replacing: nil, in: f.journal, referenceDate: f.day(2026, 1, 1), calendar: f.calendar)
        XCTAssertEqual(f.rows(journal).count, 3005)
        let initial = f.rows(journal)
        let deleted = initial[3]
        journal = try RecurringJournalEditor.deleting(deleted.id, scope: .occurrence, in: journal, calendar: f.calendar).journal
        var moved = initial[10]
        moved.date = f.day(2040, 1, 1)
        journal = try RecurringJournalEditor.apply(moved, replacing: moved.id, in: journal, referenceDate: f.day(2026, 1, 1), calendar: f.calendar, deletedIDs: [deleted.id])
        for index in journal.transactions.indices { journal.transactions[index].recurrenceRule?.occurrenceCount = 3010 }
        let extended = RecurringJournalEditor.materialized(journal, referenceDate: f.day(2026, 9, 7), calendar: f.calendar, deletedIDs: [deleted.id])
        XCTAssertEqual(f.rows(extended).count, 3009)
        XCTAssertFalse(extended.transactions.contains { $0.id == deleted.id })
        XCTAssertEqual(extended.transactions.first { $0.id == moved.id }?.date, moved.date)
        XCTAssertFalse(extended.transactions.contains { $0.date == initial[10].date })
        XCTAssertEqual(Set(extended.transactions.map { f.calendar.startOfDay(for: $0.date) }).count, extended.transactions.count)
        XCTAssertEqual(RecurringJournalEditor.materialized(extended, referenceDate: f.day(2026, 9, 8), calendar: f.calendar, deletedIDs: [deleted.id]).transactions, extended.transactions)
    }

    private func roundTrip(_ journal: JournalData) throws -> JournalData {
        try JSONDecoder().decode(JournalData.self, from: JSONEncoder().encode(journal))
    }

    private struct Fixture {
        let calendar: Calendar
        let journal: JournalData
        let anchor: LedgerTransaction
        init() {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
            calendar = cal
            let ledger = Ledger(name: "Fixture")
            let currency = Commodity(ledgerID: ledger.id, symbol: "USD", name: "US Dollar")
            let cash = Account(ledgerID: ledger.id, commodityID: currency.id, name: "Cash", kind: .asset)
            let expense = Account(ledgerID: ledger.id, commodityID: currency.id, name: "Expense", kind: .expense)
            anchor = LedgerTransaction(ledgerID: ledger.id, sourceID: UUID(), date: cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!, payee: "Base", note: "Original", number: "A", cleared: true,
                postings: [Posting(accountID: cash.id, commodityID: currency.id, amount: -10, listIndex: 0), Posting(accountID: expense.id, commodityID: currency.id, amount: 10, listIndex: 1)],
                recurrenceRule: RecurrenceRule(frequency: .monthly),
                attachment: AttachmentContainer(assets: [AttachmentAsset(originalFilename: "Receipt", storedPath: "Attachments/fixture.txt", mimeType: "text/plain", sizeBytes: 1)]), externalTransactionID: "imported-anchor")
            var data = JournalData(); data.ledgers = [ledger]; data.selectedLedgerID = ledger.id
            data.commodities = [currency]; data.accounts = [cash, expense]
            data.sources = [TransactionSource(id: anchor.sourceID!, ledgerID: ledger.id)]
            journal = data
        }
        func day(_ year: Int, _ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))! }
        func series(count: Int) throws -> JournalData {
            var first = anchor; first.recurrenceRule?.occurrenceCount = count
            return try RecurringJournalEditor.apply(first, replacing: nil, in: journal, referenceDate: day(2026, 1, 1), calendar: calendar)
        }
        func rows(_ data: JournalData) -> [LedgerTransaction] { data.transactions.filter { $0.recurrenceRule != nil }.sorted { $0.date < $1.date } }
        func runningCash(_ data: JournalData) -> [Decimal] {
            var amount = Decimal.zero
            return rows(data).map { row in amount += row.postings[0].amount; return amount }
        }
    }
}
