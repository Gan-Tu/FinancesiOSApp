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
