import Foundation

/// Uses the same graph remapping rules as native macOS backup import.
enum AssistantBackup {
    static func remap(_ source: JournalData, names: [UUID: String], paths: [String: String], sizes: [String: Int64]) throws -> JournalData {
        let source = RecurringJournalEditor.materialized(RecurringJournalEditor.resumingRecurrencesFromBackup(source))
        var result = source
        var identifiers: [UUID: UUID] = [:]
        // Date ties are ordered by transaction UUID throughout the app. A
        // fresh random namespace with ordered suffixes preserves that order
        // without reusing any source transaction identity.
        let namespace = String(UUID().uuidString.prefix(28))
        for (index, oldID) in source.transactions.map(\.id).sorted(by: { $0.canonicallyPrecedes($1) }).enumerated() {
            guard index <= UInt32.max, let newID = UUID(uuidString: namespace + String(format: "%08X", index)) else {
                throw AssistantFailure("invalid_backup", "The backup has too many transactions.")
            }
            identifiers[oldID] = newID
        }
        func mapped(_ old: UUID) -> UUID {
            if let found = identifiers[old] { return found }
            let new = UUID(); identifiers[old] = new; return new
        }
        func posting(_ value: Posting) -> Posting {
            var copy = value; copy.id = mapped(value.id); copy.accountID = mapped(value.accountID)
            copy.commodityID = value.commodityID.map(mapped); return copy
        }
        func template(_ value: RecurrenceTransactionTemplate) -> RecurrenceTransactionTemplate {
            var copy = value; copy.postings = value.postings.map(posting); return copy
        }
        result.ledgers = source.ledgers.map { old in
            var value = old; value.id = mapped(old.id)
            value.name = names[old.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? old.name
            value.preservesImportedRecurringMaterializations = source.preservesRecurringMaterializations(in: old.id)
            return value
        }
        result.commodities = source.commodities.map { old in var value = old; value.id = mapped(old.id); value.ledgerID = mapped(old.ledgerID); return value }
        result.accounts = source.accounts.map { old in
            var value = old; value.id = mapped(old.id); value.ledgerID = mapped(old.ledgerID)
            value.parentID = old.parentID.map(mapped); value.commodityID = old.commodityID.map(mapped); return value
        }
        result.sources = source.sources.map { old in var value = old; value.id = mapped(old.id); value.ledgerID = mapped(old.ledgerID); return value }
        result.transactions = try source.transactions.map { old in
            var value = old; value.id = mapped(old.id); value.ledgerID = mapped(old.ledgerID)
            value.sourceID = old.sourceID.map(mapped); value.postings = old.postings.map(posting)
            if var rule = old.recurrenceRule {
                rule.id = mapped(rule.id)
                // The portable cursor continues under the fresh rule ID while
                // older clients preserve the already-covered imported range.
                rule.preservesImportedMaterializations = true
                if var history = rule.templateHistory {
                    history.baseTemplate = template(history.baseTemplate)
                    history.changes = history.changes.map { change in var copy = change; copy.template = template(change.template); return copy }
                    rule.templateHistory = history
                }
                value.recurrenceRule = rule
            }
            if let attachment = old.attachment {
                var copy = attachment
                copy.id = UUID()
                copy.assets = try attachment.assets.map { asset in
                    guard let path = paths[asset.storedPath] else { throw AssistantFailure("invalid_backup", "A receipt was not staged.") }
                    var result = asset
                    result.id = UUID()
                    result.storedPath = path; result.sizeBytes = sizes[asset.storedPath] ?? asset.sizeBytes
                    return result
                }
                value.attachment = copy
            }
            return value
        }
        result.transactionTemplates = source.transactionTemplates.map { old in
            var value = old; value.id = mapped(old.id); value.ledgerID = mapped(old.ledgerID)
            value.postings = old.postings.map { oldPosting in
                var copy = oldPosting; copy.id = mapped(oldPosting.id); copy.accountID = oldPosting.accountID.map(mapped); return copy
            }
            return value
        }
        result.selectedLedgerID = result.ledgers.first?.id
        result.syncEnabled = false; result.lastSyncedAt = nil
        return result
    }

}
