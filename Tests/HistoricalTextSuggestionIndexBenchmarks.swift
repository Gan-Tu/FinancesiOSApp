import Foundation
import XCTest
@testable import FinancesClone

final class HistoricalTextSuggestionIndexBenchmarks: XCTestCase {
    /// Opt in to this synthetic benchmark; no user databases, network, or UI.
    /// Measure fixture creation separately from the immutable index build.
    func testWorkerIndexBuildAndHotPrefixQueriesAtTenAndHundredThousandRows() async throws {
        guard ProcessInfo.processInfo.environment["FINANCES_HISTORY_SUGGESTION_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in historical suggestion index benchmark")
        }
        let reports = try await Task.detached(priority: .userInitiated) { () throws -> [HistoricalSuggestionBenchmarkReport] in
            let small = try HistoricalSuggestionBenchmarkWorker.measure(rowCount: 10_000)
            let large = try HistoricalSuggestionBenchmarkWorker.measure(rowCount: 100_000)
            return [small, large]
        }.value
        for report in reports {
            XCTAssertFalse(report.ranOnMainThread)
            XCTAssertEqual(report.distinctValues, report.rowCount * 2)
            XCTAssertLessThan(report.treeSlots, report.distinctValues * 4)
            XCTAssertEqual(report.broadResultCount, 5)
            XCTAssertEqual(report.rebuiltReplacement, "Replacement note")
            XCTAssertGreaterThan(report.checksum, 0)
            print(report.line)
        }
    }
}

private struct HistoricalSuggestionBenchmarkReport: Sendable {
    let rowCount: Int
    let ranOnMainThread: Bool
    let distinctValues: Int
    let treeSlots: Int
    let broadResultCount: Int
    let rebuiltReplacement: String?
    let checksum: Int
    let line: String
}

private enum HistoricalSuggestionBenchmarkWorker {
    nonisolated static func measure(rowCount: Int) throws -> HistoricalSuggestionBenchmarkReport {
        let clock = ContinuousClock()
        let journal = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let ranOnMainThread = Thread.isMainThread
        let fixtureStart = clock.now
        var rows = (0..<rowCount).map { i in
            LedgerTransaction(ledgerID: journal, date: asOf.addingTimeInterval(-Double(i % 1_000)),
                payee: String(format: "Common payee %06d", i), note: String(format: "Common note %06d", i),
                number: "", cleared: true, postings: [], recurrenceRule: nil, attachment: nil)
        }
        let fixtureMS = milliseconds(fixtureStart.duration(to: clock.now))
        let buildStart = clock.now
        let index = try HistoricalTextSuggestionIndex(transactions: rows, asOf: asOf, checkCancellation: Task.checkCancellation)
        let buildMS = milliseconds(buildStart.duration(to: clock.now))
        let queries = ["", " \n", "c", "common", "common note", "common note ",
                       "common note 0", "common note 09", "Common note 000000", "missing"]
        for query in queries { _ = index.suggestions(for: .note, in: journal, matching: query) }
        var checksum = 0
        var perQueryMicroseconds: [Double] = []
        let repeatedStart = clock.now
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            for query in queries {
                let start = clock.now
                let values = index.suggestions(for: .note, in: journal, matching: query)
                perQueryMicroseconds.append(milliseconds(start.duration(to: clock.now)) * 1_000)
                checksum += values.reduce(0) { $0 + $1.text.utf8.count + $1.frequency }
            }
        }
        let repeatedMS = milliseconds(repeatedStart.duration(to: clock.now))
        perQueryMicroseconds.sort()
        let p50US = perQueryMicroseconds[perQueryMicroseconds.count / 2]
        let p95US = perQueryMicroseconds[perQueryMicroseconds.count * 95 / 100]

        // This is explicitly a full rebuild after a single text edit. The
        // snapshot array is changed before timing so COW is not hidden in build.
        rows[0].note = "Replacement note"
        let rebuildStart = clock.now
        let rebuilt = try HistoricalTextSuggestionIndex(transactions: rows, asOf: asOf, checkCancellation: Task.checkCancellation)
        let rebuildMS = milliseconds(rebuildStart.duration(to: clock.now))
        let replacement = rebuilt.suggestions(for: .note, in: journal, matching: "Replacement").first?.text
        let line = "FINANCES_HISTORY_SUGGESTION_PERF rows=\(rowCount) distinct=\(index.distinctValueCount) tree_slots=\(index.rankTreeSlotCount) fixture_ms=\(fixtureMS) cold_build_ms=\(buildMS) full_rebuild_one_edit_ms=\(rebuildMS) queries=\(perQueryMicroseconds.count) repeated_total_ms=\(repeatedMS) query_p50_us=\(p50US) query_p95_us=\(p95US) checksum=\(checksum)"
        return HistoricalSuggestionBenchmarkReport(rowCount: rowCount, ranOnMainThread: ranOnMainThread,
                      distinctValues: index.distinctValueCount, treeSlots: index.rankTreeSlotCount,
                      broadResultCount: index.suggestions(for: .note, in: journal, matching: "common").count,
                      rebuiltReplacement: replacement, checksum: checksum, line: line)
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
