import Foundation

/// Balancing is arithmetic within one currency, never an exchange-rate guess.
enum PostingBalance {
    static func settingAmount(_ text: String, at index: Int, in draft: TransactionDraft, accounts: [Account], commodities: [Commodity] = []) -> TransactionDraft {
        guard draft.postings.indices.contains(index) else { return draft }
        var updated = draft
        updated.postings[index].amount = text
        guard updated.postings.count == 2, let value = decimalFromInput(text) else { return updated }
        // Focus/writeback and '=' may normalize the same numeric value. They
        // must not silently repair an imbalance left by removing a split row.
        guard decimalFromInput(draft.postings[index].amount) != value else { return updated }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let defaults = Dictionary(grouping: commodities, by: \.ledgerID).compactMapValues { $0.first?.id }
        func currency(_ posting: PostingDraft) -> UUID? {
            let account = posting.accountID.flatMap { byID[$0] }
            return posting.commodityID ?? account?.commodityID ?? account.flatMap { defaults[$0.ledgerID] }
        }
        let other = 1 - index
        if let selectedCurrency = currency(updated.postings[index]), selectedCurrency == currency(updated.postings[other]) {
            updated.postings[other].amount = decimalInputString(-value)
        }
        return updated
    }

    static func balancing(_ draft: TransactionDraft, focusedPostingID: UUID? = nil, accounts: [Account], commodities: [Commodity] = []) throws -> TransactionDraft {
        guard draft.postings.count >= 2 else {
            throw ValidationError(message: "Add at least two postings before balancing.")
        }
        // A single missing amount is the intended balancing leg, even if the
        // keyboard is still on the deduction the user just finished entering.
        let missing = draft.postings.indices.filter { index in
            let text = draft.postings[index].amount.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text == "-" || text == "−" || decimalFromInput(text) == 0
        }
        let focused = draft.postings.firstIndex { $0.id == focusedPostingID }
        let index = missing.count == 1 ? missing[0] : (focused ?? draft.postings.count - 1)
        let amount = try amount(forPostingAt: index, in: draft, accounts: accounts, commodities: commodities)
        var updated = draft
        updated.postings[index].amount = decimalInputString(amount)
        return updated
    }

    private static func amount(forPostingAt index: Int, in draft: TransactionDraft, accounts: [Account], commodities: [Commodity]) throws -> Decimal {
        let target = draft.postings[index]
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let defaults = Dictionary(grouping: commodities, by: \.ledgerID).compactMapValues { $0.first?.id }
        func currency(_ posting: PostingDraft) -> UUID? {
            let account = posting.accountID.flatMap { byID[$0] }
            return posting.commodityID ?? account?.commodityID ?? account.flatMap { defaults[$0.ledgerID] }
        }
        guard let targetCurrency = currency(target) else {
            throw ValidationError(message: "Choose an account and currency for the posting to balance.")
        }
        var total = Decimal.zero
        var matchingCount = 0
        for (otherIndex, posting) in draft.postings.enumerated() where otherIndex != index && currency(posting) == targetCurrency {
            guard let amount = decimalFromInput(posting.amount) else {
                throw ValidationError(message: "Enter a valid amount for each posting in this currency.")
            }
            total += amount
            matchingCount += 1
        }
        guard matchingCount > 0 else {
            throw ValidationError(message: "There is no other posting in this currency. Enter the converted amount explicitly.")
        }
        return -total
    }
}
