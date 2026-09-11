import XCTest
@testable import FinancesClone

/// Opt-in instrumentation, run with FINANCES_PERFORMANCE_RUN=1 and -O.
/// These are model/action timings, not touch-to-photon or animation durations.
@MainActor
final class InteractionLatencyBenchmarks: XCTestCase {
    func testLargeJournalInteractionLatencies() async throws {
        guard ProcessInfo.processInfo.environment["FINANCES_PERFORMANCE_RUN"] == "1" else {
            throw XCTSkip("Opt-in release-optimized performance comparison")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinancesPerformance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = DemoData.performanceFixture()
        let ledgerID = try XCTUnwrap(data.selectedLedgerID)
        let initStart = ContinuousClock.now
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        report("store-initialization", [milliseconds(since: initStart)])
        XCTAssertFalse(store.requiresJournalRecovery)
        try store.flushLocalChanges()
        await store.waitForCloudKitSyncIdle()
        let row = try XCTUnwrap(data.transactions.first)
        let template = try XCTUnwrap(data.transactionTemplates.first)
        let rows = store.registerSourceRows(ledgerID: ledgerID)
        XCTAssertEqual(rows.count, 10_000)
        var sink = 0
        sample("accounts-screen-model", iterations: 100) {
            let nodes = store.accountNodes(ledgerID: ledgerID)
            sink += nodes.count + store.unclearedTransactionCount(ledgerID: ledgerID)
            for node in nodes { sink += store.balanceRows(for: node.id).count }
        }
        sample("transaction-detail-model", iterations: 100) {
            for transaction in rows.prefix(40) {
                sink += store.draft(for: transaction).postings.count
                sink += store.registerAmountInfo(for: transaction).symbol.count
            }
        }
        sample("new-template-editor-model", iterations: 100) {
            let draft = store.draft(for: template)
            sink += draft.postings.count + store.templateAccountSelectionPostingIDs(in: draft).count
        }
        var presentationSamples: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let result = RegisterPresentation.build(data: data, rows: rows, scope: .all)
            presentationSamples.append(milliseconds(since: start))
            XCTAssertEqual(result.amounts.count, rows.count)
            sink += result.months.count
        }
        report("register-presentation-cold", presentationSamples)
        let request = RegisterRenderRequest(data: data, rows: rows, scope: .all, search: "", dateInterval: nil, transactionIDs: nil, filtersScope: true)
        var workerSamples: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let result = try await RegisterRenderWorker.shared.render(request)
            workerSamples.append(milliseconds(since: start))
            sink += result.presentation.months.count
        }
        report("register-worker-cold", workerSamples)
        let cache = RegisterPresentationCache()
        let key = RegisterPresentationCacheKey(revision: cache.revision, ledgerID: ledgerID, request: request)
        _ = try await cache.load(request, key: key)
        sample("register-cache-hit", iterations: 100) { sink += cache.cached(for: key)?.presentation.months.count ?? 0 }
        var clearSamples: [Double] = [], clearDurable: [Double] = []
        for i in 0..<5 {
            let current = try XCTUnwrap(store.transaction(row.id))
            let start = ContinuousClock.now
            store.setTransactionCleared(row.id, cleared: !current.cleared)
            clearSamples.append(milliseconds(since: start))
            try store.flushLocalChanges()
            clearDurable.append(milliseconds(since: start))
            XCTAssertNil(store.validationError, "Clear \(i)")
        }
        report("clear-main-actor-action", clearSamples)
        report("clear-through-durable-flush", clearDurable)
        var saveSamples: [Double] = [], saveDurable: [Double] = []
        for i in 0..<5 {
            var draft = store.draft(for: store.transaction(row.id))
            draft.note = "Updated performance note \(i)"
            let start = ContinuousClock.now
            store.saveTransaction(draft)
            saveSamples.append(milliseconds(since: start))
            try store.flushLocalChanges()
            saveDurable.append(milliseconds(since: start))
            XCTAssertNil(store.validationError, "Save \(i)")
        }
        report("note-save-main-actor-action", saveSamples)
        report("note-save-through-durable-flush", saveDurable)
        var deletionSamples: [Double] = []
        for row in rows.suffix(5) {
            let start = ContinuousClock.now
            store.deleteTransaction(row.id)
            deletionSamples.append(milliseconds(since: start))
            XCTAssertNil(store.validationError)
            XCTAssertNil(store.transaction(row.id))
        }
        report("delete-through-durable-flush", deletionSamples)
        try store.flushLocalChanges()
        XCTAssertGreaterThan(sink, 0)
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
    private func sample(_ name: String, iterations: Int, body: () throws -> Void) rethrows {
        var samples: [Double] = []
        for _ in 0..<iterations { let start = ContinuousClock.now; try body(); samples.append(milliseconds(since: start)) }
        report(name, samples)
    }
    private func report(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print("FINANCES_PERF name=\(name) rows=10000 n=\(values.count) median_ms=\(median) p95_ms=\(p95) samples_ms=\(values)")
    }
}
