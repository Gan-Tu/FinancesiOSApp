#if DEBUG
import Foundation
import UIKit

enum DemoData {
    @MainActor static func makeStore() -> MobileLedgerStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinancesiOS-Demo", isDirectory: true)
        if CommandLine.arguments.contains("--reset-demo") {
            try? FileManager.default.removeItem(at: directory)
            MobileDisplayPreferences.defaults.removePersistentDomain(forName: MobileDisplayPreferences.demoSuiteName)
        }
        var data = fixture(includeFutureEntries: CommandLine.arguments.contains("--demo-future"), includeRecurringEntries: CommandLine.arguments.contains("--demo-recurring"), includeTemplates: true)
        if CommandLine.arguments.contains("--demo-backfilled-recurring") {
            // A past cleared anchor, today's sole uncleared occurrence, and one
            // future month reproduce section removal with an imported cursor.
            let calendar = Calendar.current
            let today = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
            let ids = data.transactions.filter { $0.recurrenceRule != nil }.sorted { $0.date < $1.date }.map(\.id)
            for (offset, id) in ids.enumerated() {
                guard let index = data.transactions.firstIndex(where: { $0.id == id }) else { continue }
                data.transactions[index].date = calendar.date(byAdding: .month, value: offset - 1, to: today)!
                data.transactions[index].cleared = offset == 0
                data.transactions[index].note = offset == 1 ? "Backfilled recurring entry" : (offset == 0 ? "Prior recurring entry" : "Future recurring entry")
            }
            data = RecurringJournalEditor.preparingRecurrencesForBackup(data, calendar: calendar)
        }
        if CommandLine.arguments.contains("--demo-hierarchy"), let ledgerID = data.selectedLedgerID {
            let currencyID = data.commodities.first { $0.ledgerID == ledgerID }?.id
            let liabilities = Account(ledgerID: ledgerID, commodityID: currencyID, name: "Liabilities", kind: .liability)
            let cards = Account(ledgerID: ledgerID, parentID: liabilities.id, commodityID: currencyID, name: "Credit Card", kind: .liability)
            let apple = Account(ledgerID: ledgerID, parentID: cards.id, commodityID: currencyID, name: "Apple Card", kind: .liability, listIndex: 1)
            let wells = Account(ledgerID: ledgerID, parentID: cards.id, commodityID: currencyID, name: "Wells Fargo", kind: .liability, listIndex: 2)
            let cashWise = Account(ledgerID: ledgerID, parentID: wells.id, commodityID: currencyID, name: "Wells Fargo Cash Wise", kind: .liability)
            data.accounts += [liabilities, cards, apple, wells, cashWise]
        }
        if CommandLine.arguments.contains("--demo-scroll"), let index = data.transactions.indices.min(by: { data.transactions[$0].date < data.transactions[$1].date }) {
            data.transactions[index].note = "Oldest test transaction"
        }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        let hasSampleReceipt = store.data.transactions.contains { $0.note == "Weekly groceries" && $0.attachment?.assets.isEmpty == false }
        if !hasSampleReceipt, let transaction = store.data.transactions.first(where: { $0.note == "Weekly groceries" }) {
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
        if CommandLine.arguments.contains("--demo-large-backup"),
           let transaction = store.data.transactions.first(where: { $0.note == "Weekly groceries" }),
           transaction.attachment?.assets.contains(where: { $0.originalFilename == "Background export sample.bin" }) != true {
            do {
                let path = "Attachments/BackgroundExportSample.bin"
                let file = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: file.path, contents: Data())
                let handle = try FileHandle(forWritingTo: file)
                let size: UInt64 = 2 * 1024 * 1024 * 1024
                try handle.truncate(atOffset: size); try handle.close()
                var draft = store.draft(for: transaction)
                draft.attachments.append(AttachmentAsset(originalFilename: "Background export sample.bin", storedPath: path, mimeType: "application/octet-stream", sizeBytes: Int64(size)))
                store.saveTransactionAndFlush(draft)
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

    static func fixture(referenceDate: Date = Date(), includeFutureEntries: Bool = false, includeRecurringEntries: Bool = false, includeTemplates: Bool = false) -> JournalData {
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
        let templates: [TransactionTemplate] = includeTemplates ? [
            TransactionTemplate(ledgerID: journal.id, name: "Expense", note: "", payee: "", cleared: true, enabled: true, scanInvoice: false, listIndex: 0, postings: [PostingTemplate(accountID: food.id, listIndex: 0), PostingTemplate(accountID: checking.id, listIndex: 1)]),
            TransactionTemplate(ledgerID: journal.id, name: "Income", note: "", payee: "", cleared: true, enabled: true, scanInvoice: false, listIndex: 1, postings: [PostingTemplate(accountID: checking.id, listIndex: 0), PostingTemplate(accountID: salary.id, listIndex: 1)]),
            TransactionTemplate(ledgerID: journal.id, name: "Transfer", note: "", payee: "", cleared: true, enabled: true, scanInvoice: false, listIndex: 2, postings: [PostingTemplate(accountID: checking.id, listIndex: 0), PostingTemplate(accountID: cash.id, listIndex: 1)])
        ] : []
        return JournalData(ledgers: [journal, travel], commodities: [usd, eur], accounts: [asset, checking, cash, income, salary, expense, food, groceries, transport], transactions: rows, transactionTemplates: templates, selectedLedgerID: journal.id)
    }
}
#endif
