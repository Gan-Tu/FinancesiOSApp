import XCTest
@testable import FinancesClone

@MainActor
final class MobileCompanionTests: XCTestCase {
    func testDuplicatePreservesDateOrUsesTodayAsSelected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture(referenceDate: Date().addingTimeInterval(-90 * 86400)))
        let original = try XCTUnwrap(store.data.transactions.first)
        var ids = Set(store.data.transactions.map(\.id))
        store.duplicateTransaction(original.id, useToday: false)
        let datedCopy = try XCTUnwrap(store.data.transactions.first { !ids.contains($0.id) })
        XCTAssertEqual(datedCopy.date, original.date)
        ids.insert(datedCopy.id)
        let before = Date()
        store.duplicateTransaction(original.id, useToday: true)
        let todayCopy = try XCTUnwrap(store.data.transactions.first { !ids.contains($0.id) })
        XCTAssertGreaterThanOrEqual(todayCopy.date, before)
        XCTAssertLessThanOrEqual(todayCopy.date, Date())
        XCTAssertEqual(todayCopy.postings.map(\.amount), original.postings.map(\.amount))
    }

    func testCurrentBalancesExcludeFutureOnLoadEditAndDelete() throws {
        let now = Date()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = DemoData.fixture(referenceDate: now, includeFutureEntries: true)
        let account = try XCTUnwrap(data.accounts.first { $0.name == "Checking" })
        let expected = data.transactions.filter { $0.date <= now }.flatMap(\.postings).filter { $0.accountID == account.id }.reduce(Decimal.zero) { $0 + $1.amount }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: data)
        func balance() -> Decimal { store.balanceRows(for: account.id).reduce(.zero) { $0 + $1.amount } }
        XCTAssertEqual(balance(), expected)
        XCTAssertEqual(store.ledgerTotalsByKind(ledgerID: account.ledgerID)[.asset]?.first?.amount, expected)
        let original = try XCTUnwrap(data.transactions.first)
        var draft = store.draft(for: original)
        draft.date = try XCTUnwrap(Calendar.current.date(byAdding: .year, value: 8, to: now))
        store.saveTransactionAndFlush(draft)
        XCTAssertEqual(balance(), expected + Decimal(string: "67.31")!)
        draft.date = original.date
        store.saveTransactionAndFlush(draft)
        XCTAssertEqual(balance(), expected)
        let future = try XCTUnwrap(store.data.transactions.first { $0.date > now })
        store.deleteTransaction(future.id)
        XCTAssertEqual(balance(), expected)
        var today = store.draft(for: try XCTUnwrap(store.data.transactions.first { $0.date > now }))
        today.date = Calendar.current.dateInterval(of: .day, for: now)!.end.addingTimeInterval(-1)
        store.saveTransactionAndFlush(today)
        XCTAssertEqual(balance(), expected - 50)
        XCTAssertNil(store.validationError)
    }

    func testDeletionPersistsItsTombstoneBeforeReturning() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let id = try XCTUnwrap(store.data.transactions.first?.id)
        store.deleteTransaction(id)
        XCTAssertNil(store.validationError)
        XCTAssertTrue(try store.cloudKitSQLiteStore.deletedTransactionIDs().contains(id))
        XCTAssertFalse(try XCTUnwrap(store.cloudKitSQLiteStore.loadData()).transactions.contains { $0.id == id })
    }

    func testCloudKitReceiptLocationSurvivesDeletionThroughSymlinkedFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("real"), alias = folder.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let store = MobileLedgerStore(supportDirectory: alias, initialData: DemoData.fixture())
        let source = folder.appendingPathComponent("receipt.txt")
        try Data("Synthetic receipt".utf8).write(to: source)
        let asset = try store.importAttachment(from: source)
        let originalURL = try store.cloudKitAttachmentURL(for: asset)
        var draft = store.draft(for: try XCTUnwrap(store.data.transactions.first))
        draft.attachments = [asset]
        store.saveTransactionAndFlush(draft)
        XCTAssertNil(store.validationError)
        store.deleteTransaction(try XCTUnwrap(draft.id))
        try store.flushLocalChanges()
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try store.cloudKitAttachmentURL(for: asset), originalURL)
    }

    func testRegisterStartsAtTodayWithFiveYearsOfFutureEntries() throws {
        let now = Date()
        let data = DemoData.fixture(referenceDate: now, includeFutureEntries: true)
        let presentation = RegisterPresentation.build(data: data, rows: data.transactions, scope: .all)
        XCTAssertEqual(presentation.initialDay(now: now), Calendar.current.startOfDay(for: now))
        XCTAssertEqual(presentation.months.flatMap(\.days).flatMap(\.transactions).count, 84)
        let historical = data.transactions.filter { $0.date <= now }
        XCTAssertNil(RegisterPresentation.build(data: data, rows: historical, scope: .all).initialDay(now: now))
    }

    func testFutureOnlyRegisterStartsAtNearestScheduledDay() throws {
        let now = Date()
        let data = DemoData.fixture(referenceDate: now, includeFutureEntries: true)
        let future = data.transactions.filter { $0.date > now }
        let presentation = RegisterPresentation.build(data: data, rows: future, scope: .all)
        let nearest = try XCTUnwrap(future.map(\.date).min())
        XCTAssertEqual(presentation.initialDay(now: now), Calendar.current.startOfDay(for: nearest))
    }

    func testUnclearedBadgeCountsWholeTodayAndExcludesFutureAndOtherJournal() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30)))
        let lateToday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 30)))
        let tomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        var data = DemoData.fixture(referenceDate: now, includeFutureEntries: true)
        data.transactions[0].date = lateToday
        data.transactions[0].cleared = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        XCTAssertEqual(store.unclearedTransactionCount(ledgerID: data.ledgers[0].id, now: now, calendar: calendar), 7)
        XCTAssertEqual(store.unclearedTransactionCount(ledgerID: data.ledgers[1].id, now: now, calendar: calendar), 0)
        XCTAssertEqual(store.transactions(scope: .uncleared, ledgerID: data.ledgers[0].id).count, 67)
        XCTAssertFalse(RegisterPresentation.isFuture(lateToday, now: now, calendar: calendar))
        XCTAssertTrue(RegisterPresentation.isFuture(tomorrow, now: now, calendar: calendar))
    }

    func testNewJournalStartsWithZeroMoneyAndNoTransactions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        store.addJournal(name: "Empty Journal")
        XCTAssertTrue(store.data.transactions.isEmpty)
        XCTAssertTrue(store.ledgerTotalsByKind().values.flatMap { $0 }.allSatisfy { $0.amount == 0 })
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        XCTAssertTrue(reopened.data.transactions.isEmpty)
    }

    func testReceiptBytesSurviveBackupAndReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let source = folder.appendingPathComponent("receipt.txt")
        let bytes = Data("Synthetic receipt: Lunch 25.00".utf8)
        try bytes.write(to: source)
        let asset = try store.importAttachment(from: source)
        let row = try XCTUnwrap(store.data.transactions.first)
        var draft = store.draft(for: row); draft.attachments = [asset]
        store.saveTransaction(draft)
        XCTAssertEqual(store.backupAttachmentCount, 1)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        let restored = try XCTUnwrap(reopened.transaction(row.id)?.attachment?.assets.first)
        XCTAssertEqual(try Data(contentsOf: reopened.attachmentURL(for: restored)), bytes)
        let document = try XCTUnwrap(reopened.exportBackupDocument())
        let payload = try JSONDecoder.appDecoder.decode(MobileBackupPayload.self, from: document.data)
        XCTAssertEqual(payload.attachments.first?.data, bytes)
        reopened.deleteTransaction(row.id)
        XCTAssertEqual(reopened.backupAttachmentCount, 0)
    }

    func testFilteredRegisterPreservesPriorBalanceAndAccountSign() throws {
        let data = DemoData.fixture()
        let account = try XCTUnwrap(data.accounts.first { $0.name == "Checking" })
        let latest = try XCTUnwrap(data.transactions.max { $0.date < $1.date })
        let presentation = RegisterPresentation.build(data: data, rows: [latest], scope: .account(account.id))
        XCTAssertEqual(presentation.amounts[latest.id]?.first?.amount, Decimal(string: "-67.31"))
        let expected = data.transactions.filter { $0.date <= latest.date }.flatMap(\.postings).filter { $0.accountID == account.id }.reduce(Decimal.zero) { $0 + $1.amount }
        XCTAssertEqual(presentation.balances[latest.id]?.first?.amount, expected)
    }

    func testMixedCurrenciesNeverAddTogether() throws {
        var data = DemoData.fixture()
        let journal = data.ledgers[0]
        let currency = Commodity(ledgerID: journal.id, symbol: "EUR", name: "Euro")
        data.commodities.append(currency)
        var transaction = data.transactions[0]
        transaction.id = UUID()
        transaction.postings = transaction.postings.map { p in var p = p; p.id = UUID(); p.commodityID = currency.id; return p }
        data.transactions.append(transaction)
        let presentation = RegisterPresentation.build(data: data, rows: data.transactions, scope: .all)
        let month = try XCTUnwrap(presentation.months.first)
        XCTAssertEqual(Set(month.expenses.map(\.symbol)), Set(["USD", "EUR"]))
        XCTAssertEqual(month.expenses.first { $0.symbol == "EUR" }?.amount, Decimal(string: "-67.31"))
    }

    func testDecimalInputKeepsCryptocurrencyPrecision() throws {
        let amount = try XCTUnwrap(Decimal(string: "0.000123456789"))
        XCTAssertEqual(decimalFromInput(decimalInputString(amount)), amount)
        XCTAssertEqual(decimalFromInput("(12.50*3)+7"), Decimal(string: "44.5"))
        XCTAssertNil(decimalFromInput("2/0"))
    }

    func testNewEntryUsesCurrentAccountAndJournalOrderPersists() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let cash = try XCTUnwrap(store.selectedLedgerAccounts.first { $0.name == "Cash" })
        let draft = store.makeTransactionDraft(kind: .expense, accountID: cash.id)
        XCTAssertTrue(draft.postings.contains { $0.accountID == cash.id })
        let first = try XCTUnwrap(store.orderedLedgers.first)
        store.moveJournals(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(store.orderedLedgers.last?.id, first.id)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        XCTAssertEqual(reopened.orderedLedgers.last?.id, first.id)
    }

    func testSaveEditClearAndDeleteAreDurable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        var draft = store.makeTransactionDraft()
        draft.note = "Acceptance entry"
        draft.postings[0].amount = "12.50*2"
        draft.postings[1].amount = "-25"
        store.saveTransaction(draft)
        XCTAssertNil(store.validationError)
        let saved = try XCTUnwrap(store.data.transactions.first { $0.note == "Acceptance entry" })
        var edit = store.draft(for: saved)
        edit.note = "Edited acceptance entry"
        store.saveTransaction(edit)
        store.setTransactionCleared(saved.id, cleared: true)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        XCTAssertEqual(reopened.transaction(saved.id)?.note, "Edited acceptance entry")
        XCTAssertEqual(reopened.transaction(saved.id)?.cleared, true)
        reopened.deleteTransaction(saved.id, scope: .occurrence)
        try reopened.flushLocalChanges()
        let final = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        XCTAssertNil(final.transaction(saved.id))
    }

    func testUnbalancedEntryDoesNotAlterSavedJournal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let count = store.data.transactions.count
        var draft = store.makeTransactionDraft()
        draft.postings[0].amount = "25"; draft.postings[1].amount = "-20"
        store.saveTransaction(draft)
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(store.data.transactions.count, count)
    }
}
