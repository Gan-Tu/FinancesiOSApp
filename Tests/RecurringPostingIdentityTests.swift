import Foundation
import XCTest
@testable import FinancesClone

@MainActor
final class RecurringPostingIdentityTests: XCTestCase {
    private struct Fixture {
        var data: JournalData
        let calendar: Calendar
        let bank: UUID
        let otherBank: UUID
        let expense: UUID
        let otherExpense: UUID
        let usd: UUID
        let eur: UUID
        var rows: [LedgerTransaction] { data.transactions.sorted { $0.date < $1.date } }
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012X", value))!
    }

    private func fixture(importedSplit: Bool = false) -> Fixture {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let ledger = Ledger(id: id(1), name: "Posting identity fixture")
        let usd = Commodity(id: id(2), ledgerID: ledger.id, symbol: "USD", name: "US Dollar")
        let eur = Commodity(id: id(3), ledgerID: ledger.id, symbol: "EUR", name: "Euro")
        let bank = Account(id: id(10), ledgerID: ledger.id, commodityID: usd.id, name: "Bank", kind: .asset)
        let otherBank = Account(id: id(11), ledgerID: ledger.id, commodityID: usd.id, name: "Other Bank", kind: .asset)
        let expense = Account(id: id(12), ledgerID: ledger.id, commodityID: usd.id, name: "Expense", kind: .expense)
        let otherExpense = Account(id: id(13), ledgerID: ledger.id, commodityID: usd.id, name: "Other Expense", kind: .expense)
        var rule = RecurrenceRule(id: id(20), frequency: .monthly, occurrenceCount: 5)
        rule.preservesImportedMaterializations = true
        var rows: [LedgerTransaction] = []
        for month in 0..<5 {
            let date = calendar.date(from: DateComponents(year: 2026, month: month + 1, day: 10, hour: 12))!
            var postings = [
                Posting(id: id(1_000 + month * 10), accountID: bank.id, commodityID: usd.id, amount: -10, listIndex: importedSplit ? 7 : 0),
                Posting(id: id(1_001 + month * 10), accountID: expense.id, commodityID: usd.id, amount: 10, listIndex: importedSplit ? 7 : 1)
            ]
            if importedSplit {
                postings.append(Posting(id: id(1_002 + month * 10), accountID: expense.id, commodityID: nil, amount: 0, listIndex: 31))
                postings = [postings[2], postings[1], postings[0]]
            }
            let asset = AttachmentAsset(id: id(5_000 + month), originalFilename: "receipt-\(month).jpg", storedPath: "Attachments/fixture-\(month).jpg", sizeBytes: 1)
            rows.append(LedgerTransaction(id: id(100 + month), ledgerID: ledger.id, sourceID: id(3_000 + month),
                date: date, payee: "Base payee", note: "Base note", number: "BASE", cleared: month.isMultiple(of: 2),
                postings: postings, recurrenceRule: rule, attachment: AttachmentContainer(id: id(4_000 + month), assets: [asset], createdAt: date),
                externalTransactionID: "import-\(month)"))
        }
        rule.templateHistory = RecurrenceTemplateHistory(baseTemplate: RecurrenceTransactionTemplate(transaction: rows[0]), scheduleAnchorDate: rows[0].date)
        rule.continuation = RecurrenceContinuation(anchorDate: rows[0].date, calendar: calendar,
            nextOccurrenceIndex: rows.count, consumedOccurrences: rows.count,
            lastScheduledDay: calendar.startOfDay(for: rows.last!.date), allowsAutomaticExtension: false)
        for index in rows.indices { rows[index].recurrenceRule = rule }
        var data = JournalData(ledgers: [ledger], commodities: [usd, eur], accounts: [bank, otherBank, expense, otherExpense], transactions: rows, selectedLedgerID: ledger.id)
        data.preservesImportedRecurringMaterializations = true
        return Fixture(data: data, calendar: calendar, bank: bank.id, otherBank: otherBank.id, expense: expense.id, otherExpense: otherExpense.id, usd: usd.id, eur: eur.id)
    }

    private func apply(_ edited: LedgerTransaction, in data: JournalData, calendar: Calendar) throws -> JournalData {
        try RecurringJournalEditor.apply(edited, replacing: edited.id, in: data, scope: .future,
            referenceDate: calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!, calendar: calendar)
    }

    private func ordered(_ postings: [Posting]) -> [Posting] {
        postings.sorted { $0.listIndex == $1.listIndex ? $0.id.uuidString < $1.id.uuidString : $0.listIndex < $1.listIndex }
    }

    private func assertOccurrenceFieldsPreserved(_ before: LedgerTransaction, _ after: LedgerTransaction,
                                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(after.id, before.id, file: file, line: line)
        XCTAssertEqual(after.sourceID, before.sourceID, file: file, line: line)
        XCTAssertEqual(after.date, before.date, file: file, line: line)
        XCTAssertEqual(after.cleared, before.cleared, file: file, line: line)
        XCTAssertEqual(after.attachment, before.attachment, file: file, line: line)
        XCTAssertEqual(after.externalTransactionID, before.externalTransactionID, file: file, line: line)
        XCTAssertEqual(after.recurrenceRule?.id, before.recurrenceRule?.id, file: file, line: line)
        XCTAssertEqual(after.recurrenceRule?.frequency, before.recurrenceRule?.frequency, file: file, line: line)
        XCTAssertEqual(after.recurrenceRule?.occurrenceCount, before.recurrenceRule?.occurrenceCount, file: file, line: line)
    }

    func testNotePayeeAndNumberOnlyFutureEditsDoNotChurnPostingIDs() throws {
        for field in ["note", "payee", "number"] {
            let f = fixture()
            var edited = f.rows[1]
            switch field {
            case "note": edited.note = "Future note"
            case "payee": edited.payee = "Future payee"
            default: edited.number = "FUTURE-42"
            }
            let result = try apply(edited, in: f.data, calendar: f.calendar)
            XCTAssertEqual(result.transactions.count, f.rows.count)
            for original in f.rows {
                let actual = try XCTUnwrap(result.transactions.first { $0.id == original.id })
                XCTAssertEqual(actual.postings, original.postings, "A field-only edit must keep occurrence-owned posting IDs and values")
                assertOccurrenceFieldsPreserved(original, actual)
                XCTAssertEqual(actual.note, original.date < edited.date ? original.note : edited.note)
                XCTAssertEqual(actual.payee, original.date < edited.date ? original.payee : edited.payee)
                XCTAssertEqual(actual.number, original.date < edited.date ? original.number : edited.number)
            }
        }
    }

    func testFuturePostingValuesReplaceAccountAmountAndLiteralOptionalCurrencyWithoutChangingIDs() throws {
        let currencies: [UUID?] = [nil, id(3)]
        for currency in currencies {
            let f = fixture()
            var edited = f.rows[1]
            edited.postings[0].accountID = f.otherBank
            edited.postings[1].accountID = f.otherExpense
            for index in edited.postings.indices { edited.postings[index].commodityID = currency }
            edited.postings[0].amount = Decimal(string: "-1234.56789")!
            edited.postings[1].amount = Decimal(string: "1234.56789")!
            let result = try apply(edited, in: f.data, calendar: f.calendar)
            XCTAssertEqual(result.transactions.first { $0.id == f.rows[0].id }?.postings, f.rows[0].postings)
            for original in f.rows.dropFirst() {
                let actual = try XCTUnwrap(result.transactions.first { $0.id == original.id })
                XCTAssertEqual(actual.postings.map(\.id), original.postings.map(\.id))
                XCTAssertEqual(actual.postings.map(\.accountID), [f.otherBank, f.otherExpense])
                XCTAssertEqual(actual.postings.map(\.commodityID), [currency, currency], "Nil is a literal account-currency choice, not a resolved default")
                XCTAssertEqual(actual.postings.map(\.amount), edited.postings.map(\.amount))
                XCTAssertEqual(actual.postings.map(\.listIndex), [0, 1])
                assertOccurrenceFieldsPreserved(original, actual)
            }
        }
    }

    func testSplitReorderAddRemoveAndRepeatedAccountsPreserveDestinationPositions() throws {
        let f = fixture()
        var edited = f.rows[1]
        edited.postings = [
            Posting(id: edited.postings[1].id, accountID: f.expense, commodityID: f.usd, amount: 0, listIndex: 0),
            Posting(id: edited.postings[0].id, accountID: f.bank, commodityID: f.usd, amount: -30, listIndex: 1),
            Posting(id: id(7_000), accountID: f.expense, commodityID: f.usd, amount: 30, listIndex: 2)
        ]
        let originalIDs = Set(f.rows.flatMap(\.postings).map(\.id)).union(edited.postings.map(\.id))
        let added = try apply(edited, in: f.data, calendar: f.calendar)
        var addedIDs = Set<UUID>()
        for original in f.rows.dropFirst(2) {
            let actual = try XCTUnwrap(added.transactions.first { $0.id == original.id })
            XCTAssertEqual(Array(actual.postings.prefix(2).map(\.id)), original.postings.map(\.id))
            XCTAssertFalse(originalIDs.contains(actual.postings[2].id))
            XCTAssertTrue(addedIDs.insert(actual.postings[2].id).inserted, "Added positions need separate IDs in each occurrence")
            XCTAssertEqual(actual.postings.map(\.accountID), [f.expense, f.bank, f.expense])
            XCTAssertEqual(actual.postings.map(\.amount), [0, -30, 30])
            XCTAssertEqual(actual.postings.map(\.listIndex), [0, 1, 2])
            assertOccurrenceFieldsPreserved(original, actual)
        }
        let allIDs = added.transactions.flatMap(\.postings).map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count, "Never reuse the edited occurrence's posting IDs elsewhere")
        let repeated = try apply(try XCTUnwrap(added.transactions.first { $0.id == edited.id }), in: added, calendar: f.calendar)
        XCTAssertEqual(repeated.transactions, added.transactions, "Repeating the same future edit must not mint more IDs")
        var removing = try XCTUnwrap(repeated.transactions.first { $0.id == edited.id })
        removing.postings.removeFirst()
        for index in removing.postings.indices { removing.postings[index].listIndex = index }
        let removed = try apply(removing, in: repeated, calendar: f.calendar)
        for original in f.rows.dropFirst(2) {
            let actual = try XCTUnwrap(removed.transactions.first { $0.id == original.id })
            XCTAssertEqual(actual.postings.map(\.id), original.postings.map(\.id))
            XCTAssertEqual(actual.postings.map(\.amount), [-30, 30])
            XCTAssertEqual(actual.postings.map(\.accountID), [f.bank, f.expense])
        }
        XCTAssertTrue(addedIDs.isDisjoint(with: Set(removed.transactions.flatMap(\.postings).map(\.id))))
    }

    func testImportedDestinationIDsUseDisplayOrderWhileEditedValuesKeepArrayOrder() throws {
        for sourceIndexes in [[7, 31, 7], [0, 0, 0]] {
            var f = fixture(importedSplit: true)
            let originalRows = f.rows
            f.data.transactions = [originalRows[3], originalRows[0], originalRows[4], originalRows[1], originalRows[2]]
            var edited = originalRows[1]
            let display = ordered(edited.postings)
            edited.postings = [display[1], display[2], display[0]]
            for index in edited.postings.indices {
                edited.postings[index].listIndex = sourceIndexes[index]
                if edited.postings[index].accountID == f.bank { edited.postings[index].amount = -17 }
                else if edited.postings[index].amount != 0 { edited.postings[index].amount = 17 }
            }
            XCTAssertEqual(edited.postings.map(\.amount), [17, 0, -17])
            let result = try apply(edited, in: f.data, calendar: f.calendar)
            XCTAssertEqual(result.transactions.first { $0.id == originalRows[0].id }?.postings, originalRows[0].postings, "Earlier imported storage remains untouched")
            for original in originalRows.dropFirst(2) {
                let actual = try XCTUnwrap(result.transactions.first { $0.id == original.id })
                XCTAssertEqual(actual.postings.map(\.id), ordered(original.postings).map(\.id), "Only destination identity is resolved by display index and UUID tie")
                XCTAssertEqual(actual.postings.map(\.amount), [17, 0, -17], "Future values must retain edited array order, even when source listIndex is stale or all zero")
                XCTAssertEqual(actual.postings.map(\.accountID), edited.postings.map(\.accountID))
                XCTAssertEqual(actual.postings.map(\.commodityID), [f.usd, nil, f.usd])
                XCTAssertEqual(actual.postings.map(\.listIndex), [0, 1, 2])
                assertOccurrenceFieldsPreserved(original, actual)
            }
        }
    }

    func testUnchangedSelectedAmountsStillReplaceLaterOverridesAndFutureTemplateBoundary() throws {
        var f = fixture()
        let selected = f.rows[1]
        var override = f.rows[3]
        override.postings[0].amount = -40
        override.postings[1].amount = 40
        override.note = "Later override"
        override.payee = "Override payee"
        let overrideIndex = try XCTUnwrap(f.data.transactions.firstIndex { $0.id == override.id })
        f.data.transactions[overrideIndex] = override
        var rule = try XCTUnwrap(selected.recurrenceRule)
        rule.templateHistory?.replaceFutureTemplate(RecurrenceTransactionTemplate(transaction: override), from: f.calendar.startOfDay(for: override.date))
        for index in f.data.transactions.indices { f.data.transactions[index].recurrenceRule = rule }
        let edited = try XCTUnwrap(f.data.transactions.first { $0.id == selected.id })
        let result = try apply(edited, in: f.data, calendar: f.calendar)
        let later = try XCTUnwrap(result.transactions.first { $0.id == override.id })
        XCTAssertEqual(later.postings.map(\.id), override.postings.map(\.id))
        XCTAssertEqual(later.postings.map(\.amount), [-10, 10])
        XCTAssertEqual(later.note, selected.note)
        XCTAssertEqual(later.payee, selected.payee)
        let history = try XCTUnwrap(later.recurrenceRule?.templateHistory)
        XCTAssertEqual(history.changes.map(\.effectiveDate), [f.calendar.startOfDay(for: selected.date)])
        XCTAssertEqual(history.template(on: override.date).postings.map(\.amount), [-10, 10])
        XCTAssertEqual(result.transactions.first { $0.id == f.rows[0].id }?.postings, f.rows[0].postings)
        assertOccurrenceFieldsPreserved(override, later)
    }
}
