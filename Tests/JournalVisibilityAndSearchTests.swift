import XCTest
@testable import FinancesClone

@MainActor
final class JournalVisibilityAndSearchTests: XCTestCase {
    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    func testHiddenVisibilityPersistsWithoutChangingJournalDataAndReorderSkipsHiddenSlots() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "visibility-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        // Keep the fixture within the journal codec's stored date precision.
        var data = DemoData.fixture(referenceDate: Date(timeIntervalSince1970: 1_788_858_000))
        data.ledgers.append(Ledger(name: "Third", listIndex: 2))
        let store = MobileLedgerStore(supportDirectory: folder, initialData: data)
        let original = try JSONEncoder.appEncoder.encode(store.data)
        let hidden = data.ledgers[1]
        var visibility = JournalVisibility(rawValue: "")
        visibility.setHidden(true, id: hidden.id)
        preferences.set(visibility.rawValue, forKey: JournalVisibility.preferenceKey)
        let reloaded = JournalVisibility(rawValue: preferences.string(forKey: JournalVisibility.preferenceKey) ?? "")
        XCTAssertEqual(reloaded.hidden(in: store.orderedLedgers).map(\.id), [hidden.id])
        XCTAssertEqual(reloaded.visible(in: store.orderedLedgers).map(\.id), [data.ledgers[0].id, data.ledgers[2].id])
        XCTAssertEqual(try JSONEncoder.appEncoder.encode(store.data), original)
        store.moveJournals(from: IndexSet(integer: 1), to: 0, excluding: reloaded.hiddenIDs)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: folder)
        XCTAssertEqual(reopened.orderedLedgers.map(\.id), [data.ledgers[2].id, hidden.id, data.ledgers[0].id])
        visibility.setHidden(false, id: hidden.id)
        XCTAssertEqual(visibility.visible(in: reopened.orderedLedgers).count, 3)
        XCTAssertEqual(reopened.data.transactions.sorted { $0.id.uuidString < $1.id.uuidString }, data.transactions.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    func testSearchDatePolicyKeepsHistoryAndThisYearOneOffsButHidesFutureRepeats() throws {
        let calendar = calendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30))!
        let policy = TransactionSearchDatePolicy(includeAllFuture: false, now: now, calendar: calendar)
        var row = DemoData.fixture(referenceDate: now).transactions[0]
        row.recurrenceRule = RecurrenceRule(frequency: .monthly)
        row.date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 30))!
        XCTAssertTrue(policy.includes(row), "Today includes the whole local day across DST")
        row.date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        XCTAssertFalse(policy.includes(row))
        row.recurrenceRule = nil
        XCTAssertTrue(policy.includes(row))
        row.date = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59))!
        XCTAssertTrue(policy.includes(row))
        row.date = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        XCTAssertFalse(policy.includes(row))
        row.recurrenceRule = RecurrenceRule(frequency: .monthly)
        XCTAssertTrue(TransactionSearchDatePolicy(includeAllFuture: true, now: now, calendar: calendar).includes(row))
    }

    func testFutureMaterializationsCannotCrowdHistoryOutOfLimitedSearch() async throws {
        let now = Date()
        var data = DemoData.fixture(referenceDate: now)
        let prototype = data.transactions[0]
        var history = prototype
        history.id = UUID(); history.date = now.addingTimeInterval(-86400); history.note = "needle history"
        let future = (1...150).map { index in
            var row = prototype
            row.id = UUID(); row.date = now.addingTimeInterval(Double(index) * 86400)
            row.note = "needle recurring"; row.recurrenceRule = RecurrenceRule(frequency: .daily)
            return row
        }
        data.transactions = (future + [history]).sorted { $0.date > $1.date }
        let policy = TransactionSearchDatePolicy(includeAllFuture: false, now: now)
        var request = RegisterRenderRequest(data: data, rows: data.transactions, scope: .all, search: "needle", dateInterval: nil, transactionIDs: nil, searchDatePolicy: policy)
        let recent = try await RegisterRenderWorker.shared.search(request, limit: 40)
        XCTAssertEqual(recent.rows.map(\.id), [history.id])
        request.searchDatePolicy = TransactionSearchDatePolicy(includeAllFuture: true, now: now)
        let allDates = try await RegisterRenderWorker.shared.search(request, limit: 3)
        XCTAssertEqual(allDates.rows.first?.id, history.id)
        XCTAssertEqual(allDates.rows.dropFirst().map(\.id), future.prefix(2).map(\.id))
        request.searchDatePolicy = nil
        let normalRegister = try await RegisterRenderWorker.shared.search(request)
        XCTAssertEqual(normalRegister.rows.count, 151, "Normal registers remain complete")
    }

    func testRelativeDateRequestsInvalidateAndFilterUsingTheirCapturedDay() async throws {
        let calendar = calendar()
        let firstDay = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        var data = DemoData.fixture(referenceDate: firstDay)
        var row = data.transactions[0]
        row.date = firstDay
        data.transactions = [row]
        let today = RegisterRenderRequest(data: data, rows: data.transactions, scope: .today, search: "", dateInterval: nil, transactionIDs: nil, filtersScope: true, referenceDate: firstDay, calendar: calendar)
        var tomorrow = today
        tomorrow.referenceDate = nextDay
        XCTAssertFalse(today.matches(tomorrow))
        let firstResult = try await RegisterRenderWorker.shared.search(today)
        let nextResult = try await RegisterRenderWorker.shared.search(tomorrow)
        XCTAssertEqual(firstResult.rows.map(\.id), [row.id])
        XCTAssertTrue(nextResult.rows.isEmpty)
        let september = RegisterRenderRequest(data: data, rows: data.transactions, scope: .lastMonth, search: "", dateInterval: nil, transactionIDs: nil, filtersScope: true, referenceDate: firstDay, calendar: calendar)
        var october = september
        october.referenceDate = nextDay
        XCTAssertFalse(september.matches(october))
        var otherZone = today
        otherZone.calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertFalse(today.matches(otherZone))
    }

    func testAccountPathSearchWorksInJournalScopeAndAfterAncestorRename() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var data = DemoData.fixture()
        let ledgerID = data.ledgers[0].id
        let leafIndex = try XCTUnwrap(data.accounts.firstIndex { $0.name == "Checking" })
        let parentID = try XCTUnwrap(data.accounts[leafIndex].parentID)
        data.accounts[leafIndex].name = "Robinhood Gold Card"
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        let matches = store.searchAccounts("robinhood", ledgerID: ledgerID)
        XCTAssertEqual(matches.map(\.id), [data.accounts[leafIndex].id])
        XCTAssertTrue(store.searchAccounts("robinhood", ledgerID: data.ledgers[1].id).isEmpty)
        let path = store.accountParentPath(for: matches[0])
        XCTAssertEqual(path, "Assets")
        var parent = store.draft(for: try XCTUnwrap(store.account(parentID)))
        parent.name = "Brokerage"
        store.saveAccount(parent)
        XCTAssertTrue(store.searchAccounts("brokerage:robinhood", ledgerID: ledgerID).contains { $0.id == matches[0].id })
        let request = RegisterRenderRequest(data: store.data, rows: store.registerSourceRows(ledgerID: ledgerID), scope: .all, search: "Robinhood", dateInterval: nil, transactionIDs: nil)
        let result = try await RegisterRenderWorker.shared.search(request)
        XCTAssertFalse(result.rows.isEmpty, "Anywhere search matches posting account names")
        try store.flushLocalChanges()
    }
}
