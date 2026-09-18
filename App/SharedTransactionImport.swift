import Foundation

extension SharedTransactionCatalog {
    init(data: JournalData, hiddenLedgerIDs: Set<UUID>) {
        let visible = data.ledgers.filter { !hiddenLedgerIDs.contains($0.id) }.sorted { $0.listIndex < $1.listIndex }
        let ids = Set(visible.map(\.id))
        self.init(journals: visible.map { .init(id: $0.id, name: $0.name) },
                  accounts: data.accounts.filter { ids.contains($0.ledgerID) && !$0.isGroup }
                    .sorted { $0.listIndex < $1.listIndex }
                    .map { account in .init(id: account.id, journalID: account.ledgerID, name: account.name, kind: account.kind.rawValue,
                                 currencyID: account.commodityID ?? data.commodities.first { $0.ledgerID == account.ledgerID }?.id,
                                 parentID: account.parentID, colorName: account.colorName,
                                 note: account.note, listIndex: account.listIndex) },
                  currencies: data.commodities.filter { ids.contains($0.ledgerID) }
                    .map { .init(id: $0.id, journalID: $0.ledgerID, symbol: $0.symbol, name: $0.name) },
                  selectedJournalID: data.selectedLedgerID, locked: data.security.passwordLockEnabled)
        // Password protected journals must not expose their catalog in a host app.
        if locked { journals = []; accounts = []; currencies = [] }
    }
}

@MainActor
enum SharedTransactionImport {
    static func save(_ entry: SharedReceiptEntry, inbox: SharedReceiptInbox, store: MobileLedgerStore) async throws {
        guard let transaction = entry.transaction else { return }
        let hidden = JournalVisibility(rawValue: MobileDisplayPreferences.defaults.string(forKey: JournalVisibility.preferenceKey) ?? "").hiddenIDs
        try transaction.validate(in: SharedTransactionCatalog(data: store.data, hiddenLedgerIDs: hidden))
        var draft = transaction.draft(operationID: entry.id)
        let generation = store.attachmentImportGeneration
        do {
            for url in try await inbox.fileURLs(for: entry) {
                draft.attachments.append(try await store.importAttachmentAsync(from: url, expectedGeneration: generation))
            }
            guard await store.saveTransactionAndFlushAsync(draft) else {
                throw store.validationError ?? ValidationError(message: "Could not save the shared transaction. Your saved share is preserved.")
            }
        } catch {
            store.discardUnreferencedImportedAttachments(draft.attachments)
            throw error
        }
        try await inbox.discard(entry.id)
    }
}
