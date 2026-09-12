#if DEBUG
import Foundation
import UIKit

enum DemoData {
    static var isSplitEditorFixtureRequested: Bool {
        CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--demo-split-editor")
    }
    static var isTextSuggestionFixtureRequested: Bool {
        CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--demo-text-suggestions")
    }
    static var isSystemEntryFixtureRequested: Bool {
        CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--demo-system-entry")
    }

    @MainActor static func makeStore() -> MobileLedgerStore {
        let directoryName = isSystemEntryFixtureRequested ? "FinancesiOS-SyntheticSystemEntry"
            : isTextSuggestionFixtureRequested ? "FinancesiOS-SyntheticTextSuggestions"
            : (isSplitEditorFixtureRequested ? "FinancesiOS-SyntheticSplitEditor" : "FinancesiOS-Demo")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        if CommandLine.arguments.contains("--reset-demo") {
            try? FileManager.default.removeItem(at: directory)
            MobileDisplayPreferences.defaults.removePersistentDomain(forName: MobileDisplayPreferences.demoSuiteName)
        }
        var data = fixture(includeFutureEntries: CommandLine.arguments.contains("--demo-future"), includeRecurringEntries: CommandLine.arguments.contains("--demo-recurring"), includeTemplates: true)
        if isSplitEditorFixtureRequested { data = splitEditorFixture() }
        if isTextSuggestionFixtureRequested { data = textSuggestionFixture() }
        if isSystemEntryFixtureRequested { data = systemEntryFixture() }
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
        let dependencies: CloudKitSyncDependencies = (isSplitEditorFixtureRequested || isTextSuggestionFixtureRequested || isSystemEntryFixtureRequested)
            ? CloudKitSyncDependencies(configuration: { nil }, makeClient: { _ in
                throw ValidationError(message: "Synthetic split editor tests prohibit CloudKit access.")
            }, automaticTriggersEnabled: false)
            : .live
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data, cloudKitSyncDependencies: dependencies)
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

    static func systemEntryFixture() -> JournalData {
        func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", Int64(value)))! }
        var data = splitEditorFixture()
        data.ledgers[0].name = "SYNTHETIC Alpha"
        let beta = Ledger(id: id(400), name: "SYNTHETIC Beta", listIndex: 1)
        let usd = Commodity(id: id(401), ledgerID: beta.id, symbol: "USD", name: "US Dollar")
        let assets = Account(id: id(410), ledgerID: beta.id, commodityID: usd.id, name: "Assets", kind: .asset)
        let expenses = Account(id: id(411), ledgerID: beta.id, commodityID: usd.id, name: "Expenses", kind: .expense, listIndex: 1)
        let bank = Account(id: id(420), ledgerID: beta.id, parentID: assets.id, commodityID: usd.id, name: "SYNTHETIC Beta Bank", kind: .asset)
        let expense = Account(id: id(421), ledgerID: beta.id, parentID: expenses.id, commodityID: usd.id, name: "SYNTHETIC Beta Expense", kind: .expense)
        data.ledgers.append(beta); data.commodities.append(usd); data.accounts += [assets, expenses, bank, expense]
        data.transactions = [
            LedgerTransaction(id: id(100), ledgerID: id(1), date: Date().addingTimeInterval(-3600), payee: "SYNTHETIC Store", note: "SYNTHETIC Purchase", number: "SYN-PURCHASE", cleared: true,
                postings: [Posting(id: id(1000), accountID: id(20), commodityID: id(2), amount: -100), Posting(id: id(1001), accountID: id(21), commodityID: id(2), amount: 100, listIndex: 1)]),
            LedgerTransaction(id: id(101), ledgerID: id(1), date: Date().addingTimeInterval(-60), payee: "SYNTHETIC Partial Refund", note: "SYNTHETIC Received Payment", number: "SYN-REFUND", cleared: true,
                postings: [Posting(id: id(1010), accountID: id(20), commodityID: id(2), amount: 40), Posting(id: id(1011), accountID: id(21), commodityID: id(2), amount: -40, listIndex: 1)])
        ]
        data.transactionTemplates = ["Coffee", "Lunch", "Transit", "Groceries"].enumerated().map { index, name in
            TransactionTemplate(id: id(2000 + index), ledgerID: id(1), name: name, note: "", payee: "", cleared: true, enabled: true, scanInvoice: false, listIndex: index,
                postings: [PostingTemplate(accountID: id(20)), PostingTemplate(accountID: id(21), listIndex: 1)])
        }
        data.transactionTemplates.append(TransactionTemplate(id: id(2004), ledgerID: beta.id, name: "Coffee", note: "", payee: "", cleared: true, enabled: true, scanInvoice: false,
            postings: [PostingTemplate(accountID: bank.id), PostingTemplate(accountID: expense.id, listIndex: 1)]))
        return data
    }

    static func systemEntrySuggestion() -> CaptureSuggestion {
        CaptureSuggestion(id: UUID(uuidString: "00000000-0000-0000-0000-000000002328")!, source: .applePay,
            date: Date().addingTimeInterval(-30), amount: Decimal(string: "42.50"), currencyCode: "USD",
            merchant: "SYNTHETIC Wallet Store", card: "SYNTHETIC Bank", note: "SYNTHETIC Wallet capture",
            journalID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    }

    static func textSuggestionFixture(referenceDate: Date = Date()) -> JournalData {
        func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", Int64(value)))! }
        let notes = ["Airport parking receipt", "Annual membership renewal", "Apartment utilities payment", "Art supply purchase",
            "A complete multiword historical note whose full text is deliberately wider than one suggestion chip", "Alpha sixth note"]
        let payees = ["Aster Coffee Roasters", "Atlas Grocery Market", "Arcadia Community Gym", "Arbor Books and Stationery", "Alpine Outdoor Supply", "Astral Sixth Merchant"]
        var data = JournalData()
        for journal in 0..<2 {
            let base = 500 + journal * 100
            let ledger = Ledger(id: id(base), name: journal == 0 ? "SYNTHETIC Alpha" : "SYNTHETIC Beta", listIndex: journal)
            let currency = Commodity(id: id(base + 1), ledgerID: ledger.id, symbol: "USD", name: "US Dollar")
            let assets = Account(id: id(base + 2), ledgerID: ledger.id, commodityID: currency.id, name: "Assets", kind: .asset)
            let expenses = Account(id: id(base + 3), ledgerID: ledger.id, commodityID: currency.id, name: "Expenses", kind: .expense, listIndex: 1)
            let bank = Account(id: id(base + 4), ledgerID: ledger.id, parentID: assets.id, commodityID: currency.id, name: "SYNTHETIC Bank", kind: .asset)
            let expense = Account(id: id(base + 5), ledgerID: ledger.id, parentID: expenses.id, commodityID: currency.id, name: "SYNTHETIC Expense", kind: .expense)
            data.ledgers.append(ledger); data.commodities.append(currency); data.accounts += [assets, expenses, bank, expense]
            var ordinal = 0
            func add(note: String, payee: String, date: Date) {
                let transactionID = base * 100 + ordinal
                data.transactions.append(LedgerTransaction(id: id(transactionID), ledgerID: ledger.id, date: date, payee: payee, note: note,
                    number: "SYNTHETIC-\(ordinal)", cleared: true,
                    postings: [Posting(id: id(transactionID * 10), accountID: bank.id, commodityID: currency.id, amount: -25),
                        Posting(id: id(transactionID * 10 + 1), accountID: expense.id, commodityID: currency.id, amount: 25, listIndex: 1)]))
                ordinal += 1
            }
            for index in notes.indices {
                for _ in 0..<(6 - index) {
                    add(note: journal == 0 ? notes[index] : "Beta private historical note",
                        payee: journal == 0 ? payees[index] : "Beta Private Merchant",
                        date: referenceDate.addingTimeInterval(-Double(ordinal + 1) * 3600))
                }
            }
            add(note: "FUTURE scheduled note", payee: "FUTURE Scheduled Merchant", date: referenceDate.addingTimeInterval(7 * 86400))
            data.transactionTemplates.append(TransactionTemplate(id: id(base + 6), ledgerID: ledger.id, name: "Income", note: "", payee: "", cleared: true,
                enabled: true, scanInvoice: false, listIndex: 0,
                postings: [PostingTemplate(accountID: bank.id), PostingTemplate(accountID: expense.id, listIndex: 1)]))
        }
        data.selectedLedgerID = data.ledgers.first?.id
        data.syncEnabled = false
        return data
    }

    /// Exact, deliberately unequal values for native editor tests. The dedicated
    /// demo directory and unavailable sync transport never touch real journals.
    static func splitEditorFixture() -> JournalData {
        func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", Int64(value)))! }
        let ledger = Ledger(id: id(1), name: "SYNTHETIC Split Tests")
        let usd = Commodity(id: id(2), ledgerID: ledger.id, symbol: "USD", name: "US Dollar")
        let eur = Commodity(id: id(3), ledgerID: ledger.id, symbol: "EUR", name: "Euro")
        let assets = Account(id: id(10), ledgerID: ledger.id, commodityID: usd.id, name: "Assets", kind: .asset)
        let expenses = Account(id: id(11), ledgerID: ledger.id, commodityID: usd.id, name: "Expenses", kind: .expense, listIndex: 1)
        let bank = Account(id: id(20), ledgerID: ledger.id, parentID: assets.id, commodityID: usd.id, name: "SYNTHETIC Bank", kind: .asset)
        let expense = Account(id: id(21), ledgerID: ledger.id, parentID: expenses.id, commodityID: usd.id, name: "SYNTHETIC Expense", kind: .expense)
        let fee = Account(id: id(22), ledgerID: ledger.id, parentID: expenses.id, commodityID: usd.id, name: "SYNTHETIC Fee", kind: .expense, listIndex: 1)
        let euroBank = Account(id: id(23), ledgerID: ledger.id, parentID: assets.id, commodityID: eur.id, name: "SYNTHETIC Euro Bank", kind: .asset, listIndex: 1)
        let euroExpense = Account(id: id(24), ledgerID: ledger.id, parentID: expenses.id, commodityID: eur.id, name: "SYNTHETIC Euro Expense", kind: .expense, listIndex: 2)
        let alternate = Account(id: id(25), ledgerID: ledger.id, parentID: expenses.id, commodityID: usd.id, name: "SYNTHETIC Alternate", kind: .expense, listIndex: 3)
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        func transaction(_ index: Int, _ note: String, _ values: [(Int, Int?, Int)], date: Date? = nil, rule: RecurrenceRule? = nil) -> LedgerTransaction {
            LedgerTransaction(id: id(index), ledgerID: ledger.id, date: date ?? today,
                payee: "SYNTHETIC Merchant", note: note, number: "SYN-\(index)", cleared: true,
                postings: values.enumerated().map { offset, value in
                    Posting(id: id(index * 10 + offset), accountID: id(value.0), commodityID: value.1.map(id), amount: Decimal(value.2), listIndex: offset)
                }, recurrenceRule: rule)
        }
        let unequal = [(20, Optional(2), -27215), (21, Optional(2), 27200), (22, nil, 15)]
        var rows = [
            transaction(100, "SYNTHETIC Three Leg", unequal),
            transaction(101, "SYNTHETIC Four Leg", [(20, 2, -100), (21, nil, 100), (23, 3, -80), (24, nil, 80)]),
            transaction(102, "SYNTHETIC Two Leg", [(20, 2, -100), (21, 2, 100)]),
            transaction(103, "SYNTHETIC Remove Fee", [(20, 2, -100), (21, 2, 90), (22, 2, 10)])
        ]
        let rule = RecurrenceRule(id: id(200), frequency: .daily, occurrenceCount: 3)
        for offset in 0..<3 {
            rows.append(transaction(110 + offset, "SYNTHETIC Recurrence", unequal,
                date: Calendar.current.date(byAdding: .day, value: offset - 2, to: today)!, rule: rule))
        }
        return JournalData(ledgers: [ledger], commodities: [usd, eur], accounts: [assets, expenses, bank, expense, fee, euroBank, euroExpense, alternate],
            transactions: rows, selectedLedgerID: ledger.id, syncEnabled: false)
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
