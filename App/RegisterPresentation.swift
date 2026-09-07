import Foundation

struct RegisterMoney: Identifiable, Equatable {
    let commodityID: UUID
    let symbol: String
    var amount: Decimal
    var id: UUID { commodityID }
}

struct RegisterMonth: Identifiable {
    let date: Date
    let days: [MobileTransactionDaySection]
    let income: [RegisterMoney]
    let expenses: [RegisterMoney]
    var id: Date { date }
}

struct RegisterCashFlowBucket: Identifiable {
    let account: Account
    var amounts: [RegisterMoney]
    var transactionIDs: Set<UUID>
    var id: UUID { account.id }
}

struct RegisterCashFlow {
    let income: [RegisterCashFlowBucket]
    let expenses: [RegisterCashFlowBucket]

    static func build(data: JournalData, rows: [LedgerTransaction], scope: MobileTransactionScope) -> RegisterCashFlow {
        let accounts = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.id, $0) })
        let currencies = Dictionary(uniqueKeysWithValues: data.commodities.map { ($0.id, $0) })
        let defaults = Dictionary(grouping: data.commodities, by: \.ledgerID).compactMapValues { $0.first?.id }
        var categoryIDs: Set<UUID>?
        if case .account(let id) = scope, let account = accounts[id], account.kind == .income || account.kind == .expense {
            var ids: Set<UUID> = [id]
            var previousCount = 0
            while previousCount != ids.count {
                previousCount = ids.count
                for account in data.accounts where account.parentID.map(ids.contains) == true { ids.insert(account.id) }
            }
            categoryIDs = ids
        }
        var income: [UUID: RegisterCashFlowBucket] = [:], expenses: [UUID: RegisterCashFlowBucket] = [:]
        func append(_ posting: Posting, account: Account, currencyID: UUID, transactionID: UUID, to buckets: inout [UUID: RegisterCashFlowBucket]) {
            if buckets[account.id] == nil {
                buckets[account.id] = RegisterCashFlowBucket(account: account, amounts: [], transactionIDs: [])
            }
            // Mutate through Dictionary's modify accessor. Copying the bucket
            // first would copy its growing transaction-ID set on every insert.
            if let index = buckets[account.id]!.amounts.firstIndex(where: { $0.id == currencyID }) {
                buckets[account.id]!.amounts[index].amount -= posting.amount
            } else {
                buckets[account.id]!.amounts.append(RegisterMoney(commodityID: currencyID, symbol: currencies[currencyID]?.symbol ?? "", amount: -posting.amount))
            }
            buckets[account.id]!.transactionIDs.insert(transactionID)
        }
        for transaction in rows {
            for posting in transaction.postings {
                guard let account = accounts[posting.accountID], account.kind == .income || account.kind == .expense,
                      categoryIDs?.contains(account.id) ?? true,
                      let currencyID = posting.commodityID ?? account.commodityID ?? defaults[transaction.ledgerID] else { continue }
                if case .currency(let selected) = scope, selected != currencyID { continue }
                if posting.amount < 0 { append(posting, account: account, currencyID: currencyID, transactionID: transaction.id, to: &income) }
                if posting.amount > 0 { append(posting, account: account, currencyID: currencyID, transactionID: transaction.id, to: &expenses) }
            }
        }
        func ordered(_ buckets: [UUID: RegisterCashFlowBucket]) -> [RegisterCashFlowBucket] {
            buckets.values.map { bucket in
                var result = bucket
                result.amounts.sort { $0.symbol < $1.symbol }
                return result
            }.sorted { $0.account.name < $1.account.name }
        }
        return RegisterCashFlow(income: ordered(income), expenses: ordered(expenses))
    }

    static func totals(_ buckets: [RegisterCashFlowBucket]) -> [RegisterMoney] {
        var totals: [UUID: RegisterMoney] = [:]
        for value in buckets.flatMap(\.amounts) {
            if totals[value.id] == nil { totals[value.id] = value }
            else { totals[value.id]?.amount += value.amount }
        }
        return totals.values.sorted { $0.symbol < $1.symbol }
    }
}

/// All totals keep currencies separate. Account registers include descendants and
/// running balances include earlier entries even when a search hides those rows.
struct RegisterPresentation {
    enum ScrollTarget: Hashable {
        case day(Date)
        case chart
    }

    let months: [RegisterMonth]
    let amounts: [UUID: [RegisterMoney]]
    let balances: [UUID: [RegisterMoney]]

    /// Sync timestamps, connection preferences, and security state do not change
    /// register calculations. Array equality is cheap for unchanged COW buffers.
    static func hasSameContent(_ lhs: JournalData, _ rhs: JournalData) -> Bool {
        lhs.selectedLedgerID == rhs.selectedLedgerID && lhs.transactions == rhs.transactions &&
            lhs.accounts == rhs.accounts && lhs.commodities == rhs.commodities
    }

    /// Future occurrences stay reachable above today's entries without becoming
    /// the landing page every time a register opens.
    func initialDay(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let days = months.flatMap(\.days).map(\.date)
        guard let newest = days.first, Self.isFuture(newest, now: now, calendar: calendar) else { return nil }
        return days.first { !Self.isFuture($0, now: now, calendar: calendar) } ?? days.last
    }

    func initialScrollTarget(showsChart: Bool, now: Date = Date(), calendar: Calendar = .current) -> ScrollTarget? {
        if let day = initialDay(now: now, calendar: calendar) { return .day(day) }
        return showsChart && !months.isEmpty ? .chart : nil
    }

    static func isFuture(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.compare(date, to: now, toGranularity: .day) == .orderedDescending
    }

    static func build(data: JournalData, rows: [LedgerTransaction], scope: MobileTransactionScope, calendar: Calendar = .current) -> RegisterPresentation {
        let accounts = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.id, $0) })
        let currencies = Dictionary(uniqueKeysWithValues: data.commodities.map { ($0.id, $0) })
        let defaults = Dictionary(grouping: data.commodities, by: \.ledgerID).compactMapValues { $0.first?.id }
        func currency(_ p: Posting) -> UUID? {
            let account = accounts[p.accountID]
            return p.commodityID ?? account?.commodityID ?? account.flatMap { defaults[$0.ledgerID] }
        }
        func money(_ totals: [UUID: Decimal]) -> [RegisterMoney] {
            totals.map { RegisterMoney(commodityID: $0.key, symbol: currencies[$0.key]?.symbol ?? "", amount: $0.value) }.sorted { $0.symbol < $1.symbol }
        }
        var scopedAccounts = Set<UUID>()
        if case .account(let id) = scope {
            scopedAccounts.insert(id)
            var changed = true
            while changed {
                let old = scopedAccounts.count
                for account in data.accounts where account.parentID.map(scopedAccounts.contains) == true { scopedAccounts.insert(account.id) }
                changed = old != scopedAccounts.count
            }
        }
        let rowIDs = Set(rows.map(\.id))
        let ledgerIDs = Set(rows.map(\.ledgerID))
        var amounts: [UUID: [RegisterMoney]] = [:]
        var balances: [UUID: [RegisterMoney]] = [:]
        var cumulative: [UUID: [UUID: Decimal]] = [:]
        var scopedTotals: [UUID: Decimal] = [:]
        var scopeHasMultiCurrencyAccount = false
        let chronological = data.transactions.filter { ledgerIDs.contains($0.ledgerID) }.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
        for transaction in chronological {
            for posting in transaction.postings {
                if let id = currency(posting) {
                    cumulative[posting.accountID, default: [:]][id, default: 0] += posting.amount
                    if scopedAccounts.contains(posting.accountID) {
                        scopedTotals[id, default: 0] += posting.amount
                        scopeHasMultiCurrencyAccount = scopeHasMultiCurrencyAccount || (cumulative[posting.accountID]?.count ?? 0) > 1
                    }
                }
            }
            guard rowIDs.contains(transaction.id) else { continue }
            var displayed: [UUID: Decimal] = [:]
            var running: [UUID: Decimal] = [:]
            func rowBalances(for accountID: UUID, using currencyIDs: Set<UUID>) -> [UUID: Decimal] {
                let totals = cumulative[accountID] ?? [:]
                // Only the row projection is narrowed. Keep the complete running
                // totals for subsequent rows, including currencies now at zero.
                return totals.count > 1 ? totals.filter { currencyIDs.contains($0.key) } : totals
            }
            if !scopedAccounts.isEmpty {
                for posting in transaction.postings where scopedAccounts.contains(posting.accountID) {
                    if let id = currency(posting) { displayed[id, default: 0] += posting.amount }
                }
                if scopeHasMultiCurrencyAccount {
                    let rowCurrencies = Set(displayed.keys)
                    for accountID in scopedAccounts {
                        for (id, value) in rowBalances(for: accountID, using: rowCurrencies) { running[id, default: 0] += value }
                    }
                } else {
                    // Group totals change only with postings, not with the
                    // number of descendants displayed in the account outline.
                    running = scopedTotals
                }
            } else {
                let incomeExpense = transaction.postings.filter { p in accounts[p.accountID].map { $0.kind == .income || $0.kind == .expense } ?? false }
                for p in incomeExpense { if let id = currency(p) { displayed[id, default: 0] -= p.amount } }
                if incomeExpense.isEmpty, let posting = transaction.postings.first(where: { $0.amount > 0 }) ?? transaction.postings.first, let id = currency(posting) { displayed[id] = posting.amount }
                if let first = transaction.postings.first(where: { accounts[$0.accountID].map { $0.kind == .asset || $0.kind == .liability } ?? false }) {
                    let rowCurrencies = Set(transaction.postings.filter { $0.accountID == first.accountID }.compactMap(currency))
                    running = rowBalances(for: first.accountID, using: rowCurrencies)
                }
            }
            if case .currency(let id) = scope { displayed = displayed.filter { $0.key == id }; running = running.filter { $0.key == id } }
            amounts[transaction.id] = money(displayed)
            balances[transaction.id] = money(running)
        }
        let grouped = Dictionary(grouping: rows) { calendar.dateInterval(of: .month, for: $0.date)!.start }
        let months = grouped.keys.sorted(by: >).map { month in
            let monthRows = grouped[month]!
            let cashFlow = RegisterCashFlow.build(data: data, rows: monthRows, scope: scope)
            let days = Dictionary(grouping: monthRows) { calendar.startOfDay(for: $0.date) }
                .map { MobileTransactionDaySection(date: $0.key, transactions: $0.value) }.sorted { $0.date > $1.date }
            return RegisterMonth(date: month, days: days, income: RegisterCashFlow.totals(cashFlow.income), expenses: RegisterCashFlow.totals(cashFlow.expenses))
        }
        return RegisterPresentation(months: months, amounts: amounts, balances: balances)
    }
}
