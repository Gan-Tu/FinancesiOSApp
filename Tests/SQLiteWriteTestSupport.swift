import Foundation
import SQLite3
@testable import FinancesClone

/// Test-only SQLite triggers count actual inserted/updated/deleted rows on the
/// connection used by production persistence. No production hooks or timing
/// overhead are added. The audit participates in the same rollback boundary.
enum SQLiteWriteAudit {
    static func install(at url: URL) throws {
        try withDatabase(at: url) { database in
            var statement: OpaquePointer?
            let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'test_write_%'"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw failure(database) }
            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 0) { names.append(String(cString: name)) }
            }
            sqlite3_finalize(statement)
            try execute("CREATE TABLE IF NOT EXISTS test_write_audit(table_name TEXT NOT NULL, operation TEXT NOT NULL)", database)
            for name in names {
                let identifier = name.replacingOccurrences(of: "\"", with: "\"\"")
                let literal = name.replacingOccurrences(of: "'", with: "''")
                for operation in ["INSERT", "UPDATE", "DELETE"] {
                    try execute("""
                        CREATE TRIGGER IF NOT EXISTS "test_write_\(identifier)_\(operation)"
                        AFTER \(operation) ON "\(identifier)"
                        BEGIN INSERT INTO test_write_audit VALUES ('\(literal)', '\(operation)'); END
                        """, database)
                }
            }
        }
    }

    static func reset(at url: URL) throws {
        try withDatabase(at: url) { try execute("DELETE FROM test_write_audit", $0) }
    }

    static func counts(at url: URL) throws -> [String: Int] {
        try withDatabase(at: url) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT table_name, COUNT(*) FROM test_write_audit GROUP BY table_name", -1, &statement, nil) == SQLITE_OK else { throw failure(database) }
            defer { sqlite3_finalize(statement) }
            var counts: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = sqlite3_column_text(statement, 0) else { throw failure(database) }
                counts[String(cString: name)] = Int(sqlite3_column_int64(statement, 1))
            }
            return counts
        }
    }

    static func execute(_ sql: String, at url: URL) throws {
        try withDatabase(at: url) { try execute(sql, $0) }
    }

    private static func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            throw SQLiteJournalStoreError.openFailed("Write-audit fixture")
        }
        defer { sqlite3_close(database) }
        // Fixture schema/audit changes share the same database with normal
        // queued status reads. Match the production connection's contention
        // policy instead of failing immediately with the default zero timeout.
        guard sqlite3_busy_timeout(database, 8_000) == SQLITE_OK else { throw failure(database) }
        return try body(database)
    }

    private static func execute(_ sql: String, _ database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure(database) }
    }

    private static func failure(_ database: OpaquePointer) -> Error {
        SQLiteJournalStoreError.stepFailed(String(cString: sqlite3_errmsg(database)))
    }
}
