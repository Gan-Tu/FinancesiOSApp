import Foundation
@testable import FinancesClone

/// Shared verbatim by the published f28af6f and optimized write benchmarks.
/// Two postings per row, one finite 100-entry monthly series, 100 independent
/// entries, and a future detail edit covering the final 80 series occurrences.
enum SQLiteRecurrenceWriteFixture {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", Int64(value)))!
    }

    static func make(seriesCount: Int = 100, independentCount: Int = 100, templateCount: Int = 0, extraAccounts: Int = 0) -> JournalData {
        let ledger = Ledger(id: id(1), name: "Recurring write benchmark")
        let currency = Commodity(id: id(2), ledgerID: ledger.id, symbol: "USD", name: "Dollar")
        let bank = Account(id: id(3), ledgerID: ledger.id, commodityID: currency.id, name: "Bank", kind: .asset)
        let expense = Account(id: id(4), ledgerID: ledger.id, commodityID: currency.id, name: "Expense", kind: .expense)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!
        var anchor = LedgerTransaction(id: id(1_000), ledgerID: ledger.id, date: start, payee: "Base payee", note: "Base note", number: "R-10", cleared: false,
            postings: [Posting(id: id(10_000), accountID: bank.id, commodityID: currency.id, amount: -10, listIndex: 0), Posting(id: id(10_001), accountID: expense.id, commodityID: currency.id, amount: 10, listIndex: 1)],
            recurrenceRule: RecurrenceRule(id: id(5), frequency: .monthly, occurrenceCount: seriesCount, preservesImportedMaterializations: false))
        let baseTemplate = RecurrenceTransactionTemplate(transaction: anchor)
        anchor.recurrenceRule?.templateHistory = RecurrenceTemplateHistory(baseTemplate: baseTemplate, scheduleAnchorDate: start)
        anchor.recurrenceRule?.continuation = RecurrenceContinuation(anchorDate: start, calendar: calendar,
            nextOccurrenceIndex: seriesCount, consumedOccurrences: seriesCount,
            lastScheduledDay: calendar.startOfDay(for: calendar.date(byAdding: .month, value: seriesCount - 1, to: start)!))
        var transactions: [LedgerTransaction] = (0..<seriesCount).map { index in
            var row = anchor
            row.id = id(1_000 + index)
            row.date = calendar.date(byAdding: .month, value: index, to: start)!
            row.postings = row.postings.enumerated().map { offset, posting in
                var copy = posting; copy.id = id(10_000 + 2 * index + offset); return copy
            }
            return row
        }
        let independentStart = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1, hour: 12))!
        transactions += (0..<independentCount).map { index in
            var row = anchor
            row.id = id(2_000 + index)
            row.date = calendar.date(byAdding: .day, value: index, to: independentStart)!
            row.recurrenceRule = nil
            row.postings = row.postings.enumerated().map { offset, posting in
                var copy = posting; copy.id = id(20_000 + 2 * index + offset); return copy
            }
            return row
        }
        let accounts = [bank, expense] + (0..<extraAccounts).map { index in
            Account(id: id(500 + index), ledgerID: ledger.id, commodityID: currency.id, name: "Extra account \(index)", kind: .expense)
        }
        let templates = (0..<templateCount).map { index in
            TransactionTemplate(id: id(3_000 + index), ledgerID: ledger.id, name: "Template \(index)", listIndex: index,
                postings: [PostingTemplate(id: id(40_000 + 2 * index), accountID: bank.id), PostingTemplate(id: id(40_001 + 2 * index), accountID: expense.id, listIndex: 1)])
        }
        return JournalData(ledgers: [ledger], commodities: [currency], accounts: accounts,
            transactions: transactions.sorted { $0.date < $1.date }, transactionTemplates: templates, selectedLedgerID: ledger.id)
    }

    static func futureNoteEdit(_ original: JournalData, boundaryIndex: Int = 20) throws -> JournalData {
        let series = original.transactions.filter { $0.recurrenceRule != nil }.sorted { $0.date < $1.date }
        var boundary = series[boundaryIndex]
        boundary.note = "Changed future terms"
        return try RecurringJournalEditor.apply(boundary, replacing: boundary.id, in: original, scope: .future,
            referenceDate: series[0].date, calendar: calendar)
    }
}
