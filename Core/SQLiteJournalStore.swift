import CryptoKit
import Foundation
import SQLite3

enum SQLiteJournalStoreError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case missingPayload(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Could not open local SQLite journal: \(message)"
        case .prepareFailed(let message): "Could not prepare local SQLite query: \(message)"
        case .stepFailed(let message): "Could not run local SQLite query: \(message)"
        case .bindFailed(let message): "Could not bind local SQLite value: \(message)"
        case .missingPayload(let record): "Local SQLite journal is missing payload for \(record)."
        }
    }
}

struct SQLiteJournalRecordCounts: Equatable {
    var ledgers: Int
    var commodities: Int
    var accounts: Int
    var transactions: Int
    var postings: Int
    var sources: Int
    var transactionTemplates: Int
    var postingTemplates: Int
    var attachmentContainers: Int
    var attachmentAssets: Int
    var recurrenceRules: Int
    var recurrenceExceptions: Int
    var outboxRows: Int
}

struct SQLiteSyncOutboxChange: Equatable, Encodable {
    var clientChangeID: String
    var recordType: String
    var recordID: String
    var operation: String
    var baseRevision: Int64
    var contentHash: String?
    var payloadJSON: String?

    enum CodingKeys: String, CodingKey {
        case clientChangeID = "client_change_id"
        case recordType = "record_type"
        case recordID = "record_id"
        case operation
        case baseRevision = "base_revision"
        case contentHash = "content_hash"
        case payloadJSON = "payload_json"
    }
}

struct SQLiteAcceptedSyncChange: Equatable {
    var clientChangeID: String
    var recordType: String
    var recordID: String
    var serverRevision: Int64
}

struct SQLitePendingSyncRecordVersion: Equatable {
    var operation: String
    var contentHash: String?
}

struct SQLitePendingSyncRecord: Equatable {
    var operation: String
    var contentHash: String?
    var baseRevision: Int64 = 0
    var inFlightVersions: [SQLitePendingSyncRecordVersion] = []

    /// A pulled echo of an older upload acknowledges that upload without
    /// replacing edits made while its request was in flight.
    func preservesNewerLocalValue(whenApplying change: SQLiteRemoteSyncChange) -> Bool {
        guard operation != change.operation || contentHash != change.contentHash else { return false }
        return change.revision <= baseRevision || inFlightVersions.contains {
            $0.operation == change.operation && $0.contentHash == change.contentHash
        }
    }
}

struct SQLiteRemoteSyncChange: Equatable, Decodable {
    var revision: Int64
    var recordType: String
    var recordID: String
    var parentRecordID: String?
    var operation: String
    var contentHash: String?
    var payloadJSON: String?
    var deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case revision
        case recordType = "record_type"
        case recordID = "record_id"
        case parentRecordID = "parent_record_id"
        case operation
        case contentHash = "content_hash"
        case payloadJSON = "payload_json"
        case deletedAt = "deleted_at"
    }
}

struct SQLitePendingAttachmentUpload: Equatable {
    var assetID: UUID
    var storedPath: String
    var originalFilename: String
    var mimeType: String?
    var sha256: String
}

struct SQLiteSyncedJournalMetadata: Codable, Hashable {
    static let recordID = UUID(uuidString: "8E5D8F9E-19D6-4CE4-94C8-1B1B57E84AF6")!

    var dateFormat: AppDateFormat
    var appearance: AppAppearance
    var preservesImportedRecurringMaterializations: Bool

    init(data: JournalData) {
        dateFormat = data.dateFormat
        appearance = data.appearance
        preservesImportedRecurringMaterializations = data.preservesImportedRecurringMaterializations
    }

    func apply(to data: inout JournalData) {
        data.dateFormat = dateFormat
        data.appearance = appearance
        data.preservesImportedRecurringMaterializations = preservesImportedRecurringMaterializations
    }
}

enum AppJSONDateCoding {
    private static let fractionalFormatterKey = "FinancesClone.AppJSONDateCoding.fractionalFormatter"
    private static let wholeSecondFormatterKey = "FinancesClone.AppJSONDateCoding.wholeSecondFormatter"

    static func string(from date: Date) -> String {
        fractionalFormatter().string(from: date)
    }

    static func date(from value: String) -> Date? {
        fastDate(from: value) ?? fractionalFormatter().date(from: value) ?? wholeSecondFormatter().date(from: value)
    }

    static func fractionalFormatter() -> ISO8601DateFormatter {
        formatter(
            forKey: fractionalFormatterKey,
            options: [.withInternetDateTime, .withFractionalSeconds]
        )
    }

    private static func wholeSecondFormatter() -> ISO8601DateFormatter {
        formatter(forKey: wholeSecondFormatterKey, options: [.withInternetDateTime])
    }

    private static func formatter(
        forKey key: String,
        options: ISO8601DateFormatter.Options
    ) -> ISO8601DateFormatter {
        let dictionary = Thread.current.threadDictionary
        if let formatter = dictionary[key] as? ISO8601DateFormatter {
            return formatter
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        dictionary[key] = formatter
        return formatter
    }

    private static func fastDate(from value: String) -> Date? {
        var value = value
        return value.withUTF8 { bytes in
            guard bytes.count >= 20,
                  bytes[4] == asciiHyphen,
                  bytes[7] == asciiHyphen,
                  bytes[10] == asciiUpperT || bytes[10] == asciiLowerT,
                  bytes[13] == asciiColon,
                  bytes[16] == asciiColon,
                  let year = int(bytes, 0, 4),
                  let month = int(bytes, 5, 2),
                  let day = int(bytes, 8, 2),
                  let hour = int(bytes, 11, 2),
                  let minute = int(bytes, 14, 2),
                  let second = int(bytes, 17, 2),
                  (1...12).contains(month),
                  (1...daysInMonth(year: year, month: month)).contains(day),
                  (0...23).contains(hour),
                  (0...59).contains(minute),
                  (0...59).contains(second) else {
                return nil
            }

            var index = 19
            var fractionalSeconds = 0.0
            if index < bytes.count, bytes[index] == asciiPeriod {
                index += 1
                var scale = 0.1
                var digitCount = 0
                while index < bytes.count, let digit = digit(bytes[index]) {
                    if digitCount < 9 {
                        fractionalSeconds += Double(digit) * scale
                        scale *= 0.1
                    }
                    digitCount += 1
                    index += 1
                }
                guard digitCount > 0 else { return nil }
            }

            let offsetSeconds: Int
            if index < bytes.count, bytes[index] == asciiUpperZ || bytes[index] == asciiLowerZ {
                offsetSeconds = 0
                index += 1
            } else if index + 5 < bytes.count,
                      bytes[index] == asciiPlus || bytes[index] == asciiHyphen,
                      bytes[index + 3] == asciiColon,
                      let offsetHour = int(bytes, index + 1, 2),
                      let offsetMinute = int(bytes, index + 4, 2),
                      (0...23).contains(offsetHour),
                      (0...59).contains(offsetMinute) {
                let sign = bytes[index] == asciiPlus ? 1 : -1
                offsetSeconds = sign * ((offsetHour * 3600) + (offsetMinute * 60))
                index += 6
            } else {
                return nil
            }
            guard index == bytes.count else { return nil }

            let days = daysFromCivil(year: year, month: month, day: day)
            let utcSeconds = (days * 86_400) + (hour * 3_600) + (minute * 60) + second - offsetSeconds
            return Date(timeIntervalSince1970: Double(utcSeconds) + fractionalSeconds)
        }
    }

    private static let asciiHyphen = UInt8(ascii: "-")
    private static let asciiUpperT = UInt8(ascii: "T")
    private static let asciiLowerT = UInt8(ascii: "t")
    private static let asciiColon = UInt8(ascii: ":")
    private static let asciiPeriod = UInt8(ascii: ".")
    private static let asciiUpperZ = UInt8(ascii: "Z")
    private static let asciiLowerZ = UInt8(ascii: "z")
    private static let asciiPlus = UInt8(ascii: "+")

    private static func digit(_ byte: UInt8) -> Int? {
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
        return Int(byte - UInt8(ascii: "0"))
    }

    private static func int(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ count: Int) -> Int? {
        guard start >= 0, count > 0, start + count <= bytes.count else { return nil }
        var value = 0
        for index in start..<(start + count) {
            guard let digit = digit(bytes[index]) else { return nil }
            value = (value * 10) + digit
        }
        return value
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            return 31
        case 4, 6, 9, 11:
            return 30
        case 2:
            return isLeapYear(year) ? 29 : 28
        default:
            return 0
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - (era * 400)
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = ((153 * adjustedMonth) + 2) / 5 + day - 1
        let dayOfEra = (yearOfEra * 365) + (yearOfEra / 4) - (yearOfEra / 100) + dayOfYear
        return (era * 146_097) + dayOfEra - 719_468
    }
}

/// SQLite runtime store for the Finances journal.
///
/// The first migration keeps `LedgerStore`'s published `JournalData` facade
/// intact, but persists each logical model as a SQLite row. This gives the app a
/// durable, indexed local database and gives Cloudflare sync a per-record base
/// without forcing a risky UI-wide rewrite in the same step.
/// Record-level difference between two journal snapshots.
///
/// Drives incremental persistence: unchanged families compare by array storage
/// identity in O(1), so computing this per save is a few milliseconds even on a
/// ~10k-transaction journal, versus rewriting and re-hashing every record.
struct JournalDataDiff {
    var ledgersChanged: [Ledger] = []
    var ledgerIDsDeleted: [UUID] = []
    var commoditiesChanged: [Commodity] = []
    var commodityIDsDeleted: [UUID] = []
    var accountsChanged: [Account] = []
    var accountIDsDeleted: [UUID] = []
    var sourcesChanged: [TransactionSource] = []
    var sourceIDsDeleted: [UUID] = []
    var transactionsChanged: [LedgerTransaction] = []
    var transactionIDsDeleted: [UUID] = []
    /// A transaction's canonical payload changes for note/number/payee/cleared
    /// edits, but its normalized children usually do not. Preserve those rows
    /// (and their uploaded receipt state) instead of deleting and rebuilding.
    var postingsChangedByTransaction: [UUID: [Posting]] = [:]
    var postingIDsDeletedByTransaction: [UUID: [UUID]] = [:]
    var transactionAttachmentsUnchanged: Set<UUID> = []
    var transactionRecurrenceUnchanged: Set<UUID> = []
    var templatePostingsUnchanged: Set<UUID> = []
    var templatesChanged: [TransactionTemplate] = []
    var templateIDsDeleted: [UUID] = []
    /// Assets present in the previous snapshot but absent from the new one, so
    /// cloud sync can tombstone them individually.
    var attachmentAssetIDsDeleted: [UUID] = []
    /// Recurrence rules no transaction references anymore. The full-rewrite
    /// path purges the whole table; the incremental path must delete these
    /// explicitly or orphan rows accumulate and reload on every launch.
    var recurrenceRuleIDsDeleted: [UUID] = []
    var metadataChanged = false
    var syncedMetadataChanged = false

    var isEmpty: Bool {
        !metadataChanged
            && ledgersChanged.isEmpty && ledgerIDsDeleted.isEmpty
            && commoditiesChanged.isEmpty && commodityIDsDeleted.isEmpty
            && accountsChanged.isEmpty && accountIDsDeleted.isEmpty
            && sourcesChanged.isEmpty && sourceIDsDeleted.isEmpty
            && transactionsChanged.isEmpty && transactionIDsDeleted.isEmpty
            && templatesChanged.isEmpty && templateIDsDeleted.isEmpty
    }

    var touchedRecordCount: Int {
        ledgersChanged.count + ledgerIDsDeleted.count
            + commoditiesChanged.count + commodityIDsDeleted.count
            + accountsChanged.count + accountIDsDeleted.count
            + sourcesChanged.count + sourceIDsDeleted.count
            + transactionsChanged.count + transactionIDsDeleted.count
            + templatesChanged.count + templateIDsDeleted.count
    }

    /// Recurring edits can touch most rows while leaving every parent entity
    /// intact. Keep these child-family edits incremental so unrelated journals,
    /// accounts and receipts are not rewritten just because the diff is large.
    /// Parent changes still use the existing replacement-size heuristic.
    var changesOnlyTransactionsOrTemplates: Bool {
        ledgersChanged.isEmpty && ledgerIDsDeleted.isEmpty
            && commoditiesChanged.isEmpty && commodityIDsDeleted.isEmpty
            && accountsChanged.isEmpty && accountIDsDeleted.isEmpty
            && sourcesChanged.isEmpty && sourceIDsDeleted.isEmpty
    }

    static func between(_ old: JournalData, _ new: JournalData) -> JournalDataDiff {
        var diff = JournalDataDiff()
        diffFamily(old.ledgers, new.ledgers, changed: &diff.ledgersChanged, deleted: &diff.ledgerIDsDeleted)
        diffFamily(old.commodities, new.commodities, changed: &diff.commoditiesChanged, deleted: &diff.commodityIDsDeleted)
        diffFamily(old.accounts, new.accounts, changed: &diff.accountsChanged, deleted: &diff.accountIDsDeleted)
        diffFamily(old.sources, new.sources, changed: &diff.sourcesChanged, deleted: &diff.sourceIDsDeleted)
        diffFamily(
            old.transactionTemplates,
            new.transactionTemplates,
            changed: &diff.templatesChanged,
            deleted: &diff.templateIDsDeleted
        )

        if !diff.templatesChanged.isEmpty {
            var oldTemplates: [UUID: TransactionTemplate] = [:]
            for template in old.transactionTemplates { oldTemplates[template.id] = template }
            for template in diff.templatesChanged where oldTemplates[template.id]?.postings == template.postings {
                diff.templatePostingsUnchanged.insert(template.id)
            }
        }

        if old.transactions != new.transactions {
            var oldByID = [UUID: LedgerTransaction](minimumCapacity: old.transactions.count)
            for transaction in old.transactions {
                oldByID[transaction.id] = transaction
            }
            var removedAssetIDs: [UUID] = []
            for transaction in new.transactions {
                guard let previous = oldByID[transaction.id] else {
                    diff.transactionsChanged.append(transaction)
                    diff.postingsChangedByTransaction[transaction.id] = transaction.postings
                    continue
                }
                if previous != transaction {
                    diff.transactionsChanged.append(transaction)
                    if previous.postings != transaction.postings {
                        let previousPostings = Dictionary(previous.postings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        diff.postingsChangedByTransaction[transaction.id] = transaction.postings.filter { previousPostings[$0.id] != $0 }
                        let currentIDs = Set(transaction.postings.map(\.id))
                        diff.postingIDsDeletedByTransaction[transaction.id] = previous.postings.filter { !currentIDs.contains($0.id) }.map(\.id)
                    }
                    if previous.attachment == transaction.attachment {
                        diff.transactionAttachmentsUnchanged.insert(transaction.id)
                    }
                    if previous.recurrenceRule == transaction.recurrenceRule {
                        diff.transactionRecurrenceUnchanged.insert(transaction.id)
                    }
                    let newAssetIDs = Set((transaction.attachment?.assets ?? []).map(\.id))
                    for asset in previous.attachment?.assets ?? [] where !newAssetIDs.contains(asset.id) {
                        removedAssetIDs.append(asset.id)
                    }
                }
            }
            let newIDs = Set(new.transactions.map(\.id))
            for transaction in old.transactions where !newIDs.contains(transaction.id) {
                diff.transactionIDsDeleted.append(transaction.id)
                removedAssetIDs.append(contentsOf: (transaction.attachment?.assets ?? []).map(\.id))
            }
            if !removedAssetIDs.isEmpty {
                var liveAssetIDs = Set<UUID>()
                for transaction in new.transactions {
                    for asset in transaction.attachment?.assets ?? [] {
                        liveAssetIDs.insert(asset.id)
                    }
                }
                diff.attachmentAssetIDsDeleted = removedAssetIDs.filter { !liveAssetIDs.contains($0) }
            }

            let oldRuleIDs = Set(old.transactions.compactMap { $0.recurrenceRule?.id })
            if !oldRuleIDs.isEmpty {
                let newRuleIDs = Set(new.transactions.compactMap { $0.recurrenceRule?.id })
                diff.recurrenceRuleIDsDeleted = Array(oldRuleIDs.subtracting(newRuleIDs))
            }
        }

        diff.syncedMetadataChanged = SQLiteSyncedJournalMetadata(data: old) != SQLiteSyncedJournalMetadata(data: new)
        diff.metadataChanged = old.selectedLedgerID != new.selectedLedgerID
            || old.lastSyncedAt != new.lastSyncedAt
            || old.syncEnabled != new.syncEnabled
            || old.dateFormat != new.dateFormat
            || old.appearance != new.appearance
            || old.security != new.security
            || old.preservesImportedRecurringMaterializations != new.preservesImportedRecurringMaterializations
        return diff
    }

    private static func diffFamily<Element: Identifiable & Equatable>(
        _ old: [Element],
        _ new: [Element],
        changed: inout [Element],
        deleted: inout [UUID]
    ) where Element.ID == UUID {
        guard old != new else { return }
        var oldByID = [UUID: Element](minimumCapacity: old.count)
        for element in old {
            oldByID[element.id] = element
        }
        for element in new where oldByID[element.id] != element {
            changed.append(element)
        }
        let newIDs = Set(new.map(\.id))
        for element in old where !newIDs.contains(element.id) {
            deleted.append(element.id)
        }
    }
}

struct CloudKitSyncConflict: Identifiable, Equatable, Sendable {
    var id: String
    var local: CloudKitSyncRecord
    var remote: CloudKitSyncRecord
}

final class SQLiteJournalStore: @unchecked Sendable {
    static let currentSchemaVersion = 2
    private static let accessLock = NSRecursiveLock()
    /// Gives concurrent app/sync writes time to finish instead of surfacing a
    /// transient `database is locked` error to the user.
    private static let busyTimeoutMilliseconds: Int32 = 8_000
    private static let redundantSyncRecordTypes = [
        "posting",
        "recurrence_rule",
        "attachment_container",
        "posting_template"
    ]

    let databaseURL: URL

    private struct JournalMetadata: Codable {
        var selectedLedgerID: UUID?
        var lastSyncedAt: Date?
        var syncEnabled: Bool
        var dateFormat: AppDateFormat
        var appearance: AppAppearance
        var security: SecuritySettings
        var preservesImportedRecurringMaterializations: Bool

        init(data: JournalData) {
            selectedLedgerID = data.selectedLedgerID
            lastSyncedAt = data.lastSyncedAt
            syncEnabled = data.syncEnabled
            dateFormat = data.dateFormat
            appearance = data.appearance
            security = data.security
            preservesImportedRecurringMaterializations = data.preservesImportedRecurringMaterializations
        }

        func apply(to data: inout JournalData) {
            data.selectedLedgerID = selectedLedgerID
            data.lastSyncedAt = lastSyncedAt
            data.syncEnabled = syncEnabled
            data.dateFormat = dateFormat
            data.appearance = appearance
            data.security = security
            data.preservesImportedRecurringMaterializations = preservesImportedRecurringMaterializations
        }
    }

    private struct SyncEnvelope {
        let type: String
        let id: UUID
        let parentID: UUID?
        let payload: Data
        let hash: String
    }

    private struct AttachmentUploadState {
        var sha256: String?
        var storedPath: String
        var sizeBytes: Int64
        var r2Key: String?
        var uploadState: String
    }

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    var exists: Bool {
        return FileManager.default.fileExists(atPath: databaseURL.path)
    }

    func loadData(maximumReadBufferBytes: Int = 32 * 1024 * 1024) throws -> JournalData? {
        guard exists else { return nil }
        var mark = StartupTiming.now()
        // Apple's SQLite cannot bootstrap missing WAL/SHM sidecars through a
        // read-only connection. Open this existing clone database without
        // CREATE, run no DDL/migrations, and read one transaction snapshot.
        let database = try open(createIfMissing: false)
        defer { sqlite3_close(database) }
        let version = try rows("PRAGMA user_version", database: database) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
        guard version <= Self.currentSchemaVersion else {
            throw SQLiteJournalStoreError.openFailed("This journal was created by a newer app version.")
        }
        try execute("BEGIN DEFERRED TRANSACTION", database)
        defer { try? execute("ROLLBACK", database) }
        guard try metadataExists(in: database) else {
            throw SQLiteJournalStoreError.missingPayload("app_metadata")
        }
        StartupTiming.log("load-store.open-schema", from: &mark)

        let ledgers: [Ledger] = try readPayloads("ledgers", database: database)
            .sorted { $0.listIndex < $1.listIndex }
        let commodities: [Commodity] = try readPayloads("commodities", database: database)
            .sorted { lhs, rhs in
                if lhs.ledgerID == rhs.ledgerID { return lhs.symbol < rhs.symbol }
                return lhs.ledgerID.uuidString < rhs.ledgerID.uuidString
            }
        let accounts: [Account] = try readPayloads("accounts", database: database)
            .sorted { lhs, rhs in
                if lhs.ledgerID == rhs.ledgerID { return lhs.listIndex < rhs.listIndex }
                return lhs.ledgerID.uuidString < rhs.ledgerID.uuidString
            }
        StartupTiming.log("load-store.ledgers-commodities-accounts", from: &mark)
        let transactions = try readTransactions(database: database, maximumBufferBytes: maximumReadBufferBytes)
        StartupTiming.log("load-store.transactions", from: &mark)
        let sortedTransactions = Self.canonicallySorted(transactions)
        StartupTiming.log("load-store.sort-transactions", from: &mark)
        var data = JournalData(
            ledgers: ledgers,
            commodities: commodities,
            accounts: accounts,
            transactions: sortedTransactions,
            sources: try readPayloads("sources", database: database)
                .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) },
            transactionTemplates: try readPayloads("transaction_templates", database: database)
                .sorted { $0.listIndex < $1.listIndex }
        )
        if let metadata = try readMetadata(database) {
            metadata.apply(to: &data)
        }
        StartupTiming.log("load-store.sources-templates-metadata", from: &mark)
        return data
    }

    /// Sorts rows by the canonical (date ASC, id ASC) order through an index
    /// permutation. Transactions are large structs, so sorting indices and
    /// gathering once is much cheaper than moving whole rows during the sort.
    private static func canonicallySorted(_ transactions: [LedgerTransaction]) -> [LedgerTransaction] {
        let order = transactions.indices.sorted { lhsIndex, rhsIndex in
            let lhsDate = transactions[lhsIndex].date
            let rhsDate = transactions[rhsIndex].date
            if lhsDate == rhsDate {
                return transactions[lhsIndex].id.canonicallyPrecedes(transactions[rhsIndex].id)
            }
            return lhsDate < rhsDate
        }
        return order.map { transactions[$0] }
    }

    func replaceData(_ data: JournalData, trackSyncChanges: Bool = true, resetCloudKitState: Bool = false) throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            try pruneRedundantSyncRows(database)
            let previousSyncRows = trackSyncChanges ? try readSyncHashes(database) : [:]
            let envelopes = try syncEnvelopes(for: data)
            try replaceAppRows(data, envelopes: envelopes, database: database)
            if trackSyncChanges {
                try updateSyncRows(envelopes: envelopes, previousRows: previousSyncRows, database: database)
            }
            if resetCloudKitState {
                let bindings = try cloudKitBindings(database)
                guard bindings.count <= 1 else { throw cloudKitError("Multiple CloudKit bindings require recovery.") }
                if let contextKey = bindings.first?.0 {
                    try resetCloudKitSyncState(contextKey: contextKey, database: database)
                }
            }
            try execute("COMMIT", database)
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    private static let initialSyncSnapshotPreparedKey = "initial_sync_snapshot_prepared"

    func hasPreparedInitialSyncSnapshot() throws -> Bool {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        return try hasPreparedInitialSyncSnapshot(database: database)
    }

    private func hasPreparedInitialSyncSnapshot(database: OpaquePointer) throws -> Bool {
        let prepared = try rows(
            """
            SELECT EXISTS(SELECT 1 FROM sync_state WHERE key = 'initial_sync_snapshot_prepared' AND value = '1')
                OR EXISTS(SELECT 1 FROM sync_outbox WHERE state = 'in_flight')
            """,
            database: database,
            map: { sqlite3_column_int64($0, 0) }
        ).first ?? 0
        return prepared != 0
    }

    /// Preparing a first upload is durable independently of its network pass.
    /// A cancelled request must resume the existing IDs, not regenerate a full
    /// snapshot. Legacy in-flight claims also prove an upload was prepared.
    @discardableResult
    func prepareInitialSyncSnapshot(_ data: JournalData) throws -> Bool {
        try prepareSyncSnapshot(data, onlyIfNeeded: true)
    }

    /// Explicit forced enqueue retains its existing semantics, and also records
    /// that a future initial-sync retry must preserve the resulting outbox.
    func enqueueFullSyncSnapshot(_ data: JournalData) throws {
        _ = try prepareSyncSnapshot(data, onlyIfNeeded: false)
    }

    private func prepareSyncSnapshot(_ data: JournalData, onlyIfNeeded: Bool) throws -> Bool {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            let alreadyPrepared = try hasPreparedInitialSyncSnapshot(database: database)
            let wroteSnapshot = !onlyIfNeeded || !alreadyPrepared
            if wroteSnapshot {
                let envelopes = try syncEnvelopes(for: data)
                try replaceAppRows(data, envelopes: envelopes, database: database)
                try updateSyncRows(envelopes: envelopes, previousRows: [:], database: database)
            }
            try upsertMetadata(Self.initialSyncSnapshotPreparedKey, value: "1", database: database, table: "sync_state")
            try execute("COMMIT", database)
            return wroteSnapshot
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    /// Persists a journal snapshot, writing only the records that changed since
    /// `previous` instead of rewriting every table.
    ///
    /// `replaceData` deletes and re-inserts all rows and re-encodes every record
    /// for sync hashing, which costs seconds on a ~10k-transaction journal. The
    /// caller keeps the last snapshot it successfully persisted; diffing two
    /// value snapshots is cheap (unchanged families compare by array storage
    /// identity), so a routine edit touches a handful of rows. Falls back to the
    /// full rewrite on first save or without a baseline, and for large parent
    /// entity changes. Imports/restores retain their explicit replacement path.
    func persist(_ data: JournalData, previous: JournalData?, trackSyncChanges: Bool = true) throws {
        guard let previous else {
            try replaceData(data, trackSyncChanges: trackSyncChanges)
            return
        }
        let diff = JournalDataDiff.between(previous, data)
        guard !diff.isEmpty else { return }
        let totalRecords = data.ledgers.count + data.commodities.count + data.accounts.count
            + data.sources.count + data.transactions.count + data.transactionTemplates.count
        if diff.touchedRecordCount > max(64, totalRecords / 4), !diff.changesOnlyTransactionsOrTemplates {
            try replaceData(data, trackSyncChanges: trackSyncChanges)
            return
        }
        try applyDiff(diff, data: data, trackSyncChanges: trackSyncChanges)
    }

    private func applyDiff(_ diff: JournalDataDiff, data: JournalData, trackSyncChanges: Bool) throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            try applyDiffContents(diff, data: data, trackSyncChanges: trackSyncChanges, database: database)
            try execute("COMMIT", database)
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    private func applyDiffContents(
        _ diff: JournalDataDiff,
        data: JournalData,
        trackSyncChanges: Bool,
        database: OpaquePointer
    ) throws {
        let dateFormatter = Self.makeISOFormatter()
        let now = dateFormatter.string(from: Date())
        // Scope the sync-hash and upload-state reads to the records this
        // diff touches; the full-table variants scan ~15k rows per save on
        // a real journal, all but a handful discarded.
        let syncKeys = trackSyncChanges ? diffSyncKeys(diff) : []
        let previousSyncRows = trackSyncChanges
            ? try readSyncHashes(forKeys: syncKeys, database: database)
            : [:]
        let changedAssetIDs = diff.transactionsChanged.filter {
            !diff.transactionAttachmentsUnchanged.contains($0.id)
        }.flatMap { transaction in
            (transaction.attachment?.assets ?? []).map(\.id)
        }
        let attachmentUploadStates = changedAssetIDs.isEmpty
            ? [:]
            : try readAttachmentUploadStates(forAssetIDs: changedAssetIDs, database: database)

        for transactionID in diff.transactionIDsDeleted {
            try deleteTransactionRows(transactionID: transactionID, database: database)
        }
        for templateID in diff.templateIDsDeleted {
            try executePrepared("DELETE FROM posting_templates WHERE template_id = ?", database) { statement in
                try bind(templateID.uuidString, to: statement, at: 1, database)
            }
            try executePrepared("DELETE FROM transaction_templates WHERE id = ?", database) { statement in
                try bind(templateID.uuidString, to: statement, at: 1, database)
            }
        }
        for ruleID in diff.recurrenceRuleIDsDeleted {
            try executePrepared("DELETE FROM recurrence_ends WHERE rule_id = ?", database) { statement in
                try bind(ruleID.uuidString, to: statement, at: 1, database)
            }
            try executePrepared("DELETE FROM recurrence_rules WHERE id = ?", database) { statement in
                try bind(ruleID.uuidString, to: statement, at: 1, database)
            }
        }
        for (table, ids) in [
            ("ledgers", diff.ledgerIDsDeleted),
            ("commodities", diff.commodityIDsDeleted),
            ("accounts", diff.accountIDsDeleted),
            ("sources", diff.sourceIDsDeleted)
        ] {
            for id in ids {
                try executePrepared("DELETE FROM \(table) WHERE id = ?", database) { statement in
                    try bind(id.uuidString, to: statement, at: 1, database)
                }
            }
        }

        for ledger in diff.ledgersChanged {
            try executePrepared(
                """
                INSERT INTO ledgers(id, list_index, name, payload_json)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    list_index = excluded.list_index,
                    name = excluded.name,
                    payload_json = excluded.payload_json
                """,
                database
            ) { statement in
                try bind(ledger.id.uuidString, to: statement, at: 1, database)
                try bind(Int64(ledger.listIndex), to: statement, at: 2, database)
                try bind(ledger.name, to: statement, at: 3, database)
                try bind(encodedString(ledger), to: statement, at: 4, database)
            }
        }
        for commodity in diff.commoditiesChanged {
            try executePrepared(
                """
                INSERT INTO commodities(id, ledger_id, symbol, name, payload_json)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    ledger_id = excluded.ledger_id,
                    symbol = excluded.symbol,
                    name = excluded.name,
                    payload_json = excluded.payload_json
                """,
                database
            ) { statement in
                try bind(commodity.id.uuidString, to: statement, at: 1, database)
                try bind(commodity.ledgerID.uuidString, to: statement, at: 2, database)
                try bind(commodity.symbol, to: statement, at: 3, database)
                try bind(commodity.name, to: statement, at: 4, database)
                try bind(encodedString(commodity), to: statement, at: 5, database)
            }
        }
        for account in diff.accountsChanged {
            try executePrepared(
                """
                INSERT INTO accounts(id, ledger_id, parent_id, commodity_id, kind, list_index, name, note, payload_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    ledger_id = excluded.ledger_id,
                    parent_id = excluded.parent_id,
                    commodity_id = excluded.commodity_id,
                    kind = excluded.kind,
                    list_index = excluded.list_index,
                    name = excluded.name,
                    note = excluded.note,
                    payload_json = excluded.payload_json
                """,
                database
            ) { statement in
                try bind(account.id.uuidString, to: statement, at: 1, database)
                try bind(account.ledgerID.uuidString, to: statement, at: 2, database)
                try bind(account.parentID?.uuidString, to: statement, at: 3, database)
                try bind(account.commodityID?.uuidString, to: statement, at: 4, database)
                try bind(Int64(account.kind.rawValue), to: statement, at: 5, database)
                try bind(Int64(account.listIndex), to: statement, at: 6, database)
                try bind(account.name, to: statement, at: 7, database)
                try bind(account.note, to: statement, at: 8, database)
                try bind(encodedString(account), to: statement, at: 9, database)
            }
        }
        for source in diff.sourcesChanged {
            try executePrepared(
                """
                INSERT INTO sources(id, ledger_id, type, date, external_id, payload_json)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    ledger_id = excluded.ledger_id,
                    type = excluded.type,
                    date = excluded.date,
                    external_id = excluded.external_id,
                    payload_json = excluded.payload_json
                """,
                database
            ) { statement in
                try bind(source.id.uuidString, to: statement, at: 1, database)
                try bind(source.ledgerID.uuidString, to: statement, at: 2, database)
                try bind(Int64(source.type), to: statement, at: 3, database)
                try bind(isoString(source.date, formatter: dateFormatter), to: statement, at: 4, database)
                try bind(source.externalID, to: statement, at: 5, database)
                try bind(encodedString(source), to: statement, at: 6, database)
            }
        }

        var writtenRecurrenceRules: [UUID: RecurrenceRule] = [:]
        // Statements are prepared once and reused for both small edits and
        // broad transaction-only changes, including long recurring series.
        try withPreparedStatement("DELETE FROM postings WHERE id = ? AND transaction_id = ?", database) { deletePosting in
        try withPreparedStatement("DELETE FROM attachment_assets WHERE transaction_id = ?", database) { deleteAssets in
        try withPreparedStatement("DELETE FROM attachment_containers WHERE transaction_id = ?", database) { deleteContainers in
        try withPreparedStatement(
            """
            INSERT INTO transactions(
                id, ledger_id, source_id, date, payee, note, number, cleared,
                recurrence_rule_id, attachment_container_id, external_transaction_id, payload_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                ledger_id = excluded.ledger_id,
                source_id = excluded.source_id,
                date = excluded.date,
                payee = excluded.payee,
                note = excluded.note,
                number = excluded.number,
                cleared = excluded.cleared,
                recurrence_rule_id = excluded.recurrence_rule_id,
                attachment_container_id = excluded.attachment_container_id,
                external_transaction_id = excluded.external_transaction_id,
                payload_json = excluded.payload_json
            """,
            database
        ) { upsertTransaction in
        try withPreparedStatement(
            """
            INSERT INTO postings(id, transaction_id, account_id, commodity_id, amount, list_index, payload_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                account_id = excluded.account_id,
                commodity_id = excluded.commodity_id,
                amount = excluded.amount,
                list_index = excluded.list_index,
                payload_json = excluded.payload_json
            WHERE postings.transaction_id = excluded.transaction_id
            """,
            database
        ) { insertPosting in
            for transaction in diff.transactionsChanged {
                guard Set(transaction.postings.map(\.id)).count == transaction.postings.count else {
                    throw SQLiteJournalStoreError.stepFailed("A transaction contains duplicate posting identifiers.")
                }
                for postingID in diff.postingIDsDeletedByTransaction[transaction.id] ?? [] {
                    try executePreparedStatement(deletePosting, database) { statement in
                        try bind(postingID.uuidString, to: statement, at: 1, database)
                        try bind(transaction.id.uuidString, to: statement, at: 2, database)
                    }
                }
                if !diff.transactionAttachmentsUnchanged.contains(transaction.id) {
                    for statement in [deleteAssets, deleteContainers] {
                        try executePreparedStatement(statement, database) { statement in
                            try bind(transaction.id.uuidString, to: statement, at: 1, database)
                        }
                    }
                }
                try executePreparedStatement(upsertTransaction, database) { statement in
                    try bind(transaction.id.uuidString, to: statement, at: 1, database)
                    try bind(transaction.ledgerID.uuidString, to: statement, at: 2, database)
                    try bind(transaction.sourceID?.uuidString, to: statement, at: 3, database)
                    try bind(isoString(transaction.date, formatter: dateFormatter), to: statement, at: 4, database)
                    try bind(transaction.payee, to: statement, at: 5, database)
                    try bind(transaction.note, to: statement, at: 6, database)
                    try bind(transaction.number, to: statement, at: 7, database)
                    try bind(transaction.cleared ? Int64(1) : Int64(0), to: statement, at: 8, database)
                    try bind(transaction.recurrenceRule?.id.uuidString, to: statement, at: 9, database)
                    try bind(transaction.attachment?.id.uuidString, to: statement, at: 10, database)
                    try bind(transaction.externalTransactionID, to: statement, at: 11, database)
                    try bind(encodedString(transaction), to: statement, at: 12, database)
                }
                for posting in diff.postingsChangedByTransaction[transaction.id] ?? [] {
                    try executePreparedStatement(insertPosting, database) { statement in
                        try bind(posting.id.uuidString, to: statement, at: 1, database)
                        try bind(transaction.id.uuidString, to: statement, at: 2, database)
                        try bind(posting.accountID.uuidString, to: statement, at: 3, database)
                        try bind(posting.commodityID?.uuidString, to: statement, at: 4, database)
                        try bind(NSDecimalNumber(decimal: posting.amount).stringValue, to: statement, at: 5, database)
                        try bind(Int64(posting.listIndex), to: statement, at: 6, database)
                        try bind(encodedString(posting), to: statement, at: 7, database)
                    }
                    // Stable IDs can be updated within their own transaction,
                    // but must never silently steal another transaction's row.
                    guard sqlite3_changes(database) == 1 else {
                        throw SQLiteJournalStoreError.stepFailed("A posting identifier belongs to another transaction.")
                    }
                }
                if !diff.transactionRecurrenceUnchanged.contains(transaction.id), let rule = transaction.recurrenceRule {
                    try upsertRecurrenceRule(rule, writtenRules: &writtenRecurrenceRules, database: database)
                }
                if !diff.transactionAttachmentsUnchanged.contains(transaction.id), let attachment = transaction.attachment {
                    try upsertAttachmentContainer(
                        attachment,
                        transactionID: transaction.id,
                        previousUploadStates: attachmentUploadStates,
                        database: database
                    )
                }
            }
        }}}}}

        for template in diff.templatesChanged {
            if !diff.templatePostingsUnchanged.contains(template.id) {
                try executePrepared("DELETE FROM posting_templates WHERE template_id = ?", database) { statement in
                    try bind(template.id.uuidString, to: statement, at: 1, database)
                }
            }
            try executePrepared(
                """
                INSERT INTO transaction_templates(id, ledger_id, name, list_index, payload_json)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    ledger_id = excluded.ledger_id,
                    name = excluded.name,
                    list_index = excluded.list_index,
                    payload_json = excluded.payload_json
                """,
                database
            ) { statement in
                try bind(template.id.uuidString, to: statement, at: 1, database)
                try bind(template.ledgerID.uuidString, to: statement, at: 2, database)
                try bind(template.name, to: statement, at: 3, database)
                try bind(Int64(template.listIndex), to: statement, at: 4, database)
                try bind(encodedString(template), to: statement, at: 5, database)
            }
            for posting in template.postings where !diff.templatePostingsUnchanged.contains(template.id) {
                try executePrepared(
                    """
                    INSERT INTO posting_templates(id, template_id, account_id, list_index, payload_json)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    database
                ) { statement in
                    try bind(posting.id.uuidString, to: statement, at: 1, database)
                    try bind(template.id.uuidString, to: statement, at: 2, database)
                    try bind(posting.accountID?.uuidString, to: statement, at: 3, database)
                    try bind(Int64(posting.listIndex), to: statement, at: 4, database)
                    try bind(encodedString(posting), to: statement, at: 5, database)
                }
            }
        }

        if diff.metadataChanged {
            let metadata = try JSONEncoder.appEncoder.encode(JournalMetadata(data: data))
            try upsertMetadata("journal", value: String(decoding: metadata, as: UTF8.self), database: database)
        }

        if trackSyncChanges {
            let envelopes = try syncEnvelopes(forDiff: diff, data: data)
            try upsertSyncRecords(envelopes: envelopes, now: now, database: database)
            var pendingClientChangeIDs = try readPendingOutboxClientChangeIDs(forKeys: syncKeys, database: database)
            try upsertSyncOutboxRows(
                envelopes: envelopes,
                previousRows: previousSyncRows,
                pendingClientChangeIDs: &pendingClientChangeIDs,
                now: now,
                database: database
            )
            var deletedKeys: [(type: String, id: String, hash: String)] = []
            func appendDeletedKeys(_ type: String, _ ids: [UUID]) {
                for id in ids {
                    let key = syncKey(type: type, id: id)
                    if let hash = previousSyncRows[key] {
                        deletedKeys.append((type: type, id: id.uuidString, hash: hash))
                    }
                }
            }
            appendDeletedKeys("ledger", diff.ledgerIDsDeleted)
            appendDeletedKeys("commodity", diff.commodityIDsDeleted)
            appendDeletedKeys("account", diff.accountIDsDeleted)
            appendDeletedKeys("source", diff.sourceIDsDeleted)
            appendDeletedKeys("transaction", diff.transactionIDsDeleted)
            appendDeletedKeys("attachment_asset", diff.attachmentAssetIDsDeleted)
            appendDeletedKeys("transaction_template", diff.templateIDsDeleted)
            try tombstoneSyncRecords(
                deletedKeys: deletedKeys,
                pendingClientChangeIDs: &pendingClientChangeIDs,
                now: now,
                database: database
            )
        }
    }

    private func deleteTransactionRows(transactionID: UUID, database: OpaquePointer) throws {
        for sql in [
            "DELETE FROM postings WHERE transaction_id = ?",
            "DELETE FROM attachment_assets WHERE transaction_id = ?",
            "DELETE FROM attachment_containers WHERE transaction_id = ?",
            "DELETE FROM transactions WHERE id = ?"
        ] {
            try executePrepared(sql, database) { statement in
                try bind(transactionID.uuidString, to: statement, at: 1, database)
            }
        }
    }

    private func syncEnvelopes(forDiff diff: JournalDataDiff, data: JournalData) throws -> [SyncEnvelope] {
        var envelopes: [SyncEnvelope] = []
        if diff.syncedMetadataChanged {
            try envelopes.append(envelope(
                "journal_metadata",
                id: SQLiteSyncedJournalMetadata.recordID,
                parentID: nil,
                payload: SQLiteSyncedJournalMetadata(data: data)
            ))
        }
        try envelopes.append(contentsOf: diff.ledgersChanged.map { try envelope("ledger", id: $0.id, parentID: nil, payload: $0) })
        try envelopes.append(contentsOf: diff.commoditiesChanged.map { try envelope("commodity", id: $0.id, parentID: $0.ledgerID, payload: $0) })
        try envelopes.append(contentsOf: diff.accountsChanged.map { try envelope("account", id: $0.id, parentID: $0.parentID ?? $0.ledgerID, payload: $0) })
        try envelopes.append(contentsOf: diff.sourcesChanged.map { try envelope("source", id: $0.id, parentID: $0.ledgerID, payload: $0) })
        for transaction in diff.transactionsChanged {
            try envelopes.append(envelope("transaction", id: transaction.id, parentID: transaction.ledgerID, payload: transaction))
            if !diff.transactionAttachmentsUnchanged.contains(transaction.id), let container = transaction.attachment {
                try envelopes.append(contentsOf: container.assets.map {
                    try envelope("attachment_asset", id: $0.id, parentID: container.id, payload: $0)
                })
            }
        }
        for template in diff.templatesChanged {
            try envelopes.append(envelope("transaction_template", id: template.id, parentID: template.ledgerID, payload: template))
        }
        var seen: Set<String> = []
        return envelopes.filter { envelope in
            seen.insert(syncKey(type: envelope.type, id: envelope.id)).inserted
        }
    }

    // CloudKit state is deliberately separate from the legacy integer-revision
    // metadata. One local journal has one bound container/environment/account.
    func bindCloudKitAccount(contextKey: String, accountID: String) throws -> Bool {
        guard !contextKey.isEmpty, !accountID.isEmpty else { throw cloudKitError("CloudKit account context is missing.") }
        return try withCloudKitDatabase { database in
            let bindings = try cloudKitBindings(database)
            if let existing = bindings.first {
                guard bindings.count == 1, existing.0 == contextKey, existing.1 == accountID else {
                    throw cloudKitError("This journal belongs to another iCloud account or CloudKit context. Use a separate local journal; existing data is preserved.")
                }
                return false
            }
            try executePrepared("INSERT INTO cloudkit_contexts(context_key, account_id, initial_prepared) VALUES (?, ?, 0)", database) {
                try bind(contextKey, to: $0, at: 1, database)
                try bind(accountID, to: $0, at: 2, database)
            }
            return true
        }
    }

    func cloudKitBoundContextKey() throws -> String? {
        try withCloudKitDatabase { database in
            let bindings = try cloudKitBindings(database)
            guard bindings.count <= 1 else { throw cloudKitError("Multiple CloudKit bindings require recovery.") }
            return bindings.first?.0
        }
    }

    func hasCloudKitSyncState(contextKey: String) throws -> Bool {
        try withCloudKitDatabase { database in
            try cloudKitBindings(database).contains { $0.0 == contextKey }
        }
    }

    func cloudKitChangeToken(contextKey: String) throws -> Data? {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            try rows("SELECT change_token FROM cloudkit_contexts WHERE context_key = ?", database: database,
                     bindValues: { try bind(contextKey, to: $0, at: 1, database) },
                     map: { columnData($0, 0) }).first ?? nil
        }
    }

    func knownCloudKitRecords(contextKey: String) throws -> [String: CloudKitSyncRecord] {
        try withCloudKitDatabase(contextKey: contextKey) { try readKnownCloudKitRecords(contextKey: contextKey, database: $0) }
    }

    func knownCloudKitRecord(forKey key: String, contextKey: String) throws -> CloudKitSyncRecord? {
        try withCloudKitDatabase(contextKey: contextKey) {
            try readKnownCloudKitRecord(forKey: key, contextKey: contextKey, database: $0)
        }
    }

    func cloudKitSystemFields(forKey key: String, contextKey: String) throws -> Data? {
        try knownCloudKitRecord(forKey: key, contextKey: contextKey)?.systemFields
    }

    func pendingCloudKitRecords(contextKey: String) throws -> [String: CloudKitSyncRecord] {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            var result: [String: CloudKitSyncRecord] = [:]
            let placeholders = try initialDefaultCloudKitMetadataIDs(contextKey: contextKey, database: database)
            for record in try readCloudKitOutbox(database: database).reversed() where result[record.key] == nil && !placeholders.contains(record.clientChangeID ?? "") {
                result[record.key] = try decorateCloudKitRecord(record, contextKey: contextKey, database: database)
            }
            return result
        }
    }

    /// The argument is a caller convenience only. A background preparation must
    /// never overwrite newer disk rows or pending versions from a stale copy.
    @discardableResult
    func prepareInitialCloudKitSnapshot(_ data: JournalData, contextKey: String) throws -> Bool {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            let prepared = try rows("SELECT initial_prepared FROM cloudkit_contexts WHERE context_key = ?", database: database,
                                    bindValues: { try bind(contextKey, to: $0, at: 1, database) },
                                    map: { sqlite3_column_int64($0, 0) }).first ?? 0
            guard prepared == 0 else { return false }
            let pendingKeys = Set(try readCloudKitOutbox(database: database).map(\.key))
            let known = try readKnownCloudKitRecords(contextKey: contextKey, database: database)
            for base in try currentCloudKitRecords(database: database) where !pendingKeys.contains(base.key) {
                let record = try decorateCloudKitRecord(base, contextKey: contextKey, database: database)
                if let remote = known[record.key], cloudKitValuesMatch(record, remote) { continue }
                try enqueueCloudKitRecord(record, database: database)
            }
            try executePrepared("UPDATE cloudkit_contexts SET initial_prepared = 1 WHERE context_key = ?", database) {
                try bind(contextKey, to: $0, at: 1, database)
            }
            return true
        }
    }

    /// Receipt bytes remain necessary until immutable upload attempts are acknowledged.
    func attachmentFileRetention(includeCompletedClaims: Bool = false) throws -> (pending: Set<String>, completed: Set<String>, pendingAssets: [AttachmentAsset]) {
        try withCloudKitDatabase { database in
            let pending = try rows("SELECT payload_json FROM sync_outbox WHERE record_type = 'attachment_asset' AND operation = 'upsert' AND state IN ('pending', 'in_flight')", database: database) { statement in
                guard let json = columnText(statement, 0)?.data(using: .utf8) else { throw cloudKitError("Pending receipt metadata is missing.") }
                return try JSONDecoder.appDecoder.decode(AttachmentAsset.self, from: json)
            }
            var completed = Set<String>()
            if includeCompletedClaims {
                let records = try rows("SELECT record_json FROM cloudkit_receipt_claims AS claim WHERE NOT EXISTS (SELECT 1 FROM sync_outbox WHERE client_change_id = claim.client_change_id AND state IN ('pending', 'in_flight'))", database: database) { statement in
                    try decodeCloudKitRecord(columnText(statement, 0) ?? "")
                }
                for record in records {
                    guard let json = record.payloadJSON?.data(using: .utf8) else { throw cloudKitError("Completed receipt metadata is missing.") }
                    completed.insert(try JSONDecoder.appDecoder.decode(AttachmentAsset.self, from: json).storedPath)
                }
            }
            return (Set(pending.map(\.storedPath)), completed, pending)
        }
    }

    /// Count queued mutations, including successors of an in-flight version.
    /// No receipt payloads or file bytes are loaded for progress reporting.
    func remainingCloudKitChangeCount(contextKey: String) throws -> Int {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            let domainTypes = Self.cloudKitDomainTypes.sorted().map { "'\($0)'" }.joined(separator: ", ")
            return try rows("""
                SELECT COUNT(*) FROM sync_outbox AS candidate
                WHERE candidate.state IN ('pending', 'in_flight') AND candidate.record_type IN (\(domainTypes))
                  AND NOT EXISTS (
                    SELECT 1 FROM cloudkit_conflicts AS conflict
                    WHERE conflict.context_key = ?
                      AND conflict.record_key = candidate.record_type || ':' || candidate.record_id
                      AND conflict.resolved_at IS NULL
                  )
                """, database: database, bindValues: { try bind(contextKey, to: $0, at: 1, database) },
                map: { Int(sqlite3_column_int64($0, 0)) }).first ?? 0
        }
    }

    func claimCloudKitChanges(contextKey: String, limit: Int = 50) throws -> [CloudKitSyncRecord] {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            var result: [CloudKitSyncRecord] = []
            for base in try readClaimableCloudKitOutbox(contextKey: contextKey, limit: limit, database: database) {
                var record = try decorateCloudKitRecord(base, contextKey: contextKey, database: database)
                record.systemFields = try readKnownCloudKitRecord(forKey: record.key, contextKey: contextKey, database: database)?.systemFields
                if record.recordType == "attachment_asset", record.operation == "upsert" {
                    guard let url = record.assetFileURL, FileManager.default.fileExists(atPath: url.path),
                          validCloudKitSHA(record.assetSHA256) else {
                        throw cloudKitError("A pending receipt is missing or has no verified checksum. Local changes are preserved.")
                    }
                    try executePrepared("INSERT OR IGNORE INTO cloudkit_receipt_claims(context_key, client_change_id, record_json) VALUES (?, ?, ?)", database) {
                        try bind(contextKey, to: $0, at: 1, database)
                        try bind(record.clientChangeID, to: $0, at: 2, database)
                        try bind(try encodeCloudKitRecord(record), to: $0, at: 3, database)
                    }
                }
                try executePrepared("UPDATE sync_outbox SET state = 'in_flight' WHERE client_change_id = ? AND state IN ('pending', 'in_flight')", database) {
                    try bind(record.clientChangeID, to: $0, at: 1, database)
                }
                result.append(record)
            }
            return result
        }
    }

    func persistCloudKitPull(_ records: [CloudKitSyncRecord], data: JournalData, previous: JournalData?, contextKey: String, changeToken: Data?, receiptInstallationID: UUID? = nil) throws {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            let placeholders = records.contains(where: { $0.recordType == "journal_metadata" && $0.operation == "upsert" })
                ? try initialDefaultCloudKitMetadataIDs(contextKey: contextKey, database: database) : []
            try guardCloudKitCandidate(data, contextKey: contextKey, ignoringClientIDs: placeholders, database: database)
            let pending = try readCloudKitOutbox(database: database)
            let knownBeforePull = try readKnownCloudKitRecords(contextKey: contextKey, database: database)
            for record in records {
                try validateCloudKitRecord(record)
                // The coordinator filters historical bases. An exact already
                // acknowledged mutation must never roll known CAS state back.
                if try isKnownCloudKitMutation(record, contextKey: contextKey, database: database) {
                    // Reset can queue fresh bootstrap IDs before a full refetch.
                    // An observed equal server value can retire those IDs, but
                    // an old echo must not acknowledge a reversion queued after
                    // a different newer server value was already observed.
                    if let known = knownBeforePull[record.key] {
                        guard cloudKitValuesMatch(known, record) else { continue }
                    } else {
                        try writeKnownCloudKitRecord(record, contextKey: contextKey, database: database)
                    }
                    for base in pending where base.key == record.key {
                        let local = try decorateCloudKitRecord(base, contextKey: contextKey, database: database)
                        guard cloudKitValuesMatch(local, record) else { continue }
                        try acceptCloudKitMutation(local: local, remote: record, contextKey: contextKey, database: database)
                    }
                    // Keep existing CAS fields, which may be newer even when
                    // their record value is identical to this historical echo.
                    continue
                }
                for base in pending where base.key == record.key {
                    let local = try decorateCloudKitRecord(base, contextKey: contextKey, database: database)
                    guard cloudKitValuesMatch(local, record) else { continue }
                    try acceptCloudKitMutation(local: local, remote: record, contextKey: contextKey, database: database)
                }
                try writeKnownCloudKitRecord(record, contextKey: contextKey, database: database)
            }
            for id in placeholders {
                // Only an empty device's exact default placeholder is retired.
                // It is not a fabricated server acknowledgement.
                try executePrepared("UPDATE sync_outbox SET state = 'superseded' WHERE client_change_id = ? AND state IN ('pending', 'in_flight')", database) { try bind(id, to: $0, at: 1, database) }
            }
            try persistCloudKitDomain(data, previous: previous, records: records, database: database)
            for record in records { try markCloudKitReceiptStored(record, database: database) }
            try bindCloudKitToken(changeToken, contextKey: contextKey, database: database)
            if let receiptInstallationID { try markReceiptInstallationCommitted(receiptInstallationID, database: database) }
        }
    }

    func acknowledgeCloudKitRecords(_ saved: [CloudKitSyncRecord], submitted: [CloudKitSyncRecord], contextKey: String) throws {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            var submittedByID: [String: CloudKitSyncRecord] = [:]
            for record in submitted {
                guard let id = record.clientChangeID, submittedByID[id] == nil else { throw cloudKitError("CloudKit submission contains an invalid mutation identity.") }
                submittedByID[id] = record
            }
            for record in saved {
                guard let id = record.clientChangeID, let expected = submittedByID[id], expected.key == record.key,
                      cloudKitExactMutationValueMatch(expected, record) else {
                    throw cloudKitError("CloudKit acknowledgement does not match the submitted change. Pending data is preserved.")
                }
                if try isKnownCloudKitMutation(expected, contextKey: contextKey, database: database) { continue }
                guard let durable = try readPendingCloudKitRecord(clientChangeID: id, database: database),
                      durable.key == expected.key, durable.operation == expected.operation,
                      durable.contentHash == expected.contentHash, durable.payloadJSON == expected.payloadJSON else {
                    throw cloudKitError("The acknowledged local version is no longer pending.")
                }
                let decorated = try decorateCloudKitRecord(durable, contextKey: contextKey, database: database)
                guard cloudKitValuesMatch(decorated, record) else { throw cloudKitError("The acknowledged receipt checksum does not match its claimed version.") }
                try acceptCloudKitMutation(local: decorated, remote: record, contextKey: contextKey, database: database)
                try writeKnownCloudKitRecord(record, contextKey: contextKey, database: database)
                try markCloudKitReceiptStored(record, database: database)
            }
        }
    }

    func acknowledgeCloudKitEquivalentRecords(_ remote: [CloudKitSyncRecord], submitted: [CloudKitSyncRecord], contextKey: String) throws {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            var submittedByKey: [String: CloudKitSyncRecord] = [:]
            for record in submitted {
                guard submittedByKey[record.key] == nil else { throw cloudKitError("CloudKit submission contains duplicate record keys.") }
                submittedByKey[record.key] = record
            }
            for record in remote {
                guard let expected = submittedByKey[record.key], let id = expected.clientChangeID,
                      cloudKitValuesMatch(expected, record) else {
                    throw cloudKitError("The server conflict is not equivalent to the submitted change.")
                }
                if !(try isKnownCloudKitMutation(expected, contextKey: contextKey, database: database)) {
                    guard let durable = try readPendingCloudKitRecord(clientChangeID: id, database: database),
                          cloudKitExactMutationValueMatch(try decorateCloudKitRecord(durable, contextKey: contextKey, database: database), expected) else {
                        throw cloudKitError("The equivalent acknowledgement no longer matches a pending local version.")
                    }
                    try acceptCloudKitMutation(local: expected, remote: record, contextKey: contextKey, database: database)
                }
                // This path is an observed serverRecordChanged result, not an
                // old success callback: preserve the server's real mutation ID.
                try writeKnownCloudKitRecord(record, contextKey: contextKey, database: database)
                try markCloudKitReceiptStored(record, database: database)
            }
        }
    }

    func saveCloudKitConflict(local: CloudKitSyncRecord, remote: CloudKitSyncRecord, contextKey: String) throws {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            guard local.key == remote.key else { throw cloudKitError("CloudKit conflict record identities differ.") }
            let localJSON = try encodeCloudKitRecord(local)
            let remoteJSON = try encodeCloudKitRecord(remote)
            let known = try readKnownCloudKitRecords(contextKey: contextKey, database: database)[local.key]
            let duplicate = try rows("SELECT id FROM cloudkit_conflicts WHERE context_key = ? AND local_record = ? AND remote_record = ? AND resolved_at IS NULL", database: database, bindValues: {
                try bind(contextKey, to: $0, at: 1, database); try bind(localJSON, to: $0, at: 2, database); try bind(remoteJSON, to: $0, at: 3, database)
            }, map: { columnText($0, 0) }).first ?? nil
            if let duplicate {
                // A fresh observation of the same conflict can have a newer
                // local CAS baseline. Refresh it without changing UI values.
                try executePrepared("UPDATE cloudkit_conflicts SET known_system_fields = ? WHERE id = ?", database) {
                    try bindCloudKitBlob(known?.systemFields, to: $0, at: 1, database); try bind(duplicate, to: $0, at: 2, database)
                }
                return
            }
            // Keep prior versions as audit, but only one current unresolved
            // pair per key. Stale dialog IDs then fail instead of retiring a
            // different local version than the one the user reviewed.
            try executePrepared("UPDATE cloudkit_conflicts SET resolved_at = ? WHERE context_key = ? AND record_key = ? AND resolved_at IS NULL", database) {
                try bind(isoString(Date()), to: $0, at: 1, database); try bind(contextKey, to: $0, at: 2, database); try bind(local.key, to: $0, at: 3, database)
            }
            try executePrepared("INSERT INTO cloudkit_conflicts(id, context_key, record_key, local_record, remote_record, known_system_fields, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", database) {
                try bind(UUID().uuidString, to: $0, at: 1, database); try bind(contextKey, to: $0, at: 2, database)
                try bind(local.key, to: $0, at: 3, database); try bind(localJSON, to: $0, at: 4, database); try bind(remoteJSON, to: $0, at: 5, database)
                try bindCloudKitBlob(known?.systemFields, to: $0, at: 6, database)
                try bind(isoString(Date()), to: $0, at: 7, database)
            }
        }
    }

    func unresolvedCloudKitConflicts(contextKey: String) throws -> [CloudKitSyncConflict] {
        try withCloudKitDatabase(contextKey: contextKey) { try readCloudKitConflicts(contextKey: contextKey, database: $0) }
    }

    func resolveCloudKitConflict(id: String, keepLocal: Bool, contextKey: String, data: JournalData, previous: JournalData?, receiptInstallationID: UUID? = nil) throws {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            guard let conflict = try readCloudKitConflicts(contextKey: contextKey, database: database).first(where: { $0.id == id }) else { throw cloudKitError("This CloudKit conflict is no longer available.") }
            let originalKnown = try rows("SELECT known_system_fields FROM cloudkit_conflicts WHERE id = ? AND context_key = ?", database: database, bindValues: {
                try bind(id, to: $0, at: 1, database); try bind(contextKey, to: $0, at: 2, database)
            }, map: { columnData($0, 0) }).first ?? nil
            let known = try readKnownCloudKitRecords(contextKey: contextKey, database: database)[conflict.local.key]
            guard known?.systemFields == originalKnown || known?.systemFields == conflict.remote.systemFields else {
                throw cloudKitError("This conflict has changed since it was shown. Refresh before resolving it.")
            }
            var retire = Set<String>()
            if !keepLocal, let localID = conflict.local.clientChangeID,
               let durable = try readCloudKitOutbox(database: database).first(where: { $0.clientChangeID == localID }),
               durable.key == conflict.local.key, durable.operation == conflict.local.operation,
               durable.contentHash == conflict.local.contentHash, durable.payloadJSON == conflict.local.payloadJSON {
                retire.insert(localID)
            }
            try guardCloudKitCandidate(data, contextKey: contextKey, ignoringClientIDs: retire, database: database)
            try persistCloudKitDomain(data, previous: previous, records: [conflict.remote], database: database)
            for localID in retire {
                try executePrepared("DELETE FROM sync_outbox WHERE client_change_id = ?", database) { try bind(localID, to: $0, at: 1, database) }
            }
            try writeKnownCloudKitRecord(conflict.remote, contextKey: contextKey, database: database)
            if keepLocal {
                let outstanding = try readCloudKitOutbox(database: database).contains { $0.key == conflict.local.key }
                if !outstanding {
                    let current = try currentCloudKitRecords(database: database).first { $0.key == conflict.local.key } ?? conflict.local
                    try enqueueCloudKitRecord(current, database: database)
                }
            } else {
                try markCloudKitReceiptStored(conflict.remote, database: database)
            }
            try executePrepared("UPDATE cloudkit_conflicts SET resolved_at = ? WHERE id = ? AND context_key = ?", database) {
                try bind(isoString(Date()), to: $0, at: 1, database); try bind(id, to: $0, at: 2, database); try bind(contextKey, to: $0, at: 3, database)
            }
            if let receiptInstallationID { try markReceiptInstallationCommitted(receiptInstallationID, database: database) }
        }
    }

    /// This marker commits with the journal/checkpoint, never in a separate
    /// transaction. A receipt-file manifest can therefore recover after a kill
    /// on either side of SQLite COMMIT without guessing from receipt metadata.
    private func markReceiptInstallationCommitted(_ id: UUID, database: OpaquePointer) throws {
        try upsertMetadata("cloudkit_receipt_install:" + id.uuidString, value: "committed", database: database)
    }

    func isReceiptInstallationCommitted(_ id: UUID) throws -> Bool {
        Self.accessLock.lock(); defer { Self.accessLock.unlock() }
        let database = try open(readOnly: true, createIfMissing: false)
        defer { sqlite3_close(database) }
        return try rows("SELECT value FROM app_metadata WHERE key = ?", database: database,
                        bindValues: { try bind("cloudkit_receipt_install:" + id.uuidString, to: $0, at: 1, database) },
                        map: { columnText($0, 0) }).first == "committed"
    }

    func removeReceiptInstallationCommit(_ id: UUID) throws {
        try withCloudKitDatabase { database in
            try executePrepared("DELETE FROM app_metadata WHERE key = ?", database) {
                try bind("cloudkit_receipt_install:" + id.uuidString, to: $0, at: 1, database)
            }
        }
    }

    func resetCloudKitSyncState(contextKey: String) throws {
        try withCloudKitDatabase(contextKey: contextKey) { database in
            try resetCloudKitSyncState(contextKey: contextKey, database: database)
        }
    }

    private func resetCloudKitSyncState(contextKey: String, database: OpaquePointer) throws {
        guard try readMetadata(database)?.syncEnabled != true else { throw cloudKitError("Turn Cloud Sync off before resetting its metadata.") }
        for table in ["cloudkit_records", "cloudkit_conflicts"] {
            try executePrepared("DELETE FROM \(table) WHERE context_key = ?", database) { try bind(contextKey, to: $0, at: 1, database) }
        }
        try executePrepared("UPDATE cloudkit_contexts SET change_token = NULL, initial_prepared = 0 WHERE context_key = ?", database) { try bind(contextKey, to: $0, at: 1, database) }
        // Binding, mutation receipts, frozen receipt claims, and outbox survive reset.
    }

    private func withCloudKitDatabase<T>(contextKey: String? = nil, _ action: (OpaquePointer) throws -> T) throws -> T {
        Self.accessLock.lock(); defer { Self.accessLock.unlock() }
        let database = try open(); defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            if let contextKey {
                let bindings = try cloudKitBindings(database)
                guard bindings.count == 1, bindings[0].0 == contextKey else { throw cloudKitError("This journal is not bound to this CloudKit context.") }
            }
            let result = try action(database)
            try execute("COMMIT", database)
            return result
        } catch { try? execute("ROLLBACK", database); throw error }
    }

    private func cloudKitBindings(_ database: OpaquePointer) throws -> [(String, String)] {
        try rows("SELECT context_key, account_id FROM cloudkit_contexts", database: database) {
            guard let context = columnText($0, 0), let account = columnText($0, 1) else { throw cloudKitError("CloudKit binding metadata is incomplete.") }
            return (context, account)
        }
    }

    private static let cloudKitDomainTypes: Set<String> = ["journal_metadata", "ledger", "commodity", "account", "source", "transaction", "transaction_template", "attachment_asset"]

    func isCloudKitReceiptUploadEcho(_ record: CloudKitSyncRecord, contextKey: String) throws -> Bool {
        guard record.recordType == "attachment_asset", record.operation == "upsert", let id = record.clientChangeID else { return false }
        return try withCloudKitDatabase(contextKey: contextKey) { database in
            guard let json = try rows("SELECT record_json FROM cloudkit_receipt_claims WHERE context_key = ? AND client_change_id = ?", database: database, bindValues: {
                try bind(contextKey, to: $0, at: 1, database); try bind(id, to: $0, at: 2, database)
            }, map: { columnText($0, 0) }).first ?? nil else { return false }
            return cloudKitExactMutationValueMatch(try decodeCloudKitRecord(json), record)
        }
    }

    func hasAcknowledgedCloudKitMutation(_ record: CloudKitSyncRecord, contextKey: String) throws -> Bool {
        try withCloudKitDatabase(contextKey: contextKey) { try isKnownCloudKitMutation(record, contextKey: contextKey, database: $0) }
    }

    private func initialDefaultCloudKitMetadataIDs(contextKey: String, database: OpaquePointer) throws -> Set<String> {
        let prepared = try rows("SELECT initial_prepared FROM cloudkit_contexts WHERE context_key = ?", database: database,
                                bindValues: { try bind(contextKey, to: $0, at: 1, database) }, map: { sqlite3_column_int64($0, 0) }).first ?? 0
        guard prepared == 0 else { return [] }
        for table in ["ledgers", "accounts", "transactions", "sources", "transaction_templates"] {
            if try count(table, database) > 0 { return [] }
        }
        let placeholder = try envelope("journal_metadata", id: SQLiteSyncedJournalMetadata.recordID, parentID: nil, payload: SQLiteSyncedJournalMetadata(data: JournalData()))
        return Set(try readCloudKitOutbox(database: database).compactMap { record in
            record.recordType == "journal_metadata" && record.operation == "upsert"
                && record.contentHash == placeholder.hash && record.payloadJSON == String(decoding: placeholder.payload, as: UTF8.self)
                ? record.clientChangeID : nil
        })
    }

    private func readCloudKitOutbox(database: OpaquePointer) throws -> [CloudKitSyncRecord] {
        try rows("SELECT record_type, record_id, operation, content_hash, payload_json, client_change_id FROM sync_outbox WHERE state IN ('pending', 'in_flight') ORDER BY id ASC", database: database) {
            CloudKitSyncRecord(recordType: columnText($0, 0) ?? "", recordID: columnText($0, 1) ?? "", operation: columnText($0, 2) ?? "", contentHash: columnText($0, 3), payloadJSON: columnText($0, 4), clientChangeID: columnText($0, 5))
        }.filter { Self.cloudKitDomainTypes.contains($0.recordType) }
    }

    private func readClaimableCloudKitOutbox(contextKey: String, limit: Int, database: OpaquePointer) throws -> [CloudKitSyncRecord] {
        // Separate state scans let SQLite merge the existing (state, id) index
        // in ID order and stop at the batch limit. A state IN query would sort
        // all outstanding rows before applying LIMIT. Never let a successor
        // overtake its immutable in-flight version or an unresolved conflict.
        let domainTypes = Self.cloudKitDomainTypes.sorted().map { "'\($0)'" }.joined(separator: ", ")
        let select = """
        SELECT candidate.record_type, candidate.record_id, candidate.operation,
               candidate.content_hash, candidate.payload_json, candidate.client_change_id, candidate.id
        FROM sync_outbox AS candidate
        WHERE candidate.state = ? AND candidate.record_type IN (\(domainTypes))
          AND NOT EXISTS (
            SELECT 1 FROM sync_outbox AS older
            WHERE older.state IN ('pending', 'in_flight')
              AND older.record_type = candidate.record_type AND older.record_id = candidate.record_id
              AND older.id < candidate.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM cloudkit_conflicts AS conflict
            WHERE conflict.context_key = ?
              AND conflict.record_key = candidate.record_type || ':' || candidate.record_id
              AND conflict.resolved_at IS NULL
          )
        """
        return try rows(select + " UNION ALL " + select + " ORDER BY id ASC LIMIT ?", database: database, bindValues: {
            try bind("pending", to: $0, at: 1, database); try bind(contextKey, to: $0, at: 2, database)
            try bind("in_flight", to: $0, at: 3, database); try bind(contextKey, to: $0, at: 4, database)
            try bind(Int64(max(1, limit)), to: $0, at: 5, database)
        }, map: { cloudKitOutboxRecord($0) })
    }

    private func readPendingCloudKitRecord(clientChangeID: String, database: OpaquePointer) throws -> CloudKitSyncRecord? {
        let record = try rows("SELECT record_type, record_id, operation, content_hash, payload_json, client_change_id FROM sync_outbox WHERE client_change_id = ? AND state IN ('pending', 'in_flight')", database: database, bindValues: {
            try bind(clientChangeID, to: $0, at: 1, database)
        }, map: { cloudKitOutboxRecord($0) }).first
        return record.flatMap { Self.cloudKitDomainTypes.contains($0.recordType) ? $0 : nil }
    }

    private func cloudKitOutboxRecord(_ statement: OpaquePointer) -> CloudKitSyncRecord {
        CloudKitSyncRecord(recordType: columnText(statement, 0) ?? "", recordID: columnText(statement, 1) ?? "", operation: columnText(statement, 2) ?? "", contentHash: columnText(statement, 3), payloadJSON: columnText(statement, 4), clientChangeID: columnText(statement, 5))
    }

    private func currentCloudKitRecords(database: OpaquePointer) throws -> [CloudKitSyncRecord] {
        try rows("SELECT record_type, record_id, parent_record_id, content_hash, payload_json, deleted_at FROM sync_records UNION ALL SELECT record_type, record_id, NULL, content_hash, NULL, deleted_at FROM sync_tombstones AS tombstone WHERE NOT EXISTS(SELECT 1 FROM sync_records WHERE record_type = tombstone.record_type AND record_id = tombstone.record_id) ORDER BY record_type, record_id", database: database) {
            CloudKitSyncRecord(recordType: columnText($0, 0) ?? "", recordID: columnText($0, 1) ?? "", operation: columnText($0, 5) == nil ? "upsert" : "delete", parentRecordID: columnText($0, 2), contentHash: columnText($0, 3), payloadJSON: columnText($0, 5) == nil ? columnText($0, 4) : nil)
        }.filter { Self.cloudKitDomainTypes.contains($0.recordType) }
    }

    private func decorateCloudKitRecord(_ base: CloudKitSyncRecord, contextKey: String, database: OpaquePointer) throws -> CloudKitSyncRecord {
        var record = base
        if record.parentRecordID == nil {
            if let payload = record.payloadJSON?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                record.parentRecordID = object["parentID"] as? String ?? object["ledgerID"] as? String
            }
        }
        guard record.recordType == "attachment_asset", record.operation == "upsert" else { return record }
        guard let payload = record.payloadJSON?.data(using: .utf8), let asset = try? JSONDecoder.appDecoder.decode(AttachmentAsset.self, from: payload), asset.id.uuidString == record.recordID else { throw cloudKitError("Pending receipt metadata is invalid.") }
        let components = asset.storedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "Attachments", components.count > 1, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw cloudKitError("A receipt must use a local path inside Attachments.") }
        record.assetFileURL = attachmentFileURL(asset.storedPath)
        if record.parentRecordID == nil {
            record.parentRecordID = try rows("SELECT parent_record_id FROM sync_records WHERE record_type = 'attachment_asset' AND record_id = ?", database: database,
                                             bindValues: { try bind(record.recordID, to: $0, at: 1, database) }, map: { columnText($0, 0) }).first ?? nil
        }
        record.assetFilename = asset.originalFilename
        record.assetMIMEType = asset.mimeType ?? "application/octet-stream"
        if let clientID = record.clientChangeID,
           let frozenJSON = try rows("SELECT record_json FROM cloudkit_receipt_claims WHERE context_key = ? AND client_change_id = ?", database: database, bindValues: {
               try bind(contextKey, to: $0, at: 1, database); try bind(clientID, to: $0, at: 2, database)
           }, map: { columnText($0, 0) }).first ?? nil {
            let frozen = try decodeCloudKitRecord(frozenJSON)
            guard frozen.key == record.key, frozen.contentHash == record.contentHash, frozen.payloadJSON == record.payloadJSON else { throw cloudKitError("A claimed receipt mutation changed unexpectedly.") }
            record.assetSHA256 = frozen.assetSHA256
            if let parent = frozen.parentRecordID { record.parentRecordID = parent }
        } else {
            record.assetSHA256 = try rows("SELECT sha256 FROM attachment_assets WHERE id = ? AND stored_path = ? AND original_filename = ? AND COALESCE(mime_type, 'application/octet-stream') = ?", database: database, bindValues: {
                try bind(asset.id.uuidString, to: $0, at: 1, database); try bind(asset.storedPath, to: $0, at: 2, database)
                try bind(asset.originalFilename, to: $0, at: 3, database); try bind(record.assetMIMEType, to: $0, at: 4, database)
            }, map: { columnText($0, 0) }).first ?? nil
        }
        return record
    }

    private func enqueueCloudKitRecord(_ record: CloudKitSyncRecord, database: OpaquePointer) throws {
        try executePrepared("INSERT INTO sync_outbox(client_change_id, record_type, record_id, operation, base_revision, content_hash, payload_json, created_at, state) VALUES (?, ?, ?, ?, 0, ?, ?, ?, 'pending')", database) {
            try bind(UUID().uuidString, to: $0, at: 1, database); try bind(record.recordType, to: $0, at: 2, database); try bind(record.recordID, to: $0, at: 3, database)
            try bind(record.operation, to: $0, at: 4, database); try bind(record.contentHash, to: $0, at: 5, database); try bind(record.payloadJSON, to: $0, at: 6, database); try bind(isoString(Date()), to: $0, at: 7, database)
        }
    }

    private func readKnownCloudKitRecords(contextKey: String, database: OpaquePointer) throws -> [String: CloudKitSyncRecord] {
        var result: [String: CloudKitSyncRecord] = [:]
        for record in try rows("SELECT record_json FROM cloudkit_records WHERE context_key = ?", database: database, bindValues: { try bind(contextKey, to: $0, at: 1, database) }, map: { try decodeCloudKitRecord(columnText($0, 0) ?? "") }) { result[record.key] = record }
        return result
    }

    private func readKnownCloudKitRecord(forKey key: String, contextKey: String, database: OpaquePointer) throws -> CloudKitSyncRecord? {
        try rows("SELECT record_json FROM cloudkit_records WHERE context_key = ? AND record_key = ?", database: database, bindValues: {
            try bind(contextKey, to: $0, at: 1, database); try bind(key, to: $0, at: 2, database)
        }, map: { try decodeCloudKitRecord(columnText($0, 0) ?? "") }).first
    }

    private func writeKnownCloudKitRecord(_ record: CloudKitSyncRecord, contextKey: String, database: OpaquePointer) throws {
        try executePrepared("INSERT INTO cloudkit_records(context_key, record_key, record_json) VALUES (?, ?, ?) ON CONFLICT(context_key, record_key) DO UPDATE SET record_json = excluded.record_json", database) {
            try bind(contextKey, to: $0, at: 1, database); try bind(record.key, to: $0, at: 2, database); try bind(try encodeCloudKitRecord(record), to: $0, at: 3, database)
        }
    }

    private func isKnownCloudKitMutation(_ record: CloudKitSyncRecord, contextKey: String, database: OpaquePointer) throws -> Bool {
        guard let id = record.clientChangeID else { return false }
        guard let text = try rows("SELECT record_json FROM cloudkit_mutation_receipts WHERE context_key = ? AND client_change_id = ?", database: database, bindValues: {
            try bind(contextKey, to: $0, at: 1, database); try bind(id, to: $0, at: 2, database)
        }, map: { columnText($0, 0) }).first ?? nil else { return false }
        let accepted = try decodeCloudKitRecord(text)
        guard cloudKitExactMutationValueMatch(accepted, record) else { throw cloudKitError("An acknowledged CloudKit mutation was reused with different contents.") }
        return true
    }

    private func acceptCloudKitMutation(local: CloudKitSyncRecord, remote: CloudKitSyncRecord, contextKey: String, database: OpaquePointer) throws {
        guard let id = local.clientChangeID, cloudKitValuesMatch(local, remote) else { throw cloudKitError("CloudKit echo does not match the local version.") }
        // Receipt identity describes the exact local version retired, even
        // when another device produced an equivalent tombstone with a different
        // previous hash. CAS fields still come from the observed server record.
        var receipt = local; receipt.systemFields = remote.systemFields
        try executePrepared("UPDATE sync_outbox SET state = 'accepted' WHERE client_change_id = ? AND state IN ('pending', 'in_flight')", database) { try bind(id, to: $0, at: 1, database) }
        try executePrepared("INSERT OR IGNORE INTO cloudkit_mutation_receipts(context_key, client_change_id, record_json) VALUES (?, ?, ?)", database) {
            try bind(contextKey, to: $0, at: 1, database); try bind(id, to: $0, at: 2, database); try bind(try encodeCloudKitRecord(receipt), to: $0, at: 3, database)
        }
    }

    private func cloudKitValuesMatch(_ lhs: CloudKitSyncRecord, _ rhs: CloudKitSyncRecord) -> Bool {
        guard lhs.key == rhs.key, lhs.operation == rhs.operation else { return false }
        if lhs.operation == "delete" { return true }
        return cloudKitExactMutationValueMatch(lhs, rhs)
    }

    private func cloudKitExactMutationValueMatch(_ lhs: CloudKitSyncRecord, _ rhs: CloudKitSyncRecord) -> Bool {
        guard lhs.key == rhs.key, lhs.operation == rhs.operation, lhs.contentHash == rhs.contentHash, lhs.payloadJSON == rhs.payloadJSON else { return false }
        if lhs.recordType == "attachment_asset", lhs.operation == "upsert" {
            return validCloudKitSHA(lhs.assetSHA256) && validCloudKitSHA(rhs.assetSHA256)
                && lhs.assetSHA256?.lowercased() == rhs.assetSHA256?.lowercased()
                && lhs.assetFilename == rhs.assetFilename
                && (lhs.assetMIMEType ?? "application/octet-stream") == (rhs.assetMIMEType ?? "application/octet-stream")
        }
        return true
    }

    private func validCloudKitSHA(_ value: String?) -> Bool {
        guard let value = value?.lowercased(), value.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func validateCloudKitRecord(_ record: CloudKitSyncRecord) throws {
        guard Self.cloudKitDomainTypes.contains(record.recordType), let id = UUID(uuidString: record.recordID), id.uuidString == record.recordID,
              ["upsert", "delete"].contains(record.operation) else { throw cloudKitError("CloudKit record identity or operation is invalid.") }
        if record.operation == "upsert" {
            guard let payload = record.payloadJSON, let hash = record.contentHash,
                  SHA256.hash(data: Data(payload.utf8)).map({ String(format: "%02x", $0) }).joined() == hash.lowercased() else { throw cloudKitError("CloudKit record payload checksum is invalid.") }
        }
    }

    private func guardCloudKitCandidate(_ data: JournalData, contextKey: String, ignoringClientIDs: Set<String>, database: OpaquePointer) throws {
        let outstanding = try readCloudKitOutbox(database: database).filter { !ignoringClientIDs.contains($0.clientChangeID ?? "") }
        guard !outstanding.isEmpty else { return }
        let envelopes = try syncEnvelopes(for: data)
        let candidate = Dictionary(uniqueKeysWithValues: envelopes.map { (syncKey(type: $0.type, id: $0.id), $0.hash) })
        var checked = Set<String>()
        for pending in outstanding.reversed() where !checked.contains(pending.key) {
            checked.insert(pending.key)
            let valid = pending.operation == "delete" ? candidate[pending.key] == nil : candidate[pending.key] == pending.contentHash
            guard valid else { throw cloudKitError("Local edits changed while CloudKit was waiting. They were preserved; sync again before applying this change.") }
        }
    }

    private func persistCloudKitDomain(_ data: JournalData, previous: JournalData?, records: [CloudKitSyncRecord], database: OpaquePointer) throws {
        if let previous {
            let diff = JournalDataDiff.between(previous, data)
            if !diff.isEmpty {
                try applyDiffContents(diff, data: data, trackSyncChanges: false, database: database)
                // Remote commits still need the canonical local mirror used by
                // later diffs/deletions. Mirror the validated candidate, never
                // a raw older echo that the coordinator chose not to apply.
                try upsertSyncRecords(envelopes: syncEnvelopes(forDiff: diff, data: data), now: Self.makeISOFormatter().string(from: Date()), database: database)
            }
        } else {
            // Full replacement already updates the full canonical mirror.
            try replaceAppRows(data, envelopes: syncEnvelopes(for: data), database: database)
        }
        let deleted = records.filter { $0.operation == "delete" }
        guard !deleted.isEmpty else { return }
        // Membership needs IDs only; an idle/ordinary delta must not encode
        // every transaction simply to protect tombstones from newer local rows.
        var liveKeys: Set<String> = [syncKey(type: "journal_metadata", id: SQLiteSyncedJournalMetadata.recordID)]
        for (type, ids) in [("ledger", data.ledgers.map(\.id)), ("commodity", data.commodities.map(\.id)), ("account", data.accounts.map(\.id)), ("source", data.sources.map(\.id)), ("transaction", data.transactions.map(\.id)), ("transaction_template", data.transactionTemplates.map(\.id))] {
            liveKeys.formUnion(ids.map { syncKey(type: type, id: $0) })
        }
        for transaction in data.transactions {
            liveKeys.formUnion((transaction.attachment?.assets ?? []).map { syncKey(type: "attachment_asset", id: $0.id) })
        }
        for record in deleted where !liveKeys.contains(record.key) {
            try executePrepared("INSERT INTO sync_records(record_type, record_id, parent_record_id, content_hash, payload_json, server_revision, updated_at, deleted_at) VALUES (?, ?, ?, ?, NULL, 0, ?, ?) ON CONFLICT(record_type, record_id) DO UPDATE SET deleted_at = excluded.deleted_at, payload_json = NULL", database) {
                try bind(record.recordType, to: $0, at: 1, database); try bind(record.recordID, to: $0, at: 2, database); try bind(record.parentRecordID, to: $0, at: 3, database)
                try bind(record.contentHash ?? "", to: $0, at: 4, database); try bind(isoString(Date()), to: $0, at: 5, database); try bind(isoString(Date()), to: $0, at: 6, database)
            }
            try executePrepared("INSERT INTO sync_tombstones(record_type, record_id, content_hash, deleted_at, server_revision) VALUES (?, ?, ?, ?, 0) ON CONFLICT(record_type, record_id) DO UPDATE SET content_hash = excluded.content_hash, deleted_at = excluded.deleted_at", database) {
                try bind(record.recordType, to: $0, at: 1, database); try bind(record.recordID, to: $0, at: 2, database); try bind(record.contentHash, to: $0, at: 3, database); try bind(isoString(Date()), to: $0, at: 4, database)
            }
        }
    }

    private func markCloudKitReceiptStored(_ record: CloudKitSyncRecord, database: OpaquePointer) throws {
        guard record.recordType == "attachment_asset", record.operation == "upsert", validCloudKitSHA(record.assetSHA256),
              let expectedSHA = record.assetSHA256?.lowercased(), let payloadHash = record.contentHash else { return }
        let storedPath = try rows("SELECT stored_path FROM attachment_assets WHERE id = ? AND EXISTS(SELECT 1 FROM sync_records WHERE record_type = 'attachment_asset' AND record_id = attachment_assets.id AND content_hash = ? AND deleted_at IS NULL)", database: database, bindValues: {
            try bind(record.recordID, to: $0, at: 1, database); try bind(payloadHash, to: $0, at: 2, database)
        }, map: { columnText($0, 0) }).first ?? nil
        guard let storedPath, let file = ownedCloudKitReceiptURL(storedPath),
              let verified = try? hashStableCloudKitReceipt(file), verified.sha256 == expectedSHA else { return }
        // Blob bytes can legitimately change without any JSON/size change.
        // Refresh the cached SHA only from the actual owned file, never from
        // an old echo or trusted-looking metadata alone.
        try executePrepared("UPDATE attachment_assets SET sha256 = ?, size_bytes = ?, upload_state = 'uploaded' WHERE id = ? AND stored_path = ? AND EXISTS(SELECT 1 FROM sync_records WHERE record_type = 'attachment_asset' AND record_id = attachment_assets.id AND content_hash = ? AND deleted_at IS NULL)", database) {
            try bind(expectedSHA, to: $0, at: 1, database); try bind(verified.size, to: $0, at: 2, database)
            try bind(record.recordID, to: $0, at: 3, database); try bind(storedPath, to: $0, at: 4, database); try bind(payloadHash, to: $0, at: 5, database)
        }
    }

    private func ownedCloudKitReceiptURL(_ storedPath: String) -> URL? {
        let parts = storedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1, parts.first == "Attachments", parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let root = databaseURL.deletingLastPathComponent().appending(path: "Attachments").resolvingSymlinksInPath().standardizedFileURL
        let file = attachmentFileURL(storedPath).resolvingSymlinksInPath().standardizedFileURL
        return file.path.hasPrefix(root.path + "/") ? file : nil
    }

    private func hashStableCloudKitReceipt(_ file: URL) throws -> (sha256: String, size: Int64) {
        let manager = FileManager.default
        let before = try manager.attributesOfItem(atPath: file.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
              let identifier = before[.systemFileNumber] as? NSNumber,
              let size = before[.size] as? NSNumber,
              let modified = before[.modificationDate] as? Date else { throw cloudKitError("Receipt file metadata is unavailable.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var bytesRead: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hash.update(data: chunk)
            bytesRead += Int64(chunk.count)
        }
        let after = try manager.attributesOfItem(atPath: file.path)
        guard (after[.systemFileNumber] as? NSNumber) == identifier,
              (after[.size] as? NSNumber) == size,
              (after[.modificationDate] as? Date) == modified,
              bytesRead == size.int64Value,
              file.resolvingSymlinksInPath().standardizedFileURL == file else { throw cloudKitError("Receipt file changed while its checksum was verified.") }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytesRead)
    }

    private func bindCloudKitToken(_ token: Data?, contextKey: String, database: OpaquePointer) throws {
        try executePrepared("UPDATE cloudkit_contexts SET change_token = ? WHERE context_key = ?", database) {
            try bindCloudKitBlob(token, to: $0, at: 1, database); try bind(contextKey, to: $0, at: 2, database)
        }
    }

    private func readCloudKitConflicts(contextKey: String, database: OpaquePointer) throws -> [CloudKitSyncConflict] {
        try rows("SELECT id, local_record, remote_record FROM cloudkit_conflicts WHERE context_key = ? AND resolved_at IS NULL ORDER BY created_at, id", database: database, bindValues: { try bind(contextKey, to: $0, at: 1, database) }) {
            CloudKitSyncConflict(id: columnText($0, 0) ?? "", local: try decodeCloudKitRecord(columnText($0, 1) ?? ""), remote: try decodeCloudKitRecord(columnText($0, 2) ?? ""))
        }
    }

    private struct StoredCloudKitRecord: Codable {
        var recordType: String; var recordID: String; var operation: String
        var parentRecordID: String?; var contentHash: String?; var payloadJSON: String?; var clientChangeID: String?
        var systemFields: Data?; var assetSHA256: String?; var assetFilename: String?; var assetMIMEType: String?
        init(_ record: CloudKitSyncRecord) {
            recordType = record.recordType; recordID = record.recordID; operation = record.operation
            parentRecordID = record.parentRecordID; contentHash = record.contentHash; payloadJSON = record.payloadJSON; clientChangeID = record.clientChangeID
            systemFields = record.systemFields; assetSHA256 = record.assetSHA256; assetFilename = record.assetFilename; assetMIMEType = record.assetMIMEType
        }
        var record: CloudKitSyncRecord {
            CloudKitSyncRecord(recordType: recordType, recordID: recordID, operation: operation, parentRecordID: parentRecordID, contentHash: contentHash, payloadJSON: payloadJSON, clientChangeID: clientChangeID, systemFields: systemFields, assetSHA256: assetSHA256, assetFilename: assetFilename, assetMIMEType: assetMIMEType)
        }
    }

    private func encodeCloudKitRecord(_ record: CloudKitSyncRecord) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(StoredCloudKitRecord(record)), as: UTF8.self)
    }
    private func decodeCloudKitRecord(_ text: String) throws -> CloudKitSyncRecord { try JSONDecoder().decode(StoredCloudKitRecord.self, from: Data(text.utf8)).record }
    private func cloudKitError(_ message: String) -> SQLiteJournalStoreError { .stepFailed(message) }
    private func bindCloudKitBlob(_ value: Data?, to statement: OpaquePointer, at index: Int32, _ database: OpaquePointer) throws {
        let status: Int32
        if let value {
            status = value.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
        } else { status = sqlite3_bind_null(statement, index) }
        guard status == SQLITE_OK else { throw SQLiteJournalStoreError.bindFailed("CloudKit opaque state") }
    }

    func recordCounts() throws -> SQLiteJournalRecordCounts {
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        return SQLiteJournalRecordCounts(
            ledgers: try count("ledgers", database),
            commodities: try count("commodities", database),
            accounts: try count("accounts", database),
            transactions: try count("transactions", database),
            postings: try count("postings", database),
            sources: try count("sources", database),
            transactionTemplates: try count("transaction_templates", database),
            postingTemplates: try count("posting_templates", database),
            attachmentContainers: try count("attachment_containers", database),
            attachmentAssets: try count("attachment_assets", database),
            recurrenceRules: try count("recurrence_rules", database),
            recurrenceExceptions: try count("recurrence_exceptions", database),
            outboxRows: try count("sync_outbox", database)
        )
    }

    func resetCloudSyncState() throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("DELETE FROM sync_state", database)
        try execute("DELETE FROM sync_outbox", database)
        try execute("DELETE FROM sync_conflicts", database)
        try execute("DELETE FROM attachment_transfer_queue", database)
        try execute("UPDATE attachment_assets SET upload_state = 'pending' WHERE sha256 IS NOT NULL", database)
    }

    func clearCloudSyncMetadataForRemoteReplacement() throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            try execute("DELETE FROM sync_state", database)
            try execute("DELETE FROM sync_outbox", database)
            try execute("DELETE FROM sync_records", database)
            try execute("DELETE FROM sync_tombstones", database)
            try execute("DELETE FROM sync_conflicts", database)
            try execute("DELETE FROM attachment_transfer_queue", database)
            try execute("COMMIT", database)
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    func lastPulledServerRevision() throws -> Int64 {
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        return try lastPulledServerRevision(database: database)
    }

    private func lastPulledServerRevision(database: OpaquePointer) throws -> Int64 {
        let value = try rows(
            "SELECT value FROM sync_state WHERE key = 'last_server_revision'",
            database: database,
            map: { columnText($0, 0) }
        ).first ?? nil
        return value.flatMap(Int64.init) ?? 0
    }

    func setLastPulledServerRevision(_ revision: Int64) throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try upsertMetadata("last_server_revision", value: String(revision), database: database, table: "sync_state")
    }

    func pendingSyncChanges(limit: Int = 250) throws -> [SQLiteSyncOutboxChange] {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        return try readPendingSyncChanges(limit: limit, database: database)
    }

    /// Freezes the exact idempotency key and payload before starting a request.
    /// New edits get a separate pending row; a timeout retries this same batch.
    func claimPendingSyncChanges(limit: Int = 250) throws -> [SQLiteSyncOutboxChange] {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            let changes = try readPendingSyncChanges(limit: limit, database: database)
            for change in changes {
                try executePrepared(
                    "UPDATE sync_outbox SET state = 'in_flight' WHERE client_change_id = ?",
                    database
                ) { statement in
                    try bind(change.clientChangeID, to: statement, at: 1, database)
                }
            }
            try execute("COMMIT", database)
            return changes
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    private func readPendingSyncChanges(limit: Int, database: OpaquePointer) throws -> [SQLiteSyncOutboxChange] {
        try pruneRedundantSyncRows(database)
        // Send at most one version per record in a batch. Its successor must
        // wait for the acknowledged server revision before it can be sent.
        return try rows(
            """
            SELECT client_change_id, record_type, record_id, operation, base_revision, content_hash, payload_json
            FROM sync_outbox AS current
            WHERE state IN ('pending', 'in_flight')
              AND NOT EXISTS (
                SELECT 1 FROM sync_outbox AS earlier
                WHERE earlier.state IN ('pending', 'in_flight')
                  AND earlier.record_type = current.record_type
                  AND earlier.record_id = current.record_id
                  AND earlier.id < current.id
              )
            ORDER BY id ASC
            LIMIT \(max(1, limit))
            """,
            database: database
        ) { statement in
            SQLiteSyncOutboxChange(
                clientChangeID: columnText(statement, 0) ?? "",
                recordType: columnText(statement, 1) ?? "",
                recordID: columnText(statement, 2) ?? "",
                operation: columnText(statement, 3) ?? "",
                baseRevision: sqlite3_column_int64(statement, 4),
                contentHash: columnText(statement, 5),
                payloadJSON: columnText(statement, 6)
            )
        }
    }

    func pendingSyncRecordKeys() throws -> Set<String> {
        Set(try pendingSyncRecordsByKey().keys)
    }

    func pendingSyncRecordsByKey() throws -> [String: SQLitePendingSyncRecord] {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        let entries: [(String, SQLitePendingSyncRecord, Bool)] = try rows(
            """
            SELECT record_type, record_id, operation, content_hash, base_revision, state
            FROM sync_outbox
            WHERE state IN ('pending', 'in_flight')
            ORDER BY id DESC
            """,
            database: database,
            map: { statement in
                guard let type = columnText(statement, 0),
                      let id = columnText(statement, 1),
                      let operation = columnText(statement, 2) else {
                    throw SQLiteJournalStoreError.missingPayload("sync_outbox")
                }
                return (
                    "\(type):\(id)",
                    SQLitePendingSyncRecord(
                        operation: operation,
                        contentHash: columnText(statement, 3),
                        baseRevision: sqlite3_column_int64(statement, 4)
                    ),
                    columnText(statement, 5) == "in_flight"
                )
            }
        )
        return entries.reduce(into: [:]) { partial, entry in
            if partial[entry.0] == nil {
                partial[entry.0] = entry.1
            } else if entry.2 {
                partial[entry.0]?.inFlightVersions.append(SQLitePendingSyncRecordVersion(
                    operation: entry.1.operation,
                    contentHash: entry.1.contentHash
                ))
            }
        }
    }

    func hasPendingDescendantChanges(of recordID: String) throws -> Bool {
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        return try rows(
            """
            WITH RECURSIVE descendants(record_type, record_id) AS (
                SELECT record_type, record_id FROM sync_records WHERE parent_record_id = ?
                UNION
                SELECT child.record_type, child.record_id
                FROM sync_records AS child
                JOIN descendants ON child.parent_record_id = descendants.record_id
            )
            SELECT EXISTS(
                SELECT 1 FROM sync_outbox
                JOIN descendants USING(record_type, record_id)
                WHERE sync_outbox.state IN ('pending', 'in_flight')
            )
            """,
            database: database,
            bindValues: { statement in try bind(recordID, to: statement, at: 1, database) }
        ) { sqlite3_column_int($0, 0) != 0 }.first ?? false
    }

    func acknowledgedSyncRevisions(for changes: [SQLiteRemoteSyncChange]) throws -> [String: Int64] {
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        var result: [String: Int64] = [:]
        for change in changes {
            let key = "\(change.recordType):\(change.recordID)"
            guard result[key] == nil else { continue }
            let revision = try rows(
                "SELECT server_revision FROM sync_records WHERE record_type = ? AND record_id = ?",
                database: database,
                bindValues: { statement in
                    try bind(change.recordType, to: statement, at: 1, database)
                    try bind(change.recordID, to: statement, at: 2, database)
                }
            ) { sqlite3_column_int64($0, 0) }.first
            if let revision { result[key] = revision }
        }
        return result
    }

    func hasAcknowledgedSyncRecords() throws -> Bool {
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        return try rows(
            "SELECT EXISTS(SELECT 1 FROM sync_records WHERE server_revision > 0)",
            database: database
        ) { sqlite3_column_int($0, 0) != 0 }.first ?? false
    }

    func hasUntrackedZeroRevisionRecordsWithoutPendingOutbox() throws -> Bool {
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        // A stale zero-revision row for a redundant record type (left by older
        // builds that synced posting/rule/container records individually) must
        // not force a since=0 full re-pull: the schema fast path no longer
        // prunes on every open, so sweep here before deciding.
        try pruneRedundantSyncRows(database)
        let pendingOutboxRows = try rows(
            "SELECT COUNT(*) FROM sync_outbox WHERE state IN ('pending', 'in_flight')",
            database: database
        ) { statement in
            Int(sqlite3_column_int64(statement, 0))
        }.first ?? 0
        guard pendingOutboxRows == 0 else { return false }

        let zeroRevisionRows = try rows(
            "SELECT COUNT(*) FROM sync_records WHERE deleted_at IS NULL AND server_revision = 0",
            database: database
        ) { statement in
            Int(sqlite3_column_int64(statement, 0))
        }.first ?? 0
        return zeroRevisionRows > 0
    }

    func deletedTransactionIDs() throws -> Set<UUID> {
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        let ids: [UUID] = try rows(
            "SELECT record_id FROM sync_tombstones WHERE record_type = 'transaction'",
            database: database
        ) { statement in
            guard let idText = columnText(statement, 0),
                  let id = UUID(uuidString: idText) else {
                throw SQLiteJournalStoreError.missingPayload("sync_tombstones")
            }
            return id
        }
        return Set(ids)
    }

    /// Capture conversion is create-once, including after reopening or an
    /// unrelated write failure invalidates the in-memory persistence baseline.
    func hasRecordedTransaction(_ id: UUID) throws -> Bool {
        let database = try open(readOnly: true, createIfMissing: false)
        defer { sqlite3_close(database) }
        return try rows("""
            SELECT EXISTS(SELECT 1 FROM transactions WHERE id = ?1)
                OR EXISTS(SELECT 1 FROM sync_tombstones WHERE record_type = 'transaction' AND record_id = ?1)
            """, database: database, bindValues: {
                try bind(id.uuidString, to: $0, at: 1, database)
            }, map: { sqlite3_column_int($0, 0) != 0 }).first ?? false
    }

    /// A raced batch may contain both accepted records and conflicts. Commit
    /// acknowledgements before surfacing conflicts so independent edits do not
    /// remain stuck behind a record that needs user resolution.
    func markSyncChangesAccepted(_ accepted: [SQLiteAcceptedSyncChange]) throws {
        guard !accepted.isEmpty else { return }
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            for change in accepted {
                try executePrepared(
                    "UPDATE sync_outbox SET state = 'accepted' WHERE client_change_id = ?",
                    database
                ) { statement in
                    try bind(change.clientChangeID, to: statement, at: 1, database)
                }
                try executePrepared(
                    """
                    UPDATE sync_records
                    SET server_revision = MAX(server_revision, ?), updated_at = ?
                    WHERE record_type = ? AND record_id = ?
                    """,
                    database
                ) { statement in
                    try bind(change.serverRevision, to: statement, at: 1, database)
                    try bind(isoString(Date()), to: statement, at: 2, database)
                    try bind(change.recordType, to: statement, at: 3, database)
                    try bind(change.recordID, to: statement, at: 4, database)
                }
                try rebasePendingSyncChanges(
                    recordType: change.recordType,
                    recordID: change.recordID,
                    revision: change.serverRevision,
                    database: database
                )
            }
            try execute("COMMIT", database)
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    private func rebasePendingSyncChanges(
        recordType: String,
        recordID: String,
        revision: Int64,
        database: OpaquePointer
    ) throws {
        try executePrepared(
            """
            UPDATE sync_outbox SET base_revision = MAX(base_revision, ?)
            WHERE record_type = ? AND record_id = ? AND state = 'pending'
            """,
            database
        ) { statement in
            try bind(revision, to: statement, at: 1, database)
            try bind(recordType, to: statement, at: 2, database)
            try bind(recordID, to: statement, at: 3, database)
        }
    }

    func markRemoteChangesApplied(_ changes: [SQLiteRemoteSyncChange]) throws {
        guard !changes.isEmpty else { return }
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            try applyRemoteSyncMetadata(changes, database: database)
            if let maxRevision = changes.map(\.revision).max() {
                try upsertMetadata("last_server_revision", value: String(maxRevision), database: database, table: "sync_state")
            }
            try execute("COMMIT", database)
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    /// A pull is durable only when its journal rows, acknowledgements, and
    /// cursor all commit. A failure leaves the entire page available to retry.
    func persistRemoteChanges(
        _ changes: [SQLiteRemoteSyncChange],
        data: JournalData,
        previous: JournalData?,
        resetMetadata: Bool,
        revision: Int64,
        acknowledgedAttachmentIDs: Set<UUID> = []
    ) throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            if !acknowledgedAttachmentIDs.isEmpty {
                let matching = try matchingPendingAttachmentUploadEchoIDs(changes, database: database)
                guard acknowledgedAttachmentIDs.isSubset(of: matching) else {
                    throw SQLiteJournalStoreError.stepFailed("A pending attachment changed before its upload acknowledgement could be committed.")
                }
            }
            if resetMetadata {
                for table in ["sync_state", "sync_outbox", "sync_records", "sync_tombstones", "sync_conflicts", "attachment_transfer_queue"] {
                    try execute("DELETE FROM \(table)", database)
                }
            }
            try applyRemoteSyncMetadata(changes, database: database)
            if let previous, !resetMetadata {
                let diff = JournalDataDiff.between(previous, data)
                if !diff.isEmpty {
                    try applyDiffContents(diff, data: data, trackSyncChanges: false, database: database)
                }
            } else {
                try replaceAppRows(data, envelopes: syncEnvelopes(for: data), database: database)
            }
            if !acknowledgedAttachmentIDs.isEmpty {
                // Recheck against the rows installed by this transaction. A
                // caller's earlier match must not acknowledge changed receipts.
                let matching = try matchingPendingAttachmentUploadEchoIDs(changes, database: database)
                guard acknowledgedAttachmentIDs.isSubset(of: matching) else {
                    throw SQLiteJournalStoreError.stepFailed("A pending attachment changed before its upload acknowledgement could be committed.")
                }
                for assetID in acknowledgedAttachmentIDs {
                    let assetRevision = changes.filter {
                        $0.recordType == "attachment_asset" && UUID(uuidString: $0.recordID) == assetID
                    }.map(\.revision).max()
                    try markAttachmentUploaded(assetID: assetID, serverRevision: assetRevision, database: database)
                }
            }
            try upsertMetadata("last_server_revision", value: String(revision), database: database, table: "sync_state")
            try execute("COMMIT", database)
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    private func applyRemoteSyncMetadata(_ changes: [SQLiteRemoteSyncChange], database: OpaquePointer) throws {
        for change in changes {
            try executePrepared(
                """
                INSERT INTO sync_records(
                    record_type, record_id, parent_record_id, content_hash, payload_json,
                    server_revision, updated_at, deleted_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(record_type, record_id) DO UPDATE SET
                    parent_record_id = CASE WHEN excluded.server_revision < sync_records.server_revision OR EXISTS (
                        SELECT 1 FROM sync_outbox AS outstanding
                        WHERE outstanding.record_type = excluded.record_type
                          AND outstanding.record_id = excluded.record_id
                          AND outstanding.state IN ('pending', 'in_flight')
                          AND (outstanding.operation != CASE WHEN excluded.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END OR outstanding.content_hash IS NOT excluded.content_hash)
                    ) THEN sync_records.parent_record_id ELSE excluded.parent_record_id END,
                    content_hash = CASE WHEN excluded.server_revision < sync_records.server_revision OR EXISTS (
                        SELECT 1 FROM sync_outbox AS outstanding
                        WHERE outstanding.record_type = excluded.record_type
                          AND outstanding.record_id = excluded.record_id
                          AND outstanding.state IN ('pending', 'in_flight')
                          AND (outstanding.operation != CASE WHEN excluded.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END OR outstanding.content_hash IS NOT excluded.content_hash)
                    ) THEN sync_records.content_hash ELSE excluded.content_hash END,
                    payload_json = CASE WHEN excluded.server_revision < sync_records.server_revision OR EXISTS (
                        SELECT 1 FROM sync_outbox AS outstanding
                        WHERE outstanding.record_type = excluded.record_type
                          AND outstanding.record_id = excluded.record_id
                          AND outstanding.state IN ('pending', 'in_flight')
                          AND (outstanding.operation != CASE WHEN excluded.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END OR outstanding.content_hash IS NOT excluded.content_hash)
                    ) THEN sync_records.payload_json ELSE excluded.payload_json END,
                    server_revision = MAX(sync_records.server_revision, excluded.server_revision),
                    updated_at = excluded.updated_at,
                    deleted_at = CASE WHEN excluded.server_revision < sync_records.server_revision OR EXISTS (
                        SELECT 1 FROM sync_outbox AS outstanding
                        WHERE outstanding.record_type = excluded.record_type
                          AND outstanding.record_id = excluded.record_id
                          AND outstanding.state IN ('pending', 'in_flight')
                          AND (outstanding.operation != CASE WHEN excluded.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END OR outstanding.content_hash IS NOT excluded.content_hash)
                    ) THEN sync_records.deleted_at ELSE excluded.deleted_at END
                """,
                database
            ) { statement in
                try bind(change.recordType, to: statement, at: 1, database)
                try bind(change.recordID, to: statement, at: 2, database)
                try bind(change.parentRecordID, to: statement, at: 3, database)
                try bind(change.contentHash, to: statement, at: 4, database)
                try bind(change.payloadJSON, to: statement, at: 5, database)
                try bind(change.revision, to: statement, at: 6, database)
                try bind(isoString(Date()), to: statement, at: 7, database)
                try bind(change.operation == "delete" ? (change.deletedAt ?? isoString(Date())) : nil, to: statement, at: 8, database)
            }
            try executePrepared(
                """
                UPDATE sync_outbox AS matching
                SET state = 'accepted'
                WHERE state IN ('pending', 'in_flight')
                  AND (state = 'in_flight' OR NOT EXISTS (
                    SELECT 1 FROM sync_outbox AS earlier
                    WHERE earlier.state = 'in_flight'
                      AND earlier.record_type = matching.record_type
                      AND earlier.record_id = matching.record_id
                      AND earlier.id < matching.id
                  ))
                  AND record_type = ?
                  AND record_id = ?
                  AND operation = ?
                  AND ((content_hash IS NULL AND ? IS NULL) OR content_hash = ?)
                """,
                database
            ) { statement in
                try bind(change.recordType, to: statement, at: 1, database)
                try bind(change.recordID, to: statement, at: 2, database)
                try bind(change.operation, to: statement, at: 3, database)
                try bind(change.contentHash, to: statement, at: 4, database)
                try bind(change.contentHash, to: statement, at: 5, database)
            }
            if sqlite3_changes(database) > 0 {
                try rebasePendingSyncChanges(
                    recordType: change.recordType,
                    recordID: change.recordID,
                    revision: change.revision,
                    database: database
                )
            }
        }
    }

    func pendingAttachmentUploads(limit: Int = 50) throws -> [SQLitePendingAttachmentUpload] {
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        return try rows(
            """
            SELECT id, stored_path, original_filename, mime_type, sha256
            FROM attachment_assets
            WHERE upload_state = 'pending' AND sha256 IS NOT NULL
            ORDER BY id ASC
            LIMIT \(max(1, limit))
            """,
            database: database
        ) { statement in
            guard let idText = columnText(statement, 0),
                  let id = UUID(uuidString: idText),
                  let storedPath = columnText(statement, 1),
                  let originalFilename = columnText(statement, 2),
                  let sha256 = columnText(statement, 4) else {
                throw SQLiteJournalStoreError.missingPayload("attachment_assets")
            }
            return SQLitePendingAttachmentUpload(
                assetID: id,
                storedPath: storedPath,
                originalFilename: originalFilename,
                mimeType: columnText(statement, 3),
                sha256: sha256
            )
        }
    }

    func matchingPendingAttachmentUploadEchoIDs(_ changes: [SQLiteRemoteSyncChange]) throws -> Set<UUID> {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        return try matchingPendingAttachmentUploadEchoIDs(changes, database: database)
    }

    private struct AttachmentUploadEcho: Decodable {
        var assetID: UUID
        var sha256: String
        var originalFilename: String
        var contentType: String

        enum CodingKeys: String, CodingKey {
            case assetID = "asset_id"
            case sha256
            case originalFilename = "original_filename"
            case contentType = "content_type"
        }
    }

    private func matchingPendingAttachmentUploadEchoIDs(
        _ changes: [SQLiteRemoteSyncChange],
        database: OpaquePointer
    ) throws -> Set<UUID> {
        var latestByID: [UUID: SQLiteRemoteSyncChange] = [:]
        for change in changes where change.recordType == "attachment_asset" {
            guard let id = UUID(uuidString: change.recordID) else { continue }
            if let existing = latestByID[id], existing.revision >= change.revision { continue }
            latestByID[id] = change
        }
        var matching: Set<UUID> = []
        for (id, change) in latestByID {
            guard change.operation == "upsert", change.revision > 0,
                  let hash = change.contentHash?.lowercased(),
                  hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let payload = change.payloadJSON?.data(using: .utf8),
                  let echo = try? JSONDecoder().decode(AttachmentUploadEcho.self, from: payload),
                  echo.assetID == id, echo.sha256.lowercased() == hash else { continue }
            let matches = try rows(
                """
                SELECT COUNT(*) FROM attachment_assets AS asset
                WHERE asset.id = ? AND asset.upload_state = 'pending'
                  AND LOWER(asset.sha256) = ? AND asset.original_filename = ?
                  AND COALESCE(asset.mime_type, 'application/octet-stream') = ?
                  AND COALESCE((SELECT server_revision FROM sync_records
                      WHERE record_type = 'attachment_asset' AND record_id = asset.id), 0) <= ?
                  AND NOT EXISTS(SELECT 1 FROM sync_outbox
                      WHERE record_type = 'attachment_asset' AND record_id = asset.id
                        AND state IN ('pending', 'in_flight') AND operation = 'delete')
                """,
                database: database,
                bindValues: { statement in
                    try bind(id.uuidString, to: statement, at: 1, database)
                    try bind(hash, to: statement, at: 2, database)
                    try bind(echo.originalFilename, to: statement, at: 3, database)
                    try bind(echo.contentType, to: statement, at: 4, database)
                    try bind(change.revision, to: statement, at: 5, database)
                },
                map: { sqlite3_column_int64($0, 0) }
            ).first ?? 0
            if matches == 1 { matching.insert(id) }
        }
        return matching
    }

    func markAttachmentUploaded(assetID: UUID, serverRevision: Int64? = nil) throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let database = try open()
        defer { sqlite3_close(database) }
        try ensureSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            try markAttachmentUploaded(assetID: assetID, serverRevision: serverRevision, database: database)
            try execute("COMMIT", database)
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    private func markAttachmentUploaded(assetID: UUID, serverRevision: Int64?, database: OpaquePointer) throws {
        try executePrepared(
            "UPDATE attachment_assets SET upload_state = 'uploaded' WHERE id = ?",
            database
        ) { statement in
            try bind(assetID.uuidString, to: statement, at: 1, database)
        }
        try executePrepared(
            """
            UPDATE sync_outbox
            SET state = 'accepted'
            WHERE record_type = 'attachment_asset' AND record_id = ? AND state IN ('pending', 'in_flight')
            """,
            database
        ) { statement in
            try bind(assetID.uuidString, to: statement, at: 1, database)
        }
        if let serverRevision {
            let now = Self.makeISOFormatter().string(from: Date())
            try executePrepared(
                """
                UPDATE sync_records
                SET server_revision = MAX(server_revision, ?), updated_at = ?
                WHERE record_type = 'attachment_asset' AND record_id = ?
                """,
                database
            ) { statement in
                try bind(serverRevision, to: statement, at: 1, database)
                try bind(now, to: statement, at: 2, database)
                try bind(assetID.uuidString, to: statement, at: 3, database)
            }
        }
    }

    private func replaceAppRows(_ data: JournalData, envelopes: [SyncEnvelope], database: OpaquePointer) throws {
        let dateFormatter = Self.makeISOFormatter()
        let now = dateFormatter.string(from: Date())
        var writtenRecurrenceRules: [UUID: RecurrenceRule] = [:]
        let metadata = try JSONEncoder.appEncoder.encode(JournalMetadata(data: data))
        let attachmentUploadStates = try readAttachmentUploadStates(database)
        try upsertMetadata("journal", value: String(decoding: metadata, as: UTF8.self), database: database)

        for table in [
            "ledgers", "commodities", "accounts", "transactions", "postings", "sources",
            "transaction_templates", "posting_templates", "attachment_containers",
            "attachment_assets", "recurrence_rules", "recurrence_ends"
        ] {
            try execute("DELETE FROM \(table)", database)
        }

        for ledger in data.ledgers {
            try executePrepared(
                """
                INSERT INTO ledgers(id, list_index, name, payload_json)
                VALUES (?, ?, ?, ?)
                """,
                database
            ) { statement in
                try bind(ledger.id.uuidString, to: statement, at: 1, database)
                try bind(Int64(ledger.listIndex), to: statement, at: 2, database)
                try bind(ledger.name, to: statement, at: 3, database)
                try bind(encodedString(ledger), to: statement, at: 4, database)
            }
        }

        for commodity in data.commodities {
            try executePrepared(
                """
                INSERT INTO commodities(id, ledger_id, symbol, name, payload_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                database
            ) { statement in
                try bind(commodity.id.uuidString, to: statement, at: 1, database)
                try bind(commodity.ledgerID.uuidString, to: statement, at: 2, database)
                try bind(commodity.symbol, to: statement, at: 3, database)
                try bind(commodity.name, to: statement, at: 4, database)
                try bind(encodedString(commodity), to: statement, at: 5, database)
            }
        }

        for account in data.accounts {
            try executePrepared(
                """
                INSERT INTO accounts(id, ledger_id, parent_id, commodity_id, kind, list_index, name, note, payload_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                database
            ) { statement in
                try bind(account.id.uuidString, to: statement, at: 1, database)
                try bind(account.ledgerID.uuidString, to: statement, at: 2, database)
                try bind(account.parentID?.uuidString, to: statement, at: 3, database)
                try bind(account.commodityID?.uuidString, to: statement, at: 4, database)
                try bind(Int64(account.kind.rawValue), to: statement, at: 5, database)
                try bind(Int64(account.listIndex), to: statement, at: 6, database)
                try bind(account.name, to: statement, at: 7, database)
                try bind(account.note, to: statement, at: 8, database)
                try bind(encodedString(account), to: statement, at: 9, database)
            }
        }

        for source in data.sources {
            try executePrepared(
                """
                INSERT INTO sources(id, ledger_id, type, date, external_id, payload_json)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                database
            ) { statement in
                try bind(source.id.uuidString, to: statement, at: 1, database)
                try bind(source.ledgerID.uuidString, to: statement, at: 2, database)
                try bind(Int64(source.type), to: statement, at: 3, database)
                try bind(isoString(source.date, formatter: dateFormatter), to: statement, at: 4, database)
                try bind(source.externalID, to: statement, at: 5, database)
                try bind(encodedString(source), to: statement, at: 6, database)
            }
        }

        try withPreparedStatement(
            """
            INSERT INTO transactions(
                id, ledger_id, source_id, date, payee, note, number, cleared,
                recurrence_rule_id, attachment_container_id, external_transaction_id, payload_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            database
        ) { transactionStatement in
            try withPreparedStatement(
                """
                INSERT INTO postings(id, transaction_id, account_id, commodity_id, amount, list_index, payload_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                database
            ) { postingStatement in
                for transaction in data.transactions {
                    let recurrenceRuleID = transaction.recurrenceRule?.id
                    let attachmentContainerID = transaction.attachment?.id
                    try executePreparedStatement(transactionStatement, database) { statement in
                        try bind(transaction.id.uuidString, to: statement, at: 1, database)
                        try bind(transaction.ledgerID.uuidString, to: statement, at: 2, database)
                        try bind(transaction.sourceID?.uuidString, to: statement, at: 3, database)
                        try bind(isoString(transaction.date, formatter: dateFormatter), to: statement, at: 4, database)
                        try bind(transaction.payee, to: statement, at: 5, database)
                        try bind(transaction.note, to: statement, at: 6, database)
                        try bind(transaction.number, to: statement, at: 7, database)
                        try bind(transaction.cleared ? Int64(1) : Int64(0), to: statement, at: 8, database)
                        try bind(recurrenceRuleID?.uuidString, to: statement, at: 9, database)
                        try bind(attachmentContainerID?.uuidString, to: statement, at: 10, database)
                        try bind(transaction.externalTransactionID, to: statement, at: 11, database)
                        try bind(encodedString(transaction), to: statement, at: 12, database)
                    }

                    for posting in transaction.postings {
                        try executePreparedStatement(postingStatement, database) { statement in
                            try bind(posting.id.uuidString, to: statement, at: 1, database)
                            try bind(transaction.id.uuidString, to: statement, at: 2, database)
                            try bind(posting.accountID.uuidString, to: statement, at: 3, database)
                            try bind(posting.commodityID?.uuidString, to: statement, at: 4, database)
                            try bind(NSDecimalNumber(decimal: posting.amount).stringValue, to: statement, at: 5, database)
                            try bind(Int64(posting.listIndex), to: statement, at: 6, database)
                            try bind(encodedString(posting), to: statement, at: 7, database)
                        }
                    }

                    if let rule = transaction.recurrenceRule {
                        try upsertRecurrenceRule(rule, writtenRules: &writtenRecurrenceRules, database: database)
                    }
                    if let attachment = transaction.attachment {
                        try upsertAttachmentContainer(
                            attachment,
                            transactionID: transaction.id,
                            previousUploadStates: attachmentUploadStates,
                            database: database
                        )
                    }
                }
            }
        }

        for template in data.transactionTemplates {
            try executePrepared(
                """
                INSERT INTO transaction_templates(id, ledger_id, name, list_index, payload_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                database
            ) { statement in
                try bind(template.id.uuidString, to: statement, at: 1, database)
                try bind(template.ledgerID.uuidString, to: statement, at: 2, database)
                try bind(template.name, to: statement, at: 3, database)
                try bind(Int64(template.listIndex), to: statement, at: 4, database)
                try bind(encodedString(template), to: statement, at: 5, database)
            }

            for posting in template.postings {
                try executePrepared(
                    """
                    INSERT INTO posting_templates(id, template_id, account_id, list_index, payload_json)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    database
                ) { statement in
                    try bind(posting.id.uuidString, to: statement, at: 1, database)
                    try bind(template.id.uuidString, to: statement, at: 2, database)
                    try bind(posting.accountID?.uuidString, to: statement, at: 3, database)
                    try bind(Int64(posting.listIndex), to: statement, at: 4, database)
                    try bind(encodedString(posting), to: statement, at: 5, database)
                }
            }
        }

        try upsertSyncRecords(envelopes: envelopes, now: now, database: database)
    }

    private func upsertSyncRecords(envelopes: [SyncEnvelope], now: String, database: OpaquePointer) throws {
        let idsByKey = Dictionary(uniqueKeysWithValues: envelopes.map { (syncKey(type: $0.type, id: $0.id), $0) })
        for (_, envelope) in idsByKey {
            try executePrepared(
                """
                INSERT INTO sync_records(
                    record_type, record_id, parent_record_id, content_hash, payload_json, updated_at, deleted_at, server_revision
                )
                VALUES (?, ?, ?, ?, ?, ?, NULL, COALESCE(
                    (SELECT server_revision FROM sync_records WHERE record_type = ? AND record_id = ?),
                    0
                ))
                ON CONFLICT(record_type, record_id) DO UPDATE SET
                    parent_record_id = excluded.parent_record_id,
                    content_hash = excluded.content_hash,
                    payload_json = excluded.payload_json,
                    updated_at = excluded.updated_at,
                    deleted_at = NULL
                WHERE sync_records.content_hash IS NOT excluded.content_hash
                   OR sync_records.parent_record_id IS NOT excluded.parent_record_id
                   OR sync_records.payload_json IS NOT excluded.payload_json
                   OR sync_records.deleted_at IS NOT NULL
                """,
                database
            ) { statement in
                try bind(envelope.type, to: statement, at: 1, database)
                try bind(envelope.id.uuidString, to: statement, at: 2, database)
                try bind(envelope.parentID?.uuidString, to: statement, at: 3, database)
                try bind(envelope.hash, to: statement, at: 4, database)
                try bind(String(decoding: envelope.payload, as: UTF8.self), to: statement, at: 5, database)
                try bind(now, to: statement, at: 6, database)
                try bind(envelope.type, to: statement, at: 7, database)
                try bind(envelope.id.uuidString, to: statement, at: 8, database)
            }
        }
    }

    private func upsertRecurrenceRule(
        _ rule: RecurrenceRule,
        writtenRules: inout [UUID: RecurrenceRule],
        database: OpaquePointer
    ) throws {
        // A coherent series shares one identical value across its occurrences.
        // Remember the last successfully written value, not merely the ID: an
        // existing A/B/A input must keep its original ordered last-value behavior.
        guard writtenRules[rule.id] != rule else { return }
        try preserveLegacyEmbeddedRules(beforeReplacing: rule, database: database)
        try upsertRecurrenceRule(rule, database: database)
        writtenRules[rule.id] = rule
    }

    private func preserveLegacyEmbeddedRules(beforeReplacing rule: RecurrenceRule, database: OpaquePointer) throws {
        // Pin the old fallback before changing a shared row. Otherwise untouched
        // legacy occurrences could inherit a different rule on their next load.
        // The check is scoped by indexed rule ID and only runs for rule writes.
        let needsBackfill = try rows("""
            SELECT EXISTS(SELECT 1 FROM recurrence_rules WHERE id = ?)
               AND EXISTS(SELECT 1 FROM transactions WHERE recurrence_rule_id = ?
                          AND json_type(payload_json, '$.recurrenceRule') IS NULL)
            """, database: database, bindValues: { statement in
                try bind(rule.id.uuidString, to: statement, at: 1, database)
                try bind(rule.id.uuidString, to: statement, at: 2, database)
            }, map: { sqlite3_column_int64($0, 0) != 0 }).first ?? false
        guard needsBackfill,
              let old = try readRecurrenceRulesByID(database: database, matching: rule.id)[rule.id], old != rule else { return }
        let payload = try encodedString(old)
        try executePrepared("""
            UPDATE transactions SET payload_json = json_set(payload_json, '$.recurrenceRule', json(?))
            WHERE recurrence_rule_id = ? AND json_type(payload_json, '$.recurrenceRule') IS NULL
            """, database) { statement in
                try bind(payload, to: statement, at: 1, database)
                try bind(rule.id.uuidString, to: statement, at: 2, database)
            }
    }

    private func upsertRecurrenceRule(_ rule: RecurrenceRule, database: OpaquePointer) throws {
        try executePrepared(
            """
            INSERT INTO recurrence_rules(
                id, frequency, interval_value, occurrence_count, end_date, on_workdays, payload_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                frequency = excluded.frequency,
                interval_value = excluded.interval_value,
                occurrence_count = excluded.occurrence_count,
                end_date = excluded.end_date,
                on_workdays = excluded.on_workdays,
                payload_json = excluded.payload_json
            """,
            database
        ) { statement in
            try bind(rule.id.uuidString, to: statement, at: 1, database)
            try bind(rule.frequency.rawValue, to: statement, at: 2, database)
            try bind(Int64(rule.intervalValue), to: statement, at: 3, database)
            try bind(rule.occurrenceCount.map(Int64.init), to: statement, at: 4, database)
            try bind(isoString(rule.endDate), to: statement, at: 5, database)
            try bind(rule.onWorkdays ? Int64(1) : Int64(0), to: statement, at: 6, database)
            try bind(encodedString(rule), to: statement, at: 7, database)
        }

        if rule.occurrenceCount != nil || rule.endDate != nil {
            try executePrepared(
                """
                INSERT INTO recurrence_ends(rule_id, occurrence_count, end_date)
                VALUES (?, ?, ?)
                ON CONFLICT(rule_id) DO UPDATE SET
                    occurrence_count = excluded.occurrence_count,
                    end_date = excluded.end_date
                WHERE recurrence_ends.occurrence_count IS NOT excluded.occurrence_count
                   OR recurrence_ends.end_date IS NOT excluded.end_date
                """,
                database
            ) { statement in
                try bind(rule.id.uuidString, to: statement, at: 1, database)
                try bind(rule.occurrenceCount.map(Int64.init), to: statement, at: 2, database)
                try bind(isoString(rule.endDate), to: statement, at: 3, database)
            }
        } else {
            try executePrepared("DELETE FROM recurrence_ends WHERE rule_id = ?", database) { statement in
                try bind(rule.id.uuidString, to: statement, at: 1, database)
            }
        }
    }

    private func upsertAttachmentContainer(
        _ container: AttachmentContainer,
        transactionID: UUID,
        previousUploadStates: [UUID: AttachmentUploadState],
        database: OpaquePointer
    ) throws {
        try executePrepared(
            """
            INSERT INTO attachment_containers(id, transaction_id, created_at, payload_json)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                transaction_id = excluded.transaction_id,
                created_at = excluded.created_at,
                payload_json = excluded.payload_json
            """,
            database
        ) { statement in
            try bind(container.id.uuidString, to: statement, at: 1, database)
            try bind(transactionID.uuidString, to: statement, at: 2, database)
            try bind(isoString(container.createdAt), to: statement, at: 3, database)
            try bind(encodedString(container), to: statement, at: 4, database)
        }

        for asset in container.assets {
            let previousState = previousUploadStates[asset.id]
            let fileURL = attachmentFileURL(asset.storedPath)
            let fileSize = Self.fileSize(at: fileURL)
            // Reuse the stored hash when the on-disk file still matches what was
            // hashed last time. The model's sizeBytes is unreliable (imports
            // record 0), so compare against the size recorded alongside the
            // previous hash — otherwise every save re-reads and re-hashes every
            // attachment on disk.
            let canReuseHash = previousState?.sha256 != nil &&
                previousState?.storedPath == asset.storedPath &&
                fileSize != nil &&
                fileSize == previousState?.sizeBytes
            let sha256: String?
            let key: String?
            if canReuseHash, let previousState {
                sha256 = previousState.sha256
                key = previousState.r2Key ?? previousState.sha256.map {
                    r2Key(datasetID: nil, assetID: asset.id, sha256: $0, filename: asset.originalFilename)
                }
            } else if let assetData = try? Data(contentsOf: fileURL) {
                sha256 = SHA256.hash(data: assetData).map { String(format: "%02x", Int($0)) }.joined()
                key = sha256.map { r2Key(datasetID: nil, assetID: asset.id, sha256: $0, filename: asset.originalFilename) }
            } else {
                sha256 = nil
                key = nil
            }
            let uploadState: String
            if sha256 == nil {
                uploadState = "missing_local_file"
            } else if previousState?.sha256 == sha256,
                      previousState?.uploadState == "uploaded" {
                uploadState = "uploaded"
            } else {
                uploadState = "pending"
            }
            try executePrepared(
                """
                INSERT INTO attachment_assets(
                    id, container_id, transaction_id, original_filename, stored_path, mime_type,
                    size_bytes, sha256, r2_key, upload_state, payload_json
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    container_id = excluded.container_id,
                    transaction_id = excluded.transaction_id,
                    original_filename = excluded.original_filename,
                    stored_path = excluded.stored_path,
                    mime_type = excluded.mime_type,
                    size_bytes = excluded.size_bytes,
                    sha256 = excluded.sha256,
                    r2_key = excluded.r2_key,
                    upload_state = excluded.upload_state,
                    payload_json = excluded.payload_json
                """,
                database
            ) { statement in
                try bind(asset.id.uuidString, to: statement, at: 1, database)
                try bind(container.id.uuidString, to: statement, at: 2, database)
                try bind(transactionID.uuidString, to: statement, at: 3, database)
                try bind(asset.originalFilename, to: statement, at: 4, database)
                try bind(asset.storedPath, to: statement, at: 5, database)
                try bind(asset.mimeType, to: statement, at: 6, database)
                try bind(fileSize ?? asset.sizeBytes, to: statement, at: 7, database)
                try bind(sha256, to: statement, at: 8, database)
                try bind(key, to: statement, at: 9, database)
                try bind(uploadState, to: statement, at: 10, database)
                try bind(encodedString(asset), to: statement, at: 11, database)
            }
        }
    }

    private func syncEnvelopes(for data: JournalData) throws -> [SyncEnvelope] {
        var envelopes: [SyncEnvelope] = []
        try envelopes.append(envelope(
            "journal_metadata",
            id: SQLiteSyncedJournalMetadata.recordID,
            parentID: nil,
            payload: SQLiteSyncedJournalMetadata(data: data)
        ))
        try envelopes.append(contentsOf: data.ledgers.map { try envelope("ledger", id: $0.id, parentID: nil, payload: $0) })
        try envelopes.append(contentsOf: data.commodities.map { try envelope("commodity", id: $0.id, parentID: $0.ledgerID, payload: $0) })
        try envelopes.append(contentsOf: data.accounts.map { try envelope("account", id: $0.id, parentID: $0.parentID ?? $0.ledgerID, payload: $0) })
        try envelopes.append(contentsOf: data.sources.map { try envelope("source", id: $0.id, parentID: $0.ledgerID, payload: $0) })
        for transaction in data.transactions {
            try envelopes.append(envelope("transaction", id: transaction.id, parentID: transaction.ledgerID, payload: transaction))
            if let container = transaction.attachment {
                try envelopes.append(contentsOf: container.assets.map {
                    try envelope("attachment_asset", id: $0.id, parentID: container.id, payload: $0)
                })
            }
        }
        for template in data.transactionTemplates {
            try envelopes.append(envelope("transaction_template", id: template.id, parentID: template.ledgerID, payload: template))
        }
        var seen: Set<String> = []
        return envelopes.filter { envelope in
            seen.insert(syncKey(type: envelope.type, id: envelope.id)).inserted
        }
    }

    private func envelope<T: Encodable>(_ type: String, id: UUID, parentID: UUID?, payload: T) throws -> SyncEnvelope {
        let data = try JSONEncoder.appEncoder.encode(payload)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
        return SyncEnvelope(type: type, id: id, parentID: parentID, payload: data, hash: hash)
    }

    private func updateSyncRows(
        envelopes: [SyncEnvelope],
        previousRows: [String: String],
        database: OpaquePointer
    ) throws {
        let now = Self.makeISOFormatter().string(from: Date())
        var pendingClientChangeIDs = try readPendingOutboxClientChangeIDs(database)
        try upsertSyncOutboxRows(
            envelopes: envelopes,
            previousRows: previousRows,
            pendingClientChangeIDs: &pendingClientChangeIDs,
            now: now,
            database: database
        )
        let currentKeys = Set(envelopes.map { syncKey(type: $0.type, id: $0.id) })
        var deletedKeys: [(type: String, id: String, hash: String)] = []
        for (key, hash) in previousRows where !currentKeys.contains(key) {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            deletedKeys.append((type: parts[0], id: parts[1], hash: hash))
        }
        try tombstoneSyncRecords(
            deletedKeys: deletedKeys,
            pendingClientChangeIDs: &pendingClientChangeIDs,
            now: now,
            database: database
        )
    }

    private func upsertSyncOutboxRows(
        envelopes: [SyncEnvelope],
        previousRows: [String: String],
        pendingClientChangeIDs: inout [String: String],
        now: String,
        database: OpaquePointer
    ) throws {
        let current = Dictionary(uniqueKeysWithValues: envelopes.map { (syncKey(type: $0.type, id: $0.id), $0) })
        for (key, envelope) in current where previousRows[key] != envelope.hash {
            let payloadJSON = String(decoding: envelope.payload, as: UTF8.self)
            if let pendingID = pendingClientChangeIDs[key] {
                try executePrepared(
                    """
                    UPDATE sync_outbox
                    SET operation = 'upsert', content_hash = ?, payload_json = ?, created_at = ?, state = 'pending'
                    WHERE client_change_id = ?
                    """,
                    database
                ) { statement in
                    try bind(envelope.hash, to: statement, at: 1, database)
                    try bind(payloadJSON, to: statement, at: 2, database)
                    try bind(now, to: statement, at: 3, database)
                    try bind(pendingID, to: statement, at: 4, database)
                }
            } else {
                let clientChangeID = UUID().uuidString
                try executePrepared(
                    """
                    INSERT INTO sync_outbox(client_change_id, record_type, record_id, operation, base_revision, content_hash, payload_json, created_at, state)
                    VALUES (?, ?, ?, 'upsert',
                        COALESCE((SELECT server_revision FROM sync_records WHERE record_type = ? AND record_id = ?), 0),
                        ?, ?, ?, 'pending'
                    )
                    """,
                    database
                ) { statement in
                    try bind(clientChangeID, to: statement, at: 1, database)
                    try bind(envelope.type, to: statement, at: 2, database)
                    try bind(envelope.id.uuidString, to: statement, at: 3, database)
                    try bind(envelope.type, to: statement, at: 4, database)
                    try bind(envelope.id.uuidString, to: statement, at: 5, database)
                    try bind(envelope.hash, to: statement, at: 6, database)
                    try bind(payloadJSON, to: statement, at: 7, database)
                    try bind(now, to: statement, at: 8, database)
                }
                pendingClientChangeIDs[key] = clientChangeID
            }
        }
    }

    private func tombstoneSyncRecords(
        deletedKeys: [(type: String, id: String, hash: String)],
        pendingClientChangeIDs: inout [String: String],
        now: String,
        database: OpaquePointer
    ) throws {
        for (recordType, recordID, hash) in deletedKeys {
            let key = "\(recordType):\(recordID)"
            try executePrepared(
                """
                INSERT INTO sync_tombstones(record_type, record_id, content_hash, deleted_at, server_revision)
                VALUES (?, ?, ?, ?, COALESCE(
                    (SELECT server_revision FROM sync_records WHERE record_type = ? AND record_id = ?),
                    0
                ))
                ON CONFLICT(record_type, record_id) DO UPDATE SET
                    content_hash = excluded.content_hash,
                    deleted_at = excluded.deleted_at,
                    server_revision = excluded.server_revision
                """,
                database
            ) { statement in
                try bind(recordType, to: statement, at: 1, database)
                try bind(recordID, to: statement, at: 2, database)
                try bind(hash, to: statement, at: 3, database)
                try bind(now, to: statement, at: 4, database)
                try bind(recordType, to: statement, at: 5, database)
                try bind(recordID, to: statement, at: 6, database)
            }
            if let pendingID = pendingClientChangeIDs[key] {
                try executePrepared(
                    """
                    UPDATE sync_outbox
                    SET operation = 'delete', content_hash = ?, payload_json = NULL, created_at = ?, state = 'pending'
                    WHERE client_change_id = ?
                    """,
                    database
                ) { statement in
                    try bind(hash, to: statement, at: 1, database)
                    try bind(now, to: statement, at: 2, database)
                    try bind(pendingID, to: statement, at: 3, database)
                }
            } else {
                let clientChangeID = UUID().uuidString
                try executePrepared(
                    """
                    INSERT INTO sync_outbox(client_change_id, record_type, record_id, operation, base_revision, content_hash, payload_json, created_at, state)
                    VALUES (?, ?, ?, 'delete',
                        COALESCE((SELECT server_revision FROM sync_records WHERE record_type = ? AND record_id = ?), 0),
                        ?, NULL, ?, 'pending'
                    )
                    """,
                    database
                ) { statement in
                    try bind(clientChangeID, to: statement, at: 1, database)
                    try bind(recordType, to: statement, at: 2, database)
                    try bind(recordID, to: statement, at: 3, database)
                    try bind(recordType, to: statement, at: 4, database)
                    try bind(recordID, to: statement, at: 5, database)
                    try bind(hash, to: statement, at: 6, database)
                    try bind(now, to: statement, at: 7, database)
                }
                pendingClientChangeIDs[key] = clientChangeID
            }
            try executePrepared(
                "UPDATE sync_records SET deleted_at = ? WHERE record_type = ? AND record_id = ?",
                database
            ) { statement in
                try bind(now, to: statement, at: 1, database)
                try bind(recordType, to: statement, at: 2, database)
                try bind(recordID, to: statement, at: 3, database)
            }
        }
    }

    private func readPendingOutboxClientChangeIDs(_ database: OpaquePointer) throws -> [String: String] {
        let rows: [(String, String)] = try rows(
            """
            SELECT record_type, record_id, client_change_id
            FROM sync_outbox
            WHERE state = 'pending'
            ORDER BY id DESC
            """,
            database: database
        ) { statement in
            guard let type = columnText(statement, 0),
                  let id = columnText(statement, 1),
                  let clientChangeID = columnText(statement, 2) else {
                throw SQLiteJournalStoreError.missingPayload("sync_outbox")
            }
            return ("\(type):\(id)", clientChangeID)
        }
        return rows.reduce(into: [:]) { partial, row in
            if partial[row.0] == nil {
                partial[row.0] = row.1
            }
        }
    }

    private func readPendingOutboxClientChangeIDs(
        forKeys keys: [(type: String, id: String)],
        database: OpaquePointer
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        let idsByType = Dictionary(grouping: keys, by: \.type).mapValues { Array(Set($0.map(\.id))) }
        for (type, ids) in idsByType {
            for start in stride(from: 0, to: ids.count, by: 200) {
                let chunk = Array(ids[start..<min(start + 200, ids.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let pending = try rows(
                    """
                    SELECT record_id, client_change_id FROM sync_outbox
                    WHERE state = 'pending' AND record_type = ? AND record_id IN (\(placeholders))
                    ORDER BY id DESC
                    """,
                    database: database,
                    bindValues: { statement in
                        try bind(type, to: statement, at: 1, database)
                        for (offset, id) in chunk.enumerated() {
                            try bind(id, to: statement, at: Int32(offset + 2), database)
                        }
                    }
                ) { statement -> (String, String) in
                    guard let id = columnText(statement, 0), let clientID = columnText(statement, 1) else {
                        throw SQLiteJournalStoreError.missingPayload("sync_outbox")
                    }
                    return (id, clientID)
                }
                for (id, clientID) in pending where result["\(type):\(id)"] == nil {
                    result["\(type):\(id)"] = clientID
                }
            }
        }
        return result
    }

    private func readSyncHashes(_ database: OpaquePointer) throws -> [String: String] {
        let rows: [(String, String)] = try rows(
            "SELECT record_type, record_id, content_hash FROM sync_records WHERE deleted_at IS NULL",
            database: database
        ) { statement in
            guard let type = columnText(statement, 0),
                  let id = columnText(statement, 1),
                  let hash = columnText(statement, 2) else {
                throw SQLiteJournalStoreError.missingPayload("sync_records")
            }
            return ("\(type):\(id)", hash)
        }
        return rows.reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    /// Sync keys (type + id) for every record a diff touches, including
    /// deletions — the exact probe set `applyDiff` needs from `sync_records`.
    private func diffSyncKeys(_ diff: JournalDataDiff) -> [(type: String, id: String)] {
        var keys: [(type: String, id: String)] = []
        if diff.syncedMetadataChanged {
            keys.append(("journal_metadata", SQLiteSyncedJournalMetadata.recordID.uuidString))
        }
        func add(_ type: String, changedIDs: [UUID], deletedIDs: [UUID]) {
            for id in changedIDs { keys.append((type, id.uuidString)) }
            for id in deletedIDs { keys.append((type, id.uuidString)) }
        }
        add("ledger", changedIDs: diff.ledgersChanged.map(\.id), deletedIDs: diff.ledgerIDsDeleted)
        add("commodity", changedIDs: diff.commoditiesChanged.map(\.id), deletedIDs: diff.commodityIDsDeleted)
        add("account", changedIDs: diff.accountsChanged.map(\.id), deletedIDs: diff.accountIDsDeleted)
        add("source", changedIDs: diff.sourcesChanged.map(\.id), deletedIDs: diff.sourceIDsDeleted)
        add("transaction", changedIDs: diff.transactionsChanged.map(\.id), deletedIDs: diff.transactionIDsDeleted)
        add("transaction_template", changedIDs: diff.templatesChanged.map(\.id), deletedIDs: diff.templateIDsDeleted)
        var assetIDs = diff.attachmentAssetIDsDeleted
        for transaction in diff.transactionsChanged where !diff.transactionAttachmentsUnchanged.contains(transaction.id) {
            assetIDs.append(contentsOf: (transaction.attachment?.assets ?? []).map(\.id))
        }
        add("attachment_asset", changedIDs: assetIDs, deletedIDs: [])
        return keys
    }

    private func readSyncHashes(
        forKeys keys: [(type: String, id: String)],
        database: OpaquePointer
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        let idsByType = Dictionary(grouping: keys, by: \.type).mapValues { $0.map(\.id) }
        for (type, ids) in idsByType {
            for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let rows: [(String, String)] = try rows(
                    """
                    SELECT record_id, content_hash FROM sync_records
                    WHERE deleted_at IS NULL AND record_type = ? AND record_id IN (\(placeholders))
                    """,
                    database: database,
                    bindValues: { statement in
                        try bind(type, to: statement, at: 1, database)
                        for (offset, id) in chunk.enumerated() {
                            try bind(id, to: statement, at: Int32(offset + 2), database)
                        }
                    }
                ) { statement in
                    guard let id = columnText(statement, 0), let hash = columnText(statement, 1) else {
                        throw SQLiteJournalStoreError.missingPayload("sync_records")
                    }
                    return (id, hash)
                }
                for (id, hash) in rows {
                    result["\(type):\(id)"] = hash
                }
            }
        }
        return result
    }

    private func readAttachmentUploadStates(
        forAssetIDs assetIDs: [UUID],
        database: OpaquePointer
    ) throws -> [UUID: AttachmentUploadState] {
        var result: [UUID: AttachmentUploadState] = [:]
        let ids = assetIDs.map(\.uuidString)
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows: [(UUID, AttachmentUploadState)] = try rows(
                "SELECT id, sha256, stored_path, size_bytes, r2_key, upload_state FROM attachment_assets WHERE id IN (\(placeholders))",
                database: database,
                bindValues: { statement in
                    for (offset, id) in chunk.enumerated() {
                        try bind(id, to: statement, at: Int32(offset + 1), database)
                    }
                }
            ) { statement in
                guard let idText = columnText(statement, 0),
                      let id = UUID(uuidString: idText),
                      let storedPath = columnText(statement, 2),
                      let uploadState = columnText(statement, 5) else {
                    throw SQLiteJournalStoreError.missingPayload("attachment_assets")
                }
                return (id, AttachmentUploadState(
                    sha256: columnText(statement, 1),
                    storedPath: storedPath,
                    sizeBytes: sqlite3_column_int64(statement, 3),
                    r2Key: columnText(statement, 4),
                    uploadState: uploadState
                ))
            }
            for (id, state) in rows {
                result[id] = state
            }
        }
        return result
    }

    private func pruneRedundantSyncRows(_ database: OpaquePointer) throws {
        let quotedTypes = Self.redundantSyncRecordTypes
            .map { "'\($0)'" }
            .joined(separator: ", ")
        guard !quotedTypes.isEmpty else { return }
        try execute("DELETE FROM sync_outbox WHERE record_type IN (\(quotedTypes))", database)
        try execute("DELETE FROM sync_records WHERE record_type IN (\(quotedTypes))", database)
        try execute("DELETE FROM sync_tombstones WHERE record_type IN (\(quotedTypes))", database)
        try execute("DELETE FROM sync_conflicts WHERE record_type IN (\(quotedTypes))", database)
    }

    private func readAttachmentUploadStates(_ database: OpaquePointer) throws -> [UUID: AttachmentUploadState] {
        let rows: [(UUID, AttachmentUploadState)] = try rows(
            "SELECT id, sha256, stored_path, size_bytes, r2_key, upload_state FROM attachment_assets",
            database: database
        ) { statement in
            guard let idText = columnText(statement, 0),
                  let id = UUID(uuidString: idText),
                  let storedPath = columnText(statement, 2),
                  let uploadState = columnText(statement, 5) else {
                throw SQLiteJournalStoreError.missingPayload("attachment_assets")
            }
            return (id, AttachmentUploadState(
                sha256: columnText(statement, 1),
                storedPath: storedPath,
                sizeBytes: sqlite3_column_int64(statement, 3),
                r2Key: columnText(statement, 4),
                uploadState: uploadState
            ))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private func readPayloads<T: Decodable>(_ table: String, database: OpaquePointer) throws -> [T] {
        try rows("SELECT payload_json FROM \(table)", database: database) { statement in
            guard let payload = columnData(statement, 0) else {
                throw SQLiteJournalStoreError.missingPayload(table)
            }
            return try JSONDecoder.appDecoder.decode(T.self, from: payload)
        }
    }

    /// Row-level fields of one transaction before its postings, recurrence
    /// rule, and attachment container are joined in.
    private struct TransactionRowRecord {
        let id: UUID
        let ledgerID: UUID
        let sourceID: UUID?
        let date: Date
        let payee: String
        let note: String
        let number: String
        let cleared: Bool
        let recurrenceRuleID: UUID?
        let embeddedRecurrenceRule: RecurrenceRule?
        let attachmentContainerID: UUID?
        let externalTransactionID: String?
    }

    private struct RawPostingRow: Sendable {
        let transactionID: String?
        let id: String?
        let accountID: String?
        let commodityID: String?
        let amount: String?
        let listIndex: Int
    }

    private struct RawAttachmentRow: Sendable {
        let id: String?
        let payload: Data?
    }

    private struct RawTransactionRow: Sendable {
        let id: String?
        let ledgerID: String?
        let sourceID: String?
        let date: String?
        let payee: String
        let note: String
        let number: String
        let cleared: Bool
        let recurrenceRuleID: String?
        let recurrencePayload: Data?
        let attachmentContainerID: String?
        let externalTransactionID: String?
    }

    /// Current writers serialize the exact rule inside each transaction. The
    /// shared rule table is retained for old rows lacking that field, but must
    /// not overwrite per-record truth during a partial or conflicting sync.
    /// Extract only recurring JSON; ordinary rows keep their typed fast path.
    private static let transactionSnapshotSQL = """
        SELECT id, ledger_id, source_id, date, payee, note, number, cleared,
               recurrence_rule_id, attachment_container_id, external_transaction_id,
               CASE WHEN recurrence_rule_id IS NULL THEN NULL
                    WHEN json_type(payload_json, '$.recurrenceRule') IS NULL THEN NULL
                    WHEN json_type(payload_json, '$.recurrenceRule') = 'null' THEN 'null'
                    ELSE json_extract(payload_json, '$.recurrenceRule') END
        FROM transactions
        """

    private struct RecurrencePayloadDecoder {
        private let decoder = JSONDecoder.makeAppDecoder()
        private var cached: [Data: RecurrenceRule] = [:]
        private var cachedBytes = 0
        private static let maximumBytes = 4 * 1024 * 1024
        private static let maximumEntries = 256

        mutating func decode(_ payload: Data?, matching id: UUID?) throws -> RecurrenceRule? {
            guard let payload else { return nil }
            let rule: RecurrenceRule
            if let existing = cached[payload] { rule = existing }
            else {
                rule = try decoder.decode(RecurrenceRule.self, from: payload)
                if payload.count <= Self.maximumBytes {
                    if cached.count >= Self.maximumEntries || cachedBytes + payload.count > Self.maximumBytes {
                        cached.removeAll(keepingCapacity: true)
                        cachedBytes = 0
                    }
                    cached[payload] = rule
                    cachedBytes += payload.count
                }
            }
            guard rule.id == id else {
                throw SQLiteJournalStoreError.missingPayload("transactions.recurrenceRule identity")
            }
            return rule
        }
    }

    private enum SnapshotBufferLimit: Error { case exceeded }

    /// Bounds temporary raw buffers independently of the final journal model.
    /// The estimate includes spare array capacity, retained UTF-8, and per-value
    /// allocation overhead. Oversized input uses the typed same-snapshot reader.
    private struct SnapshotBufferBudget {
        var remaining: Int

        mutating func consume<T>(rowType: T.Type, strings: [String?], payloadBytes: Int = 0) throws {
            var bytes = MemoryLayout<T>.stride * 2 + payloadBytes
            for value in strings {
                if let value { bytes += value.utf8.count + 32 }
            }
            guard bytes <= remaining else { throw SnapshotBufferLimit.exceeded }
            remaining -= bytes
        }
    }

    /// Each worker writes one distinct result slot, and concurrentPerform joins
    /// before any slot is read. Only immutable Swift values cross this boundary;
    /// the SQLite connection and statement pointers remain on the caller.
    private final class SnapshotDecodeWork: @unchecked Sendable {
        let postings: [RawPostingRow]
        let attachments: [RawAttachmentRow]
        let transactions: [RawTransactionRow]
        var decodedPostings: Result<[UUID: [Posting]], Error>?
        var decodedAttachments: Result<[UUID: AttachmentContainer], Error>?
        var decodedTransactions: Result<[TransactionRowRecord], Error>?

        init(postings: [RawPostingRow], attachments: [RawAttachmentRow], transactions: [RawTransactionRow]) {
            self.postings = postings
            self.attachments = attachments
            self.transactions = transactions
        }
    }

    private func readTransactionComponents(
        database: OpaquePointer,
        maximumBufferBytes: Int
    ) throws -> (postings: [UUID: [Posting]], attachments: [UUID: AttachmentContainer], rows: [TransactionRowRecord]) {
        do {
            return try readBufferedTransactionComponents(database: database, maximumBufferBytes: maximumBufferBytes)
        } catch SnapshotBufferLimit.exceeded {
            // A partial raw scan was finalized and released on unwinding. The
            // fallback reads the SAME transaction snapshot, so outside writers
            // cannot change its view between the component queries.
            var mark = StartupTiming.now()
            let postings = try readPostingsByTransaction(database: database)
            let attachments = try readAttachmentsByID(database: database, decoder: JSONDecoder.makeAppDecoder())
            let transactionRows = try readTransactionRows(database: database)
            StartupTiming.log("load-store.transactions.bounded-fallback", from: &mark)
            return (postings, attachments, transactionRows)
        }
    }

    private func readBufferedTransactionComponents(
        database: OpaquePointer,
        maximumBufferBytes: Int
    ) throws -> (postings: [UUID: [Posting]], attachments: [UUID: AttachmentContainer], rows: [TransactionRowRecord]) {
        var mark = StartupTiming.now()
        var budget = SnapshotBufferBudget(remaining: max(0, maximumBufferBytes))
        let postings = try rows(
            "SELECT transaction_id, id, account_id, commodity_id, amount, list_index FROM postings ORDER BY transaction_id, list_index",
            database: database
        ) { statement in
            let row = RawPostingRow(
                transactionID: columnText(statement, 0), id: columnText(statement, 1),
                accountID: columnText(statement, 2), commodityID: columnText(statement, 3),
                amount: columnText(statement, 4), listIndex: Int(sqlite3_column_int64(statement, 5))
            )
            try budget.consume(rowType: RawPostingRow.self, strings: [row.transactionID, row.id, row.accountID, row.commodityID, row.amount])
            return row
        }
        StartupTiming.log("load-store.transactions.raw-postings", from: &mark)
        let attachments = try rows("SELECT id, payload_json FROM attachment_containers", database: database) { statement in
            let row = RawAttachmentRow(id: columnText(statement, 0), payload: columnData(statement, 1))
            try budget.consume(rowType: RawAttachmentRow.self, strings: [row.id], payloadBytes: row.payload?.count ?? 0)
            return row
        }
        StartupTiming.log("load-store.transactions.raw-attachments", from: &mark)
        let transactionRows = try rows(
            Self.transactionSnapshotSQL,
            database: database
        ) { statement in
            let row = RawTransactionRow(
                id: columnText(statement, 0), ledgerID: columnText(statement, 1),
                sourceID: columnText(statement, 2), date: columnText(statement, 3),
                payee: columnText(statement, 4) ?? "", note: columnText(statement, 5) ?? "",
                number: columnText(statement, 6) ?? "", cleared: sqlite3_column_int64(statement, 7) != 0,
                recurrenceRuleID: columnText(statement, 8), recurrencePayload: columnData(statement, 11),
                attachmentContainerID: columnText(statement, 9),
                externalTransactionID: columnText(statement, 10)
            )
            try budget.consume(rowType: RawTransactionRow.self, strings: [row.id, row.ledgerID, row.sourceID, row.date, row.payee, row.note, row.number, row.recurrenceRuleID, row.attachmentContainerID, row.externalTransactionID], payloadBytes: row.recurrencePayload?.count ?? 0)
            return row
        }
        StartupTiming.log("load-store.transactions.raw-rows", from: &mark)

        let work = SnapshotDecodeWork(postings: postings, attachments: attachments, transactions: transactionRows)
        let decode: @Sendable (Int) -> Void = { index in
            switch index {
            case 0: work.decodedPostings = Result { try self.decodePostingRows(work.postings) }
            case 1: work.decodedAttachments = Result { try self.decodeAttachmentRows(work.attachments) }
            default: work.decodedTransactions = Result { try self.decodeTransactionRows(work.transactions) }
            }
        }
        if postings.count + attachments.count + transactionRows.count < 512 {
            for index in 0..<3 { decode(index) }
        } else {
            DispatchQueue.concurrentPerform(iterations: 3, execute: decode)
        }
        StartupTiming.log("load-store.transactions.decode-components", from: &mark)
        guard let decodedPostings = work.decodedPostings,
              let decodedAttachments = work.decodedAttachments,
              let decodedTransactions = work.decodedTransactions else {
            throw SQLiteJournalStoreError.stepFailed("Transaction snapshot decoding did not complete.")
        }
        return try (decodedPostings.get(), decodedAttachments.get(), decodedTransactions.get())
    }

    private func decodePostingRows(_ input: [RawPostingRow]) throws -> [UUID: [Posting]] {
        let decoded: [(UUID, Posting)] = try input.map { row in
            let transactionID = try requiredUUID(row.transactionID, table: "postings", column: "transaction_id")
            return (transactionID, Posting(
                id: try requiredUUID(row.id, table: "postings", column: "id"),
                accountID: try requiredUUID(row.accountID, table: "postings", column: "account_id"),
                commodityID: try optionalUUID(row.commodityID, table: "postings", column: "commodity_id"),
                amount: try requiredDecimal(row.amount, table: "postings", column: "amount"),
                listIndex: row.listIndex
            ))
        }
        return Dictionary(grouping: decoded, by: \.0).mapValues { $0.map(\.1) }
    }

    private func decodeAttachmentRows(_ input: [RawAttachmentRow]) throws -> [UUID: AttachmentContainer] {
        let decoder = JSONDecoder.makeAppDecoder()
        return try Dictionary(uniqueKeysWithValues: input.map { row in
            let id = try requiredUUID(row.id, table: "attachment_containers", column: "id")
            guard let payload = row.payload else {
                throw SQLiteJournalStoreError.missingPayload("attachment_containers.payload_json")
            }
            return (id, try decoder.decode(AttachmentContainer.self, from: payload))
        })
    }

    private func decodeTransactionRows(_ input: [RawTransactionRow]) throws -> [TransactionRowRecord] {
        var recurrenceDecoder = RecurrencePayloadDecoder()
        return try input.map { row in
            let ruleID = try optionalUUID(row.recurrenceRuleID, table: "transactions", column: "recurrence_rule_id")
            return TransactionRowRecord(
                id: try requiredUUID(row.id, table: "transactions", column: "id"),
                ledgerID: try requiredUUID(row.ledgerID, table: "transactions", column: "ledger_id"),
                sourceID: try optionalUUID(row.sourceID, table: "transactions", column: "source_id"),
                date: try requiredDate(row.date, table: "transactions", column: "date"),
                payee: row.payee, note: row.note, number: row.number, cleared: row.cleared,
                recurrenceRuleID: ruleID,
                embeddedRecurrenceRule: try recurrenceDecoder.decode(row.recurrencePayload, matching: ruleID),
                attachmentContainerID: try optionalUUID(row.attachmentContainerID, table: "transactions", column: "attachment_container_id"),
                externalTransactionID: row.externalTransactionID
            )
        }
    }

    /// Reads all register components through the caller's SQLite snapshot.
    private func readTransactions(database: OpaquePointer, maximumBufferBytes: Int) throws -> [LedgerTransaction] {
        var mark = StartupTiming.now()
        let (postingsByTransaction, attachmentsByID, rows) = try readTransactionComponents(
            database: database, maximumBufferBytes: maximumBufferBytes
        )
        let needsLegacyRules = rows.contains { $0.recurrenceRuleID != nil && $0.embeddedRecurrenceRule == nil }
        let recurrenceRulesByID: [UUID: RecurrenceRule] = needsLegacyRules
            ? try readRecurrenceRulesByID(database: database) : [:]
        StartupTiming.log("load-store.transactions.snapshot-scans", from: &mark)
        defer { StartupTiming.log("load-store.transactions.assemble", from: &mark) }

        return try rows.map { row in
            let recurrenceRule: RecurrenceRule?
            if let embeddedRule = row.embeddedRecurrenceRule {
                recurrenceRule = embeddedRule
            } else if let recurrenceRuleID = row.recurrenceRuleID {
                guard let rule = recurrenceRulesByID[recurrenceRuleID] else {
                    throw SQLiteJournalStoreError.missingPayload("recurrence_rules:\(recurrenceRuleID)")
                }
                recurrenceRule = rule
            } else {
                recurrenceRule = nil
            }
            let attachment: AttachmentContainer?
            if let attachmentContainerID = row.attachmentContainerID {
                guard let container = attachmentsByID[attachmentContainerID] else {
                    throw SQLiteJournalStoreError.missingPayload("attachment_containers:\(attachmentContainerID)")
                }
                attachment = container
            } else {
                attachment = nil
            }
            return LedgerTransaction(
                id: row.id,
                ledgerID: row.ledgerID,
                sourceID: row.sourceID,
                date: row.date,
                payee: row.payee,
                note: row.note,
                number: row.number,
                cleared: row.cleared,
                postings: postingsByTransaction[row.id] ?? [],
                recurrenceRule: recurrenceRule,
                attachment: attachment,
                externalTransactionID: row.externalTransactionID
            )
        }
    }

    private func readTransactionRows(database: OpaquePointer) throws -> [TransactionRowRecord] {
        var recurrenceDecoder = RecurrencePayloadDecoder()
        return try rows(
            Self.transactionSnapshotSQL,
            database: database
        ) { statement in
            let ruleID = try optionalUUID(columnText(statement, 8), table: "transactions", column: "recurrence_rule_id")
            return TransactionRowRecord(
                id: try requiredUUID(columnText(statement, 0), table: "transactions", column: "id"),
                ledgerID: try requiredUUID(columnText(statement, 1), table: "transactions", column: "ledger_id"),
                sourceID: try optionalUUID(columnText(statement, 2), table: "transactions", column: "source_id"),
                date: try requiredDate(columnText(statement, 3), table: "transactions", column: "date"),
                payee: columnText(statement, 4) ?? "",
                note: columnText(statement, 5) ?? "",
                number: columnText(statement, 6) ?? "",
                cleared: sqlite3_column_int64(statement, 7) != 0,
                recurrenceRuleID: ruleID,
                embeddedRecurrenceRule: try recurrenceDecoder.decode(columnData(statement, 11), matching: ruleID),
                attachmentContainerID: try optionalUUID(columnText(statement, 9), table: "transactions", column: "attachment_container_id"),
                externalTransactionID: columnText(statement, 10)
            )
        }
    }

    private func readPostingsByTransaction(database: OpaquePointer) throws -> [UUID: [Posting]] {
        let rows: [(UUID, Posting)] = try rows(
            """
            SELECT transaction_id, id, account_id, commodity_id, amount, list_index
            FROM postings
            ORDER BY transaction_id, list_index
            """,
            database: database
        ) { statement in
            let transactionID = try requiredUUID(columnText(statement, 0), table: "postings", column: "transaction_id")
            let posting = Posting(
                id: try requiredUUID(columnText(statement, 1), table: "postings", column: "id"),
                accountID: try requiredUUID(columnText(statement, 2), table: "postings", column: "account_id"),
                commodityID: try optionalUUID(columnText(statement, 3), table: "postings", column: "commodity_id"),
                amount: try requiredDecimal(columnText(statement, 4), table: "postings", column: "amount"),
                listIndex: Int(sqlite3_column_int64(statement, 5))
            )
            return (transactionID, posting)
        }
        return Dictionary(grouping: rows, by: \.0).mapValues { entries in entries.map(\.1) }
    }

    private func readRecurrenceRulesByID(database: OpaquePointer, matching requestedRuleID: UUID? = nil) throws -> [UUID: RecurrenceRule] {
        // Schedule columns remain authoritative. Template history has no typed
        // column, so recover it once per rule from the persisted JSON payload.
        // Missing history is valid for older journals; malformed history must
        // fail loading rather than silently lose future-series edits.
        struct HistoryPayload: Decodable {
            var templateHistory: RecurrenceTemplateHistory?
            var preservesImportedMaterializations: Bool?
            var continuation: RecurrenceContinuation?
        }
        let decoder = JSONDecoder.makeAppDecoder()
        let filter = requestedRuleID == nil ? "" : " WHERE id = ?"
        let rows: [(UUID, RecurrenceRule)] = try rows(
            """
            SELECT id, frequency, interval_value, occurrence_count, end_date, on_workdays, payload_json
            FROM recurrence_rules\(filter)
            """,
            database: database,
            bindValues: { statement in
                if let requestedRuleID { try bind(requestedRuleID.uuidString, to: statement, at: 1, database) }
            }
        ) { statement in
            let id = try requiredUUID(columnText(statement, 0), table: "recurrence_rules", column: "id")
            guard let frequencyText = columnText(statement, 1),
                  let frequency = RecurrenceFrequency(rawValue: frequencyText) else {
                throw SQLiteJournalStoreError.missingPayload("recurrence_rules.frequency")
            }
            let occurrenceCount: Int?
            if sqlite3_column_type(statement, 3) == SQLITE_NULL {
                occurrenceCount = nil
            } else {
                occurrenceCount = Int(sqlite3_column_int64(statement, 3))
            }
            guard let payload = columnData(statement, 6) else {
                throw SQLiteJournalStoreError.missingPayload("recurrence_rules.payload_json")
            }
            let saved = try decoder.decode(HistoryPayload.self, from: payload)
            return (
                id,
                RecurrenceRule(
                    id: id,
                    frequency: frequency,
                    intervalValue: Int(sqlite3_column_int64(statement, 2)),
                    occurrenceCount: occurrenceCount,
                    endDate: try optionalDate(columnText(statement, 4), table: "recurrence_rules", column: "end_date"),
                    onWorkdays: sqlite3_column_int64(statement, 5) != 0,
                    templateHistory: saved.templateHistory,
                    preservesImportedMaterializations: saved.preservesImportedMaterializations,
                    continuation: saved.continuation
                )
            )
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    private func readAttachmentsByID(
        database: OpaquePointer,
        decoder: JSONDecoder = JSONDecoder.appDecoder
    ) throws -> [UUID: AttachmentContainer] {
        let rows: [(UUID, AttachmentContainer)] = try rows(
            """
            SELECT id, payload_json
            FROM attachment_containers
            """,
            database: database
        ) { statement in
            let containerID = try requiredUUID(columnText(statement, 0), table: "attachment_containers", column: "id")
            guard let payload = columnData(statement, 1) else {
                throw SQLiteJournalStoreError.missingPayload("attachment_containers.payload_json")
            }
            let container = try decoder.decode(AttachmentContainer.self, from: payload)
            return (containerID, container)
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    private func readMetadata(_ database: OpaquePointer) throws -> JournalMetadata? {
        guard let value = try rows(
            "SELECT value FROM app_metadata WHERE key = 'journal'",
            database: database,
            map: { columnText($0, 0) }
        ).first ?? nil,
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder.appDecoder.decode(JournalMetadata.self, from: data)
    }

    private func metadataExists(in database: OpaquePointer) throws -> Bool {
        try rows(
            "SELECT 1 FROM app_metadata WHERE key = 'journal' LIMIT 1",
            database: database,
            map: { _ in true }
        ).first ?? false
    }

    private func upsertMetadata(
        _ key: String,
        value: String,
        database: OpaquePointer,
        table: String = "app_metadata"
    ) throws {
        try executePrepared(
            """
            INSERT INTO \(table)(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            database
        ) { statement in
            try bind(key, to: statement, at: 1, database)
            try bind(value, to: statement, at: 2, database)
        }
    }

    private func ensureSchema(in database: OpaquePointer) throws {
        try execute("PRAGMA journal_mode = WAL", database)
        try execute("PRAGMA foreign_keys = ON", database)
        try execute("PRAGMA synchronous = NORMAL", database)

        // Every store call opens a fresh connection, so the DDL batch and the
        // redundant-row sweep used to run on each operation. Skip both once the
        // on-disk schema already matches; only a version bump pays the full cost.
        let storedVersion = try rows("PRAGMA user_version", database: database) { statement in
            Int(sqlite3_column_int64(statement, 0))
        }.first ?? 0
        guard storedVersion <= Self.currentSchemaVersion else {
            throw SQLiteJournalStoreError.openFailed("This journal was created by a newer app version.")
        }
        if storedVersion == Self.currentSchemaVersion { return }
        // Additive migration only. Cloudflare metadata and all journal/outbox
        // rows are retained, and a failed migration cannot publish version 2.
        try execute("BEGIN IMMEDIATE TRANSACTION", database)
        do {
            if storedVersion < 1 {
                for statement in Self.schemaStatements { try execute(statement, database) }
            }
            if storedVersion < 2 {
                for statement in Self.cloudKitSchemaStatements { try execute(statement, database) }
                for table in ["cloudkit_contexts", "cloudkit_records", "cloudkit_mutation_receipts", "cloudkit_receipt_claims", "cloudkit_conflicts"] {
                    let type = try rows("SELECT type FROM sqlite_master WHERE name = ?", database: database,
                                        bindValues: { try bind(table, to: $0, at: 1, database) }, map: { columnText($0, 0) }).first ?? nil
                    guard type == "table" else { throw cloudKitError("CloudKit schema migration encountered an incompatible object.") }
                }
            }
            try execute("PRAGMA user_version = \(Self.currentSchemaVersion)", database)
            try execute("COMMIT", database)
        } catch {
            try? execute("ROLLBACK", database)
            throw error
        }
    }

    private func open(readOnly: Bool = false, createIfMissing: Bool = true) throws -> OpaquePointer {
        if !readOnly, createIfMissing {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | (createIfMissing ? SQLITE_OPEN_CREATE : 0)) | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            let message = database.map { sqlite3_errmsg($0).map(String.init(cString:)) ?? "Unknown error" } ?? "Unknown error"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteJournalStoreError.openFailed(message)
        }
        let busyTimeoutResult = sqlite3_busy_timeout(database, Self.busyTimeoutMilliseconds)
        guard busyTimeoutResult == SQLITE_OK else {
            let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "Could not configure SQLite busy timeout."
            sqlite3_close(database)
            throw SQLiteJournalStoreError.openFailed(message)
        }
        return database
    }

    private func count(_ table: String, _ database: OpaquePointer) throws -> Int {
        try rows("SELECT COUNT(*) FROM \(table)", database: database) { statement in
            Int(sqlite3_column_int64(statement, 0))
        }.first ?? 0
    }

    private func execute(_ sql: String, _ database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteJournalStoreError.stepFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? sql)
        }
    }

    private func executePrepared(
        _ sql: String,
        _ database: OpaquePointer,
        bindValues: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteJournalStoreError.prepareFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? sql)
        }
        defer { sqlite3_finalize(statement) }
        try bindValues(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteJournalStoreError.stepFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? sql)
        }
    }

    private func withPreparedStatement<T>(
        _ sql: String,
        _ database: OpaquePointer,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteJournalStoreError.prepareFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? sql)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func executePreparedStatement(
        _ statement: OpaquePointer,
        _ database: OpaquePointer,
        bindValues: (OpaquePointer) throws -> Void
    ) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bindValues(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteJournalStoreError.stepFailed(
                sqlite3_errmsg(database).map(String.init(cString:)) ?? "prepared statement"
            )
        }
    }

    private func rows<T>(
        _ sql: String,
        database: OpaquePointer,
        bindValues: (OpaquePointer) throws -> Void,
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteJournalStoreError.prepareFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? sql)
        }
        defer { sqlite3_finalize(statement) }
        try bindValues(statement)
        var output: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                output.append(try map(statement))
            } else if result == SQLITE_DONE {
                return output
            } else {
                throw SQLiteJournalStoreError.stepFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? sql)
            }
        }
    }

    private func rows<T>(_ sql: String, database: OpaquePointer, map: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteJournalStoreError.prepareFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? sql)
        }
        defer { sqlite3_finalize(statement) }
        var output: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                output.append(try map(statement))
            } else if result == SQLITE_DONE {
                return output
            } else {
                throw SQLiteJournalStoreError.stepFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? sql)
            }
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32, _ database: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw SQLiteJournalStoreError.bindFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? "text")
        }
    }

    private func bind(_ value: Int64?, to statement: OpaquePointer, at index: Int32, _ database: OpaquePointer) throws {
        let result = value.map { sqlite3_bind_int64(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else {
            throw SQLiteJournalStoreError.bindFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? "int")
        }
    }

    private func columnText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: text)
    }

    private func columnData(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func requiredUUID(_ value: String?, table: String, column: String) throws -> UUID {
        guard let value, let uuid = UUID(uuidString: value) else {
            throw SQLiteJournalStoreError.missingPayload("\(table).\(column)")
        }
        return uuid
    }

    private func optionalUUID(_ value: String?, table: String, column: String) throws -> UUID? {
        guard let value else { return nil }
        guard let uuid = UUID(uuidString: value) else {
            throw SQLiteJournalStoreError.missingPayload("\(table).\(column)")
        }
        return uuid
    }

    private func requiredDate(_ value: String?, table: String, column: String) throws -> Date {
        guard let date = try optionalDate(value, table: table, column: column) else {
            throw SQLiteJournalStoreError.missingPayload("\(table).\(column)")
        }
        return date
    }

    private func optionalDate(_ value: String?, table: String, column: String) throws -> Date? {
        guard let value else { return nil }
        guard let date = AppJSONDateCoding.date(from: value) else {
            throw SQLiteJournalStoreError.missingPayload("\(table).\(column)")
        }
        return date
    }

    private func requiredDecimal(_ value: String?, table: String, column: String) throws -> Decimal {
        guard let value, let decimal = Decimal(string: value) else {
            throw SQLiteJournalStoreError.missingPayload("\(table).\(column)")
        }
        return decimal
    }

    private func encodedString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder.appEncoder.encode(value), as: UTF8.self)
    }

    private static func makeISOFormatter() -> ISO8601DateFormatter {
        AppJSONDateCoding.fractionalFormatter()
    }

    private func isoString(_ date: Date?, formatter: ISO8601DateFormatter = SQLiteJournalStore.makeISOFormatter()) -> String? {
        guard let date else { return nil }
        return formatter.string(from: date)
    }

    private func syncKey(type: String, id: UUID) -> String {
        "\(type):\(id.uuidString)"
    }

    private func attachmentFileURL(_ storedPath: String) -> URL {
        databaseURL.deletingLastPathComponent().appending(path: storedPath)
    }

    private func r2Key(datasetID: UUID?, assetID: UUID, sha256: String, filename: String) -> String {
        let dataset = datasetID?.uuidString ?? "default"
        let safeName = filename
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "attachments/\(dataset)/\(assetID.uuidString)/\(sha256)-\(safeName.isEmpty ? "Attachment" : safeName)"
    }

    private static let cloudKitSchemaStatements = [
        "CREATE TABLE IF NOT EXISTS cloudkit_contexts(context_key TEXT PRIMARY KEY, account_id TEXT NOT NULL, change_token BLOB, initial_prepared INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS cloudkit_records(context_key TEXT NOT NULL, record_key TEXT NOT NULL, record_json TEXT NOT NULL, PRIMARY KEY(context_key, record_key), FOREIGN KEY(context_key) REFERENCES cloudkit_contexts(context_key))",
        "CREATE TABLE IF NOT EXISTS cloudkit_mutation_receipts(context_key TEXT NOT NULL, client_change_id TEXT NOT NULL, record_json TEXT NOT NULL, PRIMARY KEY(context_key, client_change_id), FOREIGN KEY(context_key) REFERENCES cloudkit_contexts(context_key))",
        "CREATE TABLE IF NOT EXISTS cloudkit_receipt_claims(context_key TEXT NOT NULL, client_change_id TEXT NOT NULL, record_json TEXT NOT NULL, PRIMARY KEY(context_key, client_change_id), FOREIGN KEY(context_key) REFERENCES cloudkit_contexts(context_key))",
        "CREATE TABLE IF NOT EXISTS cloudkit_conflicts(id TEXT PRIMARY KEY, context_key TEXT NOT NULL, record_key TEXT NOT NULL, local_record TEXT NOT NULL, remote_record TEXT NOT NULL, known_system_fields BLOB, created_at TEXT NOT NULL, resolved_at TEXT, FOREIGN KEY(context_key) REFERENCES cloudkit_contexts(context_key))",
        "CREATE INDEX IF NOT EXISTS idx_cloudkit_conflicts_context ON cloudkit_conflicts(context_key, record_key, resolved_at)"
    ]

    private static let schemaStatements = [
        """
        CREATE TABLE IF NOT EXISTS app_metadata(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS ledgers(
            id TEXT PRIMARY KEY,
            list_index INTEGER NOT NULL,
            name TEXT NOT NULL,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS commodities(
            id TEXT PRIMARY KEY,
            ledger_id TEXT NOT NULL,
            symbol TEXT NOT NULL,
            name TEXT NOT NULL,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS accounts(
            id TEXT PRIMARY KEY,
            ledger_id TEXT NOT NULL,
            parent_id TEXT,
            commodity_id TEXT,
            kind INTEGER NOT NULL,
            list_index INTEGER NOT NULL,
            name TEXT NOT NULL,
            note TEXT NOT NULL,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS transactions(
            id TEXT PRIMARY KEY,
            ledger_id TEXT NOT NULL,
            source_id TEXT,
            date TEXT NOT NULL,
            payee TEXT NOT NULL,
            note TEXT NOT NULL,
            number TEXT NOT NULL,
            cleared INTEGER NOT NULL,
            recurrence_rule_id TEXT,
            attachment_container_id TEXT,
            external_transaction_id TEXT,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS postings(
            id TEXT PRIMARY KEY,
            transaction_id TEXT NOT NULL,
            account_id TEXT NOT NULL,
            commodity_id TEXT,
            amount TEXT NOT NULL,
            list_index INTEGER NOT NULL,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS recurrence_rules(
            id TEXT PRIMARY KEY,
            frequency TEXT NOT NULL,
            interval_value INTEGER NOT NULL,
            occurrence_count INTEGER,
            end_date TEXT,
            on_workdays INTEGER NOT NULL,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS recurrence_ends(
            rule_id TEXT PRIMARY KEY,
            occurrence_count INTEGER,
            end_date TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS recurrence_exceptions(
            id TEXT PRIMARY KEY,
            recurrence_rule_id TEXT NOT NULL,
            occurrence_date TEXT NOT NULL,
            transaction_id TEXT,
            kind TEXT NOT NULL,
            payload_json TEXT,
            created_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS attachment_containers(
            id TEXT PRIMARY KEY,
            transaction_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS attachment_assets(
            id TEXT PRIMARY KEY,
            container_id TEXT NOT NULL,
            transaction_id TEXT NOT NULL,
            original_filename TEXT NOT NULL,
            stored_path TEXT NOT NULL,
            mime_type TEXT,
            size_bytes INTEGER NOT NULL,
            sha256 TEXT,
            r2_key TEXT,
            upload_state TEXT NOT NULL DEFAULT 'pending',
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sources(
            id TEXT PRIMARY KEY,
            ledger_id TEXT NOT NULL,
            type INTEGER NOT NULL,
            date TEXT,
            external_id TEXT,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS transaction_templates(
            id TEXT PRIMARY KEY,
            ledger_id TEXT NOT NULL,
            name TEXT NOT NULL,
            list_index INTEGER NOT NULL,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS posting_templates(
            id TEXT PRIMARY KEY,
            template_id TEXT NOT NULL,
            account_id TEXT,
            list_index INTEGER NOT NULL,
            payload_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_state(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_records(
            record_type TEXT NOT NULL,
            record_id TEXT NOT NULL,
            parent_record_id TEXT,
            content_hash TEXT NOT NULL,
            payload_json TEXT,
            server_revision INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            PRIMARY KEY(record_type, record_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_outbox(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            client_change_id TEXT NOT NULL UNIQUE,
            record_type TEXT NOT NULL,
            record_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            base_revision INTEGER NOT NULL DEFAULT 0,
            content_hash TEXT,
            payload_json TEXT,
            created_at TEXT NOT NULL,
            state TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_tombstones(
            record_type TEXT NOT NULL,
            record_id TEXT NOT NULL,
            content_hash TEXT,
            deleted_at TEXT NOT NULL,
            server_revision INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(record_type, record_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_conflicts(
            id TEXT PRIMARY KEY,
            record_type TEXT NOT NULL,
            record_id TEXT NOT NULL,
            local_payload_json TEXT,
            remote_payload_json TEXT,
            created_at TEXT NOT NULL,
            resolved_at TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS attachment_transfer_queue(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            asset_id TEXT NOT NULL,
            direction TEXT NOT NULL,
            r2_key TEXT,
            sha256 TEXT,
            state TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_transactions_ledger_date ON transactions(ledger_id, date DESC)",
        "CREATE INDEX IF NOT EXISTS idx_transactions_recurrence_date ON transactions(recurrence_rule_id, date)",
        "CREATE INDEX IF NOT EXISTS idx_transactions_cleared_date ON transactions(cleared, date DESC)",
        "CREATE INDEX IF NOT EXISTS idx_transactions_attachment ON transactions(attachment_container_id)",
        "CREATE INDEX IF NOT EXISTS idx_postings_transaction_list ON postings(transaction_id, list_index)",
        "CREATE INDEX IF NOT EXISTS idx_postings_account_transaction ON postings(account_id, transaction_id)",
        "CREATE INDEX IF NOT EXISTS idx_sync_outbox_state ON sync_outbox(state, id)",
        "CREATE INDEX IF NOT EXISTS idx_sync_outbox_pending_record ON sync_outbox(state, record_type, record_id, id DESC)",
        "CREATE INDEX IF NOT EXISTS idx_sync_records_revision ON sync_records(server_revision)",
        "CREATE INDEX IF NOT EXISTS idx_attachment_assets_sha ON attachment_assets(sha256)"
    ]
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
