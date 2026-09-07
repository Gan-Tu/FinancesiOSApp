import XCTest
@testable import FinancesClone

@MainActor
final class CompanionParityTests: XCTestCase {
    func testCashFlowSeparatesRefundsFromSpendingAndUsesDefaultCurrency() throws {
        var data = DemoData.fixture()
        let ledger = data.ledgers[0].id
        let expense = try XCTUnwrap(data.accounts.first { $0.ledgerID == ledger && $0.kind == .expense && !$0.isGroup })
        let currency = try XCTUnwrap(data.commodities.first { $0.ledgerID == ledger })
        for index in data.accounts.indices { data.accounts[index].commodityID = nil }
        let spend = LedgerTransaction(ledgerID: ledger, date: Date(), payee: "", note: "", number: "", cleared: true, postings: [Posting(accountID: expense.id, amount: 100)])
        let refund = LedgerTransaction(ledgerID: ledger, date: Date(), payee: "", note: "", number: "", cleared: true, postings: [Posting(accountID: expense.id, amount: -20)])
        let result = RegisterCashFlow.build(data: data, rows: [spend, refund], scope: .all)
        XCTAssertEqual(result.income.first?.amounts.first?.amount, 20)
        XCTAssertEqual(result.expenses.first?.amounts.first?.amount, -100)
        XCTAssertEqual(result.income.first?.amounts.first?.commodityID, currency.id)
        XCTAssertEqual(result.income.first?.transactionIDs, [refund.id])
        XCTAssertEqual(result.expenses.first?.transactionIDs, [spend.id])
    }

    func testCashFlowRespectsCurrencyAndCategoryScopesWithinSplitTransactions() throws {
        var data = DemoData.fixture()
        let ledger = data.ledgers[0].id
        let usd = try XCTUnwrap(data.commodities.first { $0.ledgerID == ledger })
        let eur = Commodity(ledgerID: ledger, symbol: "EUR", name: "Euro")
        data.commodities.append(eur)
        let groceries = try XCTUnwrap(data.accounts.first { $0.name == "Groceries" })
        let transportation = try XCTUnwrap(data.accounts.first { $0.name == "Transportation" })
        let row = LedgerTransaction(ledgerID: ledger, date: Date(), payee: "", note: "", number: "", cleared: true, postings: [
            Posting(accountID: groceries.id, commodityID: usd.id, amount: 30),
            Posting(accountID: transportation.id, commodityID: eur.id, amount: 40)
        ])
        let currencyResult = RegisterCashFlow.build(data: data, rows: [row], scope: .currency(usd.id))
        XCTAssertEqual(currencyResult.expenses.map(\.id), [groceries.id])
        XCTAssertEqual(RegisterCashFlow.totals(currencyResult.expenses).map(\.amount), [-30])
        let categoryResult = RegisterCashFlow.build(data: data, rows: [row], scope: .account(groceries.parentID ?? groceries.id))
        XCTAssertEqual(categoryResult.expenses.map(\.id), [groceries.id])
        XCTAssertEqual(categoryResult.expenses.first?.transactionIDs, [row.id])
    }

    func testAccountDefaultCurrencyWorksInAmountEntryAndRegister() throws {
        var data = DemoData.fixture()
        for index in data.accounts.indices { data.accounts[index].commodityID = nil }
        for index in data.transactions.indices {
            for row in data.transactions[index].postings.indices { data.transactions[index].postings[row].commodityID = nil }
        }
        let transaction = try XCTUnwrap(data.transactions.first)
        let presentation = RegisterPresentation.build(data: data, rows: data.transactions, scope: .all)
        XCTAssertEqual(presentation.amounts[transaction.id]?.first?.symbol, "USD")
        XCTAssertEqual(presentation.amounts[transaction.id]?.first?.amount, Decimal(string: "-67.31"))
        var draft = TransactionDraft(ledgerID: transaction.ledgerID)
        draft.postings = transaction.postings.map { PostingDraft(accountID: $0.accountID, amount: "") }
        draft = PostingBalance.settingAmount("25", at: 0, in: draft, accounts: data.accounts, commodities: data.commodities)
        XCTAssertEqual(decimalFromInput(draft.postings[1].amount), -25)
        XCTAssertEqual(try PostingBalance.amount(forLastPostingIn: draft, accounts: data.accounts, commodities: data.commodities), -25)
    }

    func testReopeningEmptyTemplatesDoesNotManufactureNewRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.fixture())
        let originalTransactions = store.data.transactions.map(\.id)
        XCTAssertTrue(store.data.transactionTemplates.isEmpty)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: directory)
        XCTAssertTrue(reopened.data.transactionTemplates.isEmpty)
        XCTAssertEqual(Set(reopened.data.transactions.map(\.id)), Set(originalTransactions))
    }

    func testTypingAmountsUpdatesBothPostingsInOneStateChange() throws {
        let ledger = UUID(), currency = UUID()
        let accounts = [Account(ledgerID: ledger, commodityID: currency, name: "A", kind: .asset), Account(ledgerID: ledger, commodityID: currency, name: "B", kind: .expense)]
        var draft = TransactionDraft(ledgerID: ledger)
        draft.postings = accounts.map { PostingDraft(accountID: $0.id, amount: "") }
        for text in ["2", "25", "25.", "25.5", "25.50", "25.50*2"] {
            draft = PostingBalance.settingAmount(text, at: 0, in: draft, accounts: accounts)
            XCTAssertEqual(decimalFromInput(draft.postings[1].amount), -decimalFromInput(text)!)
            XCTAssertEqual(draft.postings[0].amount, text)
        }
        draft = PostingBalance.settingAmount("-75", at: 1, in: draft, accounts: accounts)
        XCTAssertEqual(decimalFromInput(draft.postings[0].amount), 75)
    }

    func testBalancingSplitsKeepsCurrenciesSeparateAndRejectsMissingRate() throws {
        let usd = UUID(), eur = UUID(), ledger = UUID()
        let a = Account(ledgerID: ledger, commodityID: usd, name: "USD", kind: .asset)
        let b = Account(ledgerID: ledger, commodityID: eur, name: "EUR", kind: .expense)
        let c = Account(ledgerID: ledger, commodityID: usd, name: "USD Expense", kind: .expense)
        var draft = TransactionDraft(ledgerID: ledger)
        draft.postings = [PostingDraft(accountID: a.id, amount: "-100"), PostingDraft(accountID: b.id, amount: "80"), PostingDraft(accountID: c.id, amount: "")]
        XCTAssertEqual(try PostingBalance.amount(forLastPostingIn: draft, accounts: [a,b,c]), 100)
        draft.postings = [draft.postings[0], draft.postings[1]]
        XCTAssertThrowsError(try PostingBalance.amount(forLastPostingIn: draft, accounts: [a,b,c]))
        draft.postings = [PostingDraft(accountID: a.id, amount: "bad amount"), PostingDraft(accountID: c.id, amount: "")]
        XCTAssertThrowsError(try PostingBalance.amount(forLastPostingIn: draft, accounts: [a,b,c]))
    }

    func testAccountReorderingAndGroupingPersistAndRejectCycles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.fixture())
        let checking = try XCTUnwrap(store.selectedLedgerAccounts.first { $0.name == "Checking" })
        let cash = try XCTUnwrap(store.selectedLedgerAccounts.first { $0.name == "Cash" })
        store.moveAccount(cash.id, relativeTo: checking.id, placement: .before)
        XCTAssertNil(store.validationError)
        XCTAssertLessThan(try XCTUnwrap(store.account(cash.id)?.listIndex), try XCTUnwrap(store.account(checking.id)?.listIndex))
        let groceries = try XCTUnwrap(store.selectedLedgerAccounts.first { $0.name == "Groceries" })
        let food = try XCTUnwrap(store.selectedLedgerAccounts.first { $0.name == "Food & Dining" })
        let transportation = try XCTUnwrap(store.selectedLedgerAccounts.first { $0.name == "Transportation" })
        store.moveAccount(groceries.id, relativeTo: transportation.id, placement: .inside)
        XCTAssertNil(store.validationError)
        XCTAssertEqual(store.account(groceries.id)?.parentID, transportation.id)
        store.moveAccount(transportation.id, relativeTo: groceries.id, placement: .inside)
        XCTAssertNotNil(store.validationError)
        XCTAssertNotEqual(store.account(transportation.id)?.parentID, groceries.id)
        store.moveAccount(cash.id, relativeTo: food.id, placement: .inside)
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(store.account(cash.id)?.parentID, checking.parentID)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: directory, initialData: JournalData())
        XCTAssertEqual(reopened.account(groceries.id)?.parentID, transportation.id)
        XCTAssertLessThan(try XCTUnwrap(reopened.account(cash.id)?.listIndex), try XCTUnwrap(reopened.account(checking.id)?.listIndex))
    }

    func testOpenEditorAndRegisterKeepTheirJournalWhenSelectionChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.fixture())
        let first = store.data.ledgers[0], second = store.data.ledgers[1]
        let account = try XCTUnwrap(store.accounts(for: first.id).first { $0.name == "Cash" })
        let currency = try XCTUnwrap(store.commodities(for: first.id).first)
        var accountDraft = store.draft(for: account)
        var currencyDraft = store.draft(for: currency)
        let register = MobileRoute.transactions(scope: .all, title: "All", ledgerID: first.id)
        store.selectLedger(second.id)
        accountDraft.note = "Belongs to Personal"
        currencyDraft.name = "US Dollar Personal"
        store.saveAccount(accountDraft)
        XCTAssertNil(store.validationError)
        store.saveCurrency(currencyDraft)
        XCTAssertNil(store.validationError)
        XCTAssertEqual(store.account(account.id)?.ledgerID, first.id)
        XCTAssertEqual(store.account(account.id)?.note, "Belongs to Personal")
        XCTAssertEqual(store.commodity(currency.id)?.name, "US Dollar Personal")
        XCTAssertEqual(register.resolvedLedgerID(in: store), first.id)
        XCTAssertEqual(store.transactions(scope: .all, ledgerID: register.resolvedLedgerID(in: store)).count, 24)
        XCTAssertTrue(store.transactions(scope: .all, ledgerID: second.id).isEmpty)
    }
}

final class RegisterBalanceCurrencyTests: XCTestCase {
    @MainActor func testBackgroundRenderFiltersAmountsAndPreservesPriorBalances() async throws {
        let fixture = makeFixture()
        let request = RegisterRenderRequest(data: fixture.data, rows: fixture.data.transactions, scope: .account(fixture.cash.id), search: "-25", dateInterval: nil, transactionIDs: nil)
        let result = try await RegisterRenderWorker.shared.render(request).presentation
        XCTAssertEqual(result.months.flatMap(\.days).flatMap(\.transactions).map(\.id), [fixture.data.transactions[4].id])
        XCTAssertEqual(result.balances[fixture.data.transactions[4].id], [RegisterMoney(commodityID: fixture.usd.id, symbol: "USD", amount: 975)])
    }

    @MainActor func testCanceledBackgroundRenderProducesNoResult() async throws {
        let fixture = makeFixture()
        let request = RegisterRenderRequest(data: fixture.data, rows: fixture.data.transactions, scope: .all, search: "", dateInterval: nil, transactionIDs: nil)
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream { break }
            return try await RegisterRenderWorker.shared.render(request)
        }
        task.cancel()
        gate.continuation.finish()
        do { _ = try await task.value; XCTFail("A canceled render must not replace current rows") }
        catch is CancellationError { }
    }

    func testInitialPositionPrioritizesTodayOverChartAndDistantFutureEntries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 12)))
        var fixture = makeFixture()
        for (index, offset) in [-10, -1, 0, 1, 365, 1095].enumerated() {
            fixture.data.transactions[index].date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: now))
        }
        for scope in [MobileTransactionScope.all, .account(fixture.cash.id), .account(fixture.group.id)] {
            let result = RegisterPresentation.build(data: fixture.data, rows: fixture.data.transactions, scope: scope, calendar: calendar)
            XCTAssertEqual(result.initialDay(now: now, calendar: calendar), calendar.startOfDay(for: now))
            XCTAssertEqual(result.months.flatMap(\.days).flatMap(\.transactions).count, 6)
        }
        let withoutToday = fixture.data.transactions.filter { !calendar.isDate($0.date, inSameDayAs: now) }
        let recent = RegisterPresentation.build(data: fixture.data, rows: withoutToday, scope: .all, calendar: calendar)
        XCTAssertEqual(recent.initialDay(now: now, calendar: calendar), calendar.startOfDay(for: fixture.data.transactions[1].date))
        let future = fixture.data.transactions.filter { $0.date > now }
        let futureOnly = RegisterPresentation.build(data: fixture.data, rows: future, scope: .all, calendar: calendar)
        XCTAssertEqual(futureOnly.initialDay(now: now, calendar: calendar), calendar.startOfDay(for: fixture.data.transactions[3].date))
        let history = fixture.data.transactions.filter { $0.date < now }
        let historyOnly = RegisterPresentation.build(data: fixture.data, rows: history, scope: .all, calendar: calendar)
        XCTAssertNil(historyOnly.initialDay(now: now, calendar: calendar))
    }

    func testSyncOnlyChangesDoNotInvalidateRegisterContent() {
        let original = makeFixture().data
        var updated = original
        updated.lastSyncedAt = Date()
        updated.syncEnabled.toggle()
        updated.security = SecuritySettings(passwordHash: "synthetic", passwordSalt: "test")
        XCTAssertTrue(RegisterPresentation.hasSameContent(original, updated))
        updated.transactions[0].cleared.toggle()
        XCTAssertFalse(RegisterPresentation.hasSameContent(original, updated))
        updated = original; updated.accounts[0].name = "Renamed"
        XCTAssertFalse(RegisterPresentation.hasSameContent(original, updated))
        updated = original; updated.commodities[0].symbol = "CAD"
        XCTAssertFalse(RegisterPresentation.hasSameContent(original, updated))
        updated = original; updated.selectedLedgerID = UUID()
        XCTAssertFalse(RegisterPresentation.hasSameContent(original, updated))
        updated = original; updated.ledgers[0].name = "Renamed journal"
        XCTAssertFalse(RegisterPresentation.hasSameContent(original, updated))
    }

    func testDenseCashFlowKeepsSplitTotalsAndEveryTransactionID() throws {
        var fixture = makeFixture()
        let expense = try XCTUnwrap(fixture.data.accounts.first { $0.kind == .expense })
        fixture.data.transactions = (0..<2000).map { index in
            let currency = index.isMultiple(of: 2) ? fixture.usd : fixture.eur
            return LedgerTransaction(ledgerID: fixture.cash.ledgerID, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), payee: "", note: "Split", number: "", cleared: true, postings: [
                Posting(accountID: fixture.cash.id, commodityID: currency.id, amount: -3),
                Posting(accountID: expense.id, commodityID: currency.id, amount: 1),
                Posting(accountID: expense.id, commodityID: currency.id, amount: 2)
            ])
        }
        let result = RegisterCashFlow.build(data: fixture.data, rows: fixture.data.transactions, scope: .all)
        let bucket = try XCTUnwrap(result.expenses.first)
        XCTAssertEqual(bucket.transactionIDs, Set(fixture.data.transactions.map(\.id)))
        XCTAssertEqual(bucket.amounts, [
            RegisterMoney(commodityID: fixture.eur.id, symbol: "EUR", amount: -3000),
            RegisterMoney(commodityID: fixture.usd.id, symbol: "USD", amount: -3000)
        ])
    }

    func testGroupFastPathPreservesMixedAccountBalancesAfterCurrencyTransition() throws {
        var fixture = makeFixture()
        let fixed = Account(ledgerID: fixture.cash.ledgerID, parentID: fixture.group.id, commodityID: fixture.usd.id, name: "USD only", kind: .asset)
        let expense = try XCTUnwrap(fixture.data.accounts.first { $0.kind == .expense })
        fixture.data.accounts.append(fixed)
        fixture.data.transactions.append(LedgerTransaction(ledgerID: fixed.ledgerID, date: Date(timeIntervalSince1970: 1_800_000_001.5), payee: "", note: "Fixed account", number: "", cleared: true, postings: [
            Posting(accountID: fixed.id, amount: 50), Posting(accountID: expense.id, commodityID: fixture.usd.id, amount: -50)
        ]))
        let rows = Array(fixture.data.transactions.prefix(5))
        let result = RegisterPresentation.build(data: fixture.data, rows: rows, scope: .account(fixture.group.id))
        XCTAssertEqual(result.balances[rows[0].id], [RegisterMoney(commodityID: fixture.usd.id, symbol: "USD", amount: 1000)])
        XCTAssertEqual(result.balances[rows[3].id], [
            RegisterMoney(commodityID: fixture.eur.id, symbol: "EUR", amount: 150),
            RegisterMoney(commodityID: fixture.usd.id, symbol: "USD", amount: 50)
        ])
        XCTAssertEqual(result.balances[rows[4].id], [RegisterMoney(commodityID: fixture.usd.id, symbol: "USD", amount: 1025)])
    }

    func testInterleavedCurrenciesShowOnlyEachTransactionsRunningBalance() throws {
        let fixture = makeFixture()
        for scope in [MobileTransactionScope.all, .account(fixture.cash.id), .account(fixture.group.id)] {
            let result = RegisterPresentation.build(data: fixture.data, rows: fixture.data.transactions, scope: scope)
            let eurRow = fixture.data.transactions[3]
            let usdRow = fixture.data.transactions[4]
            XCTAssertEqual(result.balances[eurRow.id], [RegisterMoney(commodityID: fixture.eur.id, symbol: "EUR", amount: 150)])
            XCTAssertEqual(result.balances[usdRow.id], [RegisterMoney(commodityID: fixture.usd.id, symbol: "USD", amount: 975)])
            let zeroRow = fixture.data.transactions[5]
            XCTAssertEqual(result.balances[zeroRow.id], [RegisterMoney(commodityID: fixture.eur.id, symbol: "EUR", amount: 0)])
        }
    }

    func testFilteredRowsRetainHiddenHistoryWithoutOtherCurrencyBalances() throws {
        let fixture = makeFixture()
        let row = fixture.data.transactions[3]
        for scope in [MobileTransactionScope.all, .account(fixture.cash.id), .currency(fixture.eur.id)] {
            let result = RegisterPresentation.build(data: fixture.data, rows: [row], scope: scope)
            XCTAssertEqual(result.balances[row.id], [RegisterMoney(commodityID: fixture.eur.id, symbol: "EUR", amount: 150)])
        }
    }

    func testMultiCurrencyTransactionKeepsBothUsedCurrenciesButHidesUnrelatedOnes() throws {
        var fixture = makeFixture()
        let other = try XCTUnwrap(fixture.data.accounts.first { $0.kind == .expense })
        let exchange = LedgerTransaction(ledgerID: fixture.cash.ledgerID, date: Date(timeIntervalSince1970: 1_800_000_007), payee: "", note: "Exchange", number: "", cleared: true, postings: [
            Posting(accountID: fixture.cash.id, commodityID: fixture.usd.id, amount: -100),
            Posting(accountID: fixture.cash.id, commodityID: fixture.eur.id, amount: 90),
            Posting(accountID: other.id, commodityID: fixture.usd.id, amount: 100),
            Posting(accountID: other.id, commodityID: fixture.eur.id, amount: -90)
        ])
        fixture.data.transactions.append(exchange)
        for scope in [MobileTransactionScope.all, .account(fixture.cash.id)] {
            let result = RegisterPresentation.build(data: fixture.data, rows: [exchange], scope: scope)
            XCTAssertEqual(result.balances[exchange.id], [
                RegisterMoney(commodityID: fixture.eur.id, symbol: "EUR", amount: 90),
                RegisterMoney(commodityID: fixture.usd.id, symbol: "USD", amount: 875)
            ])
        }
    }

    func testSingleCurrencyAccountsAndTheirGroupTotalsStayUnchanged() throws {
        var fixture = makeFixture()
        let euroCash = Account(ledgerID: fixture.cash.ledgerID, parentID: fixture.group.id, commodityID: fixture.eur.id, name: "Euro Cash", kind: .asset)
        let francCash = Account(ledgerID: fixture.cash.ledgerID, parentID: fixture.group.id, commodityID: fixture.chf.id, name: "Franc Cash", kind: .asset)
        fixture.data.accounts += [euroCash, francCash]
        for index in fixture.data.transactions.indices {
            let currency = fixture.data.transactions[index].postings[0].commodityID
            if currency == fixture.eur.id { fixture.data.transactions[index].postings[0].accountID = euroCash.id }
            if currency == fixture.chf.id { fixture.data.transactions[index].postings[0].accountID = francCash.id }
        }
        let row = fixture.data.transactions[4]
        let account = RegisterPresentation.build(data: fixture.data, rows: [row], scope: .account(fixture.cash.id))
        XCTAssertEqual(account.balances[row.id], [RegisterMoney(commodityID: fixture.usd.id, symbol: "USD", amount: 975)])
        let group = RegisterPresentation.build(data: fixture.data, rows: [row], scope: .account(fixture.group.id))
        XCTAssertEqual(group.balances[row.id], [
            RegisterMoney(commodityID: fixture.chf.id, symbol: "CHF", amount: 200),
            RegisterMoney(commodityID: fixture.eur.id, symbol: "EUR", amount: 150),
            RegisterMoney(commodityID: fixture.usd.id, symbol: "USD", amount: 975)
        ])
    }

    private struct Fixture {
        var data: JournalData
        let cash: Account
        let group: Account
        let usd: Commodity
        let eur: Commodity
        let chf: Commodity
    }

    private func makeFixture() -> Fixture {
        let ledger = Ledger(name: "Multi-currency")
        let currencies = ["USD", "EUR", "CHF", "GBP", "JPY"].map { Commodity(ledgerID: ledger.id, symbol: $0, name: $0) }
        let group = Account(ledgerID: ledger.id, name: "Assets", kind: .asset)
        let cash = Account(ledgerID: ledger.id, parentID: group.id, name: "Cash", kind: .asset)
        let other = Account(ledgerID: ledger.id, name: "Other", kind: .expense)
        let entries: [(Int, Decimal)] = [(0, 1000), (1, 100), (2, 200), (1, 50), (0, -25), (1, -150)]
        let transactions = entries.enumerated().map { index, entry in
            LedgerTransaction(ledgerID: ledger.id, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), payee: "", note: "Entry \(index)", number: "", cleared: true, postings: [
                Posting(accountID: cash.id, commodityID: currencies[entry.0].id, amount: entry.1),
                Posting(accountID: other.id, commodityID: currencies[entry.0].id, amount: -entry.1)
            ])
        }
        return Fixture(data: JournalData(ledgers: [ledger], commodities: currencies, accounts: [group, cash, other], transactions: transactions), cash: cash, group: group, usd: currencies[0], eur: currencies[1], chf: currencies[2])
    }
}
