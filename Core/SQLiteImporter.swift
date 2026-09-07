import Foundation
import SQLite3

enum SQLiteImportError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case queryFailed(String)
    case missingLedger
    case preservationFailed([String])

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Could not open SQLite database: \(message)"
        case .prepareFailed(let message): "Could not prepare SQLite query: \(message)"
        case .queryFailed(let message): "Could not read SQLite database: \(message)"
        case .missingLedger: "The database does not contain a Finances ledger."
        case .preservationFailed(let issues): "SQLite import is incomplete: \(issues.joined(separator: " "))"
        }
    }
}

struct OriginalFinancesSQLiteImporter {
#if os(iOS)
    static let defaultDatabaseURL = FileManager.default.temporaryDirectory
        .appending(path: "Finances.sqlite")
#else
    static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Containers/at.mah.FinancesMac/Data/Library/Application Support/Finances/Finances.sqlite")
#endif

    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func importData() throws -> JournalData {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            let message = database.map { sqlite3_errmsg($0).map(String.init(cString:)) ?? "Unknown error" } ?? "Unknown error"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteImportError.openFailed(message)
        }
        defer { sqlite3_close(database) }

        let ledgers = try readLedgers(database)
        guard !ledgers.isEmpty else { throw SQLiteImportError.missingLedger }
        let commodities = try readCommodities(database, ledgers: ledgers)
        let accounts = try readAccounts(database, ledgers: ledgers, commodities: commodities)
        let sources = try readSources(database, ledgers: ledgers)
        let recurrenceEnds = try readRecurrenceEnds(database)
        let recurrenceRules = try readRecurrenceRules(database, recurrenceEnds: recurrenceEnds)
        let attachments = try readAttachments(database)
        let postingsByTransaction = try readPostings(database, accounts: accounts, commodities: commodities)
        let transactions = try inferStoppedRecurrenceEnds(
            in: readTransactions(
            database,
            ledgers: ledgers,
            accounts: accounts,
            commodities: commodities,
            sources: sources,
            recurrenceRules: recurrenceRules,
            attachments: attachments,
            postingsByTransaction: postingsByTransaction
            )
        )
        let postingTemplatesByTemplate = try readPostingTemplates(database, accounts: accounts)
        let transactionTemplates = try readTransactionTemplates(
            database,
            ledgers: ledgers,
            accounts: accounts,
            postingTemplatesByTemplate: postingTemplatesByTemplate
        )

        try validatePreservation(
            database,
            ledgers: ledgers,
            commodities: commodities,
            accounts: accounts,
            sources: sources,
            recurrenceEnds: recurrenceEnds,
            recurrenceRules: recurrenceRules,
            transactions: transactions,
            postingsByTransaction: postingsByTransaction,
            attachments: attachments,
            transactionTemplates: transactionTemplates,
            postingTemplatesByTemplate: postingTemplatesByTemplate
        )

        var data = JournalData(
            ledgers: ledgers.values.sorted { $0.listIndex < $1.listIndex },
            commodities: commodities.values.sorted { $0.symbol < $1.symbol },
            accounts: accounts.values.sorted { $0.listIndex < $1.listIndex },
            transactions: transactions.sorted { $0.date < $1.date },
            sources: sources.values.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) },
            transactionTemplates: transactionTemplates.sorted { $0.listIndex < $1.listIndex },
            selectedLedgerID: ledgers.values.sorted { $0.listIndex < $1.listIndex }.first?.id
        )
        if data.commodities.isEmpty, let ledgerID = data.selectedLedgerID {
            data.commodities.append(Commodity(ledgerID: ledgerID, symbol: "USD", name: "US Dollar"))
        }
        return data
    }

    private func inferStoppedRecurrenceEnds(in transactions: [LedgerTransaction], now: Date = Date()) -> [LedgerTransaction] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let grouped = Dictionary(grouping: transactions) { transaction in
            transaction.recurrenceRule?.id
        }
        let stoppedRuleIDs = Set(grouped.compactMap { ruleID, rows -> UUID? in
            guard let ruleID,
                  let rule = rows.first?.recurrenceRule,
                  rule.endDate == nil,
                  rule.occurrenceCount == nil,
                  let latest = rows.map(\.date).max(),
                  calendar.startOfDay(for: latest) < today else {
                return nil
            }
            return ruleID
        })
        guard !stoppedRuleIDs.isEmpty else { return transactions }

        let latestDateByRule = Dictionary(grouping: transactions.filter { transaction in
            transaction.recurrenceRule.map { stoppedRuleIDs.contains($0.id) } ?? false
        }, by: { $0.recurrenceRule!.id }).mapValues { rows in
            rows.map(\.date).max()
        }

        return transactions.map { transaction in
            guard var rule = transaction.recurrenceRule,
                  stoppedRuleIDs.contains(rule.id),
                  let endDate = latestDateByRule[rule.id] ?? nil else {
                return transaction
            }
            var copy = transaction
            rule.endDate = endDate
            copy.recurrenceRule = rule
            return copy
        }
    }

    private func readLedgers(_ database: OpaquePointer) throws -> [Int64: Ledger] {
        try query(database, "SELECT Z_PK, ZNAME, ZLISTINDEX, ZOBJECTNAME FROM ZLEDGER ORDER BY ZLISTINDEX, Z_PK") { statement in
            let pk = int64(statement, 0)
            return (pk, Ledger(
                id: stableID(text(statement, 3)),
                name: text(statement, 1)?.nilIfEmpty ?? "Untitled",
                listIndex: Int(int64(statement, 2))
            ))
        }
        .dictionary()
    }

    private func readCommodities(_ database: OpaquePointer, ledgers: [Int64: Ledger]) throws -> [Int64: Commodity] {
        try query(database, "SELECT Z_PK, ZLEDGER, ZSYMBOL, ZOBJECTNAME FROM ZCOMMODITY ORDER BY Z_PK") { statement in
            let pk = int64(statement, 0)
            let ledgerPK = int64(statement, 1)
            guard let ledgerID = ledgers[ledgerPK]?.id else { return nil }
            let symbol = text(statement, 2)?.nilIfEmpty ?? "USD"
            return (pk, Commodity(
                id: stableID(text(statement, 3)),
                ledgerID: ledgerID,
                symbol: symbol,
                name: currencyName(for: symbol)
            ))
        }
        .compactMap { $0 }
        .dictionary()
    }

    private func readAccounts(
        _ database: OpaquePointer,
        ledgers: [Int64: Ledger],
        commodities: [Int64: Commodity]
    ) throws -> [Int64: Account] {
        let rows = try query(database, """
        SELECT Z_PK, ZLEDGER, ZPARENT, ZCOMMODITY, ZNAME, ZNOTE, ZKINDINT16, ZCOLORTYPEINT16, ZLISTINDEX, ZOBJECTNAME
        FROM ZACCOUNT
        ORDER BY ZLISTINDEX, Z_PK
        """) { statement in
            ImportedAccountRow(
                pk: int64(statement, 0),
                ledgerPK: int64(statement, 1),
                parentPK: optionalInt64(statement, 2),
                commodityPK: optionalInt64(statement, 3),
                name: text(statement, 4)?.nilIfEmpty ?? "Untitled",
                note: text(statement, 5) ?? "",
                kind: AccountKind(rawValue: Int(int64(statement, 6))) ?? .equity,
                colorName: colorName(for: Int(int64(statement, 7))),
                listIndex: Int(int64(statement, 8)),
                objectName: text(statement, 9)
            )
        }

        var accountIDs: [Int64: UUID] = [:]
        for row in rows {
            accountIDs[row.pk] = stableID(row.objectName)
        }

        return rows.compactMap { row in
            guard let ledgerID = ledgers[row.ledgerPK]?.id else { return nil }
            return (
                row.pk,
                Account(
                    id: accountIDs[row.pk] ?? UUID(),
                    ledgerID: ledgerID,
                    parentID: row.parentPK.flatMap { accountIDs[$0] },
                    commodityID: row.commodityPK.flatMap { commodities[$0]?.id },
                    name: row.name,
                    note: row.note,
                    kind: row.kind,
                    colorName: row.colorName,
                    listIndex: row.listIndex
                )
            )
        }
        .dictionary()
    }

    private func readTransactions(
        _ database: OpaquePointer,
        ledgers: [Int64: Ledger],
        accounts: [Int64: Account],
        commodities: [Int64: Commodity],
        sources: [Int64: TransactionSource],
        recurrenceRules: [Int64: RecurrenceRule],
        attachments: [Int64: AttachmentContainer],
        postingsByTransaction: [Int64: [Posting]]
    ) throws -> [LedgerTransaction] {
        return try query(database, """
        SELECT Z_PK, ZLEDGER, ZDATE, ZPAYEE, ZNOTE, ZNUMBER, ZCLEARED, ZRECURRENCERULE, ZATTACHMENT, ZSOURCE, ZOBJECTNAME
        FROM ZTRANSACTION
        ORDER BY ZDATE, Z_PK
        """) { statement in
            let pk = int64(statement, 0)
            let ledgerPK = int64(statement, 1)
            guard let ledgerID = ledgers[ledgerPK]?.id else { return nil }
            let postings = postingsByTransaction[pk] ?? []
            guard postings.count >= 2 else { return nil }
            return LedgerTransaction(
                id: stableID(text(statement, 10)),
                ledgerID: ledgerID,
                sourceID: optionalInt64(statement, 9).flatMap { sources[$0]?.id },
                date: dateFromCoreDataSeconds(double(statement, 2)),
                payee: text(statement, 3) ?? "",
                note: text(statement, 4) ?? "",
                number: text(statement, 5) ?? "",
                cleared: int64(statement, 6) != 0,
                postings: postings,
                recurrenceRule: optionalInt64(statement, 7).flatMap { recurrenceRules[$0] },
                attachment: optionalInt64(statement, 8).map { attachments[$0] ?? AttachmentContainer() }
            )
        }
        .compactMap { $0 }
    }

    private func readSources(_ database: OpaquePointer, ledgers: [Int64: Ledger]) throws -> [Int64: TransactionSource] {
        guard try tableExists("ZSOURCE", in: database) else { return [:] }
        return try query(database, """
        SELECT Z_PK, ZTYPEINT16, ZLEDGER, ZDATE, ZOBJECTNAME
        FROM ZSOURCE
        ORDER BY ZDATE, Z_PK
        """) { statement in
            let pk = int64(statement, 0)
            let ledgerPK = int64(statement, 2)
            guard let ledgerID = ledgers[ledgerPK]?.id else { return nil }
            return (
                pk,
                TransactionSource(
                    id: stableID(text(statement, 4)),
                    ledgerID: ledgerID,
                    type: Int(int64(statement, 1)),
                    date: optionalDouble(statement, 3).map(dateFromCoreDataSeconds)
                )
            )
        }
        .compactMap { $0 }
        .dictionary()
    }

    private func readTransactionTemplates(
        _ database: OpaquePointer,
        ledgers: [Int64: Ledger],
        accounts: [Int64: Account],
        postingTemplatesByTemplate: [Int64: [PostingTemplate]]
    ) throws -> [TransactionTemplate] {
        guard try tableExists("ZTRANSACTIONTEMPLATE", in: database) else { return [] }
        return try query(database, """
        SELECT Z_PK, ZLEDGER, ZNAME, ZNOTE, ZPAYEE, ZCLEARED, ZENABLED, ZSCANINVOICE, ZLISTINDEX, ZOBJECTNAME
        FROM ZTRANSACTIONTEMPLATE
        ORDER BY ZLISTINDEX, Z_PK
        """) { statement in
            let pk = int64(statement, 0)
            let ledgerPK = int64(statement, 1)
            guard let ledgerID = ledgers[ledgerPK]?.id else { return nil }
            return TransactionTemplate(
                id: stableID(text(statement, 9)),
                ledgerID: ledgerID,
                name: text(statement, 2)?.nilIfEmpty ?? "Untitled",
                note: text(statement, 3) ?? "",
                payee: text(statement, 4) ?? "",
                cleared: int64(statement, 5) != 0,
                enabled: int64(statement, 6) != 0,
                scanInvoice: int64(statement, 7) != 0,
                listIndex: Int(int64(statement, 8)),
                postings: postingTemplatesByTemplate[pk] ?? []
            )
        }
        .compactMap { $0 }
    }

    private func readPostingTemplates(
        _ database: OpaquePointer,
        accounts: [Int64: Account]
    ) throws -> [Int64: [PostingTemplate]] {
        guard try tableExists("ZPOSTINGTEMPLATE", in: database) else { return [:] }
        let optionalRows: [(Int64, PostingTemplate)?] = try query(database, """
        SELECT Z_PK, ZTRANSACTIONTEMPLATE, ZACCOUNT, ZLISTINDEX, ZOBJECTNAME
        FROM ZPOSTINGTEMPLATE
        ORDER BY ZTRANSACTIONTEMPLATE, ZLISTINDEX, Z_PK
        """) { statement in
            let templatePK = int64(statement, 1)
            return (
                templatePK,
                PostingTemplate(
                    id: stableID(text(statement, 4)),
                    accountID: optionalInt64(statement, 2).flatMap { accounts[$0]?.id },
                    listIndex: Int(int64(statement, 3))
                )
            )
        }
        let rows = optionalRows.compactMap { $0 }
        return Dictionary(grouping: rows, by: { $0.0 }).mapValues { pairs in
            pairs.map { $0.1 }.sorted { $0.listIndex < $1.listIndex }
        }
    }

    private func readRecurrenceEnds(_ database: OpaquePointer) throws -> [Int64: ImportedRecurrenceEnd] {
        guard try tableExists("ZRECURRENCEEND", in: database) else { return [:] }
        return try query(database, """
        SELECT Z_PK, ZOCCURRENCECOUNT, ZENDDATE
        FROM ZRECURRENCEEND
        ORDER BY Z_PK
        """) { statement in
            let occurrenceCount = optionalInt64(statement, 1).flatMap { value in
                value > 0 ? Int(value) : nil
            }
            return (
                int64(statement, 0),
                ImportedRecurrenceEnd(
                    occurrenceCount: occurrenceCount,
                    endDate: optionalDouble(statement, 2).map(dateFromCoreDataSeconds)
                )
            )
        }
        .dictionary()
    }

    private func readRecurrenceRules(
        _ database: OpaquePointer,
        recurrenceEnds: [Int64: ImportedRecurrenceEnd]
    ) throws -> [Int64: RecurrenceRule] {
        guard try tableExists("ZRECURRENCERULE", in: database) else { return [:] }
        return try query(database, """
        SELECT Z_PK, ZFREQUENCYINT16, ZONWORKDAYS, ZVALUEINT16, ZRECURRENCEEND, ZOBJECTNAME
        FROM ZRECURRENCERULE
        ORDER BY Z_PK
        """) { statement in
            let interval = max(1, Int(int64(statement, 3)))
            let recurrenceEnd = optionalInt64(statement, 4).flatMap { recurrenceEnds[$0] }
            return (
                int64(statement, 0),
                RecurrenceRule(
                    id: stableID(text(statement, 5)),
                    frequency: recurrenceFrequency(for: Int(int64(statement, 1))),
                    intervalValue: interval,
                    occurrenceCount: recurrenceEnd?.occurrenceCount,
                    endDate: recurrenceEnd?.endDate,
                    onWorkdays: int64(statement, 2) != 0
                )
            )
        }
        .dictionary()
    }

    private func readPostings(
        _ database: OpaquePointer,
        accounts: [Int64: Account],
        commodities: [Int64: Commodity]
    ) throws -> [Int64: [Posting]] {
        let optionalRows: [(Int64, Posting)?] = try query(database, """
        SELECT Z_PK, ZTRANSACTION, ZACCOUNT, ZCOMMODITY, ZAMOUNT, ZLISTINDEX, ZOBJECTNAME
        FROM ZPOSTING
        ORDER BY ZTRANSACTION, ZLISTINDEX, Z_PK
        """) { statement in
            let transactionPK = int64(statement, 1)
            let accountPK = int64(statement, 2)
            guard let accountID = accounts[accountPK]?.id else { return nil }
            return (
                transactionPK,
                Posting(
                    id: stableID(text(statement, 6)),
                    accountID: accountID,
                    commodityID: optionalInt64(statement, 3).flatMap { commodities[$0]?.id },
                    amount: decimal(statement, 4),
                    listIndex: Int(int64(statement, 5))
                )
            )
        }
        let rows = optionalRows.compactMap { $0 }

        return Dictionary(grouping: rows, by: { $0.0 }).mapValues { pairs in
            pairs.map { $0.1 }.sorted { $0.listIndex < $1.listIndex }
        }
    }

    private func readAttachments(_ database: OpaquePointer) throws -> [Int64: AttachmentContainer] {
        guard try tableExists("ZATTACHMENT", in: database) else { return [:] }

        var containers = try query(database, "SELECT Z_PK, ZOBJECTNAME FROM ZATTACHMENT ORDER BY Z_PK") { statement in
            (int64(statement, 0), AttachmentContainer(id: stableID(text(statement, 1))))
        }
        .dictionary()

        guard try tableExists("ZASSET", in: database) else { return containers }

        let assets = try query(database, """
        SELECT Z_PK, ZATTACHMENT, ZOBJECTNAME, ZORIGINALFILENAME, ZBOOKMARKDATA
        FROM ZASSET
        ORDER BY ZATTACHMENT, Z_PK
        """) { statement in
            let attachmentPK = int64(statement, 1)
            let objectName = text(statement, 2)
            let originalFilename = text(statement, 3)?.nilIfEmpty ?? "Attachment"
            let bookmark = dataBlob(statement, 4)
            return (
                attachmentPK,
                AttachmentAsset(
                    id: stableID(text(statement, 2) ?? text(statement, 3)),
                    originalFilename: originalFilename,
                    storedPath: attachmentPath(objectName: objectName, originalFilename: originalFilename, bookmark: bookmark),
                    mimeType: nil,
                    sizeBytes: 0
                )
            )
        }

        for (attachmentPK, asset) in assets {
            if containers[attachmentPK] == nil {
                containers[attachmentPK] = AttachmentContainer()
            }
            containers[attachmentPK]?.assets.append(asset)
        }
        return containers
    }

    private func validatePreservation(
        _ database: OpaquePointer,
        ledgers: [Int64: Ledger],
        commodities: [Int64: Commodity],
        accounts: [Int64: Account],
        sources: [Int64: TransactionSource],
        recurrenceEnds: [Int64: ImportedRecurrenceEnd],
        recurrenceRules: [Int64: RecurrenceRule],
        transactions: [LedgerTransaction],
        postingsByTransaction: [Int64: [Posting]],
        attachments: [Int64: AttachmentContainer],
        transactionTemplates: [TransactionTemplate],
        postingTemplatesByTemplate: [Int64: [PostingTemplate]]
    ) throws {
        var issues: [String] = []
        try appendCountIssue(&issues, database: database, table: "ZLEDGER", imported: ledgers.count, label: "journal")
        try appendCountIssue(&issues, database: database, table: "ZCOMMODITY", imported: commodities.count, label: "currency")
        try appendCountIssue(&issues, database: database, table: "ZACCOUNT", imported: accounts.count, label: "account")
        try appendCountIssue(&issues, database: database, table: "ZSOURCE", imported: sources.count, label: "source")
        try appendCountIssue(&issues, database: database, table: "ZRECURRENCEEND", imported: recurrenceEnds.count, label: "recurrence end")
        try appendCountIssue(&issues, database: database, table: "ZRECURRENCERULE", imported: recurrenceRules.count, label: "recurrence rule")
        try appendCountIssue(&issues, database: database, table: "ZTRANSACTION", imported: transactions.count, label: "transaction")
        try appendCountIssue(
            &issues,
            database: database,
            table: "ZTRANSACTION",
            whereClause: "ZRECURRENCERULE IS NOT NULL",
            imported: transactions.filter { $0.recurrenceRule != nil }.count,
            label: "recurring transaction"
        )
        try appendCountIssue(
            &issues,
            database: database,
            table: "ZPOSTING",
            imported: postingsByTransaction.values.reduce(0) { $0 + $1.count },
            label: "posting"
        )
        try appendCountIssue(&issues, database: database, table: "ZATTACHMENT", imported: attachments.count, label: "attachment container")
        try appendCountIssue(
            &issues,
            database: database,
            table: "ZASSET",
            imported: attachments.values.reduce(0) { $0 + $1.assets.count },
            label: "attachment asset"
        )
        try appendCountIssue(
            &issues,
            database: database,
            table: "ZTRANSACTIONTEMPLATE",
            imported: transactionTemplates.count,
            label: "transaction template"
        )
        try appendCountIssue(
            &issues,
            database: database,
            table: "ZPOSTINGTEMPLATE",
            imported: postingTemplatesByTemplate.values.reduce(0) { $0 + $1.count },
            label: "posting template"
        )
        if !issues.isEmpty {
            throw SQLiteImportError.preservationFailed(issues)
        }
    }

    private func appendCountIssue(
        _ issues: inout [String],
        database: OpaquePointer,
        table: String,
        whereClause: String? = nil,
        imported: Int,
        label: String
    ) throws {
        guard let sourceCount = try rowCount(table, in: database, whereClause: whereClause), sourceCount != imported else { return }
        let dropped = sourceCount - imported
        if dropped > 0 {
            issues.append("Would drop \(dropped) \(label)\(dropped == 1 ? "" : "s") from \(table) (imported \(imported) of \(sourceCount)).")
        } else {
            issues.append("Would create \(abs(dropped)) extra \(label)\(dropped == -1 ? "" : "s") from \(table) (imported \(imported) of \(sourceCount)).")
        }
    }

    private func attachmentPath(objectName: String?, originalFilename: String, bookmark: Data?) -> String {
        if let bookmarkURL = urlFromBookmark(bookmark) {
            return bookmarkURL.path
        }

        let attachmentsDirectory = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Attachments", directoryHint: .isDirectory)

        guard let objectName = objectName?.nilIfEmpty else {
            return attachmentsDirectory.appending(path: originalFilename).path
        }

        let objectURL = URL(fileURLWithPath: objectName)
        if objectURL.isFileURL && objectName.hasPrefix("/") {
            return objectURL.path
        }

        let direct = attachmentsDirectory.appending(path: objectName)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct.path
        }

        let ext = URL(fileURLWithPath: originalFilename).pathExtension
        if !ext.isEmpty && direct.pathExtension.isEmpty {
            return direct.appendingPathExtension(ext).path
        }
        return direct.path
    }

    private func urlFromBookmark(_ bookmark: Data?) -> URL? {
        guard let bookmark, !bookmark.isEmpty else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}

private struct ImportedAccountRow {
    let pk: Int64
    let ledgerPK: Int64
    let parentPK: Int64?
    let commodityPK: Int64?
    let name: String
    let note: String
    let kind: AccountKind
    let colorName: String
    let listIndex: Int
    let objectName: String?
}

private struct ImportedRecurrenceEnd {
    let occurrenceCount: Int?
    let endDate: Date?
}

private func query<T>(_ database: OpaquePointer, _ sql: String, map: (OpaquePointer) throws -> T) throws -> [T] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw SQLiteImportError.prepareFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? sql)
    }
    defer { sqlite3_finalize(statement) }

    var rows: [T] = []
    while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            rows.append(try map(statement))
        } else if result == SQLITE_DONE {
            return rows
        } else {
            throw SQLiteImportError.queryFailed(sqlite3_errmsg(database).map(String.init(cString:)) ?? sql)
        }
    }
}

private func tableExists(_ tableName: String, in database: OpaquePointer) throws -> Bool {
    try query(database, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(tableName)'") { _ in
        true
    }
    .first ?? false
}

private func rowCount(_ tableName: String, in database: OpaquePointer, whereClause: String? = nil) throws -> Int? {
    guard try tableExists(tableName, in: database) else { return nil }
    let filter = whereClause.map { " WHERE \($0)" } ?? ""
    return try query(database, "SELECT COUNT(*) FROM \(tableName)\(filter)") { statement in
        Int(int64(statement, 0))
    }
    .first
}

private func int64(_ statement: OpaquePointer, _ column: Int32) -> Int64 {
    sqlite3_column_int64(statement, column)
}

private func optionalInt64(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
}

private func double(_ statement: OpaquePointer, _ column: Int32) -> Double {
    sqlite3_column_double(statement, column)
}

private func optionalDouble(_ statement: OpaquePointer, _ column: Int32) -> Double? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
}

private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, column) else {
        return nil
    }
    return String(cString: pointer)
}

private func dataBlob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
          let pointer = sqlite3_column_blob(statement, column) else {
        return nil
    }
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
}

private func decimal(_ statement: OpaquePointer, _ column: Int32) -> Decimal {
    if let value = text(statement, column), let decimal = Decimal(string: value) {
        return decimal
    }
    return Decimal(sqlite3_column_double(statement, column))
}

private func dateFromCoreDataSeconds(_ seconds: Double) -> Date {
    Date(timeIntervalSince1970: seconds + 978_307_200)
}

private func stableID(_ value: String?) -> UUID {
    guard let value, !value.isEmpty else { return UUID() }
    if let uuid = UUID(uuidString: value) {
        return uuid
    }
    return UUID(uuidString: String(value.uuidV5LikePrefix.prefix(36))) ?? UUID()
}

private func colorName(for index: Int) -> String {
    // Persisted ZCOLORTYPEINT16 values, checked against original accounts and
    // their reference UI: Miscellaneous=2/brown, Transportation=3/orange,
    // Personal=5/green, Health=6/cyan, Food=7/blue, Living Expense=8/purple.
    // These are stored enum values, not localization-table positions. Keep
    // the existing gray convention for no color (0) and unknown values.
    let colors = ["gray", "red", "brown", "orange", "yellow", "green", "cyan", "blue", "purple", "pink"]
    return colors.indices.contains(index) ? colors[index] : "gray"
}

private func currencyName(for symbol: String) -> String {
    Locale.current.localizedString(forCurrencyCode: symbol) ?? symbol
}

private func recurrenceFrequency(for value: Int) -> RecurrenceFrequency {
    switch value {
    case 0: .daily
    case 1: .weekly
    case 2: .monthly
    case 4: .yearly
    default: .custom
    }
}

private extension Array {
    func dictionary<K: Hashable, V>() -> [K: V] where Element == (K, V) {
        Dictionary(self, uniquingKeysWith: { first, _ in first })
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var uuidV5LikePrefix: String {
        let scalars = unicodeScalars.map { UInt64($0.value) }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for scalar in scalars {
            hash ^= scalar
            hash &*= 1_099_511_628_211
        }
        let hex = String(format: "%016llx%016llx", hash, hash.byteSwapped)
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    }
}
