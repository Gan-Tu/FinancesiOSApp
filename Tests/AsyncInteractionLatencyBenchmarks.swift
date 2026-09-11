import XCTest
@testable import FinancesClone

@MainActor
final class AsyncInteractionLatencyBenchmarks: XCTestCase {
    func testAsyncMutationLatenciesAndMainActorResponsiveness() async throws {
        guard ProcessInfo.processInfo.environment["FINANCES_PERFORMANCE_RUN"] == "1" else {
            throw XCTSkip("Opt-in async UI-path performance comparison")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinancesAsyncPerformance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.performanceFixture())
        try await store.flushLocalChangesAsync()
        let row = try XCTUnwrap(store.data.transactions.first)
        let clock = MainActorPerformanceHeartbeat()
        clock.start()
        defer { clock.stop() }
        try await Task.sleep(for: .milliseconds(10))
        var elapsed: [Double] = [], stalls: [Double] = []
        for i in 0..<5 {
            var draft = store.draft(for: store.transaction(row.id))
            draft.note = "Updated performance note \(i)"
            clock.reset()
            let start = ContinuousClock.now
            let success = await store.saveTransactionAndFlushAsync(draft)
            elapsed.append(milliseconds(since: start))
            try await Task.sleep(for: .milliseconds(10))
            stalls.append(clock.maximumDelayMS)
            XCTAssertTrue(success)
            XCTAssertNil(store.validationError)
        }
        report("async-note-save-through-durable-flush", elapsed)
        report("async-note-save-main-actor-heartbeat-delay", stalls)
        elapsed = []; stalls = []
        for row in store.registerSourceRows(ledgerID: row.ledgerID).suffix(5) {
            clock.reset()
            let start = ContinuousClock.now
            let success = await store.deleteTransactionAsync(row.id)
            elapsed.append(milliseconds(since: start))
            try await Task.sleep(for: .milliseconds(10))
            stalls.append(clock.maximumDelayMS)
            XCTAssertTrue(success)
            XCTAssertNil(store.transaction(row.id))
            XCTAssertNil(store.validationError)
        }
        report("async-delete-through-durable-flush", elapsed)
        report("async-delete-main-actor-heartbeat-delay", stalls)
        try await store.flushLocalChangesAsync()
    }
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
    private func report(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        print("FINANCES_PERF name=\(name) rows=10000 n=\(values.count) median_ms=\(sorted[sorted.count / 2]) p95_ms=\(sorted.last ?? 0) samples_ms=\(values)")
    }
}

@MainActor
private final class MainActorPerformanceHeartbeat {
    private var task: Task<Void, Never>?
    private(set) var maximumDelayMS = 0.0
    func reset() { maximumDelayMS = 0 }
    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                let start = ContinuousClock.now
                do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                let duration = start.duration(to: .now).components
                let delay = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15 - 2
                self?.maximumDelayMS = max(self?.maximumDelayMS ?? 0, delay)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}
