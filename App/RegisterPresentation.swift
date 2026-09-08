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
    let months: [RegisterMonth]
    let amounts: [UUID: [RegisterMoney]]
    let balances: [UUID: [RegisterMoney]]

    /// Sync timestamps, connection preferences, and security state do not change
    /// register calculations. Array equality is cheap for unchanged COW buffers.
    static func hasSameContent(_ lhs: JournalData, _ rhs: JournalData) -> Bool {
        lhs.selectedLedgerID == rhs.selectedLedgerID && lhs.ledgers == rhs.ledgers && lhs.transactions == rhs.transactions &&
            lhs.accounts == rhs.accounts && lhs.commodities == rhs.commodities
    }

    /// Future occurrences stay reachable above today's entries without becoming
    /// the landing page every time a register opens.
    func initialDay(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let days = months.flatMap(\.days).map(\.date)
        guard let newest = days.first, Self.isFuture(newest, now: now, calendar: calendar) else { return nil }
        return days.first { !Self.isFuture($0, now: now, calendar: calendar) } ?? days.last
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

enum TransactionSearchField: String, CaseIterable, Identifiable, Sendable {
    case note, number, payee, anywhere
    var id: String { rawValue }
    var title: String {
        switch self {
        case .note: "Note"
        case .number: "Number"
        case .payee: "Payee"
        case .anywhere: "Search"
        }
    }
    var suggestionPrefix: String { self == .anywhere ? "Search for" : "\(title) contains" }
}

struct TransactionSearchQuery: Hashable, Sendable {
    var text: String
    var field: TransactionSearchField = .anywhere
    var title: String { "\(field.title): \(text)" }
    var suggestion: String { "\(field.suggestionPrefix): \(text)" }
}

/// Immutable Foundation-value snapshots; no mutable store or UI objects cross
/// the worker boundary. Receipt contents remain on disk.
struct RegisterRenderRequest: @unchecked Sendable {
    let data: JournalData
    let rows: [LedgerTransaction]
    let scope: MobileTransactionScope
    let search: String
    let dateInterval: DateInterval?
    let transactionIDs: Set<UUID>?
    var searchField: TransactionSearchField = .anywhere
    var filtersScope = false

    func matches(_ other: RegisterRenderRequest) -> Bool {
        filtersScope == other.filtersScope && scope == other.scope && search == other.search && searchField == other.searchField && dateInterval == other.dateInterval &&
            transactionIDs == other.transactionIDs && RegisterPresentation.hasSameContent(data, other.data) && rows == other.rows
    }
}

struct RegisterRenderResult: @unchecked Sendable {
    let presentation: RegisterPresentation
}

struct RegisterSearchResult: @unchecked Sendable {
    let rows: [LedgerTransaction]
}

actor RegisterRenderWorker {
    static let shared = RegisterRenderWorker()

    func render(_ request: RegisterRenderRequest) async throws -> RegisterRenderResult {
        try Task.checkCancellation()
        #if DEBUG
        if CommandLine.arguments.contains("--demo-slow-register") { try await Task.sleep(for: .seconds(2)) }
        #endif
        let rows = try filteredRows(request)
        let presentation = RegisterPresentation.build(data: request.data, rows: rows, scope: request.scope)
        try Task.checkCancellation()
        return RegisterRenderResult(presentation: presentation)
    }

    func search(_ request: RegisterRenderRequest, limit: Int? = nil) throws -> RegisterSearchResult {
        try Task.checkCancellation()
        return RegisterSearchResult(rows: try filteredRows(request, limit: limit))
    }

    private func filteredRows(_ request: RegisterRenderRequest, limit: Int? = nil) throws -> [LedgerTransaction] {
        let query = request.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let accountsByID = Dictionary(uniqueKeysWithValues: request.data.accounts.map { ($0.id, $0) })
        let defaults = Dictionary(grouping: request.data.commodities, by: \.ledgerID).compactMapValues { $0.first?.id }
        let accounts = query.isEmpty ? [:] : accountsByID.mapValues(\.name)
        let ledgers = query.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: request.data.ledgers.map { ($0.id, $0.name) })
        var scopedAccounts = Set<UUID>()
        if request.filtersScope, case .account(let id) = request.scope {
            let children = Dictionary(grouping: request.data.accounts.compactMap { account in account.parentID.map { ($0, account.id) } }, by: { $0.0 })
            var pending = [id]
            while let id = pending.popLast() {
                guard scopedAccounts.insert(id).inserted else { continue }
                pending.append(contentsOf: (children[id] ?? []).map { $0.1 })
            }
        }
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.dateInterval(of: .day, for: now)
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: now).flatMap { calendar.dateInterval(of: .month, for: $0) }
        func isInScope(_ row: LedgerTransaction) -> Bool {
            guard request.filtersScope else { return true }
            switch request.scope {
            case .all: return true
            case .uncleared: return !row.cleared
            case .repeating: return row.recurrenceRule.map { $0.frequency != .never } ?? false
            case .account: return row.postings.contains { scopedAccounts.contains($0.accountID) }
            case .currency(let id): return row.postings.contains { ($0.commodityID ?? accountsByID[$0.accountID]?.commodityID ?? defaults[row.ledgerID]) == id }
            case .today: return today.map { row.date >= $0.start && row.date < $0.end } ?? false
            case .lastMonth: return lastMonth.map { row.date >= $0.start && row.date < $0.end } ?? false
            }
        }
        var matches: [LedgerTransaction] = []
        if let limit { matches.reserveCapacity(max(0, min(limit, request.rows.count))) }
        for transaction in request.rows {
            try Task.checkCancellation()
            guard isInScope(transaction) else { continue }
            if let interval = request.dateInterval, !(transaction.date >= interval.start && transaction.date < interval.end) { continue }
            if let ids = request.transactionIDs, !ids.contains(transaction.id) { continue }
            // Ordinary registers skip search-string allocation entirely.
            if !query.isEmpty {
                let text: String
                switch request.searchField {
                case .note: text = transaction.note
                case .number: text = transaction.number
                case .payee: text = transaction.payee
                case .anywhere:
                    let fields = [transaction.note, transaction.payee, transaction.number, ledgers[transaction.ledgerID] ?? ""]
                        + transaction.postings.compactMap { accounts[$0.accountID] }
                        + transaction.postings.map { String(describing: $0.amount) }
                    text = fields.joined(separator: " ")
                }
                if !text.lowercased().contains(query) { continue }
            }
            if let limit, matches.count >= max(0, limit) { break }
            matches.append(transaction)
        }
        return matches
    }
}
