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
                commodityID: account.currencyID, name: account.name, note: account.note ?? "", kind: kind,
                colorName: account.colorName ?? "gray", listIndex: account.listIndex ?? 0)
        }
    }
    func nativeCurrencies(journalID: UUID) -> [Commodity] {
        currencies.filter { $0.journalID == journalID }.map {
            Commodity(id: $0.id, ledgerID: journalID, symbol: $0.symbol, name: $0.name ?? $0.symbol)
        }
    }

    /// The catalog omits the five root accounts; section headers represent them.
    /// Walk each sibling list in saved order, retaining the depth when searching.
    func accountPickerNodes(journalID: UUID?, kind: AccountKind, search: String = "") -> [SharedAccountPickerNode] {
        guard let journalID else { return [] }
        let accounts = nativeAccounts(journalID: journalID).filter { $0.kind == kind }
        let ids = Set(accounts.map(\.id))
        let children = Dictionary(grouping: accounts, by: \.parentID)
        func ordered(_ rows: [NativeReceiptAccount]) -> [NativeReceiptAccount] {
            rows.sorted {
                if $0.listIndex != $1.listIndex { return $0.listIndex < $1.listIndex }
                let comparison = $0.name.localizedStandardCompare($1.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        var result: [SharedAccountPickerNode] = []
        var visited = Set<UUID>()
        func append(_ account: NativeReceiptAccount, depth: Int) {
            guard visited.insert(account.id).inserted else { return }
            result.append(SharedAccountPickerNode(account: account, depth: depth))
            for child in ordered(children[account.id] ?? []) { append(child, depth: depth + 1) }
        }
        for root in ordered(accounts.filter { $0.parentID.map { !ids.contains($0) } ?? true }) {
            append(root, depth: 0)
        }
        // Keep malformed/cyclic legacy catalogs usable without recursing forever.
        for account in ordered(accounts) where !visited.contains(account.id) { append(account, depth: 0) }
        return result.filter { search.isEmpty || $0.account.name.localizedCaseInsensitiveContains(search)
            || $0.account.note.localizedCaseInsensitiveContains(search) }
    }
}

struct SharedAccountPickerNode: Identifiable {
    var account: NativeReceiptAccount
    var depth: Int
    var id: UUID { account.id }
}
