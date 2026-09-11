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
        if CommandLine.arguments.contains("--demo-performance") { data = performanceFixture() }
        if CommandLine.arguments.contains("--demo-search-matches"), let ledgerID = data.selectedLedgerID {
            let root = data.accounts.first { $0.ledgerID == ledgerID && $0.kind == .asset && $0.parentID == nil }!
            for (index, name) in ["Personal Savings", "Personal Cash", "Son Account"].enumerated() {
                data.accounts.append(Account(ledgerID: ledgerID, parentID: root.id, commodityID: root.commodityID,
                    name: name, kind: .asset, listIndex: 100 + index))
            }
            if let index = data.accounts.firstIndex(where: { $0.name == "Checking" }) { data.accounts[index].name = "BoA Personal" }
            if let index = data.accounts.firstIndex(where: { $0.name == "Expenses" }) { data.accounts[index].name = "Personal & Lifestyle" }
            for index in data.transactions.indices {
                data.transactions[index].note = "Unrelated entry \(index)"
                data.transactions[index].payee = "Other"
                data.transactions[index].number = ""
            }
            data.transactions[0].note = "Lesson fee"
            data.transactions[1].note = "Reference entry"; data.transactions[1].number = "SON-7"
            data.transactions[2].note = "Speaker purchase"; data.transactions[2].payee = "Sonos"
        }
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
        if CommandLine.arguments.contains("--demo-performance") { DemoPerformanceFrames.shared.start(in: directory) }
        return store
    }

    /// Synthetic, deterministic large journal shared by before/after performance runs.
    /// Receipt metadata intentionally stays small; receipt bytes are not read by navigation.
    static func performanceFixture(transactionCount: Int = 10_000) -> JournalData {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", Int64(n)))! }
        let journal = Ledger(id: id(1), name: "Performance Journal")
        let travel = Ledger(id: id(2), name: "Performance Travel", listIndex: 1)
        let usd = Commodity(id: id(3), ledgerID: journal.id, symbol: "USD", name: "US Dollar")
        let eur = Commodity(id: id(4), ledgerID: journal.id, symbol: "EUR", name: "Euro")
        let anchor = Date(timeIntervalSince1970: 1_789_041_600)
        let assets = Account(id: id(10), ledgerID: journal.id, commodityID: usd.id, name: "Assets", kind: .asset, listIndex: 0)
        let expenses = Account(id: id(11), ledgerID: journal.id, commodityID: usd.id, name: "Expenses", kind: .expense, listIndex: 1)
        let income = Account(id: id(12), ledgerID: journal.id, commodityID: usd.id, name: "Income", kind: .income, listIndex: 2)
        var accounts = [assets, expenses, income]
        for i in 0..<100 {
            accounts.append(Account(id: id(100 + i), ledgerID: journal.id, parentID: assets.id, commodityID: usd.id,
                name: String(format: "Account %03d", i), kind: .asset, listIndex: i))
            accounts.append(Account(id: id(300 + i), ledgerID: journal.id, parentID: expenses.id, commodityID: usd.id,
                name: String(format: "Category %03d", i), kind: .expense, listIndex: i))
        }
        accounts.append(Account(id: id(500), ledgerID: journal.id, parentID: income.id, commodityID: usd.id,
            name: "Salary", kind: .income, listIndex: 0))
        let transactions = (0..<transactionCount).map { i -> LedgerTransaction in
            let currencyID = i.isMultiple(of: 7) ? eur.id : usd.id
            let amount = Decimal((i % 9900) + 100) / 100
            return LedgerTransaction(id: id(100_000 + i), ledgerID: journal.id,
                date: anchor.addingTimeInterval(-Double(i) * 18_000), payee: "Merchant \(i % 53)",
                note: "Performance transaction \(i)", number: "REF-\(i)", cleared: i.isMultiple(of: 3),
                postings: [Posting(id: id(200_000 + 2 * i), accountID: id(100 + i % 100), commodityID: currencyID, amount: -amount),
                    Posting(id: id(200_001 + 2 * i), accountID: id(300 + i % 100), commodityID: currencyID, amount: amount, listIndex: 1)])
        }
        let templates = (0..<48).map { i in
            TransactionTemplate(id: id(600 + i), ledgerID: journal.id, name: "Template \(i)", note: "", payee: "Merchant \(i)",
                cleared: true, enabled: true, scanInvoice: false, listIndex: i,
                postings: [PostingTemplate(accountID: id(100 + i), listIndex: 0), PostingTemplate(accountID: id(300 + i), listIndex: 1)])
        }
        return JournalData(ledgers: [journal, travel], commodities: [usd, eur], accounts: accounts,
            transactions: transactions, transactionTemplates: templates, selectedLedgerID: journal.id)
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

/// Frame-gap evidence for opt-in synthetic navigation runs; never present in Release.
@MainActor
private final class DemoPerformanceFrames: NSObject {
    static let shared = DemoPerformanceFrames()
    private var displayLink: CADisplayLink?
    private var destination: URL?
    private var previousTarget: CFTimeInterval?
    private var delays: [Double] = []
    private var firstTimestamp: CFTimeInterval?
    func start(in directory: URL) {
        destination = directory.appendingPathComponent("performance-display.json")
        previousTarget = nil; firstTimestamp = nil; delays = []
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        NotificationCenter.default.addObserver(self, selector: #selector(finish),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    @objc private func frame(_ link: CADisplayLink) {
        if firstTimestamp == nil { firstTimestamp = link.timestamp }
        defer { previousTarget = link.targetTimestamp }
        guard link.timestamp - (firstTimestamp ?? 0) > 2, let previousTarget else { return }
        delays.append(max(0, link.timestamp - previousTarget) * 1000)
    }
    @objc private func finish() {
        guard let destination else { return }
        displayLink?.invalidate(); displayLink = nil
        let output: [String: Any] = ["metric": "missed-display-deadline-ms", "frames": delays.count,
            "over_33_ms": delays.filter { $0 > 33 }.count, "over_100_ms": delays.filter { $0 > 100 }.count,
            "max_ms": delays.max() ?? 0, "total_ms": delays.reduce(0, +), "delays_over_16_ms": delays.filter { $0 > 16 }]
        if let encoded = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
            try? encoded.write(to: destination, options: .atomic)
        }
    }
}
#endif
