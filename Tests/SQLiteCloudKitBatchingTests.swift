import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import FinancesClone

final class SQLiteCloudKitBatchingTests: XCTestCase {
    private let context = "iCloud.example.batching|Development|Synthetic"

    func testClaimsMergePendingAndInFlightOrderWithoutSkippingOlderVersionsOrConflicts() throws {
        let f = try fixture()
        let first = record(), second = record(), blocked = record(), later = record()
        var successor = first; successor.clientChangeID = UUID().uuidString; successor.payloadJSON = "{\"version\":2}"
        var blockedSuccessor = blocked; blockedSuccessor.clientChangeID = UUID().uuidString
        var legacy = record(); legacy.recordType = "posting"
        try database(f) { db in
            try insert(first, state: "in_flight", db)
            try insert(second, state: "pending", db)
            try insert(successor, state: "pending", db)
            try insert(blocked, state: "in_flight", db)
            try insert(blockedSuccessor, state: "pending", db)
            try insert(legacy, state: "pending", db)
            try insert(later, state: "pending", db)
        }
        var remote = blocked; remote.payloadJSON = "{\"conflicting\":true}"
        try f.store.saveCloudKitConflict(local: blocked, remote: remote, contextKey: context)
        let firstBatch = try f.store.claimCloudKitChanges(contextKey: context, limit: 2)
        XCTAssertEqual(firstBatch.map(\.clientChangeID), [first.clientChangeID, second.clientChangeID])
        XCTAssertEqual(try f.store.claimCloudKitChanges(contextKey: context, limit: 2), firstBatch, "Retry must preserve exact IDs and payloads")
        var saved = firstBatch[0]; saved.systemFields = Data([1, 0, 2])
        try f.store.acknowledgeCloudKitRecords([saved], submitted: firstBatch, contextKey: context)
        let next = try f.store.claimCloudKitChanges(contextKey: context, limit: 50)
        XCTAssertEqual(next.map(\.clientChangeID), [second.clientChangeID, successor.clientChangeID, later.clientChangeID])
        XCTAssertEqual(next[1].systemFields, saved.systemFields)
        XCTAssertEqual(try f.store.claimCloudKitChanges(contextKey: context, limit: 0).map(\.clientChangeID), [second.clientChangeID])
        XCTAssertEqual(try count("SELECT COUNT(*) FROM sync_outbox WHERE record_type='posting' AND state='pending'", f), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM sync_outbox WHERE record_id='\(blocked.recordID)' AND state IN ('pending','in_flight')", f), 2)
    }

    func testSingleBatchAndCASLookupDoNotDecodeUnrelatedKnownRecordsOrConflicts() throws {
        let f = try fixture()
        let first = record(), second = record(), blocked = record()
        try database(f) { db in try insert(first, state: "pending", db) }
        var saved = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context).first)
        saved.systemFields = Data([7, 0, 8])
        try f.store.acknowledgeCloudKitRecords([saved], submitted: [saved], contextKey: context)
        var successor = first; successor.clientChangeID = UUID().uuidString
        try database(f) { db in
            try insert(successor, state: "pending", db)
            try insert(blocked, state: "pending", db)
            try insert(second, state: "pending", db)
            try execute("INSERT INTO cloudkit_records(context_key,record_key,record_json) VALUES(?,?,'invalid-unrelated-json')", [context, second.key], db)
            try execute("INSERT INTO cloudkit_conflicts(id,context_key,record_key,local_record,remote_record,created_at) VALUES(?,?,?,'unreadable-local','unreadable-remote','synthetic')", [UUID().uuidString, context, blocked.key], db)
        }
        XCTAssertEqual(try f.store.knownCloudKitRecord(forKey: first.key, contextKey: context)?.systemFields, saved.systemFields)
        XCTAssertEqual(try f.store.cloudKitSystemFields(forKey: first.key, contextKey: context), saved.systemFields)
        let selected = try f.store.claimCloudKitChanges(contextKey: context, limit: 1)
        XCTAssertEqual(selected.map(\.clientChangeID), [successor.clientChangeID])
        XCTAssertEqual(selected.first?.systemFields, saved.systemFields)
        // Invalid CAS metadata still fails closed when its own key is selected,
        // and the transaction rolls back state changes for the entire batch.
        XCTAssertThrowsError(try f.store.claimCloudKitChanges(contextKey: context, limit: 2))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM sync_outbox WHERE client_change_id='\(second.clientChangeID!)' AND state='pending'", f), 1)
    }

    func testTwelveThousandFiveHundredRecordsDrainInStableBatchesWithFrozenReceiptClaims() throws {
        let f = try fixture()
        let bytes = Data("Synthetic shared receipt fixture".utf8)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let path = "Attachments/synthetic.txt"
        try FileManager.default.createDirectory(at: f.directory.appending(path: "Attachments"), withIntermediateDirectories: true)
        try bytes.write(to: f.directory.appending(path: path))
        var expectedIDs: [String] = []
        try database(f) { db in
            try execute("BEGIN IMMEDIATE", [], db)
            for index in 0..<12_500 {
                var local = record()
                if index >= 10_000 {
                    let asset = AttachmentAsset(originalFilename: "synthetic.txt", storedPath: path, mimeType: "text/plain", sizeBytes: Int64(bytes.count))
                    let payload = try JSONEncoder.appEncoder.encode(asset)
                    local.recordType = "attachment_asset"; local.recordID = asset.id.uuidString
                    local.payloadJSON = String(decoding: payload, as: UTF8.self)
                    local.contentHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                    let parent = UUID().uuidString
                    try execute("INSERT INTO attachment_assets(id,container_id,transaction_id,original_filename,stored_path,mime_type,size_bytes,sha256,payload_json) VALUES(?,?,?,?,?,?,?, ?,?)", [local.recordID, parent, UUID().uuidString, asset.originalFilename, path, asset.mimeType!, String(bytes.count), sha, local.payloadJSON!], db)
                    try execute("INSERT INTO sync_records(record_type,record_id,parent_record_id,content_hash,payload_json,updated_at) VALUES(?,?,?,?,?,'synthetic')", [local.recordType, local.recordID, parent, local.contentHash!, local.payloadJSON!], db)
                }
                try insert(local, state: "pending", db)
                expectedIDs.append(local.clientChangeID!)
            }
            try execute("COMMIT", [], db)
        }
        var acceptedIDs: [String] = []
        var receiptCount = 0
        var claimDuration: TimeInterval = 0, acknowledgementDuration: TimeInterval = 0
        for batchIndex in 0..<250 {
            let claimStart = Date()
            let claimed = try f.store.claimCloudKitChanges(contextKey: context, limit: 50)
            claimDuration += Date().timeIntervalSince(claimStart)
            XCTAssertEqual(claimed.count, 50)
            XCTAssertEqual(claimed.compactMap(\.clientChangeID), Array(expectedIDs[(batchIndex * 50)..<((batchIndex + 1) * 50)]))
            if batchIndex == 200 { XCTAssertEqual(try f.store.claimCloudKitChanges(contextKey: context, limit: 50), claimed) }
            for receipt in claimed where receipt.recordType == "attachment_asset" {
                receiptCount += 1
                XCTAssertEqual(receipt.assetSHA256, sha)
                XCTAssertNotNil(receipt.parentRecordID)
                XCTAssertEqual(receipt.assetFileURL, f.directory.appending(path: path))
            }
            let saved = claimed.map { value -> CloudKitSyncRecord in
                var copy = value; copy.systemFields = Data([1, 0, 255]); copy.assetFileURL = nil; return copy
            }
            let ackStart = Date()
            // Exercise both strict acknowledgements and another device's exact
            // same-value creation response against the large durable queue.
            if batchIndex.isMultiple(of: 2) {
                try f.store.acknowledgeCloudKitRecords(saved, submitted: claimed, contextKey: context)
            } else {
                let equivalent = saved.map { value -> CloudKitSyncRecord in var copy = value; copy.clientChangeID = UUID().uuidString; return copy }
                try f.store.acknowledgeCloudKitEquivalentRecords(equivalent, submitted: claimed, contextKey: context)
            }
            acknowledgementDuration += Date().timeIntervalSince(ackStart)
            acceptedIDs.append(contentsOf: claimed.compactMap(\.clientChangeID))
        }
        XCTAssertEqual(acceptedIDs, expectedIDs)
        XCTAssertEqual(receiptCount, 2_500)
        XCTAssertTrue(try f.store.claimCloudKitChanges(contextKey: context).isEmpty)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM sync_outbox WHERE state='accepted'", f), 12_500)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM cloudkit_mutation_receipts", f), 12_500)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM cloudkit_receipt_claims", f), 2_500)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM attachment_assets WHERE upload_state='uploaded'", f), 2_500)
        XCTAssertNil(try f.store.cloudKitChangeToken(contextKey: context), "Push acknowledgements must not advance the pull cursor")
        print("Synthetic CloudKit 10000 records + 2500 receipt metadata: claim=\(claimDuration)s acknowledgement=\(acknowledgementDuration)s; no network")
    }

    private struct Fixture { var store: SQLiteJournalStore; var directory: URL }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SQLiteCloudKitBatching-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteJournalStore(databaseURL: directory.appending(path: "synthetic.sqlite"))
        try store.replaceData(JournalData(), trackSyncChanges: false)
        _ = try store.bindCloudKitAccount(contextKey: context, accountID: "synthetic-account")
        return Fixture(store: store, directory: directory)
    }

    private func record() -> CloudKitSyncRecord {
        CloudKitSyncRecord(recordType: "transaction", recordID: UUID().uuidString, contentHash: String(repeating: "a", count: 64), payloadJSON: "{\"synthetic\":true}", clientChangeID: UUID().uuidString)
    }

    private func insert(_ record: CloudKitSyncRecord, state: String, _ db: OpaquePointer) throws {
        try execute("INSERT INTO sync_outbox(client_change_id,record_type,record_id,operation,content_hash,payload_json,created_at,state) VALUES(?,?,?,?,?,?,'synthetic',?)", [record.clientChangeID!, record.recordType, record.recordID, record.operation, record.contentHash!, record.payloadJSON!, state], db)
    }

    private func database<T>(_ f: Fixture, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_open(f.store.databaseURL.path, &pointer) == SQLITE_OK, let pointer else { throw SQLiteJournalStoreError.openFailed("Synthetic batch fixture") }
        defer { sqlite3_close(pointer) }
        return try body(pointer)
    }

    private func execute(_ sql: String, _ values: [String], _ db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SQLiteJournalStoreError.prepareFailed(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw SQLiteJournalStoreError.bindFailed("Synthetic batch fixture") }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteJournalStoreError.stepFailed(String(cString: sqlite3_errmsg(db))) }
    }

    private func count(_ sql: String, _ f: Fixture) throws -> Int {
        try database(f) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SQLiteJournalStoreError.prepareFailed("Synthetic count") }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteJournalStoreError.stepFailed("Synthetic count") }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
}
