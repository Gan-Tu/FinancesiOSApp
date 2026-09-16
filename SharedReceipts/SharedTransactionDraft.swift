import Foundation

extension SharedTransaction {
    mutating func apply(_ value: TransactionDraft) {
        date = value.date; note = value.note; payee = value.payee; number = value.number
        postings = value.postings.map { .init(id: $0.id, accountID: $0.accountID, currencyID: $0.commodityID, amount: $0.amount) }
    }
    func draft(operationID: UUID) -> TransactionDraft {
        var result = TransactionDraft(ledgerID: journalID)
        result.saveOperationID = operationID
        result.incomingEditorSessionID = UUID()
        result.date = date
        result.payee = payee
        result.note = note
        result.number = number
        result.cleared = cleared
        if let recurrence {
            result.repeatFrequency = recurrence.frequency; result.repeatIntervalValue = recurrence.intervalValue
            result.repeatOnWorkdays = recurrence.onWorkdays; result.repeatOccurrenceCount = recurrence.occurrenceCount
            result.repeatEndDate = recurrence.endDate
        }
        result.postings = postings.map { .init(id: $0.id, accountID: $0.accountID, amount: $0.amount, commodityID: $0.currencyID) }
        return result
    }
}

typealias NativeReceiptAccount = Account

extension SharedTransactionCatalog {
    func nativeAccounts(journalID: UUID) -> [NativeReceiptAccount] {
        accounts.filter { $0.journalID == journalID }.compactMap { account -> NativeReceiptAccount? in
            guard let kind = AccountKind(rawValue: account.kind) else { return nil }
            return NativeReceiptAccount(id: account.id, ledgerID: journalID, parentID: account.parentID ?? journalID,
                commodityID: account.currencyID, name: account.name, kind: kind, colorName: account.colorName ?? "gray")
        }
    }
    func nativeCurrencies(journalID: UUID) -> [Commodity] {
        currencies.filter { $0.journalID == journalID }.map {
            Commodity(id: $0.id, ledgerID: journalID, symbol: $0.symbol, name: $0.name ?? $0.symbol)
        }
    }
}
