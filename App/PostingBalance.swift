import Foundation

/// Balancing is arithmetic within one currency, never an exchange-rate guess.
enum PostingBalance {
    static func settingAmount(_ text: String, at index: Int, in draft: TransactionDraft, accounts: [Account], commodities: [Commodity] = []) -> TransactionDraft {
        guard draft.postings.indices.contains(index) else { return draft }
        var updated = draft
        updated.postings[index].amount = text
        guard updated.postings.count == 2, let value = decimalFromInput(text) else { return updated }
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

    static func amount(forLastPostingIn draft: TransactionDraft, accounts: [Account], commodities: [Commodity] = []) throws -> Decimal {
        guard let last = draft.postings.last, draft.postings.count >= 2 else {
            throw ValidationError(message: "Add at least two postings before balancing.")
        }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let defaults = Dictionary(grouping: commodities, by: \.ledgerID).compactMapValues { $0.first?.id }
        func currency(_ posting: PostingDraft) -> UUID? {
            let account = posting.accountID.flatMap { byID[$0] }
            return posting.commodityID ?? account?.commodityID ?? account.flatMap { defaults[$0.ledgerID] }
        }
        guard let lastCurrency = currency(last) else {
            throw ValidationError(message: "Choose an account and currency for the last posting.")
        }
        var total = Decimal.zero
        var matchingCount = 0
        for posting in draft.postings.dropLast() where currency(posting) == lastCurrency {
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
