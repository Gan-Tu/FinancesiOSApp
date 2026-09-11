import XCTest
@testable import FinancesClone

@MainActor
final class SQLiteWriteBenchmarks: XCTestCase {
    func testLargeJournalPhysicalWriteCounts() throws {
        guard ProcessInfo.processInfo.environment["FINANCES_PERFORMANCE_RUN"] == "1" else {
            throw XCTSkip("Opt-in physical SQLite write comparison")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinancesWriteBenchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: DemoData.performanceFixture())
        try store.flushLocalChanges()
        let database = store.cloudKitSQLiteStore.databaseURL
        try SQLiteWriteAudit.install(at: database)
        let transaction = try XCTUnwrap(store.data.transactions.first)
        func audit(_ name: String, body: () throws -> Void) throws {
            try SQLiteWriteAudit.reset(at: database)
            try body()
            try store.flushLocalChanges()
            XCTAssertNil(store.validationError)
            let counts = try SQLiteWriteAudit.counts(at: database)
            let json = try JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys])
            print("FINANCES_WRITE_PERF name=\(name) rows=10000 sqlite_row_writes=\(counts.values.reduce(0, +)) tables=\(String(decoding: json, as: UTF8.self))")
        }
        try audit("clear") { store.setTransactionCleared(transaction.id, cleared: !transaction.cleared) }
        try audit("note-edit") {
            var draft = store.draft(for: store.transaction(transaction.id)); draft.note = "Changed note"
            store.saveTransaction(draft)
        }
        try audit("amount-edit") {
            var draft = store.draft(for: store.transaction(transaction.id))
            draft.postings[0].amount = "-250"; draft.postings[1].amount = "250"
            store.saveTransaction(draft)
        }
        try audit("insert") {
            var draft = store.draft(for: store.transaction(transaction.id)); draft.id = nil
            draft.postings = draft.postings.map { var p = $0; p.id = UUID(); return p }
            store.saveTransaction(draft)
        }
        try audit("delete") { store.deleteTransaction(transaction.id) }
        try store.flushLocalChanges()
    }
    func testReceiptAndBurstPhysicalWriteCounts() throws {
        guard ProcessInfo.processInfo.environment["FINANCES_PERFORMANCE_RUN"] == "1" else {
            throw XCTSkip("Opt-in receipt and burst SQLite write comparison")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinancesReceiptWriteBenchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptDirectory = directory.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        for i in 0..<3 { try Data("Synthetic receipt \(i)".utf8).write(to: receiptDirectory.appendingPathComponent("receipt-\(i).txt")) }
        var fixture = DemoData.performanceFixture()
        // A quarter of entries carry three receipt metadata records. The tiny
        // shared fixture files avoid spending benchmark time copying receipt bytes.
        for index in fixture.transactions.indices where index.isMultiple(of: 4) {
            fixture.transactions[index].attachment = AttachmentContainer(assets: (0..<3).map { i in
                AttachmentAsset(originalFilename: "receipt-\(i).txt", storedPath: "Attachments/receipt-\(i).txt",
                    mimeType: "text/plain", sizeBytes: 19)
            })
        }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: fixture)
        XCTAssertFalse(store.requiresJournalRecovery)
        try store.flushLocalChanges()
        let database = store.cloudKitSQLiteStore.databaseURL
        try SQLiteWriteAudit.install(at: database)
        let transaction = try XCTUnwrap(store.transaction(fixture.transactions[0].id))
        XCTAssertEqual(transaction.attachment?.assets.count, 3)
        func audit(_ name: String, body: () throws -> Void) throws {
            try SQLiteWriteAudit.reset(at: database)
            try body()
            try store.flushLocalChanges()
            XCTAssertNil(store.validationError)
            let counts = try SQLiteWriteAudit.counts(at: database)
            let json = try JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys])
            print("FINANCES_WRITE_PERF name=\(name) rows=10000 sqlite_row_writes=\(counts.values.reduce(0, +)) tables=\(String(decoding: json, as: UTF8.self))")
        }
        try audit("receipt-clear") { store.setTransactionCleared(transaction.id, cleared: !transaction.cleared) }
        try audit("receipt-note-edit") {
            var draft = store.draft(for: store.transaction(transaction.id)); draft.note = "Changed receipt note"
            store.saveTransaction(draft)
        }
        try audit("receipt-amount-edit") {
            var draft = store.draft(for: store.transaction(transaction.id))
            draft.postings[0].amount = "-250"; draft.postings[1].amount = "250"
            store.saveTransaction(draft)
        }
        try audit("receipt-insert") {
            let draft = try XCTUnwrap(store.duplicateTransactionDraft(transaction.id, useToday: false))
            store.saveTransaction(draft)
        }
        try audit("receipt-delete") { store.deleteTransaction(transaction.id) }
        let targets = fixture.transactions[1...25].map(\.id)
        try audit("clear-burst-25") {
            for id in targets {
                let row = try XCTUnwrap(store.transaction(id))
                store.setTransactionCleared(id, cleared: !row.cleared)
            }
        }
        let reloaded = MobileLedgerStore(supportDirectory: directory)
        for id in targets {
            XCTAssertEqual(reloaded.transaction(id)?.cleared, store.transaction(id)?.cleared)
        }
    }

}
