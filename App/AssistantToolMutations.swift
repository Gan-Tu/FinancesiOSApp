import Foundation

extension AssistantTools {
    func mutate(_ name: String, _ a: AssistantJSON) throws -> AssistantJSON {
        if name == "import_backup" { return try importPreview(a) }
        if name.hasSuffix("_attachment") { return try mutateAttachment(name, a) }
        if ["create_transaction", "update_transaction", "delete_transaction", "duplicate_transaction", "create_from_template"].contains(name) { return try mutateTransaction(name, a) }
        let pieces = name.split(separator: "_").map(String.init)
        guard pieces.count == 2 else { throw AssistantFailure("unknown_tool", "Unknown finance action.") }
        let op = pieces[0], type = pieces[1]
        var id: UUID?
        switch type {
        case "journal":
            if op == "create" {
                id = try store.assistantCreateJournal(name: a.required("name"), symbol: a["currency_symbol"].string ?? "USD", currencyName: a["currency_name"].string ?? "US Dollar", position: a["position"].int)
            } else {
                let target = try resolve(a["id"], rows: store.data.ledgers.map { ($0.id, $0.name) }, kind: "journal")
                let row = store.ledger(target)!; try checkRevision(row, a); id = target
                if op == "delete" { try checkSnapshot(a); store.deleteJournal(target) }
                else {
                    if let name = a["name"].string { store.renameJournal(target, name: name) }
                    if let position = a["position"].int { store.assistantSetJournalPosition(target, position: position) }
                }
            }
        case "account":
            let old = op == "create" ? nil : try account(a["id"])
            if let old { try checkRevision(old, a) }
            if op == "delete", let old {
                let referenced = store.data.accounts.contains { $0.parentID == old.id }
                    || store.data.transactions.contains { $0.postings.contains { $0.accountID == old.id } }
                    || store.data.transactionTemplates.contains { $0.postings.contains { $0.accountID == old.id } }
                guard !referenced else { throw AssistantFailure("record_in_use", "Move transactions, templates and child accounts before deleting this account.") }
                store.deleteAccount(old.id); id = old.id
            } else {
                let ledger = try old?.ledgerID ?? journal(a, explicit: true)
                var draft = old.map { store.draft(for: $0) } ?? MobileAccountDraft(ledgerID: ledger)
                if old == nil { draft.commodityID = store.data.commodities.first { $0.ledgerID == ledger }?.id; draft.isGroup = true }
                if let name = a["name"].string { draft.name = name }
                if let note = a["note"].string { draft.note = note }
                if let kind = a["kind"].string { guard let k = AccountKind.allCases.first(where: { $0.title == kind }) else { throw AssistantFailure("invalid_kind", "Choose an account type.") }; draft.kind = k }
                if a.object["parent"] != nil { draft.parentID = try a["parent"] == .null ? nil : account(a["parent"], ledger: ledger).id; draft.isGroup = draft.parentID == nil }
                if a.object["currency"] != nil { draft.commodityID = try a["currency"] == .null ? nil : currency(a["currency"], ledger: ledger).id }
                if let color = a["color"].string { draft.colorName = color }
                id = store.saveAccount(draft)
                if let id, let position = a["position"].int { store.assistantSetAccountPosition(id, position: position) }
            }
        case "currency":
            let old = op == "create" ? nil : try currency(a["id"])
            if let old { try checkRevision(old, a) }
            if op == "delete", let old {
                guard !store.data.accounts.contains(where: { $0.commodityID == old.id }), !store.data.transactions.contains(where: { $0.postings.contains { $0.commodityID == old.id } }) else { throw AssistantFailure("record_in_use", "This currency is still used by accounts or transactions.") }
                store.deleteCurrency(old.id); id = old.id
            } else {
                var draft = try old.map { store.draft(for: $0) } ?? CurrencyDraft(ledgerID: journal(a, explicit: true))
                if let name = a["name"].string { draft.name = name }
                if let symbol = a["symbol"].string { draft.symbol = symbol }
                id = store.saveCurrency(draft)
            }
        case "template":
            let old = op == "create" ? nil : try template(a["id"])
            if let old { try checkRevision(old, a) }
            if op == "delete", let old { store.deleteTransactionTemplate(old.id); id = old.id }
            else {
                var draft = try old.map { store.templateDraft(for: $0) } ?? TransactionTemplateDraft(ledgerID: journal(a, explicit: true))
                if let value = a["name"].string { draft.name = value }
                if let value = a["payee"].string { draft.payee = value }
                if let value = a["note"].string { draft.note = value }
                if let value = a["cleared"].bool { draft.cleared = value }
                if let value = a["enabled"].bool { draft.enabled = value }
                if a.object["accounts"] != nil { draft.postings = try a["accounts"].array.map { PostingTemplateDraft(accountID: try account($0, ledger: draft.ledgerID).id) } }
                id = store.saveTransactionTemplate(draft)
            }
        default: throw AssistantFailure("unknown_tool", "Unknown finance entity.")
        }
        if let error = store.validationError { throw error }
        guard let id else { throw AssistantFailure("save_failed", "The record was not saved.") }
        invalidateSnapshot()
        if op == "delete" { return .object(["id": .string(id.uuidString), "deleted": .bool(true)]) }
        switch type {
        case "journal": return try entity(store.ledger(id)!)
        case "account": return try entity(store.account(id)!)
        case "currency": return try entity(store.commodity(id)!)
        default: return try entity(store.data.transactionTemplates.first { $0.id == id }!)
        }
    }

    func mutateTransaction(_ name: String, _ a: AssistantJSON) throws -> AssistantJSON {
        let scope: RecurringJournalEditor.Scope = a["scope"].string == "future" ? .future : .occurrence
        var draft: TransactionDraft
        let old: LedgerTransaction?
        if name == "create_transaction" { old = nil; draft = TransactionDraft(ledgerID: try journal(a, explicit: true)) }
        else if name == "create_from_template" {
            old = nil
            let t = try template(a["id"]); try checkRevision(t, a)
            guard t.enabled else { throw AssistantFailure("template_disabled", "This template is disabled.") }
            draft = store.draft(for: t)
            guard a["amounts"].array.count == draft.postings.count else { throw AssistantFailure("invalid_postings", "Supply one amount per template account slot.") }
            for i in draft.postings.indices { draft.postings[i].amount = NSDecimalNumber(decimal: try decimal(a["amounts"].array[i])).stringValue }
        } else {
            old = try transaction(a["id"]); try checkRevision(old!, a)
            if old!.recurrenceRule != nil && name != "duplicate_transaction" { try checkSnapshot(a) }
            if name == "delete_transaction" {
                store.deleteTransaction(old!.id, scope: scope, expected: old)
                if let error = store.validationError { throw error }
                return .object(["id": .string(old!.id.uuidString), "deleted": .bool(true)])
            }
            if name == "duplicate_transaction" {
                guard let copy = store.duplicateTransactionDraft(old!.id, useToday: false) else { throw AssistantFailure("not_found", "This transaction was removed.") }
                draft = copy
                if a["repeat"].bool == true, let rule = old!.recurrenceRule {
                    guard rule.frequency != .custom else { throw AssistantFailure("unsupported_recurrence", "Custom imported schedules cannot be duplicated as a new repeating series.") }
                    draft.repeatFrequency = rule.frequency; draft.repeatIntervalValue = rule.intervalValue
                    draft.repeatOnWorkdays = rule.onWorkdays; draft.repeatOccurrenceCount = rule.occurrenceCount; draft.repeatEndDate = rule.endDate
                }
            } else { draft = store.draft(for: old!) }
        }
        if let id = UUID(uuidString: try a.required("request_id")) { draft.saveOperationID = id }
        if a["date"].string != nil { draft.date = try date(a["date"]) }
        if let text = a["payee"].string { draft.payee = text }
        if let text = a["note"].string { draft.note = text }
        if let text = a["number"].string { draft.number = text }
        if let cleared = a["cleared"].bool { draft.cleared = cleared }
        if a.object["postings"] != nil {
            draft.postings = try a["postings"].array.map { p in
                let acc = try account(p["account"], ledger: draft.ledgerID)
                let amount = try decimal(p["amount"])
                guard amount != 0 else { throw AssistantFailure("zero_posting", "New postings must be nonzero.") }
                let cid = try p["currency"].string == nil ? acc.commodityID : currency(p["currency"], ledger: draft.ledgerID).id
                return PostingDraft(accountID: acc.id, amount: NSDecimalNumber(decimal: amount).stringValue, commodityID: cid)
            }
        }
        if let recurrence = a.object["recurrence"] {
            if let old, old.recurrenceRule != nil, scope != .future { throw AssistantFailure("recurrence_scope", "Changing a schedule requires scope=future.") }
            if let old, let rule = old.recurrenceRule {
                guard store.data.transactions.filter({ $0.recurrenceRule?.id == rule.id }).min(by: { $0.date < $1.date })?.id == old.id else { throw AssistantFailure("recurrence_anchor", "Change the repeating schedule from its first entry.") }
            }
            if recurrence == .null { draft.repeatFrequency = .never; draft.repeatOccurrenceCount = nil; draft.repeatEndDate = nil }
            else {
                guard let frequency = RecurrenceFrequency(rawValue: try recurrence.required("frequency")), frequency != .custom, frequency != .never else { throw AssistantFailure("invalid_recurrence", "Use a supported Gregorian frequency.") }
                guard recurrence["count"].int == nil || recurrence["end_date"].string == nil else { throw AssistantFailure("invalid_recurrence", "Supply count or end_date, not both.") }
                draft.repeatFrequency = frequency; draft.repeatIntervalValue = recurrence["interval"].int ?? 1
                draft.repeatOnWorkdays = recurrence["on_workdays"].bool ?? false; draft.repeatOccurrenceCount = recurrence["count"].int
                draft.repeatEndDate = try recurrence["end_date"].string.map { _ in try date(recurrence["end_date"]) }
            }
        }
        let id = try store.assistantSaveTransaction(draft, scope: scope)
        invalidateSnapshot()
        guard let saved = store.transaction(id) else { throw AssistantFailure("save_failed", "No saved transaction was returned.") }
        return try transactionValue(saved)
    }

    func attachment(_ tx: LedgerTransaction, _ value: AssistantJSON) throws -> AttachmentAsset {
        guard let raw = value.string, let id = UUID(uuidString: raw), let asset = tx.attachment?.assets.first(where: { $0.id == id }) else { throw AssistantFailure("attachment_missing", "This receipt is no longer attached to that transaction.") }; return asset
    }
    func mutateAttachment(_ name: String, _ a: AssistantJSON) throws -> AssistantJSON {
        let tx = try transaction(a["transaction"]); try checkRevision(tx, a)
        var draft = store.draft(for: tx)
        var index: Int?
        if name != "add_attachment" { let asset = try attachment(tx, a["asset_id"]); index = draft.attachments.firstIndex { $0.id == asset.id } }
        if name == "delete_attachment" { draft.attachments.remove(at: index!) }
        else {
            if let file = a["file_id"].string {
                let url = try stagedFile(file); try checkFile(url, maximum: 15 * 1024 * 1024)
                var asset = try store.importAttachment(from: url)
                if let filename = a["filename"].string { asset.originalFilename = safeFilename(filename) }
                if let index { draft.attachments[index] = asset } else { draft.attachments.append(asset) }
            } else if let filename = a["filename"].string, let index { draft.attachments[index].originalFilename = safeFilename(filename) }
            else { throw AssistantFailure("invalid_arguments", "Choose a replacement file or filename.") }
        }
        let id = try store.assistantSaveTransaction(draft, scope: .occurrence)
        return try transactionValue(store.transaction(id)!)
    }

    func resolveConflict(_ call: AssistantToolCall, _ a: AssistantJSON) async throws -> AssistantJSON {
        if let result = try store.assistantDatabase.assistantAction(scope: scope, id: call.operationID, digest: call.digest) { return try JSONDecoder().decode(AssistantJSON.self, from: Data(result.utf8)) }
        guard let conflict = store.cloudKitSyncConflicts().first(where: { $0.id == a["record_name"].string }) else { throw AssistantFailure("conflict_changed", "This conflict no longer exists. Read current records; do not repeat the resolution.") }
        guard a["conflict_revision"].string == conflictValue(conflict)["conflict_revision"].string else { throw AssistantFailure("revision_conflict", "This conflict changed. Review both versions again.") }
        let result = success(.object(["status": .string("saved_locally"), "record_name": a["record_name"], "kept": a["keep"]]))
        try await store.assistantResolveConflict(conflict, keepLocal: a["keep"].string == "local", scope: scope, operationID: call.operationID, digest: call.digest, result: result.jsonString)
        invalidateSnapshot(); return result
    }
}
