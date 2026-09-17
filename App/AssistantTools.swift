import Foundation
import CryptoKit

struct AssistantPreparedImport: Sendable { var data: JournalData; var directory: URL }

/// Both typed and spoken requests enter this one native domain adapter.
@MainActor
final class AssistantTools {
    let store: MobileLedgerStore
    let contract: AssistantContract
    let scope: String
    var context: AssistantContext
    var requireActive: () throws -> Void = {}
    var selectFiles: ((String) async throws -> [URL])?
    var showArtifact: ((URL) -> Void)?
    var openView: ((AssistantJSON) -> Void)?
    var conversationTitle: (() throws -> AssistantJSON)?
    var renameConversation: ((AssistantToolCall, String) throws -> AssistantJSON)?
    var readForModel: ((UUID, AttachmentAsset, URL) async throws -> AssistantJSON)?
    var staged: [String: URL] = [:]
    var previews: [String: PreparedBackupRestore] = [:]
    var preparedImports: [String: JournalData] = [:]
    private var cachedStamp = ""
    private var cachedSnapshot = ""

    init(store: MobileLedgerStore, scope: String, context: AssistantContext, contract: AssistantContract) {
        self.store = store; self.scope = scope; self.context = context; self.contract = contract
    }
    var directory: URL { store.assistantDirectory.appending(path: AssistantJSON.string(scope).digest) }
    var snapshot: String {
        let stamp = "\(store.registerContentRevision):\(store.searchContentRevision)"
        if cachedStamp != stamp || cachedSnapshot.isEmpty {
            cachedSnapshot = (try? AssistantJSON.modelDigest(store.data)) ?? ""; cachedStamp = stamp
        }
        return cachedSnapshot
    }
    func invalidateSnapshot() { cachedStamp = "" }
    func definition(_ name: String) throws -> AssistantToolDefinition {
        guard let tool = contract.tools.first(where: { $0.name == name }) else { throw AssistantFailure("unknown_tool", "Unknown finance tool.") }; return tool
    }
    func access() throws { try Task.checkCancellation(); try requireActive(); try store.assistantRequireAccess() }
    var mode: String { scope == "local-developer" ? "sample" : "cloud" }
    func success(_ result: AssistantJSON) -> AssistantJSON { .object(["ok": .bool(true), "mode": .string(mode), "result": result]) }
    func failure(_ error: Error) -> AssistantJSON {
        .object(["ok": .bool(false), "error": .object(["code": .string((error as? AssistantFailure)?.code ?? "operation_failed"), "message": .string(error.localizedDescription)])])
    }
    func execute(_ call: AssistantToolCall) async throws -> AssistantJSON {
        try access()
        let def = try definition(call.name)
        var a = call.args
        if def.inputSchema["properties"].object["request_id"] != nil { a = a.setting("request_id", .string(call.operationID)) }
        try AssistantContract.validate(a, schema: def.inputSchema)
        let name = call.name
        if name == "get_app_context" { return success(appContext()) }
        if name == "get_conversation_title" {
            guard let conversationTitle else { throw AssistantFailure("conversation_unavailable", "Reopen the current conversation.") }
            return success(try conversationTitle())
        }
        if name == "rename_conversation" {
            guard let renameConversation else { throw AssistantFailure("conversation_unavailable", "Reopen the current conversation.") }
            return try renameConversation(call, a.required("title"))
        }
        if name == "select_files" {
            guard let selectFiles else { throw AssistantFailure("interaction_unavailable", "Open the assistant to select files.") }
            let urls = try await selectFiles(try a.required("purpose")); try access()
            return success(.object(["files": .array(try urls.map { try stage($0) })]))
        }
        if name == "read_attachment" {
            let tx = try transaction(a["transaction"]), asset = try attachment(tx, a["asset_id"])
            let url = store.attachmentURL(for: asset)
            try checkFile(url, maximum: 15 * 1024 * 1024)
            guard let readForModel else { throw AssistantFailure("attachment_reader_unavailable", "Receipt analysis is unavailable.") }
            let result = try await readForModel(tx.id, asset, url); try access(); return success(result)
        }
        if name == "sync_now" {
            guard mode != "sample" else { throw AssistantFailure("sample_mode", "The isolated sample ledger does not sync to iCloud.") }
            guard store.data.syncEnabled else { throw AssistantFailure("sync_disabled", "Enable iCloud sync in Settings first. Local changes remain saved.") }
            store.requestCloudKitSync(reportProgress: true)
            await store.waitForCloudKitSyncIdle(); try access()
            guard store.cloudSyncProgress.state == .succeeded else { throw AssistantFailure("sync_failed", store.cloudSyncProgress.detail ?? store.cloudSyncProgress.message) }
            return success(appContext()["sync"])
        }
        if name == "open_view" {
            var resolved = a.setting("journal", .string(try journal(a).uuidString))
            if a["account"].string != nil { resolved = resolved.setting("account", .string(try account(a["account"], ledger: try journal(a)).id.uuidString)) }
            if a["transaction"].string != nil { resolved = resolved.setting("transaction", .string(try transaction(a["transaction"]).id.uuidString)) }
            let from = try a["from"].string.map { _ in try date(a["from"]) }
            let to = try a["to"].string.map { _ in try date(a["to"]) }
            if let from, let to, from > to { throw AssistantFailure("invalid_range", "from must not follow to.") }
            if let from { resolved = resolved.setting("from_timestamp", .string(ISO8601DateFormatter().string(from: from))) }
            if let to {
                let end = a["to"].string?.count == 10 ? Calendar.current.date(byAdding: .day, value: 1, to: to)! : to.addingTimeInterval(1)
                resolved = resolved.setting("to_timestamp", .string(ISO8601DateFormatter().string(from: end)))
            }
            openView?(resolved); return success(.object(["status": .string("view_requested")]))
        }
        if name == "export_csv" || name == "export_backup" { return success(try await export(name, a)) }
        if name == "preview_backup" { return success(try await preview(a)) }
        if def.isReadOnly { return success(try read(name, a)) }
        if name == "resolve_conflict" { return try await resolveConflict(call, a) }
        var preparedImport: AssistantPreparedImport?
        var didCommit = false
        defer {
            preparedImports.removeValue(forKey: call.operationID)
            if !didCommit, let directory = preparedImport?.directory { try? FileManager.default.removeItem(at: directory) }
        }
        if name == "import_backup" {
            if let replay = try store.assistantDatabase.assistantAction(scope: scope, id: call.operationID, digest: call.digest) {
                return try JSONDecoder().decode(AssistantJSON.self, from: Data(replay.utf8))
            }
            preparedImport = try await prepareImport(a)
            preparedImports[call.operationID] = preparedImport?.data
            try access()
        }
        let saved = try store.assistantMutate(scope: scope, id: call.operationID, digest: call.digest) {
            try self.access()
            if !self.store.cloudSyncConflicts.isEmpty { throw AssistantFailure("sync_conflict", "Resolve the current iCloud conflicts before editing through the assistant.") }
            let result = try self.mutate(name, a)
            self.invalidateSnapshot()
            return self.success(result.setting("status", .string("saved_locally")).setting("pending_sync", .bool(self.store.data.syncEnabled)))
        }
        didCommit = true
        if name == "import_backup", let id = a["preview_id"].string { discardPreview(id) }
        invalidateSnapshot()
        return saved
    }
    func appContext() -> AssistantJSON {
        let progress = store.cloudSyncProgress
        let binding = try? store.assistantDatabase.assistantBoundIdentity()
        let pending = binding.flatMap { try? store.assistantDatabase.remainingCloudKitChangeCount(contextKey: $0.context) }
        return .object([
            "mode": .string(mode), "journal": .text((context.journalID ?? store.selectedLedgerID)?.uuidString),
            "account": .text(context.accountID?.uuidString), "transaction": .text(context.transactionID?.uuidString),
            "timezone": .string(TimeZone.current.identifier), "today": .string(day(Date())),
            "storage": .string("Reads include local pending edits. Writes commit on this iPhone; iCloud delivery is separate."),
            "sync": .object(["enabled": .bool(store.data.syncEnabled), "running": .bool(progress.isRunning),
                "pending_changes": pending.map { .number(Double($0)) } ?? .null, "synced": .bool(progress.state == .succeeded && pending == 0), "message": .string(progress.message),
                "last_synced_at": .text(store.data.lastSyncedAt.map { ISO8601DateFormatter().string(from: $0) }),
                "conflicts": .number(Double(store.cloudSyncConflicts.count)), "detail": .text(progress.detail),
                "local_save_error": .text(store.localPersistenceError?.message)]),
            "account_types": .array(AccountKind.allCases.map { .string($0.title) }), "snapshot_revision": .string(snapshot)
        ])
    }
    func journal(_ a: AssistantJSON, explicit: Bool = false) throws -> UUID {
        if a["journal"].string != nil { return try resolve(a["journal"], rows: store.data.ledgers.map { ($0.id, $0.name) }, kind: "journal") }
        guard !explicit, let id = context.journalID ?? store.selectedLedgerID, store.ledger(id) != nil else { throw AssistantFailure("journal_required", "Choose an explicit journal.") }; return id
    }
    func resolve(_ value: AssistantJSON, rows: [(UUID, String)], kind: String) throws -> UUID {
        guard let name = value.string else { throw AssistantFailure("invalid_reference", "Supply a \(kind) UUID or exact name.") }
        let matches = rows.filter { $0.0.uuidString.caseInsensitiveCompare(name) == .orderedSame || $0.1.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count == 1 else { throw AssistantFailure(matches.isEmpty ? "not_found" : "ambiguous_reference", matches.isEmpty ? "No matching \(kind). Read the list again." : "Several \(kind)s match: " + matches.map { "\($0.1) (\($0.0))" }.joined(separator: ", ")) }
        return matches[0].0
    }
    func account(_ value: AssistantJSON, ledger: UUID? = nil) throws -> Account {
        let rows = store.data.accounts.filter { ledger == nil || $0.ledgerID == ledger }
        let id = try resolve(value, rows: rows.map { ($0.id, $0.name) }, kind: "account")
        return rows.first { $0.id == id }!
    }
    func currency(_ value: AssistantJSON, ledger: UUID? = nil) throws -> Commodity {
        let rows = store.data.commodities.filter { ledger == nil || $0.ledgerID == ledger }
        guard let text = value.string else { throw AssistantFailure("invalid_reference", "Supply a currency.") }
        let matches = rows.filter { $0.id.uuidString.caseInsensitiveCompare(text) == .orderedSame || $0.name.caseInsensitiveCompare(text) == .orderedSame || $0.symbol.caseInsensitiveCompare(text) == .orderedSame }
        guard matches.count == 1 else { throw AssistantFailure("ambiguous_currency", "Read list_currencies and choose an exact currency UUID.") }; return matches[0]
    }
    func transaction(_ value: AssistantJSON) throws -> LedgerTransaction {
        guard let text = value.string, let id = UUID(uuidString: text), let row = store.transaction(id) else { throw AssistantFailure("not_found", "Read the transaction list and choose an existing transaction UUID.") }; return row
    }
    func template(_ value: AssistantJSON) throws -> TransactionTemplate {
        let id = try resolve(value, rows: store.data.transactionTemplates.map { ($0.id, $0.name) }, kind: "template")
        return store.data.transactionTemplates.first { $0.id == id }!
    }
    func entity<T: Encodable>(_ row: T) throws -> AssistantJSON {
        let value = try AssistantJSON.model(row); return value.setting("revision", .string(try AssistantJSON.modelDigest(row)))
    }
    func transactionValue(_ tx: LedgerTransaction) throws -> AssistantJSON {
        try entity(tx).setting("snapshot_revision", .string(snapshot)).setting("postings", .array(tx.postings.map { p in
            .object(["id": .string(p.id.uuidString), "accountID": .string(p.accountID.uuidString), "account_name": .text(store.account(p.accountID)?.name),
                "commodityID": .text(p.commodityID?.uuidString), "currency_symbol": .text(store.commodity(postingCurrency(p, ledger: tx.ledgerID))?.symbol), "amount": .decimal(p.amount), "listIndex": .number(Double(p.listIndex))])
        }))
    }
    func page(_ rows: [AssistantJSON], _ a: AssistantJSON, revision: String? = nil) throws -> AssistantJSON {
        let rev = revision ?? snapshot, offset = a["offset"].int ?? 0, limit = a["limit"].int ?? 50
        if offset > 0 { guard a["snapshot_revision"].string == rev else { throw AssistantFailure("snapshot_changed", "The data changed. Restart pagination at offset zero.") } }
        let result = Array(rows.dropFirst(offset).prefix(limit)), next = offset + result.count
        return .object(["items": .array(result), "total": .number(Double(rows.count)), "snapshot_revision": .string(rev), "next_offset": next < rows.count ? .number(Double(next)) : .null])
    }
    func checkRevision<T: Encodable>(_ row: T, _ a: AssistantJSON) throws {
        guard a["if_revision"].string == (try AssistantJSON.modelDigest(row)) else { throw AssistantFailure("revision_conflict", "This record changed. Read it again before editing.") }
    }
    func checkSnapshot(_ a: AssistantJSON) throws {
        guard a["snapshot_revision"].string == snapshot else { throw AssistantFailure("snapshot_changed", "The journal changed. Read the current records and review the action again.") }
    }
    func conflictValue(_ conflict: CloudKitSyncConflict) -> AssistantJSON {
        func safe(_ record: CloudKitSyncRecord) -> AssistantJSON {
            .object(["record_type": .string(record.recordType), "record_id": .string(record.recordID), "operation": .string(record.operation), "payload_json": .text(record.payloadJSON), "content_hash": .text(record.contentHash)])
        }
        let value = AssistantJSON.object(["record_name": .string(conflict.id), "local": safe(conflict.local), "remote": safe(conflict.remote)])
        return value.setting("conflict_revision", .string(value.digest))
    }
    func date(_ value: AssistantJSON) throws -> Date {
        guard let text = value.string else { throw AssistantFailure("invalid_date", "Use YYYY-MM-DD or an ISO timestamp with timezone.") }
        if text.count == 10 {
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            if let result = formatter.date(from: text), formatter.string(from: result) == text { return result }
        } else {
            let formatter = ISO8601DateFormatter()
            if let result = formatter.date(from: text) { return result }
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let result = formatter.date(from: text) { return result }
        }
        throw AssistantFailure("invalid_date", "Use a valid YYYY-MM-DD or ISO timestamp with timezone.")
    }
    func day(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    func decimal(_ value: AssistantJSON) throws -> Decimal {
        guard let text = value.string, text.range(of: "^[+-]?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              text.filter(\.isNumber).count <= 38, let result = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !result.isNaN else {
            throw AssistantFailure("invalid_amount", "Use an exact signed decimal string with at most 38 digits.")
        }; return result
    }
    func descendants(_ id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var grew = true
        while grew { let count = result.count; for a in store.data.accounts where a.parentID.map(result.contains) == true { result.insert(a.id) }; grew = result.count != count }
        return result
    }
    func postingCurrency(_ posting: Posting, ledger: UUID) -> UUID? {
        posting.commodityID ?? store.account(posting.accountID)?.commodityID ?? store.data.commodities.first(where: { $0.ledgerID == ledger })?.id
    }
    func filtered(_ a: AssistantJSON, defaultFuture: Bool = true) throws -> [LedgerTransaction] {
        let ledger = try journal(a), query = (a["query"].string ?? "").lowercased()
        let accountIDs: Set<UUID>? = try a["account"].string.map { _ in let id = try account(a["account"], ledger: ledger).id; return a["include_children"].bool == false ? [id] : descendants(id) }
        let currencyID = try a["currency"].string.map { _ in try currency(a["currency"], ledger: ledger).id }
        let from = try a["from"].string.map { _ in try date(a["from"]) }
        let to = try a["to"].string.map { _ in try date(a["to"]) }
        if let from, let to, from > to { throw AssistantFailure("invalid_range", "from must not follow to.") }
        let cutoff = to.map { (a["to"].string?.count == 10) ? Calendar.current.date(byAdding: .day, value: 1, to: $0)! : $0.addingTimeInterval(0.001) }
        let min = try a["min_amount"].string.map { _ in try decimal(a["min_amount"]) }, max = try a["max_amount"].string.map { _ in try decimal(a["max_amount"]) }
        if min != nil || max != nil { guard accountIDs != nil || currencyID != nil else { throw AssistantFailure("currency_required", "Amount filters need an account or currency.") } }
        let future = a["include_future"].bool ?? defaultFuture
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        return store.data.transactions.filter { tx in
            guard tx.ledgerID == ledger, (from == nil || tx.date >= from!), (cutoff == nil || tx.date < cutoff!),
                future || tx.date < tomorrow, a["cleared"].bool == nil || tx.cleared == a["cleared"].bool else { return false }
            if !query.isEmpty && !(tx.payee + " " + tx.note + " " + tx.number + " " + tx.postings.compactMap { store.account($0.accountID)?.name }.joined(separator: " ")).lowercased().contains(query) { return false }
            return tx.postings.contains { p in
                let c = postingCurrency(p, ledger: ledger)
                return (accountIDs == nil || accountIDs!.contains(p.accountID)) && (currencyID == nil || currencyID == c) && (min == nil || p.amount >= min!) && (max == nil || p.amount <= max!)
            }
        }.sorted {
            if a["sort"].string == "payee_asc", $0.payee != $1.payee { return $0.payee.localizedCaseInsensitiveCompare($1.payee) == .orderedAscending }
            if $0.date != $1.date { return a["sort"].string == "date_asc" ? $0.date < $1.date : $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    func read(_ name: String, _ a: AssistantJSON) throws -> AssistantJSON {
        if name == "get_transaction" { return try transactionValue(transaction(a["id"])) }
        if name == "list_transactions" || name == "search_entries" { return try page(filtered(a).map(transactionValue), a) }
        if name == "list_attachments" {
            let tx = try transaction(a["transaction"])
            return .object(["transaction": .string(tx.id.uuidString), "revision": .string(try AssistantJSON.modelDigest(tx)), "items": .array(try (tx.attachment?.assets ?? []).map(entity))])
        }
        if name == "get_balances" { return try balances(a) }
        if name == "get_summary" { return try summary(a) }
        if name == "get_suggestions" {
            let ledger = try journal(a), prefix = (a["prefix"].string ?? "").lowercased()
            let values = Set(store.data.transactions.filter { $0.ledgerID == ledger }.map { a["field"].string == "note" ? $0.note : $0.payee }.filter { !$0.isEmpty && $0.lowercased().hasPrefix(prefix) }).sorted()
            return .object(["values": .array(values.prefix(a["limit"].int ?? 30).map(AssistantJSON.string))])
        }
        if name == "list_conflicts" {
            let conflicts = store.cloudKitSyncConflicts().map(conflictValue)
            return try page(conflicts, a, revision: AssistantJSON.array(conflicts).digest)
        }
        let ledger = name == "list_journals" ? nil : try journal(a)
        var rows: [AssistantJSON]
        switch name {
        case "list_journals": rows = try store.data.ledgers.sorted { $0.listIndex < $1.listIndex }.map(entity)
        case "list_accounts": rows = try store.data.accounts.filter { $0.ledgerID == ledger }.map { try entity($0).setting("kind", .string($0.kind.title)) }
        case "list_currencies": rows = try store.data.commodities.filter { $0.ledgerID == ledger }.map(entity)
        case "list_templates": rows = try store.data.transactionTemplates.filter { $0.ledgerID == ledger }.map { try entity($0).setting("accounts", .array($0.postings.map { .text($0.accountID?.uuidString) })) }
        default: throw AssistantFailure("unknown_tool", "Unknown read tool.")
        }
        if let id = a["id"].string { rows = rows.filter { $0["id"].string?.caseInsensitiveCompare(id) == .orderedSame || $0["name"].string?.caseInsensitiveCompare(id) == .orderedSame } }
        if let query = a["query"].string { rows = rows.filter { ($0["name"].string ?? "").localizedCaseInsensitiveContains(query) } }
        return try page(rows, a)
    }
    func balances(_ a: AssistantJSON) throws -> AssistantJSON {
        var filterValues = a.object; filterValues.removeValue(forKey: "account")
        var filters = AssistantJSON.object(filterValues)
        if a["as_of"].string != nil { filters = filters.setting("to", a["as_of"]).setting("include_future", .bool(true)) }
        let txs = try filtered(filters, defaultFuture: false), ledger = try journal(a)
        let selected = try a["account"].string.map { _ in try account(a["account"], ledger: ledger).id }
        let targets = store.data.accounts.filter { $0.ledgerID == ledger && (selected == nil || $0.id == selected) }
        let rows = targets.map { account -> AssistantJSON in
            let ids = a["include_children"].bool == false ? Set([account.id]) : descendants(account.id)
            var totals: [String: Decimal] = [:]
            for tx in txs { for p in tx.postings where ids.contains(p.accountID) {
                let c = postingCurrency(p, ledger: ledger)?.uuidString ?? "unspecified"
                totals[c, default: 0] += p.amount
            } }
            return .object(["id": .string(account.id.uuidString), "name": .string(account.name), "balances": .array(totals.keys.sorted().map { key in
                .object(["currency_id": .string(key), "symbol": .text(store.commodity(UUID(uuidString: key))?.symbol), "amount": .decimal(totals[key]!)])
            })])
        }
        return .object(["journal_id": .string(ledger.uuidString), "accounts": .array(rows), "as_of": a["as_of"].string.map(AssistantJSON.string) ?? (a["include_future"].bool == true ? .null : .string(day(Date()))), "snapshot_revision": .string(snapshot)])
    }
    func summary(_ a: AssistantJSON) throws -> AssistantJSON {
        let ledger = try journal(a), transactions = try filtered(a, defaultFuture: false)
        let selected = try a["currency"].string.map { _ in try currency(a["currency"], ledger: ledger).id }
        let currencies = store.data.commodities.filter { $0.ledgerID == ledger && (selected == nil || $0.id == selected) }
        func totals(_ rows: [LedgerTransaction], currencyID: UUID) -> AssistantJSON {
            var income: Decimal = 0, expenses: Decimal = 0, categories: [UUID: Decimal] = [:]
            for tx in rows { for posting in tx.postings where postingCurrency(posting, ledger: ledger) == currencyID {
                guard let account = store.account(posting.accountID), account.kind == .income || account.kind == .expense else { continue }
                let amount = account.kind == .income ? -posting.amount : posting.amount
                if account.kind == .income { income += amount } else { expenses += amount }
                categories[account.id, default: 0] += amount
            } }
            return .object(["income": .decimal(income), "expenses": .decimal(expenses), "net": .decimal(income - expenses),
                "categories": .array(categories.keys.sorted { $0.uuidString < $1.uuidString }.map { id in
                    .object(["account_id": .string(id.uuidString), "name": .text(store.account(id)?.name), "amount": .decimal(categories[id]!)])
                })])
        }
        let months = Set(transactions.map { String(day($0.date).prefix(7)) }).sorted()
        return .object(["journal_id": .string(ledger.uuidString), "from": a["from"], "to": a["to"],
            "include_future": .bool(a["include_future"].bool ?? false), "currencies": .array(currencies.map { currency in
                totals(transactions, currencyID: currency.id).setting("currency_id", .string(currency.id.uuidString)).setting("symbol", .string(currency.symbol))
                    .setting("months", .array(months.map { month in
                        totals(transactions.filter { day($0.date).hasPrefix(month) }, currencyID: currency.id).setting("month", .string(month))
                    }))
            }), "snapshot_revision": .string(snapshot)])
    }
}
