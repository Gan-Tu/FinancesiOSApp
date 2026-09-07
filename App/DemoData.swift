#if DEBUG
import Foundation
import UIKit

enum DemoData {
    @MainActor static func makeStore() -> MobileLedgerStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinancesiOS-Demo", isDirectory: true)
        if CommandLine.arguments.contains("--reset-demo") { try? FileManager.default.removeItem(at: directory) }
        var data = fixture(includeFutureEntries: CommandLine.arguments.contains("--demo-future"), includeRecurringEntries: CommandLine.arguments.contains("--demo-recurring"))
        if CommandLine.arguments.contains("--demo-scroll"), let index = data.transactions.indices.min(by: { data.transactions[$0].date < data.transactions[$1].date }) {
            data.transactions[index].note = "Oldest test transaction"
        }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        if let transaction = store.data.transactions.first(where: { $0.note == "Weekly groceries" }), transaction.attachment == nil {
            do {
                let receipt = directory.appendingPathComponent("Sample Receipt.txt")
                try Data("SAMPLE RECEIPT — DEMO DATA ONLY\nMarket\nWeekly groceries\nTotal: USD 67.31\n".utf8).write(to: receipt)
                var draft = store.draft(for: transaction)
                draft.attachments = [try store.importAttachment(from: receipt)]
                store.saveTransaction(draft)
                try store.flushLocalChanges()
                try? FileManager.default.removeItem(at: receipt)
            } catch { store.validationError = ValidationError(message: error.localizedDescription) }
        }
        // UI fixtures report progress without connecting to an iCloud account.
        if CommandLine.arguments.contains("--demo-sync-upload") {
            store.cloudKitSyncDidUpdate(.running(message: "Uploading changes to iCloud", detail: "50 of 200 changes uploaded", fractionCompleted: 0.25, phase: .uploading))
        } else if CommandLine.arguments.contains("--demo-sync-download") {
            store.cloudKitSyncDidUpdate(.running(message: "Downloading iCloud changes", detail: "150 changes received", phase: .downloading))
        }
        return store
    }

    static func fixture(referenceDate: Date = Date(), includeFutureEntries: Bool = false, includeRecurringEntries: Bool = false) -> JournalData {
        let journal = Ledger(name: "Personal")
        let travel = Ledger(name: "Travel", listIndex: 1)
        let usd = Commodity(ledgerID: journal.id, symbol: "USD", name: "US Dollar")
        let eur = Commodity(ledgerID: travel.id, symbol: "EUR", name: "Euro")
        let asset = Account(ledgerID: journal.id, commodityID: usd.id, name: "Assets", kind: .asset, colorName: "gray")
        let income = Account(ledgerID: journal.id, commodityID: usd.id, name: "Income", kind: .income, colorName: "green")
        let expense = Account(ledgerID: journal.id, commodityID: usd.id, name: "Expenses", kind: .expense, colorName: "red")
        let checking = Account(ledgerID: journal.id, parentID: asset.id, commodityID: usd.id, name: "Checking", kind: .asset, colorName: "gray", listIndex: 1)
        let cash = Account(ledgerID: journal.id, parentID: asset.id, commodityID: usd.id, name: "Cash", kind: .asset, colorName: "gray", listIndex: 2)
        let salary = Account(ledgerID: journal.id, parentID: income.id, commodityID: usd.id, name: "Salary", kind: .income, colorName: "green", listIndex: 3)
        let food = Account(ledgerID: journal.id, parentID: expense.id, commodityID: usd.id, name: "Food & Dining", kind: .expense, colorName: "blue", listIndex: 4)
        let groceries = Account(ledgerID: journal.id, parentID: food.id, commodityID: usd.id, name: "Groceries", note: "Pantry essentials and everyday food.", kind: .expense, colorName: "blue", listIndex: 5)
        let transport = Account(ledgerID: journal.id, parentID: expense.id, commodityID: usd.id, name: "Transportation", kind: .expense, colorName: "orange", listIndex: 6)
        var rows: [LedgerTransaction] = []
        for month in 0..<6 {
            let base = Calendar.current.date(byAdding: .month, value: -month, to: referenceDate)!
            for (offset, title, payee, amount, account) in [(0, "Weekly groceries", "Market", Decimal(string: "67.31")!, groceries), (1, "Dinner with friends", "Bistro", Decimal(string: "48.50")!, food), (2, "Train ticket", "Transit", Decimal(12), transport), (3, "Monthly salary", "Employer", Decimal(-4500), salary)] {
                let date = Calendar.current.date(byAdding: .day, value: -offset, to: base)!
                rows.append(LedgerTransaction(ledgerID: journal.id, date: date, payee: payee, note: title, number: "", cleared: offset != 1, postings: [Posting(accountID: checking.id, commodityID: usd.id, amount: -amount), Posting(accountID: account.id, commodityID: usd.id, amount: amount, listIndex: 1)]))
            }
        }
        if includeFutureEntries {
            for month in 1...60 {
                let date = Calendar.current.date(byAdding: .month, value: month, to: referenceDate)!
                rows.append(LedgerTransaction(ledgerID: journal.id, date: date, payee: "Market", note: "Scheduled groceries \(month)", number: "", cleared: false, postings: [Posting(accountID: checking.id, commodityID: usd.id, amount: -50), Posting(accountID: groceries.id, commodityID: usd.id, amount: 50, listIndex: 1)]))
            }
        }
        if includeRecurringEntries {
            let rule = RecurrenceRule(frequency: .monthly, occurrenceCount: 3)
            for month in 0..<3 {
                let date = Calendar.current.date(byAdding: .month, value: month, to: referenceDate)!
                rows.append(LedgerTransaction(ledgerID: journal.id, date: date, payee: "Club", note: "Repeating sample", number: "", cleared: month == 0, postings: [Posting(accountID: checking.id, commodityID: usd.id, amount: -50), Posting(accountID: food.id, commodityID: usd.id, amount: 50, listIndex: 1)], recurrenceRule: rule))
            }
        }
        return JournalData(ledgers: [journal, travel], commodities: [usd, eur], accounts: [asset, checking, cash, income, salary, expense, food, groceries, transport], transactions: rows, selectedLedgerID: journal.id)
    }
}
#endif
