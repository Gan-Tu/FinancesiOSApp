import Foundation
import XCTest
@testable import FinancesClone

@MainActor
final class NoopTransactionSaveTests: XCTestCase {
    private var stores: [MobileLedgerStore] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for store in stores { await store.waitForCloudKitSyncIdle() }
        stores.removeAll()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    private func fixture(canonical: Bool = true, rowCount: Int = 200) async throws -> (MobileLedgerStore, UUID) {
        var data = DemoData.performanceFixture(transactionCount: rowCount)
        let calendar = Calendar.current
        let anchorDate = calendar.date(from: DateComponents(year: 2020, month: 1, day: 10, hour: 12))!
        let count = min(100, rowCount)
        let source = data.transactions[0]
        var rule = RecurrenceRule(frequency: .monthly, occurrenceCount: count, preservesImportedMaterializations: true)
        for index in 0..<count {
            data.transactions[index].date = calendar.date(byAdding: .month, value: index, to: anchorDate)!
            data.transactions[index].payee = "Canonical recurring payee"
            data.transactions[index].note = "Canonical recurring note"
            data.transactions[index].number = "Recurring-10"
            data.transactions[index].postings[0].accountID = source.postings[0].accountID
            data.transactions[index].postings[1].accountID = source.postings[1].accountID
            data.transactions[index].postings[0].commodityID = source.postings[0].commodityID
            data.transactions[index].postings[1].commodityID = source.postings[1].commodityID
            data.transactions[index].postings[0].amount = -10
            data.transactions[index].postings[1].amount = 10
        }
        if canonical {
            rule.templateHistory = RecurrenceTemplateHistory(baseTemplate: RecurrenceTransactionTemplate(transaction: data.transactions[0]), scheduleAnchorDate: anchorDate)
            rule.continuation = RecurrenceContinuation(anchorDate: anchorDate, calendar: calendar,
                nextOccurrenceIndex: count, consumedOccurrences: count,
                lastScheduledDay: calendar.startOfDay(for: data.transactions[count - 1].date), allowsAutomaticExtension: false)
        }
        for index in 0..<count { data.transactions[index].recurrenceRule = rule }
        let target = data.transactions[20].id
        data.transactions.sort { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoopSave-\(UUID())")
        var dependencies = CloudKitSyncDependencies.live
        dependencies.automaticTriggersEnabled = false
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data, cloudKitSyncDependencies: dependencies)
        directories.append(directory); stores.append(store)
        XCTAssertFalse(store.requiresJournalRecovery)
        if canonical {
            let primed = await store.saveTransactionAndFlushAsync(store.draft(for: try XCTUnwrap(store.transaction(target))), scope: .future)
            XCTAssertTrue(primed)
        } else { try await store.flushLocalChangesAsync() }
        await store.waitForCloudKitSyncIdle()
        return (store, target)
    }

    private func warm(_ store: MobileLedgerStore) async throws -> RegisterPresentationCacheKey {
        let request = RegisterRenderRequest(data: store.data, rows: store.registerSourceRows(ledgerID: store.selectedLedgerID),
            scope: .all, search: "", dateInterval: nil, transactionIDs: nil, filtersScope: true)
        let key = RegisterPresentationCacheKey(revision: store.registerContentRevision, ledgerID: store.selectedLedgerID, request: request)
        _ = try await store.registerPresentations.load(request, key: key)
        return key
    }

    func testCanonicalNoopKeepsWarmCacheAndRevisionsButStillValidates() async throws {
        let (store, target) = try await fixture()
        let key = try await warm(store)
        let revision = store.registerContentRevision, searchRevision = store.searchContentRevision
        let before = store.data.transactions
        let saved = await store.saveTransactionAndFlushAsync(store.draft(for: try XCTUnwrap(store.transaction(target))), scope: .future)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.data.transactions, before)
        XCTAssertEqual(store.registerContentRevision, revision)
        XCTAssertEqual(store.searchContentRevision, searchRevision)
        XCTAssertNotNil(store.registerPresentations.cached(for: key))
        var invalid = store.draft(for: try XCTUnwrap(store.transaction(target)))
        invalid.postings[0].amount = "invalid"
        let rejected = await store.saveTransactionAndFlushAsync(invalid, scope: .future)
        XCTAssertFalse(rejected)
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(store.data.transactions, before)
    }

    func testIdenticalRetryAfterFailedWriteStillCommitsAndClearsFailure() async throws {
        let (store, target) = try await fixture()
        let url = store.cloudKitSQLiteStore.databaseURL
        try SQLiteWriteAudit.execute("CREATE TRIGGER test_noop_write_failure_insert BEFORE INSERT ON transactions BEGIN SELECT RAISE(ABORT, 'Synthetic write failure'); END", at: url)
        try SQLiteWriteAudit.execute("CREATE TRIGGER test_noop_write_failure_update BEFORE UPDATE ON transactions BEGIN SELECT RAISE(ABORT, 'Synthetic write failure'); END", at: url)
        var draft = store.draft(for: try XCTUnwrap(store.transaction(target)))
        draft.note = "Pending durable retry"
        let failed = await store.saveTransactionAndFlushAsync(draft, scope: .future)
        XCTAssertFalse(failed)
        XCTAssertNotNil(store.localPersistenceError)
        XCTAssertEqual(store.transaction(target)?.note, draft.note)
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: url).loadData()?.transactions.first { $0.id == target }?.note, "Canonical recurring note")
        try SQLiteWriteAudit.execute("DROP TRIGGER test_noop_write_failure_insert", at: url)
        try SQLiteWriteAudit.execute("DROP TRIGGER test_noop_write_failure_update", at: url)
        let key = try await warm(store)
        let revision = store.registerContentRevision
        let retried = await store.saveTransactionAndFlushAsync(draft, scope: .future)
        XCTAssertTrue(retried)
        XCTAssertNil(store.localPersistenceError)
        XCTAssertEqual(store.registerContentRevision, revision)
        XCTAssertNotNil(store.registerPresentations.cached(for: key))
        let disk = try XCTUnwrap(SQLiteJournalStore(databaseURL: url).loadData())
        XCTAssertEqual(disk.transactions, store.data.transactions)
        XCTAssertEqual(disk.transactions.first { $0.id == target }?.note, draft.note)
    }

    func testUnchangedSelectedEntryStillReplacesLaterOverride() async throws {
        let (store, target) = try await fixture()
        let selected = try XCTUnwrap(store.transaction(target))
        let later = try XCTUnwrap(store.data.transactions.filter { $0.recurrenceRule?.id == selected.recurrenceRule?.id && $0.date > selected.date }.max { $0.date < $1.date })
        var override = store.draft(for: later)
        override.postings[0].amount = "-99"; override.postings[1].amount = "99"
        override.note = "Later exception"
        let overrideSaved = await store.saveTransactionAndFlushAsync(override)
        XCTAssertTrue(overrideSaved)
        let revision = store.registerContentRevision
        let saved = await store.saveTransactionAndFlushAsync(store.draft(for: try XCTUnwrap(store.transaction(target))), scope: .future)
        XCTAssertTrue(saved)
        XCTAssertGreaterThan(store.registerContentRevision, revision)
        XCTAssertEqual(store.transaction(later.id)?.postings.map(\.amount), [-10, 10])
        XCTAssertEqual(store.transaction(later.id)?.note, selected.note)
        XCTAssertEqual(store.transaction(later.id)?.postings.map(\.id), later.postings.map(\.id))
    }

    func testMissingHistoryAndContinuationStillNormalize() async throws {
        let (store, target) = try await fixture(canonical: false)
        XCTAssertNil(store.transaction(target)?.recurrenceRule?.templateHistory)
        XCTAssertNil(store.transaction(target)?.recurrenceRule?.continuation)
        let revision = store.registerContentRevision
        let saved = await store.saveTransactionAndFlushAsync(store.draft(for: try XCTUnwrap(store.transaction(target))))
        XCTAssertTrue(saved)
        XCTAssertGreaterThan(store.registerContentRevision, revision)
        XCTAssertNotNil(store.transaction(target)?.recurrenceRule?.templateHistory)
        XCTAssertNotNil(store.transaction(target)?.recurrenceRule?.continuation)
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: store.cloudKitSQLiteStore.databaseURL).loadData()?.transactions, store.data.transactions)
    }

    func testUnchangedDuplicateRetryKeepsOneOwnedReceiptCopy() async throws {
        let (store, target) = try await fixture()
        let source = directories.last!.appendingPathComponent("original.bin")
        let bytes = Data(repeating: 73, count: 1024)
        try bytes.write(to: source)
        let originalAsset = try store.importAttachment(from: source)
        var withReceipt = store.draft(for: try XCTUnwrap(store.transaction(target)))
        withReceipt.attachments = [originalAsset]
        let prepared = await store.saveTransactionAndFlushAsync(withReceipt)
        XCTAssertTrue(prepared)
        let duplicate = try XCTUnwrap(store.duplicateTransactionDraft(target, useToday: true))
        let url = store.cloudKitSQLiteStore.databaseURL
        try SQLiteWriteAudit.execute("CREATE TRIGGER test_noop_duplicate_failure BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'Synthetic write failure'); END", at: url)
        let failed = await store.saveTransactionAndFlushAsync(duplicate)
        XCTAssertFalse(failed)
        let copied = try XCTUnwrap(store.transaction(duplicate.saveOperationID)?.attachment?.assets.first)
        XCTAssertNotEqual(copied.id, originalAsset.id)
        let count = store.data.transactions.count
        let revision = store.registerContentRevision
        try SQLiteWriteAudit.execute("DROP TRIGGER test_noop_duplicate_failure", at: url)
        let retried = await store.saveTransactionAndFlushAsync(duplicate)
        XCTAssertTrue(retried)
        XCTAssertNil(store.localPersistenceError)
        XCTAssertEqual(store.registerContentRevision, revision)
        XCTAssertEqual(store.data.transactions.count, count)
        XCTAssertEqual(store.transaction(duplicate.saveOperationID)?.attachment?.assets, [copied])
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(for: originalAsset)), bytes)
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(for: copied)), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directories.last!.appendingPathComponent("Attachments").path).count, 2)
        XCTAssertEqual(try SQLiteJournalStore(databaseURL: url).loadData()?.transactions.filter { $0.id == duplicate.saveOperationID }.count, 1)
    }

    func testTenThousandRowCanonicalNoopBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["FINANCES_NOOP_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in isolated no-op comparison") }
        let label = ProcessInfo.processInfo.environment["FINANCES_NOOP_LABEL"] ?? "unspecified"
        let (store, target) = try await fixture(rowCount: 10_000)
        let url = store.cloudKitSQLiteStore.databaseURL
        try SQLiteWriteAudit.install(at: url)
        var records: [[String: Any]] = []
        for iteration in 0..<5 {
            let key = try await warm(store)
            _ = store.transactions(scope: .all, search: "Canonical recurring note")
            let before = store.data.transactions
            let draft = store.draft(for: try XCTUnwrap(store.transaction(target)))
            let revision = store.registerContentRevision, searchRevision = store.searchContentRevision
            let renderCount = store.registerPresentations.renderCount
            try SQLiteWriteAudit.reset(at: url)
            let heartbeat = Heartbeat()
            heartbeat.start()
            try await Task.sleep(for: .milliseconds(10))
            heartbeat.reset()
            let start = ContinuousClock.now
            let saved = await store.saveTransactionAndFlushAsync(draft, scope: .future)
            let saveEnd = ContinuousClock.now
            let durableMS = Self.ms(start.duration(to: saveEnd))
            let pulse = heartbeat.finish(at: saveEnd)
            let maximumMainGap = pulse.gaps.max() ?? 0
            XCTAssertFalse(pulse.gaps.isEmpty)
            XCTAssertEqual(pulse.gaps.last, pulse.terminalGap)
            let cacheMiss = store.registerPresentations.cached(for: key) == nil
            let recoveryStart = ContinuousClock.now
            _ = try await warm(store)
            let recoveryMS = Self.ms(recoveryStart.duration(to: .now))
            XCTAssertTrue(saved)
            XCTAssertEqual(store.data.transactions, before)
            XCTAssertNil(store.localPersistenceError)
            XCTAssertTrue(try SQLiteJournalStore(databaseURL: url).loadData()?.transactions == before, "Durable snapshot must match all canonical transaction values and IDs")
            let writes = try SQLiteWriteAudit.counts(at: url).values.reduce(0, +)
            records.append(["iteration": iteration, "durable_ms": durableMS, "max_main_gap_ms": maximumMainGap,
                "heartbeat_sample_count": pulse.gaps.count, "terminal_main_gap_ms": pulse.terminalGap,
                "cache_miss": cacheMiss, "cache_recovery_ms": recoveryMS, "save_plus_recovery_ms": durableMS + recoveryMS,
                "render_delta": store.registerPresentations.renderCount - renderCount,
                "register_revision_delta": store.registerContentRevision - revision,
                "search_revision_delta": store.searchContentRevision - searchRevision, "physical_row_writes": writes])
        }
        let payload: [String: Any] = ["label": label, "rows": 10_000, "accounts": store.data.accounts.count, "samples": records]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print("FINANCES_NOOP_BENCHMARK " + String(decoding: json, as: UTF8.self))
    }

    func testHeartbeatRecordsTerminalMainActorBlockWithoutAwaitingAnotherTick() {
        let heartbeat = Heartbeat()
        heartbeat.start()
        heartbeat.reset()
        // No actor suspension: the scheduled pulse cannot run before finish.
        // This reproduces a save continuation winning over an overdue pulse.
        Thread.sleep(forTimeInterval: 0.03)
        let end = ContinuousClock.now
        let measurement = heartbeat.finish(at: end)
        XCTAssertEqual(measurement.gaps.count, 1)
        XCTAssertGreaterThanOrEqual(measurement.terminalGap, 25)
        XCTAssertEqual(measurement.gaps.last, measurement.terminalGap)
    }

    private static func ms(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?
        private var previous = ContinuousClock.now
        var gaps: [Double] = []
        func start() {
            task = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
                    let now = ContinuousClock.now
                    gaps.append(NoopTransactionSaveTests.ms(previous.duration(to: now)))
                    previous = now
                }
            }
        }
        func reset() { gaps = []; previous = .now }
        func finish(at end: ContinuousClock.Instant) -> (gaps: [Double], terminalGap: Double) {
            // The save continuation may run before an overdue heartbeat. Close
            // that final interval explicitly instead of silently dropping it.
            let terminal = NoopTransactionSaveTests.ms(previous.duration(to: end))
            gaps.append(terminal)
            task?.cancel(); task = nil
            return (gaps, terminal)
        }
    }
}
