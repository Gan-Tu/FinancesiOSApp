import Foundation
import XCTest
@testable import FinancesClone

final class SQLiteRecurrenceWriteBenchmarks: XCTestCase {
    func testMatchedTwoHundredRowFutureSeriesWriteCount() throws {
        guard ProcessInfo.processInfo.environment["FINANCES_PERFORMANCE_RUN"] == "1" else {
            throw XCTSkip("Opt-in matched recurrence SQLite write comparison")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "RecurrenceWriteBenchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteJournalStore(databaseURL: directory.appending(path: "journal.sqlite"))
        let original = SQLiteRecurrenceWriteFixture.make()
        let changed = try SQLiteRecurrenceWriteFixture.futureNoteEdit(original)
        try store.replaceData(original, trackSyncChanges: false)
        try SQLiteWriteAudit.install(at: store.databaseURL)
        try store.persist(changed, previous: original)
        let counts = try SQLiteWriteAudit.counts(at: store.databaseURL)
        let json = try JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys])
        print("FINANCES_RECURRENCE_WRITE_PERF rows=200 series=100 future_rows=80 sqlite_row_writes=\(counts.values.reduce(0, +)) tables=\(String(decoding: json, as: UTF8.self))")
        XCTAssertEqual(try store.loadData()?.transactions, changed.transactions.sorted { $0.date < $1.date })
        let changes = try store.claimPendingSyncChanges(limit: 1_000)
        XCTAssertEqual(changes.count, 100)
        XCTAssertTrue(changes.allSatisfy { $0.recordType == "transaction" && $0.operation == "upsert" })
    }
}
