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
    let rows: [RegisterMonthRow]
    var id: Date { date }

    init(date: Date, days: [MobileTransactionDaySection], income: [RegisterMoney], expenses: [RegisterMoney]) {
        self.date = date
        self.days = days
        self.income = income
        self.expenses = expenses
        var rows: [RegisterMonthRow] = []
        rows.reserveCapacity(days.reduce(days.count) { $0 + $1.transactions.count })
        for day in days {
            rows.append(.day(day.date))
            rows.append(contentsOf: day.transactions.map(RegisterMonthRow.transaction))
        }
        self.rows = rows
    }
}

/// Each month retains a native List section. This precomputed collection gives
/// its ForEach one stable ID per independently rendered header/transaction row.
enum RegisterMonthRow: Identifiable {
    enum ID: Hashable {
        case day(Date)
        case transaction(UUID)
    }

    case day(Date)
    case transaction(LedgerTransaction)

    var id: ID {
        switch self {
        case .day(let date): .day(date)
        case .transaction(let transaction): .transaction(transaction.id)
        }
    }

    var transaction: LedgerTransaction? {
        if case .transaction(let transaction) = self { return transaction }
        return nil
    }
}

struct RegisterCashFlowBucket: Identifiable {
    let account: Account
    var amounts: [RegisterMoney]
    var transactionIDs: Set<UUID>
    var id: UUID { account.id }
}

struct RegisterCashFlow: @unchecked Sendable {
    let income: [RegisterCashFlowBucket]
    let expenses: [RegisterCashFlowBucket]

    static func build(data: JournalData, rows: [LedgerTransaction], scope: MobileTransactionScope) -> RegisterCashFlow {
        build(data: data, rows: rows, scope: scope, cancellationCheck: {})
    }

    static func build(data: JournalData, rows: [LedgerTransaction], scope: MobileTransactionScope,
                      cancellationCheck: () throws -> Void) rethrows -> RegisterCashFlow {
        try cancellationCheck()
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
        for (index, transaction) in rows.enumerated() {
            if index.isMultiple(of: 128) { try cancellationCheck() }
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
        guard let cutoff = calendar.dateInterval(of: .day, for: now)?.end,
              let newest = months.first?.days.first?.date, newest >= cutoff else { return nil }
        for month in months {
            for day in month.days where day.date < cutoff { return day.date }
        }
        return months.last?.days.last?.date
    }

    static func isFuture(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.compare(date, to: now, toGranularity: .day) == .orderedDescending
    }

    static func build(data: JournalData, rows: [LedgerTransaction], scope: MobileTransactionScope, calendar: Calendar = .current) -> RegisterPresentation {
        build(data: data, rows: rows, scope: scope, calendar: calendar, cancellationCheck: {})
    }

    static func build(data: JournalData, rows: [LedgerTransaction], scope: MobileTransactionScope, calendar: Calendar,
                      cancellationCheck: () throws -> Void) rethrows -> RegisterPresentation {
        try cancellationCheck()
        guard !rows.isEmpty else { return RegisterPresentation(months: [], amounts: [:], balances: [:]) }
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
        var comparisons = 0
        let chronological = try data.transactions.filter { ledgerIDs.contains($0.ledgerID) }.sorted { lhs, rhs in
            comparisons += 1
            if comparisons.isMultiple(of: 1024) { try cancellationCheck() }
            return lhs.date == rhs.date ? lhs.id.canonicallyPrecedes(rhs.id) : lhs.date < rhs.date
        }
        for (index, transaction) in chronological.enumerated() {
            if index.isMultiple(of: 128) { try cancellationCheck() }
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
        // Month headers need currency totals, not per-account buckets with a
        // growing set of transaction IDs. Accumulate them alongside grouping,
        // sharing the lookups already used for amount/balance projection.
        var grouped: [Date: [Date: [LedgerTransaction]]] = [:]
        var monthlyIncome: [Date: [UUID: Decimal]] = [:]
        var monthlyExpenses: [Date: [UUID: Decimal]] = [:]
        let summaryAccountIDs: Set<UUID>? = {
            guard case .account(let id) = scope, let account = accounts[id],
                  account.kind == .income || account.kind == .expense else { return nil }
            return scopedAccounts
        }()
        var previousDay: Date?
        var previousMonth: Date?
        var previousDayEnd: Date?
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 128) { try cancellationCheck() }
            let day: Date
            let month: Date
            if let cachedDay = previousDay, let dayEnd = previousDayEnd,
               row.date >= cachedDay, row.date < dayEnd, let cachedMonth = previousMonth {
                day = cachedDay
                month = cachedMonth
            } else {
                let interval = calendar.dateInterval(of: .day, for: row.date)!
                day = interval.start
                month = calendar.dateInterval(of: .month, for: row.date)!.start
                previousDay = day
                previousDayEnd = interval.end
                previousMonth = month
            }
            grouped[month, default: [:]][day, default: []].append(row)
            for posting in row.postings {
                guard let account = accounts[posting.accountID],
                      account.kind == .income || account.kind == .expense,
                      summaryAccountIDs?.contains(account.id) ?? true,
                      let currencyID = posting.commodityID ?? account.commodityID ?? defaults[row.ledgerID] else { continue }
                if case .currency(let selected) = scope, selected != currencyID { continue }
                if posting.amount < 0 { monthlyIncome[month, default: [:]][currencyID, default: 0] -= posting.amount }
                if posting.amount > 0 { monthlyExpenses[month, default: [:]][currencyID, default: 0] -= posting.amount }
            }
        }
        let months = try grouped.keys.sorted(by: >).map { month in
            try cancellationCheck()
            let days = grouped[month]!.map { MobileTransactionDaySection(date: $0.key, transactions: $0.value) }.sorted { $0.date > $1.date }
            return RegisterMonth(date: month, days: days, income: money(monthlyIncome[month] ?? [:]), expenses: money(monthlyExpenses[month] ?? [:]))
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

    /// Shared by immediate queries, cached indexes, and background register search.
    /// Account paths and receipt metadata are display context, not transaction text.
    func normalizedText(for transaction: LedgerTransaction) -> String {
        switch self {
        case .note: transaction.note.lowercased()
        case .number: transaction.number.lowercased()
        case .payee: transaction.payee.lowercased()
        case .anywhere: [transaction.note, transaction.number, transaction.payee].joined(separator: "\n").lowercased()
        }
    }
}

/// Search hides future recurring materializations by default; the normal
/// registers remain complete. Boundaries use the user's local calendar.
struct TransactionSearchDatePolicy: Hashable, Sendable {
    static let preferenceKey = "search.includeAllFutureEntries"
    let includeAllFuture: Bool
    let todayEnd: Date
    let yearEnd: Date

    init(includeAllFuture: Bool, now: Date = Date(), calendar: Calendar = .current) {
        self.includeAllFuture = includeAllFuture
        todayEnd = calendar.dateInterval(of: .day, for: now)?.end ?? now
        yearEnd = calendar.dateInterval(of: .year, for: now)?.end ?? now
    }

    func includes(_ row: LedgerTransaction) -> Bool {
        if includeAllFuture || row.date < todayEnd { return true }
        let repeating = row.recurrenceRule.map { $0.frequency != .never } ?? false
        return !repeating && row.date < yearEnd
    }
}

enum AccountSearchPath {
    static func parentNames(for account: Account, in accounts: [UUID: Account]) -> [String] {
        var names: [String] = []
        var parent = account.parentID
        var visited: Set<UUID> = [account.id]
        while let id = parent, visited.insert(id).inserted,
              let row = accounts[id], row.ledgerID == account.ledgerID {
            names.append(row.name)
            parent = row.parentID
        }
        return names.reversed()
    }
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
    var searchDatePolicy: TransactionSearchDatePolicy? = nil
    var referenceDate = Date()
    var calendar = Calendar.current

    var relativeScopeInterval: DateInterval? {
        switch scope {
        case .today: return calendar.dateInterval(of: .day, for: referenceDate)
        case .lastMonth:
            return calendar.date(byAdding: .month, value: -1, to: referenceDate)
                .flatMap { calendar.dateInterval(of: .month, for: $0) }
        default: return nil
        }
    }

    func matches(_ other: RegisterRenderRequest) -> Bool {
        calendar == other.calendar && relativeScopeInterval == other.relativeScopeInterval &&
            searchDatePolicy == other.searchDatePolicy && filtersScope == other.filtersScope && scope == other.scope && search == other.search && searchField == other.searchField && dateInterval == other.dateInterval &&
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

    nonisolated func render(_ request: RegisterRenderRequest) async throws -> RegisterRenderResult {
        let work = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            #if DEBUG
            if CommandLine.arguments.contains("--demo-slow-register") {
                let seconds = CommandLine.arguments.contains("--demo-edge-loading") ? 5 : 2
                try await Task.sleep(for: .seconds(seconds))
            }
            #endif
            let rows = try Self.filteredRows(request)
            let presentation = try RegisterPresentation.build(data: request.data, rows: rows, scope: request.scope,
                calendar: request.calendar, cancellationCheck: { try Task.checkCancellation() })
            try Task.checkCancellation()
            return RegisterRenderResult(presentation: presentation)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    nonisolated func cashFlow(_ request: RegisterRenderRequest) async throws -> RegisterCashFlow {
        let work = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            let rows = try Self.filteredRows(request)
            return try RegisterCashFlow.build(data: request.data, rows: rows, scope: request.scope,
                                               cancellationCheck: { try Task.checkCancellation() })
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func search(_ request: RegisterRenderRequest, limit: Int? = nil) throws -> RegisterSearchResult {
        try Task.checkCancellation()
        return RegisterSearchResult(rows: try Self.filteredRows(request, limit: limit))
    }

    private nonisolated static func filteredRows(_ request: RegisterRenderRequest, limit: Int? = nil) throws -> [LedgerTransaction] {
        let query = request.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let accountsByID = Dictionary(uniqueKeysWithValues: request.data.accounts.map { ($0.id, $0) })
        let defaults = Dictionary(grouping: request.data.commodities, by: \.ledgerID).compactMapValues { $0.first?.id }
        var scopedAccounts = Set<UUID>()
        if request.filtersScope, case .account(let id) = request.scope {
            let children = Dictionary(grouping: request.data.accounts.compactMap { account in account.parentID.map { ($0, account.id) } }, by: { $0.0 })
            var pending = [id]
            while let id = pending.popLast() {
                guard scopedAccounts.insert(id).inserted else { continue }
                pending.append(contentsOf: (children[id] ?? []).map { $0.1 })
            }
        }
        let relativeInterval = request.relativeScopeInterval
        func isInScope(_ row: LedgerTransaction) -> Bool {
            guard request.filtersScope else { return true }
            switch request.scope {
            case .all: return true
            case .uncleared: return !row.cleared
            case .repeating: return row.recurrenceRule.map { $0.frequency != .never } ?? false
            case .account: return row.postings.contains { scopedAccounts.contains($0.accountID) }
            case .currency(let id): return row.postings.contains { ($0.commodityID ?? accountsByID[$0.accountID]?.commodityID ?? defaults[row.ledgerID]) == id }
            case .today, .lastMonth: return relativeInterval.map { row.date >= $0.start && row.date < $0.end } ?? false
            }
        }
        var matches: [LedgerTransaction] = []
        var futureMatches: [LedgerTransaction] = []
        var futureSlot = 0
        if let limit, limit <= 0 { return [] }
        if let limit { matches.reserveCapacity(max(0, min(limit, request.rows.count))) }
        for transaction in request.rows {
            try Task.checkCancellation()
            guard isInScope(transaction), request.searchDatePolicy?.includes(transaction) ?? true else { continue }
            if let interval = request.dateInterval, !(transaction.date >= interval.start && transaction.date < interval.end) { continue }
            if let ids = request.transactionIDs, !ids.contains(transaction.id) { continue }
            // Ordinary registers skip search-string allocation entirely.
            if !query.isEmpty {
                if !request.searchField.normalizedText(for: transaction).contains(query) { continue }
            }
            if let policy = request.searchDatePolicy, transaction.date >= policy.todayEnd {
                // Source rows are newest first. A bounded ring retains the
                // nearest future matches without letting them crowd out history.
                if let limit, futureMatches.count == limit {
                    futureMatches[futureSlot] = transaction
                    futureSlot = (futureSlot + 1) % limit
                } else { futureMatches.append(transaction) }
                continue
            }
            if let limit, matches.count >= limit { break }
            matches.append(transaction)
        }
        if request.searchDatePolicy != nil {
            futureMatches.sort { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
            if let limit { matches.append(contentsOf: futureMatches.prefix(max(0, limit - matches.count))) }
            else { matches.append(contentsOf: futureMatches) }
        }
        return matches
    }
}
