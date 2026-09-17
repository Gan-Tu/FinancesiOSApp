import Foundation

extension AssistantTools {
    func approvalPreview(_ call: AssistantToolCall) throws -> (text: String, fingerprint: String) {
        let a = call.args
        let text: String
        switch call.name {
        case "import_backup":
            guard let preview = previews[try a.required("preview_id")] else { throw AssistantFailure("preview_expired", "Preview the backup again before reviewing the import.") }
            let data = preview.data
            let journals = data.ledgers.map { journal in "• \(journal.name): \(data.transactions.filter { $0.ledgerID == journal.id }.count) transactions" }.joined(separator: "\n")
            text = "Import as NEW journals:\n\(journals)\n\(data.accounts.count) accounts · \(data.transactions.count) transactions · \(data.transactions.reduce(0) { $0 + ($1.attachment?.assets.count ?? 0) }) receipts\nYour existing journals remain unchanged."
        case "resolve_conflict":
            guard let conflict = store.cloudKitSyncConflicts().first(where: { $0.id == a["record_name"].string }) else { throw AssistantFailure("conflict_changed", "This conflict is no longer available.") }
            guard conflictValue(conflict)["conflict_revision"] == a["conflict_revision"] else { throw AssistantFailure("revision_conflict", "The conflict changed. Read both versions again.") }
            text = "Keep \(a["keep"].string == "local" ? "this iPhone’s" : "iCloud’s") version of this \(conflict.local.recordType.replacingOccurrences(of: "_", with: " ")).\n\n\(conflictComparison(conflict))\n\nThe other version will be discarded."
        case "delete_attachment":
            let tx = try transaction(a["transaction"]); try checkRevision(tx, a)
            let asset = try attachment(tx, a["asset_id"])
            text = "Remove receipt “\(asset.originalFilename)” (\(asset.sizeBytes) bytes) from:\n\(transactionDescription(tx))\nOther receipts and transaction fields remain unchanged."
        case "delete_transaction":
            let tx = try transaction(a["id"]); try checkRevision(tx, a)
            if tx.recurrenceRule != nil { try checkSnapshot(a) }
            text = "Delete:\n\(transactionDescription(tx))\n" + (a["scope"].string == "future" ? "This and future occurrences in this repeating series." : "This occurrence only.")
        case "delete_journal":
            let id = try resolve(a["id"], rows: store.data.ledgers.map { ($0.id, $0.name) }, kind: "journal")
            let ledger = store.ledger(id)!; try checkRevision(ledger, a); try checkSnapshot(a)
            let transactions = store.data.transactions.filter { $0.ledgerID == id }
            text = "Delete journal “\(ledger.name)” and all of its contents:\n\(store.data.accounts.filter { $0.ledgerID == id }.count) accounts · \(transactions.count) transactions · \(store.data.transactionTemplates.filter { $0.ledgerID == id }.count) templates · \(transactions.reduce(0) { $0 + ($1.attachment?.assets.count ?? 0) }) receipts."
        case "delete_account":
            let record = try account(a["id"]); try checkRevision(record, a)
            text = "Delete “\(record.name)” (\(record.kind.title)) in \(store.ledger(record.ledgerID)?.name ?? "Journal").\nDeletion is refused if transactions, templates, or child accounts still reference it."
        case "delete_currency":
            let record = try currency(a["id"]); try checkRevision(record, a)
            text = "Delete “\(record.name)” (\(record.symbol)) in \(store.ledger(record.ledgerID)?.name ?? "Journal").\nDeletion is refused while records still use it."
        case "delete_template":
            let record = try template(a["id"]); try checkRevision(record, a)
            text = "Delete template “\(record.name)” in \(store.ledger(record.ledgerID)?.name ?? "Journal").\nPayee: \(record.payee)\nExisting transactions remain unchanged."
        default: throw AssistantFailure("review_unavailable", "This action has no supported review preview.")
        }
        return (text, AssistantJSON.object(["action": .string(call.digest), "snapshot": .string(snapshot), "preview": .string(text)]).digest)
    }
    private func transactionDescription(_ tx: LedgerTransaction) -> String {
        let postings = tx.postings.map { p in "\(store.account(p.accountID)?.name ?? "Account"): \(NSDecimalNumber(decimal: p.amount).stringValue) \(store.commodity(postingCurrency(p, ledger: tx.ledgerID))?.symbol ?? "")" }.joined(separator: "\n")
        let receipts = tx.attachment?.assets.map(\.originalFilename).joined(separator: ", ") ?? "None"
        return "\(store.ledger(tx.ledgerID)?.name ?? "Journal") · \(day(tx.date))\n\(tx.payee)\n\(tx.note)\nReference: \(tx.number.isEmpty ? "None" : tx.number) · Cleared: \(tx.cleared ? "Yes" : "No")\n\(postings)\nReceipts: \(receipts)"
    }
    func conflictComparison(_ conflict: CloudKitSyncConflict) -> String {
        let local = conflictFields(conflict.local), remote = conflictFields(conflict.remote)
        let keys = Set(local.keys).union(remote.keys).sorted()
        let changed = keys.filter { local[$0] != remote[$0] }
        return (changed.isEmpty ? keys : changed).map { key in
            "\(key)\nThis iPhone: \(local[key] ?? "None")\niCloud: \(remote[key] ?? "None")"
        }.joined(separator: "\n\n")
    }
    private func conflictFields(_ record: CloudKitSyncRecord) -> [String: String] {
        if record.operation == "delete" { return ["Record": "Deleted"] }
        guard let payload = record.payloadJSON else { return ["Record": "No contents"] }
        if record.recordType == "transaction", let tx = try? JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: Data(payload.utf8)) {
            let postings = tx.postings.enumerated().map { index, p in
                "\(index + 1). \(store.account(p.accountID)?.name ?? "Account") [\(p.accountID)]: \(NSDecimalNumber(decimal: p.amount).stringValue) \(store.commodity(postingCurrency(p, ledger: tx.ledgerID))?.symbol ?? "")"
            }.joined(separator: "\n")
            return ["Journal": store.ledger(tx.ledgerID)?.name ?? tx.ledgerID.uuidString, "Date": ISO8601DateFormatter().string(from: tx.date),
                "Payee": tx.payee, "Note": tx.note, "Reference number": tx.number, "Cleared": tx.cleared ? "Yes" : "No", "Postings": postings,
                "Recurring schedule": tx.recurrenceRule.flatMap { try? JSONEncoder.appEncoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "None",
                "Receipts": tx.attachment.map { container in container.assets.map { "\($0.originalFilename) [\($0.id)] · \($0.sizeBytes) bytes · \($0.mimeType ?? "unknown type")" }.joined(separator: "\n") } ?? "None",
                "Source": tx.sourceID?.uuidString ?? "None", "External reference": tx.externalTransactionID ?? "None"]
        }
        guard let object = try? JSONDecoder().decode(AssistantJSON.self, from: Data(payload.utf8)) else { return ["Content": payload] }
        var fields: [String: String] = [:]
        let labels = ["parentID": "Parent account", "commodityID": "Currency", "kind": "Account type", "listIndex": "Order", "ledgerID": "Journal", "originalFilename": "Filename", "sizeBytes": "Size in bytes", "mimeType": "File type"]
        for (key, value) in object.object where !["storedPath", "assetFileURL"].contains(key) {
            var display = value.string ?? value.jsonString
            if key == "parentID", let id = value.string.flatMap(UUID.init(uuidString:)) { display = "\(store.account(id)?.name ?? "Account") [\(id)]" }
            if key == "commodityID", let id = value.string.flatMap(UUID.init(uuidString:)) { display = "\(store.commodity(id)?.symbol ?? "Currency") [\(id)]" }
            if key == "kind", let raw = value.int, let kind = AccountKind(rawValue: raw) { display = kind.title }
            fields[labels[key] ?? key] = display
        }
        if let checksum = record.assetSHA256 { fields["Receipt checksum"] = checksum }
        return fields
    }
}
