import Foundation

/// Value-only daily account totals. Calendar rollover must not rebuild every
/// index and register while an account row's body is rendering.
struct AccountBalanceProjection: @unchecked Sendable {
    let cutoff: Date
    let balances: [UUID: [MobileBalanceRow]]
    let totals: [UUID: [AccountKind: [MobileBalanceRow]]]

    static func build(data: JournalData, rows: [LedgerTransaction], cutoff: Date) -> Self {
        build(data: data, rows: rows, cutoff: cutoff, cancellationCheck: {})
    }

    static func build(data: JournalData, rows: [LedgerTransaction], cutoff: Date,
                      cancellationCheck: () throws -> Void) rethrows -> Self {
        let accounts = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.id, $0) })
        let currencies = Dictionary(uniqueKeysWithValues: data.commodities.map { ($0.id, $0) })
        let accountsByLedger = Dictionary(grouping: data.accounts, by: \.ledgerID)
        let defaults = Dictionary(grouping: data.commodities, by: \.ledgerID).compactMapValues { $0.first?.id }
        func symbol(_ id: UUID?) -> String { id.flatMap { currencies[$0]?.symbol } ?? "USD" }
        var values: [UUID: [UUID?: Decimal]] = [:]
        for (index, transaction) in rows.enumerated() {
            if index.isMultiple(of: 128) { try cancellationCheck() }
            guard transaction.date < cutoff else { continue }
            for posting in transaction.postings {
                let currency = posting.commodityID ?? accounts[posting.accountID]?.commodityID ?? defaults[transaction.ledgerID]
                var accountID: UUID? = posting.accountID
                var depth = 0
                while let id = accountID, let account = accounts[id], depth < accounts.count {
                    values[id, default: [:]][currency, default: .zero] += posting.amount
                    accountID = account.parentID
                    depth += 1
                }
            }
        }
        let balances = values.mapValues { values in
            values.map { MobileBalanceRow(commodityID: $0.key, symbol: symbol($0.key), amount: $0.value) }
                .sorted { $0.symbol < $1.symbol }
        }
        var totals: [UUID: [AccountKind: [MobileBalanceRow]]] = [:]
        for (ledgerID, rows) in accountsByLedger {
            try cancellationCheck()
            let roots = rows.filter { $0.parentID == nil }.sorted { $0.listIndex < $1.listIndex }
            totals[ledgerID] = Dictionary(uniqueKeysWithValues: AccountKind.allCases.map { kind in
                let rows = roots.filter { $0.kind == kind }.flatMap { balances[$0.id] ?? [] }
                    .reduce(into: [String: MobileBalanceRow]()) { partial, row in
                        var existing = partial[row.id] ?? MobileBalanceRow(commodityID: row.commodityID, symbol: row.symbol, amount: .zero)
                        existing.amount += row.amount
                        partial[row.id] = existing
                    }.values.sorted { $0.symbol < $1.symbol }
                return (kind, rows)
            })
        }
        return Self(cutoff: cutoff, balances: balances, totals: totals)
    }
}

struct AccountBalanceSnapshot: @unchecked Sendable {
    let data: JournalData
    let rows: [LedgerTransaction]
    let cutoff: Date
}
