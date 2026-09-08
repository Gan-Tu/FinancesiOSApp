import XCTest
import Combine
@testable import FinancesClone

@MainActor
final class TemplateAndNavigationPerformanceTests: XCTestCase {
    func testTemplateExclusionRestorationAndPermanentDeletionSurviveReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.fixture())
        let existingLedger = try XCTUnwrap(store.selectedLedgerID)
        XCTAssertTrue(store.transactionTemplates(for: existingLedger).isEmpty)
        store.addJournal(name: "New journal")
        let id = try XCTUnwrap(store.selectedLedgerID)
        let defaults = store.transactionTemplates(for: id)
        XCTAssertEqual(defaults.map(\.name), ["Expense", "Income", "Transfer"])
        XCTAssertTrue(defaults.allSatisfy { $0.enabled && $0.postings.count == 2 })
        XCTAssertTrue(store.transactionTemplates(for: existingLedger).isEmpty, "Do not retrofit imported journals")
        let template = try XCTUnwrap(defaults.first)
        var draft = store.templateDraft(for: template)
        draft.name = "支出"; draft.note = "Keep my note"; draft.payee = "My payee"
        store.saveTransactionTemplate(draft)
        store.setTransactionTemplateIncluded(template.id, included: false)
        try store.flushLocalChanges()
        let restored = MobileLedgerStore(supportDirectory: directory)
        let excluded = try XCTUnwrap(restored.transactionTemplates(for: id).first { $0.id == template.id })
        XCTAssertFalse(excluded.enabled)
        XCTAssertEqual(excluded.name, "支出")
        XCTAssertEqual(excluded.note, "Keep my note")
        XCTAssertEqual(excluded.payee, "My payee")
        XCTAssertEqual(excluded.postings, template.postings)
        restored.setTransactionTemplateIncluded(template.id, included: true)
        XCTAssertEqual(restored.transactionTemplates(for: id).filter(\.enabled).map(\.name), ["支出", "Income", "Transfer"])
        restored.deleteTransactionTemplate(template.id)
        try restored.flushLocalChanges()
        let final = MobileLedgerStore(supportDirectory: directory)
        XCTAssertEqual(final.transactionTemplates(for: id).map(\.name), ["Income", "Transfer"])
        XCTAssertTrue(final.transactionTemplates(for: existingLedger).isEmpty)
    }

    func testSyncProgressDoesNotInvalidateJournalObservers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.fixture())
        var journalChanges = 0, progressChanges = 0
        let journal = store.objectWillChange.sink { journalChanges += 1 }
        let progress = store.cloudSyncState.objectWillChange.sink { progressChanges += 1 }
        for index in 0..<100 {
            store.cloudKitSyncDidUpdate(.running(message: "Uploading", detail: "\(index)", fractionCompleted: Double(index) / 100, phase: .uploading))
        }
        XCTAssertEqual(journalChanges, 0)
        XCTAssertEqual(progressChanges, 100)
        XCTAssertEqual(store.cloudSyncProgress.detail, "99")
        withExtendedLifetime((journal, progress)) {}
    }

    func testBackgroundScopeFilteringMatchesRegisterQueries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = DemoData.fixture(includeFutureEntries: true, includeRecurringEntries: true)
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        let ledgerID = try XCTUnwrap(store.selectedLedgerID)
        let scopes: [MobileTransactionScope] = [.all, .uncleared, .repeating, .today, .lastMonth]
            + data.accounts.map { .account($0.id) } + data.commodities.map { .currency($0.id) }
        for scope in scopes {
            let expected = store.transactions(scope: scope, ledgerID: ledgerID)
            let request = RegisterRenderRequest(data: data, rows: store.registerSourceRows(ledgerID: ledgerID), scope: scope, search: "", dateInterval: nil, transactionIDs: nil, filtersScope: true)
            let result = try await RegisterRenderWorker.shared.search(request)
            XCTAssertEqual(result.rows.map(\.id), expected.map(\.id), "Scope \(scope)")
        }
    }

    func testRecurrenceAnchorIndexRemainsCorrectAfterClearingAndDeletingAnchor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = DemoData.fixture(includeRecurringEntries: true)
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        let rule = try XCTUnwrap(data.transactions.compactMap(\.recurrenceRule).first)
        let anchor = try XCTUnwrap(RecurringJournalEditor.anchor(ruleID: rule.id, in: data.transactions))
        XCTAssertEqual(store.recurrenceAnchorID(ruleID: rule.id), anchor.id)
        store.setTransactionCleared(anchor.id, cleared: !anchor.cleared)
        XCTAssertEqual(store.recurrenceAnchorID(ruleID: rule.id), anchor.id)
        store.deleteTransaction(anchor.id)
        XCTAssertEqual(store.recurrenceAnchorID(ruleID: rule.id), RecurringJournalEditor.anchor(ruleID: rule.id, in: store.data.transactions)?.id)
        try store.flushLocalChanges()
    }

    func testLargeJournalCountLookupBenchmarkAndParity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), calendar = Calendar.current
        var data = DemoData.fixture(referenceDate: now)
        let prototype = try XCTUnwrap(data.transactions.first)
        data.transactions = (0..<10000).map { index in
            var row = prototype
            row.id = UUID(); row.cleared = index % 3 == 0
            row.date = now.addingTimeInterval(Double(index - 5000) * 86400)
            row.postings = row.postings.map { posting in var copy = posting; copy.id = UUID(); return copy }
            return row
        }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        let rows = store.transactions(scope: .uncleared, ledgerID: prototype.ledgerID)
        let baselineStart = ContinuousClock.now
        var expected = 0
        for _ in 0..<25 { expected = rows.filter { calendar.compare($0.date, to: now, toGranularity: .day) != .orderedDescending }.count }
        let baseline = baselineStart.duration(to: .now)
        let cachedStart = ContinuousClock.now
        var actual = 0
        for _ in 0..<25 { actual = store.unclearedTransactionCount(ledgerID: prototype.ledgerID, now: now, calendar: calendar) }
        let cached = cachedStart.duration(to: .now)
        XCTAssertEqual(actual, expected)
        print("UNCLEARED_LOOKUP_BENCHMARK rows=10000 iterations=25 baseline=\(baseline) optimized=\(cached)")
    }
}
