import Foundation

/// An unresolved capture must acquire its actual currency before account
/// defaults can participate in saving. Once resolved, currency edits are owned
/// by the user and later catalog updates must not overwrite them.
struct IncomingCaptureCurrency: Equatable {
    let code: String
    private var journalID: UUID?
    private(set) var needsResolution: Bool

    init(code: String, draft: TransactionDraft) {
        self.code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        journalID = draft.ledgerID
        needsResolution = !self.code.isEmpty && draft.postings.contains { $0.commodityID == nil }
    }

    func preventsSaving(draft: TransactionDraft, commodities: [Commodity]) -> Bool {
        !code.isEmpty && (needsResolution || journalID != draft.ledgerID || matchingCurrency(in: commodities, ledgerID: draft.ledgerID) == nil)
    }

    mutating func reconcile(draft: inout TransactionDraft, commodities: [Commodity]) {
        if journalID != draft.ledgerID {
            journalID = draft.ledgerID
            needsResolution = !code.isEmpty
            for index in draft.postings.indices {
                draft.postings[index].accountID = nil
                draft.postings[index].commodityID = nil
            }
        }
        guard needsResolution, let currency = matchingCurrency(in: commodities, ledgerID: draft.ledgerID) else { return }
        for index in draft.postings.indices { draft.postings[index].commodityID = currency.id }
        needsResolution = false
    }

    private func matchingCurrency(in commodities: [Commodity], ledgerID: UUID?) -> Commodity? {
        guard let ledgerID else { return nil }
        return commodities.first { $0.ledgerID == ledgerID && $0.symbol.caseInsensitiveCompare(code) == .orderedSame }
    }
}
