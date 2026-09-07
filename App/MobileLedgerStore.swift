import Foundation
import Darwin
import CryptoKit
import CloudKit
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum MobileTransactionScope: Hashable, Identifiable {
    case all
    case uncleared
    case repeating
    case today
    case lastMonth
    case account(UUID)
    case currency(UUID)

    var id: String {
        switch self {
        case .all: "all"
        case .uncleared: "uncleared"
        case .repeating: "repeating"
        case .today: "today"
        case .lastMonth: "last-month"
        case .account(let id): "account-\(id.uuidString)"
        case .currency(let id): "currency-\(id.uuidString)"
        }
    }
}

enum MobileNewTransactionKind: String, CaseIterable, Identifiable {
    case expense = "Expense"
    case income = "Income"
    case transfer = "Transfer"

    var id: String { rawValue }
}

struct MobileAccountDraft: Identifiable, Equatable {
    var id: UUID?
    var name = "Untitled"
    var note = ""
    var kind: AccountKind = .expense
    var parentID: UUID?
    var commodityID: UUID?
    var colorName = "red"
    var isGroup = false
    var ledgerID: UUID? = nil
}

struct MobileBalanceRow: Identifiable, Equatable {
    var commodityID: UUID?
    var symbol: String
    var amount: Decimal

    var id: String {
        "\(commodityID?.uuidString ?? "default")-\(symbol)"
    }
}

struct MobileAccountNode: Identifiable, Equatable {
    var account: Account
    var depth: Int
    var hasChildren: Bool

    var id: UUID { account.id }
}

private struct MobileAccountNodeCacheKey: Hashable {
    var ledgerID: UUID
    var kind: AccountKind?
}

private struct MobileTransactionRowsCacheKey: Hashable {
    var scope: MobileTransactionScope
    var ledgerID: UUID?
    var normalizedSearch: String
    var dayBucket: Date
}

struct MobileTransactionDaySection: Identifiable {
    var date: Date
    var transactions: [LedgerTransaction]

    var id: Date { date }
}

struct MobileAccountFlowAccount: Identifiable, Equatable {
    var id: UUID
    var name: String
    var kind: AccountKind
    var colorName: String
}

struct MobileAccountFlowDisplay: Equatable {
    var negative: [MobileAccountFlowAccount] = []
    var positive: [MobileAccountFlowAccount] = []
}

private struct MobileSearchCacheKey: Hashable {
    var normalizedSearch: String
    var limit: Int
}

private struct MobileTransactionSearchWarmupResult {
    var textByID: [UUID: String]
}

private enum MobilePersistenceTiming {
    case immediate
    case deferredLocal
}

private struct MobileLedgerDerivedCache {
    var balanceDateCutoff = Calendar.current.dateInterval(of: .day, for: Date())!.end
    var orderedLedgers: [Ledger] = []
    var ledgersByID: [UUID: Ledger] = [:]
    var accountsByID: [UUID: Account] = [:]
    var commoditiesByID: [UUID: Commodity] = [:]
    var transactionsByID: [UUID: LedgerTransaction] = [:]
    var accountsByLedger: [UUID: [Account]] = [:]
    var commoditiesByLedger: [UUID: [Commodity]] = [:]
    var transactionTemplatesByLedger: [UUID: [TransactionTemplate]] = [:]
    var accountNodesByLedgerAndKind: [MobileAccountNodeCacheKey: [MobileAccountNode]] = [:]
    var leafAccountNodesByLedger: [UUID: [MobileAccountNode]] = [:]
    var groupAccountNodesByLedgerAndKind: [MobileAccountNodeCacheKey: [MobileAccountNode]] = [:]
    var descendantIDsByAccount: [UUID: Set<UUID>] = [:]
    var defaultCommodityIDByLedger: [UUID: UUID] = [:]
    var allTransactionsDateDescending: [LedgerTransaction] = []
    var transactionsByLedgerDateDescending: [UUID: [LedgerTransaction]] = [:]
    var unclearedTransactionsByLedgerDateDescending: [UUID: [LedgerTransaction]] = [:]
    var repeatingTransactionsByLedgerDateDescending: [UUID: [LedgerTransaction]] = [:]
    var transactionsByAccountScopeDateDescending: [UUID: [LedgerTransaction]] = [:]
    var transactionsByCommodityDateDescending: [UUID: [LedgerTransaction]] = [:]
    var balanceRowsByAccount: [UUID: [MobileBalanceRow]] = [:]
    var ledgerTotalsByKind: [UUID: [AccountKind: [MobileBalanceRow]]] = [:]
    var registerAmountInfoByTransactionID: [UUID: MobileBalanceRow] = [:]
    var accountFlowDisplayByTransactionID: [UUID: MobileAccountFlowDisplay] = [:]
    var transactionSearchTextByID: [UUID: String] = [:]
    var ledgerSearchTextByID: [UUID: String] = [:]
    var accountSearchTextByID: [UUID: String] = [:]
    var commoditySearchTextByID: [UUID: String] = [:]
    var transactionTemplateSearchTextByID: [UUID: String] = [:]

    init() {}

    init(data: JournalData) {
        orderedLedgers = data.ledgers.sorted { $0.listIndex < $1.listIndex }
        ledgersByID = Dictionary(data.ledgers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        accountsByID = Dictionary(data.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        commoditiesByID = Dictionary(data.commodities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        transactionsByID = Dictionary(data.transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        accountsByLedger = Dictionary(grouping: data.accounts, by: \.ledgerID)
            .mapValues(Self.sortedAccounts)
        commoditiesByLedger = Dictionary(grouping: data.commodities, by: \.ledgerID)
            .mapValues { $0.sorted { $0.symbol.localizedCaseInsensitiveCompare($1.symbol) == .orderedAscending } }
        transactionTemplatesByLedger = Dictionary(grouping: data.transactionTemplates, by: \.ledgerID)
            .mapValues { $0.sorted { $0.listIndex < $1.listIndex } }
        defaultCommodityIDByLedger = Dictionary(data.ledgers.compactMap { ledger in
            data.commodities.first { $0.ledgerID == ledger.id }.map { (ledger.id, $0.id) }
        }, uniquingKeysWith: { first, _ in first })

        let childrenByParent = Dictionary(grouping: data.accounts.compactMap { account -> Account? in
            account.parentID == nil ? nil : account
        }, by: { $0.parentID! })
        var descendantMemo: [UUID: Set<UUID>] = [:]
        var visitingDescendants = Set<UUID>()
        func descendants(of accountID: UUID) -> Set<UUID> {
            if let memo = descendantMemo[accountID] {
                return memo
            }
            guard visitingDescendants.insert(accountID).inserted else { return [] }
            defer { visitingDescendants.remove(accountID) }
            let children = childrenByParent[accountID] ?? []
            let result = children.reduce(Set(children.map(\.id))) { partial, child in
                partial.union(descendants(of: child.id))
            }
            descendantMemo[accountID] = result
            return result
        }
        descendantIDsByAccount = Dictionary(uniqueKeysWithValues: data.accounts.map { account in
            (account.id, descendants(of: account.id))
        })

        for ledgerID in accountsByLedger.keys {
            let accounts = accountsByLedger[ledgerID] ?? []
            accountNodesByLedgerAndKind[MobileAccountNodeCacheKey(ledgerID: ledgerID, kind: nil)] = Self.accountNodes(from: accounts)
            leafAccountNodesByLedger[ledgerID] = accountNodesByLedgerAndKind[MobileAccountNodeCacheKey(ledgerID: ledgerID, kind: nil)]?
                .filter { !$0.account.isGroup } ?? []
            for kind in AccountKind.allCases {
                let key = MobileAccountNodeCacheKey(ledgerID: ledgerID, kind: kind)
                let nodes = Self.accountNodes(
                    from: accounts.filter { $0.kind == kind }
                )
                accountNodesByLedgerAndKind[key] = nodes
                groupAccountNodesByLedgerAndKind[key] = nodes.filter(\.account.isGroup)
            }
        }

        let sourceOrder = Dictionary(data.transactions.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        allTransactionsDateDescending = data.transactions.sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return (sourceOrder[lhs.id] ?? .max) < (sourceOrder[rhs.id] ?? .max)
            }
            return lhs.date > rhs.date
        }
        transactionsByLedgerDateDescending = Dictionary(grouping: allTransactionsDateDescending, by: \.ledgerID)
        unclearedTransactionsByLedgerDateDescending = transactionsByLedgerDateDescending.mapValues { $0.filter { !$0.cleared } }
        repeatingTransactionsByLedgerDateDescending = transactionsByLedgerDateDescending.mapValues { rows in
            rows.filter { transaction in
                guard let frequency = transaction.recurrenceRule?.frequency else { return false }
                return frequency != .never
            }
        }

        var balancesByAccount: [UUID: [UUID?: Decimal]] = [:]
        for transaction in allTransactionsDateDescending where transaction.date < balanceDateCutoff {
            for posting in transaction.postings {
                let commodityID = postingCommodityID(posting, ledgerID: transaction.ledgerID)
                var accountID: UUID? = posting.accountID
                while let currentID = accountID, let account = accountsByID[currentID] {
                    balancesByAccount[currentID, default: [:]][commodityID, default: .zero] += posting.amount
                    accountID = account.parentID
                }
            }
        }
        // Account/currency register scopes, per-row amount labels, row account
        // flow text, and transaction search text are lazy. The dashboard only
        // needs balances, totals, and ledger rows at startup, so large synced
        // journals should not pay to build every inactive drill-down surface.

        balanceRowsByAccount = balancesByAccount.mapValues { balances in
            balances
                .map { MobileBalanceRow(commodityID: $0.key, symbol: symbol(for: $0.key), amount: $0.value) }
                .sorted { $0.symbol < $1.symbol }
        }
        ledgerTotalsByKind = Dictionary(uniqueKeysWithValues: accountsByLedger.keys.map { ledgerID in
            let roots = (accountsByLedger[ledgerID] ?? []).filter { $0.parentID == nil }
            let totals = Dictionary(uniqueKeysWithValues: AccountKind.allCases.map { kind in
                let rows = roots
                    .filter { $0.kind == kind }
                    .flatMap { balanceRowsByAccount[$0.id] ?? [] }
                    .reduce(into: [String: MobileBalanceRow]()) { partial, row in
                        var existing = partial[row.id] ?? MobileBalanceRow(
                            commodityID: row.commodityID,
                            symbol: row.symbol,
                            amount: .zero
                        )
                        existing.amount += row.amount
                        partial[row.id] = existing
                    }
                    .values
                    .sorted { $0.symbol < $1.symbol }
                return (kind, rows)
            })
            return (ledgerID, totals)
        })

        ledgerSearchTextByID = Dictionary(uniqueKeysWithValues: data.ledgers.map { ledger in
            (ledger.id, Self.normalizedSearchText([ledger.name]))
        })
        accountSearchTextByID = Dictionary(uniqueKeysWithValues: data.accounts.map { account in
            (account.id, Self.normalizedSearchText([
                account.name,
                account.note,
                account.kind.title,
                ledgersByID[account.ledgerID]?.name ?? "",
                account.commodityID.flatMap { commoditiesByID[$0]?.symbol } ?? ""
            ]))
        })
        commoditySearchTextByID = Dictionary(uniqueKeysWithValues: data.commodities.map { commodity in
            (commodity.id, Self.normalizedSearchText([
                commodity.symbol,
                commodity.name,
                ledgersByID[commodity.ledgerID]?.name ?? ""
            ]))
        })
        transactionTemplateSearchTextByID = Dictionary(uniqueKeysWithValues: data.transactionTemplates.map { template in
            let postingAccounts = template.postings.compactMap { posting in
                posting.accountID.flatMap { accountsByID[$0]?.name }
            }
            return (template.id, Self.normalizedSearchText([
                template.name,
                template.note,
                template.payee,
                ledgersByID[template.ledgerID]?.name ?? ""
            ] + postingAccounts))
        })
    }

    static func sortedAccounts(_ accounts: [Account]) -> [Account] {
        accounts.sorted {
            if $0.kind == $1.kind {
                if $0.parentID == $1.parentID {
                    return $0.listIndex < $1.listIndex
                }
                return ($0.parentID?.uuidString ?? "") < ($1.parentID?.uuidString ?? "")
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    static func accountNodes(from accounts: [Account]) -> [MobileAccountNode] {
        let childrenByParent = Dictionary(grouping: accounts.compactMap { account -> Account? in
            account.parentID == nil ? nil : account
        }, by: { $0.parentID! })
        let roots = accounts
            .filter { $0.parentID == nil }
            .sorted {
                if $0.kind == $1.kind {
                    return $0.listIndex < $1.listIndex
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        var nodes: [MobileAccountNode] = []

        func append(_ account: Account, depth: Int) {
            let children = (childrenByParent[account.id] ?? []).sorted { $0.listIndex < $1.listIndex }
            nodes.append(MobileAccountNode(account: account, depth: depth, hasChildren: !children.isEmpty))
            for child in children {
                append(child, depth: depth + 1)
            }
        }

        for root in roots {
            append(root, depth: 0)
        }
        return nodes
    }

    private func registerAmountInfo(for transaction: LedgerTransaction) -> MobileBalanceRow {
        let incomeExpense = transaction.postings.filter { posting in
            guard let account = accountsByID[posting.accountID] else { return false }
            return account.kind == .income || account.kind == .expense
        }
        let total = incomeExpense.reduce(Decimal.zero) { $0 + $1.amount }
        let commodityID = incomeExpense.first.flatMap { postingCommodityID($0, ledgerID: transaction.ledgerID) }
            ?? transaction.postings.first.flatMap { postingCommodityID($0, ledgerID: transaction.ledgerID) }
        if total != .zero {
            return MobileBalanceRow(commodityID: commodityID, symbol: symbol(for: commodityID), amount: -total)
        }
        let positive = transaction.postings.first { $0.amount > .zero } ?? transaction.postings.first
        let positiveCommodityID = positive.flatMap { postingCommodityID($0, ledgerID: transaction.ledgerID) } ?? commodityID
        return MobileBalanceRow(
            commodityID: positiveCommodityID,
            symbol: symbol(for: positiveCommodityID),
            amount: positive?.amount ?? .zero
        )
    }

    func accountFlowDisplay(for transaction: LedgerTransaction) -> MobileAccountFlowDisplay {
        var display = MobileAccountFlowDisplay()
        for posting in transaction.postings.sortedForDisplay() {
            guard let account = accountsByID[posting.accountID] else { continue }
            let item = MobileAccountFlowAccount(
                id: account.id,
                name: account.name,
                kind: account.kind,
                colorName: account.colorName
            )
            if posting.amount < .zero {
                display.negative.append(item)
            } else {
                display.positive.append(item)
            }
        }
        return display
    }

    private func postingCommodityID(_ posting: Posting, ledgerID: UUID) -> UUID? {
        posting.commodityID ?? accountsByID[posting.accountID]?.commodityID ?? defaultCommodityIDByLedger[ledgerID]
    }

    private func symbol(for commodityID: UUID?) -> String {
        commodityID.flatMap { commoditiesByID[$0]?.symbol } ?? "USD"
    }

    private static func normalizedSearchText(_ values: [String]) -> String {
        values.joined(separator: " ").lowercased()
    }
}

/// Initialized before the store is published; thereafter accessed only on
/// MobileLedgerStore.deferredPersistenceQueue, alongside the corresponding write.
private final class MobilePersistenceBaseline: @unchecked Sendable {
    var snapshot: JournalData?
}

/// Releases the process notification token even when the store is deinitialized.
private final class MobileCloudKitAccountObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(onChange: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in onChange() }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
final class MobileLedgerStore: ObservableObject {
    private static let deferredPersistenceQueue = DispatchQueue(label: "FinancesMobile.MobileLedgerStore.deferredPersistence", qos: .utility)

    @Published private(set) var data: JournalData
    @Published var validationError: ValidationError?
    @Published private(set) var cloudSyncProgress = CloudSyncProgress.idle
    @Published private(set) var isUnlocked = true
    @Published private(set) var cloudSyncDataAvailable = false
    @Published private(set) var cloudSyncConflicts: [CloudKitSyncConflict] = []
    @Published private(set) var requiresJournalRecovery = false

    private let supportDirectory: URL
    private let sqliteStore: SQLiteJournalStore
    private let persistenceBaseline = MobilePersistenceBaseline()
    private let cloudKitSyncDependencies: CloudKitSyncDependencies
    private let foregroundTriggerDependencies: CloudKitForegroundSyncTriggerDependencies
    private var activeSceneIDs: Set<UUID> = []
    private var foregroundTriggerGeneration = UUID()
    private var foregroundSyncTriggers: CloudKitForegroundSyncTriggers?
    private var cloudKitAccountObservation: MobileCloudKitAccountObservation?
    private var isForegroundActive: Bool { !activeSceneIDs.isEmpty }
    private var lastRecurrenceProjectionDay: Date?
    private var deletedTransactionTombstoneIDs: Set<UUID> = []
    private lazy var cloudSyncCoordinator = CloudKitJournalSyncCoordinator(host: self, dependencies: cloudKitSyncDependencies)
    private var deferredCloudSaveToken: UUID?
    private var backupFileOperationInProgress = false
    private var backupSelectionChanged = false
    private var derivedCache = MobileLedgerDerivedCache()
    private var transactionRowsCache: [MobileTransactionRowsCacheKey: [LedgerTransaction]] = [:]
    private var transactionDaySectionCache: [MobileTransactionRowsCacheKey: [MobileTransactionDaySection]] = [:]
    private var ledgerSearchResultCache: [MobileSearchCacheKey: [Ledger]] = [:]
    private var accountSearchResultCache: [MobileSearchCacheKey: [Account]] = [:]
    private var commoditySearchResultCache: [MobileSearchCacheKey: [Commodity]] = [:]
    private var templateSearchResultCache: [MobileSearchCacheKey: [TransactionTemplate]] = [:]
    private var transactionSearchWarmupTask: Task<Void, Never>?
    private var transactionSearchWarmupDelayTask: Task<Void, Never>?
    private var transactionSearchCacheGeneration = 0

    private var attachmentsDirectory: URL {
        supportDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
    }

    convenience init() {
        self.init(supportDirectory: MobileLedgerStore.defaultSupportDirectory())
    }

    init(supportDirectory: URL, initialData: JournalData? = nil, cloudKitSyncDependencies: CloudKitSyncDependencies = .live, foregroundTriggerDependencies: CloudKitForegroundSyncTriggerDependencies = .live) {
        self.cloudKitSyncDependencies = cloudKitSyncDependencies
        self.foregroundTriggerDependencies = foregroundTriggerDependencies
        let resolvedSupportDirectory = supportDirectory
        self.supportDirectory = resolvedSupportDirectory
        self.sqliteStore = SQLiteJournalStore(databaseURL: resolvedSupportDirectory.appending(path: "journal.sqlite"))
        try? FileManager.default.createDirectory(at: resolvedSupportDirectory, withIntermediateDirectories: true)

        do {
            if let saved = try sqliteStore.loadData() {
                data = saved
                try Self.validateCandidateData(saved, operation: "Saved journal")
                persistenceBaseline.snapshot = saved
            } else {
                // A new device can join iCloud without uploading starter records.
                data = initialData ?? JournalData()
                try Self.validateCandidateData(data, operation: "Initial journal")
                try sqliteStore.replaceData(data, trackSyncChanges: false)
                persistenceBaseline.snapshot = data
            }
        } catch {
            // Never overwrite an unreadable journal with a starter dataset.
            data = JournalData()
            persistenceBaseline.snapshot = nil
            requiresJournalRecovery = true
            validationError = ValidationError(message: "Saved journal could not be loaded: \(error.localizedDescription). Editing, imports, and iCloud sync are blocked to preserve the saved database.")
        }

        refreshDerivedCache()
        refreshUnlockStateForLoadedData()
        reloadDeletedTransactionTombstones()
        if initialData == nil { refreshRecurringProjections(syncCloud: false) }
        refreshCloudSyncDataAvailability()
    }

    deinit {
        transactionSearchWarmupTask?.cancel()
        transactionSearchWarmupDelayTask?.cancel()
    }

    private func requireWritableJournal() throws {
        guard !backupFileOperationInProgress else { throw ValidationError(message: "A backup operation is in progress. Please wait until it finishes before editing.") }
        guard !requiresJournalRecovery else {
            throw ValidationError(message: "The saved journal requires recovery. Editing, imports, and iCloud sync are blocked to preserve its database and receipts. No automatic replacement is performed.")
        }
    }

    private func allowJournalMutation() -> Bool {
        do {
            try requireWritableJournal()
            return true
        } catch {
            validationError = ValidationError(message: error.localizedDescription)
            return false
        }
    }

    private func refreshDerivedCache() {
        derivedCache = MobileLedgerDerivedCache(data: data)
        invalidateTransactionSearchWarmup()
        clearTransactionListCaches()
        ledgerSearchResultCache.removeAll(keepingCapacity: true)
        accountSearchResultCache.removeAll(keepingCapacity: true)
        commoditySearchResultCache.removeAll(keepingCapacity: true)
        templateSearchResultCache.removeAll(keepingCapacity: true)
    }

    private func invalidateTransactionSearchWarmup() {
        transactionSearchCacheGeneration &+= 1
        transactionSearchWarmupTask?.cancel()
        transactionSearchWarmupTask = nil
        transactionSearchWarmupDelayTask?.cancel()
        transactionSearchWarmupDelayTask = nil
    }

    /// Updates cached row copies for a one-bit cleared-status change.
    ///
    /// Tapping the cleared checkmark is one of the highest-frequency mobile
    /// row actions. It should not rebuild account trees, balances, search text,
    /// and every transaction grouping when only the row copy and Uncleared
    /// membership changed.
    private func refreshDerivedCacheForTransactionStatusChange(_ transaction: LedgerTransaction) {
        derivedCache.transactionsByID[transaction.id] = transaction
        replaceTransaction(transaction, in: &derivedCache.allTransactionsDateDescending)
        replaceTransaction(transaction, in: &derivedCache.transactionsByLedgerDateDescending[transaction.ledgerID])
        replaceTransaction(transaction, in: &derivedCache.repeatingTransactionsByLedgerDateDescending[transaction.ledgerID])
        derivedCache.unclearedTransactionsByLedgerDateDescending[transaction.ledgerID] =
            (derivedCache.transactionsByLedgerDateDescending[transaction.ledgerID] ?? []).filter { !$0.cleared }

        for accountID in accountScopeIDs(touchedBy: transaction) {
            if derivedCache.transactionsByAccountScopeDateDescending[accountID] != nil {
                replaceTransaction(transaction, in: &derivedCache.transactionsByAccountScopeDateDescending[accountID])
            }
        }
        for commodityID in commodityIDs(touchedBy: transaction) {
            if derivedCache.transactionsByCommodityDateDescending[commodityID] != nil {
                replaceTransaction(transaction, in: &derivedCache.transactionsByCommodityDateDescending[commodityID])
            }
        }

        clearTransactionListCaches()
    }

    /// Removes one deleted row from mobile caches without rebuilding the whole
    /// journal. This keeps swipe/context-menu deletes responsive on larger
    /// synced journals while preserving affected balances and search caches.
    private func refreshDerivedCacheForTransactionDeletion(_ transaction: LedgerTransaction) {
        invalidateTransactionSearchWarmup()
        derivedCache.transactionsByID.removeValue(forKey: transaction.id)
        removeTransaction(transaction.id, from: &derivedCache.allTransactionsDateDescending)
        removeTransaction(transaction.id, from: &derivedCache.transactionsByLedgerDateDescending[transaction.ledgerID])
        removeTransaction(transaction.id, from: &derivedCache.unclearedTransactionsByLedgerDateDescending[transaction.ledgerID])
        removeTransaction(transaction.id, from: &derivedCache.repeatingTransactionsByLedgerDateDescending[transaction.ledgerID])

        for accountID in accountScopeIDs(touchedBy: transaction) {
            if derivedCache.transactionsByAccountScopeDateDescending[accountID] != nil {
                removeTransaction(transaction.id, from: &derivedCache.transactionsByAccountScopeDateDescending[accountID])
            }
        }
        for commodityID in commodityIDs(touchedBy: transaction) {
            if derivedCache.transactionsByCommodityDateDescending[commodityID] != nil {
                removeTransaction(transaction.id, from: &derivedCache.transactionsByCommodityDateDescending[commodityID])
            }
        }

        applyBalanceDelta(for: transaction, multiplier: -1)
        refreshLedgerTotalsByKind(ledgerID: transaction.ledgerID)
        derivedCache.registerAmountInfoByTransactionID.removeValue(forKey: transaction.id)
        derivedCache.accountFlowDisplayByTransactionID.removeValue(forKey: transaction.id)
        derivedCache.transactionSearchTextByID.removeValue(forKey: transaction.id)
        clearTransactionListCaches()
    }

    /// Inserts one new transaction into the derived caches touched by mobile
    /// duplication without forcing every journal/account/search cache to rebuild.
    private func refreshDerivedCacheForTransactionInsertion(_ transaction: LedgerTransaction) {
        invalidateTransactionSearchWarmup()
        let sourceIndexByID = transactionSourceIndexByID()
        derivedCache.transactionsByID[transaction.id] = transaction
        insertTransaction(transaction, in: &derivedCache.allTransactionsDateDescending, sourceIndexByID: sourceIndexByID)
        insertTransaction(transaction, in: &derivedCache.transactionsByLedgerDateDescending[transaction.ledgerID], sourceIndexByID: sourceIndexByID)
        if !transaction.cleared {
            insertTransaction(
                transaction,
                in: &derivedCache.unclearedTransactionsByLedgerDateDescending[transaction.ledgerID],
                sourceIndexByID: sourceIndexByID
            )
        }
        if transactionHasActiveRecurrence(transaction) {
            insertTransaction(
                transaction,
                in: &derivedCache.repeatingTransactionsByLedgerDateDescending[transaction.ledgerID],
                sourceIndexByID: sourceIndexByID
            )
        }

        for accountID in accountScopeIDs(touchedBy: transaction) {
            if derivedCache.transactionsByAccountScopeDateDescending[accountID] != nil {
                insertTransaction(
                    transaction,
                    in: &derivedCache.transactionsByAccountScopeDateDescending[accountID],
                    sourceIndexByID: sourceIndexByID
                )
            }
        }
        for commodityID in commodityIDs(touchedBy: transaction) {
            if derivedCache.transactionsByCommodityDateDescending[commodityID] != nil {
                insertTransaction(
                    transaction,
                    in: &derivedCache.transactionsByCommodityDateDescending[commodityID],
                    sourceIndexByID: sourceIndexByID
                )
            }
        }

        applyBalanceDelta(for: transaction, multiplier: 1)
        refreshLedgerTotalsByKind(ledgerID: transaction.ledgerID)
        derivedCache.registerAmountInfoByTransactionID[transaction.id] = registerAmountInfo(for: transaction)
        derivedCache.accountFlowDisplayByTransactionID[transaction.id] = derivedCache.accountFlowDisplay(for: transaction)
        derivedCache.transactionSearchTextByID[transaction.id] = transactionSearchText(for: transaction)
        clearTransactionListCaches()
    }

    private func refreshDerivedCacheForTransactionReplacement(previous: LedgerTransaction?, updated: LedgerTransaction) {
        guard let previous else {
            refreshDerivedCacheForTransactionInsertion(updated)
            return
        }
        if canRefreshTransactionDisplayReplacement(previous: previous, updated: updated) {
            refreshDerivedCacheForTransactionDisplayReplacement(updated)
            return
        }
        refreshDerivedCacheForTransactionDeletion(previous)
        refreshDerivedCacheForTransactionInsertion(updated)
    }

    private func canRefreshTransactionDisplayReplacement(previous: LedgerTransaction, updated: LedgerTransaction) -> Bool {
        previous.id == updated.id &&
            previous.ledgerID == updated.ledgerID &&
            previous.date == updated.date &&
            previous.cleared == updated.cleared &&
            previous.postings == updated.postings &&
            previous.recurrenceRule == updated.recurrenceRule
    }

    /// Replaces row copies for edits that only change visible transaction text
    /// or attachments. This avoids the heavier delete-plus-insert cache path
    /// for the common mobile note/payee/number save interaction.
    private func refreshDerivedCacheForTransactionDisplayReplacement(_ transaction: LedgerTransaction) {
        invalidateTransactionSearchWarmup()
        derivedCache.transactionsByID[transaction.id] = transaction
        replaceTransaction(transaction, in: &derivedCache.allTransactionsDateDescending)
        replaceTransaction(transaction, in: &derivedCache.transactionsByLedgerDateDescending[transaction.ledgerID])
        replaceTransaction(transaction, in: &derivedCache.unclearedTransactionsByLedgerDateDescending[transaction.ledgerID])
        replaceTransaction(transaction, in: &derivedCache.repeatingTransactionsByLedgerDateDescending[transaction.ledgerID])

        for accountID in accountScopeIDs(touchedBy: transaction) {
            if derivedCache.transactionsByAccountScopeDateDescending[accountID] != nil {
                replaceTransaction(transaction, in: &derivedCache.transactionsByAccountScopeDateDescending[accountID])
            }
        }
        for commodityID in commodityIDs(touchedBy: transaction) {
            if derivedCache.transactionsByCommodityDateDescending[commodityID] != nil {
                replaceTransaction(transaction, in: &derivedCache.transactionsByCommodityDateDescending[commodityID])
            }
        }

        derivedCache.transactionSearchTextByID[transaction.id] = transactionSearchText(for: transaction)
        clearTransactionListCaches()
        scheduleTransactionSearchWarmupAfterMutation()
    }

    /// Refreshes account-only metadata after edits that leave hierarchy,
    /// currency, balances, and transaction membership unchanged.
    private func refreshDerivedCacheForAccountMetadataChange(_ account: Account) {
        invalidateTransactionSearchWarmup()
        derivedCache.accountsByID[account.id] = account
        if var ledgerAccounts = derivedCache.accountsByLedger[account.ledgerID],
           let index = ledgerAccounts.firstIndex(where: { $0.id == account.id }) {
            ledgerAccounts[index] = account
            derivedCache.accountsByLedger[account.ledgerID] = ledgerAccounts
        }
        refreshAccountNodeCaches(ledgerID: account.ledgerID)
        derivedCache.accountSearchTextByID[account.id] = accountSearchText(for: account)
        derivedCache.accountFlowDisplayByTransactionID.removeAll(keepingCapacity: true)
        derivedCache.transactionSearchTextByID.removeAll(keepingCapacity: true)
        for template in data.transactionTemplates where template.postings.contains(where: { $0.accountID == account.id }) {
            derivedCache.transactionTemplateSearchTextByID[template.id] = transactionTemplateSearchText(for: template)
        }
        accountSearchResultCache.removeAll(keepingCapacity: true)
        templateSearchResultCache.removeAll(keepingCapacity: true)
    }

    /// Updates cached ledger labels and search text after a journal rename.
    ///
    /// Renaming a journal changes labels embedded in account, currency,
    /// template, and transaction search haystacks, but it does not affect row
    /// membership, balances, or register ordering.
    private func refreshDerivedCacheForLedgerMetadataChange(_ ledger: Ledger) {
        invalidateTransactionSearchWarmup()
        derivedCache.ledgersByID[ledger.id] = ledger
        if let index = derivedCache.orderedLedgers.firstIndex(where: { $0.id == ledger.id }) {
            derivedCache.orderedLedgers[index] = ledger
            derivedCache.orderedLedgers.sort { $0.listIndex < $1.listIndex }
        }
        derivedCache.ledgerSearchTextByID[ledger.id] = ledgerSearchText(for: ledger)

        for account in derivedCache.accountsByLedger[ledger.id] ?? [] {
            derivedCache.accountSearchTextByID[account.id] = accountSearchText(for: account)
        }
        for commodity in derivedCache.commoditiesByLedger[ledger.id] ?? [] {
            derivedCache.commoditySearchTextByID[commodity.id] = commoditySearchText(for: commodity)
        }
        for template in derivedCache.transactionTemplatesByLedger[ledger.id] ?? [] {
            derivedCache.transactionTemplateSearchTextByID[template.id] = transactionTemplateSearchText(for: template)
        }
        derivedCache.transactionSearchTextByID.removeAll(keepingCapacity: true)

        ledgerSearchResultCache.removeAll(keepingCapacity: true)
        accountSearchResultCache.removeAll(keepingCapacity: true)
        commoditySearchResultCache.removeAll(keepingCapacity: true)
        templateSearchResultCache.removeAll(keepingCapacity: true)
    }

    /// Adds a newly seeded journal to derived caches without rebuilding the
    /// existing synced transaction journal. New-journal creation only touches
    /// one ledger plus its scaffold accounts/currency/opening transaction.
    private func refreshDerivedCacheForJournalInsertion(ledgerID: UUID) {
        guard let ledger = data.ledgers.first(where: { $0.id == ledgerID }) else { return }
        invalidateTransactionSearchWarmup()
        derivedCache.ledgersByID[ledger.id] = ledger
        if !derivedCache.orderedLedgers.contains(where: { $0.id == ledger.id }) {
            derivedCache.orderedLedgers.append(ledger)
        }
        derivedCache.orderedLedgers.sort { $0.listIndex < $1.listIndex }
        derivedCache.ledgerSearchTextByID[ledger.id] = ledgerSearchText(for: ledger)

        let ledgerAccounts = MobileLedgerDerivedCache.sortedAccounts(data.accounts.filter { $0.ledgerID == ledgerID })
        let ledgerCommodities = data.commodities
            .filter { $0.ledgerID == ledgerID }
            .sorted { $0.symbol.localizedCaseInsensitiveCompare($1.symbol) == .orderedAscending }
        derivedCache.accountsByLedger[ledgerID] = ledgerAccounts
        derivedCache.commoditiesByLedger[ledgerID] = ledgerCommodities
        derivedCache.defaultCommodityIDByLedger[ledgerID] = ledgerCommodities.first?.id
        for commodity in ledgerCommodities {
            derivedCache.commoditiesByID[commodity.id] = commodity
            derivedCache.commoditySearchTextByID[commodity.id] = commoditySearchText(for: commodity)
        }
        for account in ledgerAccounts {
            derivedCache.accountsByID[account.id] = account
            derivedCache.accountSearchTextByID[account.id] = accountSearchText(for: account)
        }
        refreshDescendantCaches(for: ledgerAccounts)
        refreshAccountNodeCaches(ledgerID: ledgerID)
        refreshLedgerTotalsByKind(ledgerID: ledgerID)

        for transaction in data.transactions where transaction.ledgerID == ledgerID {
            refreshDerivedCacheForTransactionInsertion(transaction)
        }

        ledgerSearchResultCache.removeAll(keepingCapacity: true)
        accountSearchResultCache.removeAll(keepingCapacity: true)
        commoditySearchResultCache.removeAll(keepingCapacity: true)
        templateSearchResultCache.removeAll(keepingCapacity: true)
    }

    private func refreshDerivedCacheForJournalDeletion(
        ledgerID: UUID,
        removedAccountIDs: Set<UUID>,
        removedCommodityIDs: Set<UUID>,
        removedTransactionIDs: Set<UUID>,
        removedTemplateIDs: Set<UUID>
    ) {
        invalidateTransactionSearchWarmup()
        derivedCache.orderedLedgers.removeAll { $0.id == ledgerID }
        derivedCache.ledgersByID.removeValue(forKey: ledgerID)
        derivedCache.accountsByLedger.removeValue(forKey: ledgerID)
        derivedCache.commoditiesByLedger.removeValue(forKey: ledgerID)
        derivedCache.transactionTemplatesByLedger.removeValue(forKey: ledgerID)
        derivedCache.defaultCommodityIDByLedger.removeValue(forKey: ledgerID)
        derivedCache.ledgerTotalsByKind.removeValue(forKey: ledgerID)
        derivedCache.ledgerSearchTextByID.removeValue(forKey: ledgerID)

        derivedCache.transactionsByLedgerDateDescending.removeValue(forKey: ledgerID)
        derivedCache.unclearedTransactionsByLedgerDateDescending.removeValue(forKey: ledgerID)
        derivedCache.repeatingTransactionsByLedgerDateDescending.removeValue(forKey: ledgerID)
        derivedCache.allTransactionsDateDescending.removeAll { removedTransactionIDs.contains($0.id) }

        let allKey = MobileAccountNodeCacheKey(ledgerID: ledgerID, kind: nil)
        derivedCache.accountNodesByLedgerAndKind.removeValue(forKey: allKey)
        derivedCache.leafAccountNodesByLedger.removeValue(forKey: ledgerID)
        for kind in AccountKind.allCases {
            let key = MobileAccountNodeCacheKey(ledgerID: ledgerID, kind: kind)
            derivedCache.accountNodesByLedgerAndKind.removeValue(forKey: key)
            derivedCache.groupAccountNodesByLedgerAndKind.removeValue(forKey: key)
        }

        for accountID in removedAccountIDs {
            derivedCache.accountsByID.removeValue(forKey: accountID)
            derivedCache.descendantIDsByAccount.removeValue(forKey: accountID)
            derivedCache.balanceRowsByAccount.removeValue(forKey: accountID)
            derivedCache.transactionsByAccountScopeDateDescending.removeValue(forKey: accountID)
            derivedCache.accountSearchTextByID.removeValue(forKey: accountID)
        }
        for commodityID in removedCommodityIDs {
            derivedCache.commoditiesByID.removeValue(forKey: commodityID)
            derivedCache.transactionsByCommodityDateDescending.removeValue(forKey: commodityID)
            derivedCache.commoditySearchTextByID.removeValue(forKey: commodityID)
        }
        for transactionID in removedTransactionIDs {
            derivedCache.transactionsByID.removeValue(forKey: transactionID)
            derivedCache.registerAmountInfoByTransactionID.removeValue(forKey: transactionID)
            derivedCache.accountFlowDisplayByTransactionID.removeValue(forKey: transactionID)
            derivedCache.transactionSearchTextByID.removeValue(forKey: transactionID)
        }
        for templateID in removedTemplateIDs {
            derivedCache.transactionTemplateSearchTextByID.removeValue(forKey: templateID)
        }
        clearTransactionListCaches()
        ledgerSearchResultCache.removeAll(keepingCapacity: true)
        accountSearchResultCache.removeAll(keepingCapacity: true)
        commoditySearchResultCache.removeAll(keepingCapacity: true)
        templateSearchResultCache.removeAll(keepingCapacity: true)
    }

    /// Refreshes account-only lookup data for account creates and safe deletes.
    ///
    /// These paths only use this helper when the affected accounts are not
    /// referenced by transactions. That keeps transaction, balance, and row
    /// caches valid while account pickers and search update immediately.
    private func refreshDerivedCacheForAccountListChange(ledgerID: UUID) {
        invalidateTransactionSearchWarmup()
        derivedCache.accountsByID = Dictionary(data.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        derivedCache.accountsByLedger[ledgerID] = MobileLedgerDerivedCache.sortedAccounts(data.accounts.filter { $0.ledgerID == ledgerID })
        refreshAccountNodeCaches(ledgerID: ledgerID)

        let childrenByParent = Dictionary(grouping: data.accounts.compactMap { account -> Account? in
            account.parentID == nil ? nil : account
        }, by: { $0.parentID! })
        var descendantMemo: [UUID: Set<UUID>] = [:]
        func descendants(of accountID: UUID) -> Set<UUID> {
            if let memo = descendantMemo[accountID] {
                return memo
            }
            let children = childrenByParent[accountID] ?? []
            let result = children.reduce(Set(children.map(\.id))) { partial, child in
                partial.union(descendants(of: child.id))
            }
            descendantMemo[accountID] = result
            return result
        }
        derivedCache.descendantIDsByAccount = Dictionary(uniqueKeysWithValues: data.accounts.map { account in
            (account.id, descendants(of: account.id))
        })

        let validAccountIDs = Set(derivedCache.accountsByID.keys)
        derivedCache.balanceRowsByAccount = derivedCache.balanceRowsByAccount.filter { validAccountIDs.contains($0.key) }
        derivedCache.transactionsByAccountScopeDateDescending = derivedCache.transactionsByAccountScopeDateDescending.filter {
            validAccountIDs.contains($0.key)
        }
        derivedCache.accountSearchTextByID = derivedCache.accountSearchTextByID.filter { validAccountIDs.contains($0.key) }
        for account in derivedCache.accountsByLedger[ledgerID] ?? [] {
            derivedCache.accountSearchTextByID[account.id] = accountSearchText(for: account)
        }
        refreshLedgerTotalsByKind(ledgerID: ledgerID)
        accountSearchResultCache.removeAll(keepingCapacity: true)
    }

    private func refreshDescendantCaches(for accounts: [Account]) {
        let childrenByParent = Dictionary(grouping: accounts.compactMap { account -> Account? in
            account.parentID == nil ? nil : account
        }, by: { $0.parentID! })
        var descendantMemo: [UUID: Set<UUID>] = [:]
        func descendants(of accountID: UUID) -> Set<UUID> {
            if let memo = descendantMemo[accountID] {
                return memo
            }
            let children = childrenByParent[accountID] ?? []
            let result = children.reduce(Set(children.map(\.id))) { partial, child in
                partial.union(descendants(of: child.id))
            }
            descendantMemo[accountID] = result
            return result
        }
        for account in accounts {
            derivedCache.descendantIDsByAccount[account.id] = descendants(of: account.id)
        }
    }

    /// Refreshes currency lookup and rendered symbol caches after a currency
    /// create, rename, or safe delete.
    private func refreshDerivedCacheForCommodityListChange(ledgerID: UUID) {
        derivedCache.commoditiesByID = Dictionary(data.commodities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        derivedCache.commoditiesByLedger[ledgerID] = data.commodities
            .filter { $0.ledgerID == ledgerID }
            .sorted { $0.symbol.localizedCaseInsensitiveCompare($1.symbol) == .orderedAscending }
        derivedCache.defaultCommodityIDByLedger[ledgerID] = data.commodities.first { $0.ledgerID == ledgerID }?.id

        let validCommodityIDs = Set(derivedCache.commoditiesByID.keys)
        derivedCache.commoditySearchTextByID = derivedCache.commoditySearchTextByID.filter { validCommodityIDs.contains($0.key) }
        derivedCache.transactionsByCommodityDateDescending = derivedCache.transactionsByCommodityDateDescending.filter {
            validCommodityIDs.contains($0.key)
        }
        for commodity in derivedCache.commoditiesByLedger[ledgerID] ?? [] {
            derivedCache.commoditySearchTextByID[commodity.id] = commoditySearchText(for: commodity)
        }

        for account in derivedCache.accountsByLedger[ledgerID] ?? [] {
            derivedCache.accountSearchTextByID[account.id] = accountSearchText(for: account)
            if let rows = derivedCache.balanceRowsByAccount[account.id] {
                derivedCache.balanceRowsByAccount[account.id] = rows
                    .map { MobileBalanceRow(commodityID: $0.commodityID, symbol: cacheSymbol(for: $0.commodityID), amount: $0.amount) }
                    .sorted { $0.symbol < $1.symbol }
            }
        }
        derivedCache.registerAmountInfoByTransactionID.removeAll(keepingCapacity: true)
        refreshLedgerTotalsByKind(ledgerID: ledgerID)

        clearTransactionListCaches()
        accountSearchResultCache.removeAll(keepingCapacity: true)
        commoditySearchResultCache.removeAll(keepingCapacity: true)
    }

    private func clearTransactionListCaches() {
        transactionRowsCache.removeAll(keepingCapacity: true)
        transactionDaySectionCache.removeAll(keepingCapacity: true)
    }

    private func refreshDerivedCacheForTransactionTemplateListChange(ledgerID: UUID) {
        derivedCache.transactionTemplatesByLedger[ledgerID] = data.transactionTemplates
            .filter { $0.ledgerID == ledgerID }
            .sorted { $0.listIndex < $1.listIndex }
        let validTemplateIDs = Set(data.transactionTemplates.map(\.id))
        derivedCache.transactionTemplateSearchTextByID = derivedCache.transactionTemplateSearchTextByID.filter {
            validTemplateIDs.contains($0.key)
        }
        for template in derivedCache.transactionTemplatesByLedger[ledgerID] ?? [] {
            derivedCache.transactionTemplateSearchTextByID[template.id] = transactionTemplateSearchText(for: template)
        }
        templateSearchResultCache.removeAll(keepingCapacity: true)
    }

    private func refreshAccountNodeCaches(ledgerID: UUID) {
        let accounts = derivedCache.accountsByLedger[ledgerID] ?? []
        let allKey = MobileAccountNodeCacheKey(ledgerID: ledgerID, kind: nil)
        derivedCache.accountNodesByLedgerAndKind[allKey] = MobileLedgerDerivedCache.accountNodes(from: accounts)
        derivedCache.leafAccountNodesByLedger[ledgerID] =
            derivedCache.accountNodesByLedgerAndKind[allKey]?.filter { !$0.account.isGroup } ?? []
        for kind in AccountKind.allCases {
            let key = MobileAccountNodeCacheKey(ledgerID: ledgerID, kind: kind)
            let nodes = MobileLedgerDerivedCache.accountNodes(from: accounts.filter { $0.kind == kind })
            derivedCache.accountNodesByLedgerAndKind[key] = nodes
            derivedCache.groupAccountNodesByLedgerAndKind[key] = nodes.filter(\.account.isGroup)
        }
    }

    private func replaceTransaction(_ transaction: LedgerTransaction, in rows: inout [LedgerTransaction]) {
        guard let index = rows.firstIndex(where: { $0.id == transaction.id }) else { return }
        rows[index] = transaction
    }

    private func replaceTransaction(_ transaction: LedgerTransaction, in rows: inout [LedgerTransaction]?) {
        guard let index = rows?.firstIndex(where: { $0.id == transaction.id }) else { return }
        rows?[index] = transaction
    }

    private func removeTransaction(_ transactionID: UUID, from rows: inout [LedgerTransaction]) {
        rows.removeAll { $0.id == transactionID }
    }

    private func removeTransaction(_ transactionID: UUID, from rows: inout [LedgerTransaction]?) {
        rows?.removeAll { $0.id == transactionID }
    }

    private func insertTransaction(
        _ transaction: LedgerTransaction,
        in rows: inout [LedgerTransaction],
        sourceIndexByID: [UUID: Int]
    ) {
        rows.removeAll { $0.id == transaction.id }
        let sourceIndex = sourceIndexByID[transaction.id] ?? .max
        let insertionIndex = rows.firstIndex { row in
            if transaction.date != row.date {
                return transaction.date > row.date
            }
            return sourceIndex < (sourceIndexByID[row.id] ?? .max)
        } ?? rows.endIndex
        rows.insert(transaction, at: insertionIndex)
    }

    private func insertTransaction(
        _ transaction: LedgerTransaction,
        in rows: inout [LedgerTransaction]?,
        sourceIndexByID: [UUID: Int]
    ) {
        var updatedRows = rows ?? []
        insertTransaction(transaction, in: &updatedRows, sourceIndexByID: sourceIndexByID)
        rows = updatedRows
    }

    private func transactionSourceIndexByID() -> [UUID: Int] {
        Dictionary(data.transactions.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    private func applyBalanceDelta(for transaction: LedgerTransaction, multiplier: Decimal) {
        guard transaction.date < derivedCache.balanceDateCutoff else { return }
        for posting in transaction.postings {
            let commodityID = postingCommodityID(posting, ledgerID: transaction.ledgerID)
            let delta = posting.amount * multiplier
            var accountID: UUID? = posting.accountID
            while let currentID = accountID,
                  let account = derivedCache.accountsByID[currentID] {
                var balances = Dictionary(
                    uniqueKeysWithValues: (derivedCache.balanceRowsByAccount[currentID] ?? []).map { row in
                        (row.commodityID, row.amount)
                    }
                )
                balances[commodityID, default: .zero] += delta
                derivedCache.balanceRowsByAccount[currentID] = balanceRows(from: balances)
                accountID = account.parentID
            }
        }
    }

    private func balanceRows(from balances: [UUID?: Decimal]) -> [MobileBalanceRow] {
        balances
            .filter { $0.value != .zero }
            .map { MobileBalanceRow(commodityID: $0.key, symbol: cacheSymbol(for: $0.key), amount: $0.value) }
            .sorted { $0.symbol < $1.symbol }
    }

    private func cacheSymbol(for commodityID: UUID?) -> String {
        commodityID.flatMap { derivedCache.commoditiesByID[$0]?.symbol } ?? "USD"
    }

    private func refreshLedgerTotalsByKind(ledgerID: UUID) {
        let roots = (derivedCache.accountsByLedger[ledgerID] ?? []).filter { $0.parentID == nil }
        derivedCache.ledgerTotalsByKind[ledgerID] = Dictionary(uniqueKeysWithValues: AccountKind.allCases.map { kind in
            let rows = roots
                .filter { $0.kind == kind }
                .flatMap { derivedCache.balanceRowsByAccount[$0.id] ?? [] }
                .reduce(into: [String: MobileBalanceRow]()) { partial, row in
                    var existing = partial[row.id] ?? MobileBalanceRow(
                        commodityID: row.commodityID,
                        symbol: row.symbol,
                        amount: .zero
                    )
                    existing.amount += row.amount
                    partial[row.id] = existing
                }
                .values
                .sorted { $0.symbol < $1.symbol }
            return (kind, rows)
        })
    }

    private func transactionSearchText(for transaction: LedgerTransaction) -> String {
        ([
            transaction.payee,
            transaction.note,
            transaction.number,
            derivedCache.ledgersByID[transaction.ledgerID]?.name ?? ""
        ] + transaction.postings.compactMap { derivedCache.accountsByID[$0.accountID]?.name })
            .joined(separator: " ")
            .lowercased()
    }

    private nonisolated static func transactionSearchWarmupResult(
        transactions: [LedgerTransaction],
        accountsByID: [UUID: Account],
        ledgersByID: [UUID: Ledger]
    ) -> MobileTransactionSearchWarmupResult {
        var textByID: [UUID: String] = [:]
        textByID.reserveCapacity(transactions.count)
        for transaction in transactions {
            let postingAccounts = transaction.postings.compactMap { posting in
                accountsByID[posting.accountID]?.name
            }
            let text = ([
                transaction.payee,
                transaction.note,
                transaction.number,
                ledgersByID[transaction.ledgerID]?.name ?? ""
            ] + postingAccounts)
                .joined(separator: " ")
                .lowercased()
            textByID[transaction.id] = text
        }
        return MobileTransactionSearchWarmupResult(textByID: textByID)
    }

    private nonisolated static func transactionSearchTextByID(
        transactions: [LedgerTransaction],
        accountsByID: [UUID: Account],
        ledgersByID: [UUID: Ledger]
    ) -> [UUID: String] {
        transactionSearchWarmupResult(
            transactions: transactions,
            accountsByID: accountsByID,
            ledgersByID: ledgersByID
        ).textByID
    }

    private func ensureTransactionSearchText(for transaction: LedgerTransaction) -> String {
        if let cached = derivedCache.transactionSearchTextByID[transaction.id] {
            return cached
        }
        let text = transactionSearchText(for: transaction)
        derivedCache.transactionSearchTextByID[transaction.id] = text
        return text
    }

    private func warmTransactionSearchCacheInBackground() {
        let transactions = derivedCache.allTransactionsDateDescending
        guard !transactions.isEmpty else { return }
        guard derivedCache.transactionSearchTextByID.count < transactions.count else {
            return
        }

        transactionSearchWarmupTask?.cancel()
        let generation = transactionSearchCacheGeneration
        let accountsByID = derivedCache.accountsByID
        let ledgersByID = derivedCache.ledgersByID
        transactionSearchWarmupTask = Task.detached(priority: .utility) { [weak self, transactions, accountsByID, ledgersByID, generation] in
            let warmupResult = Self.transactionSearchWarmupResult(
                transactions: transactions,
                accountsByID: accountsByID,
                ledgersByID: ledgersByID
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self, warmupResult] in
                guard let self, self.transactionSearchCacheGeneration == generation else { return }
                for (id, text) in warmupResult.textByID where self.derivedCache.transactionsByID[id] != nil {
                    self.derivedCache.transactionSearchTextByID[id] = self.derivedCache.transactionSearchTextByID[id] ?? text
                }
                self.transactionSearchWarmupTask = nil
            }
        }
    }

    private func scheduleTransactionSearchWarmupAfterMutation() {
        transactionSearchWarmupDelayTask?.cancel()
        transactionSearchWarmupDelayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.transactionSearchWarmupDelayTask = nil
                self.warmTransactionSearchCacheInBackground()
            }
        }
    }

    func warmTransactionSearchCacheForPerformanceProbe() {
        let generation = transactionSearchCacheGeneration
        let warmupResult = Self.transactionSearchWarmupResult(
            transactions: derivedCache.allTransactionsDateDescending,
            accountsByID: derivedCache.accountsByID,
            ledgersByID: derivedCache.ledgersByID
        )
        guard transactionSearchCacheGeneration == generation else { return }
        for (id, text) in warmupResult.textByID where derivedCache.transactionsByID[id] != nil {
            derivedCache.transactionSearchTextByID[id] = text
        }
    }

    private func ledgerSearchText(for ledger: Ledger) -> String {
        ledger.name.lowercased()
    }

    private func accountSearchText(for account: Account) -> String {
        [
            account.name,
            account.note,
            account.kind.title,
            derivedCache.ledgersByID[account.ledgerID]?.name ?? "",
            account.commodityID.flatMap { derivedCache.commoditiesByID[$0]?.symbol } ?? ""
        ]
            .joined(separator: " ")
            .lowercased()
    }

    private func commoditySearchText(for commodity: Commodity) -> String {
        [
            commodity.symbol,
            commodity.name,
            derivedCache.ledgersByID[commodity.ledgerID]?.name ?? ""
        ]
            .joined(separator: " ")
            .lowercased()
    }

    private func transactionTemplateSearchText(for template: TransactionTemplate) -> String {
        let postingAccounts = template.postings.compactMap { posting in
            posting.accountID.flatMap { derivedCache.accountsByID[$0]?.name }
        }
        return ([
            template.name,
            template.note,
            template.payee,
            derivedCache.ledgersByID[template.ledgerID]?.name ?? ""
        ] + postingAccounts)
            .joined(separator: " ")
            .lowercased()
    }

    private func transactionHasActiveRecurrence(_ transaction: LedgerTransaction) -> Bool {
        guard let frequency = transaction.recurrenceRule?.frequency else { return false }
        return frequency != .never
    }

    static func defaultSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let subdirectory = NativeJournalStorage.subdirectory(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            infoDictionary: Bundle.main.infoDictionary
        ) ?? "FinancesMobile"
        return base.appending(path: subdirectory, directoryHint: .isDirectory)
    }

    var selectedLedger: Ledger? {
        if let selectedLedgerID = data.selectedLedgerID,
           let ledger = derivedCache.ledgersByID[selectedLedgerID] {
            return ledger
        }
        return derivedCache.orderedLedgers.first
    }

    var selectedLedgerID: UUID? {
        selectedLedger?.id
    }

    var orderedLedgers: [Ledger] {
        derivedCache.orderedLedgers
    }

    func ledger(_ id: UUID?) -> Ledger? {
        guard let id else { return nil }
        return derivedCache.ledgersByID[id]
    }

    var selectedLedgerCurrencies: [Commodity] {
        guard let selectedLedgerID else { return [] }
        return derivedCache.commoditiesByLedger[selectedLedgerID] ?? []
    }

    var selectedLedgerAccounts: [Account] {
        guard let selectedLedgerID else { return [] }
        return derivedCache.accountsByLedger[selectedLedgerID] ?? []
    }

    var selectedLedgerTransactions: [LedgerTransaction] {
        guard let selectedLedgerID else { return [] }
        return transactions(scope: .all, ledgerID: selectedLedgerID)
    }

    var selectedLedgerTransactionTemplates: [TransactionTemplate] {
        guard let selectedLedgerID else { return [] }
        return transactionTemplates(for: selectedLedgerID)
    }

    func transactionTemplates(for ledgerID: UUID) -> [TransactionTemplate] {
        derivedCache.transactionTemplatesByLedger[ledgerID] ?? []
    }

    func selectLedger(_ ledgerID: UUID) {
        guard data.selectedLedgerID != ledgerID,
              data.ledgers.contains(where: { $0.id == ledgerID }) else {
            return
        }
        data.selectedLedgerID = ledgerID
        if backupFileOperationInProgress { backupSelectionChanged = true; return }
        save(syncCloud: true, refreshCache: false)
    }

    func accounts(for ledgerID: UUID) -> [Account] {
        derivedCache.accountsByLedger[ledgerID] ?? []
    }

    func commodities(for ledgerID: UUID) -> [Commodity] {
        derivedCache.commoditiesByLedger[ledgerID] ?? []
    }

    func account(_ id: UUID?) -> Account? {
        guard let id else { return nil }
        return derivedCache.accountsByID[id]
    }

    func commodity(_ id: UUID?) -> Commodity? {
        guard let id else { return nil }
        return derivedCache.commoditiesByID[id]
    }

    func transaction(_ id: UUID?) -> LedgerTransaction? {
        guard let id else { return nil }
        return derivedCache.transactionsByID[id]
    }

    func symbol(for commodityID: UUID?, ledgerID: UUID? = nil) -> String {
        commodityID.flatMap { derivedCache.commoditiesByID[$0]?.symbol }
            ?? (ledgerID.map { commodities(for: $0) } ?? selectedLedgerCurrencies).first?.symbol ?? "USD"
    }

    func accountNodes(kind: AccountKind? = nil, ledgerID: UUID? = nil) -> [MobileAccountNode] {
        guard let ledgerID = ledgerID ?? selectedLedgerID else { return [] }
        return derivedCache.accountNodesByLedgerAndKind[MobileAccountNodeCacheKey(ledgerID: ledgerID, kind: kind)] ?? []
    }

    func leafAccountNodes(ledgerID: UUID? = nil) -> [MobileAccountNode] {
        guard let ledgerID = ledgerID ?? selectedLedgerID else { return [] }
        return derivedCache.leafAccountNodesByLedger[ledgerID] ?? []
    }

    func groupAccountNodes(kind: AccountKind, excluding excludedID: UUID? = nil, ledgerID: UUID? = nil) -> [MobileAccountNode] {
        guard let ledgerID = ledgerID ?? selectedLedgerID else { return [] }
        let rows = derivedCache.groupAccountNodesByLedgerAndKind[MobileAccountNodeCacheKey(ledgerID: ledgerID, kind: kind)] ?? []
        guard let excludedID else { return rows }
        return rows.filter { $0.account.id != excludedID }
    }

    private func ensureAccountScopeTransactionsDateDescending(for accountID: UUID) -> [LedgerTransaction] {
        if let cached = derivedCache.transactionsByAccountScopeDateDescending[accountID] {
            return cached
        }
        let scopedIDs = descendantIDs(of: accountID).union([accountID])
        let rows = derivedCache.allTransactionsDateDescending.filter { transaction in
            transaction.postings.contains { scopedIDs.contains($0.accountID) }
        }
        derivedCache.transactionsByAccountScopeDateDescending[accountID] = rows
        return rows
    }

    private func ensureCommodityTransactionsDateDescending(for commodityID: UUID) -> [LedgerTransaction] {
        if let cached = derivedCache.transactionsByCommodityDateDescending[commodityID] {
            return cached
        }
        let rows = derivedCache.allTransactionsDateDescending.filter { transaction in
            transaction.postings.contains { posting in
                postingCommodityID(posting, ledgerID: transaction.ledgerID) == commodityID
            }
        }
        derivedCache.transactionsByCommodityDateDescending[commodityID] = rows
        return rows
    }

    func accountFlowDisplay(for transaction: LedgerTransaction) -> MobileAccountFlowDisplay {
        if let cached = derivedCache.accountFlowDisplayByTransactionID[transaction.id] {
            return cached
        }
        let display = derivedCache.accountFlowDisplay(for: transaction)
        derivedCache.accountFlowDisplayByTransactionID[transaction.id] = display
        return display
    }

    func transactions(scope: MobileTransactionScope, ledgerID: UUID? = nil, search: String = "") -> [LedgerTransaction] {
        let ledgerID = ledgerID ?? selectedLedgerID
        let normalizedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dayBucket = Calendar.current.startOfDay(for: Date())
        let cacheKey = MobileTransactionRowsCacheKey(
            scope: scope,
            ledgerID: ledgerID,
            normalizedSearch: normalizedSearch,
            dayBucket: dayBucket
        )
        if let cached = transactionRowsCache[cacheKey] {
            return cached
        }

        let baseRows: [LedgerTransaction]
        switch scope {
        case .all:
            baseRows = ledgerID.map { derivedCache.transactionsByLedgerDateDescending[$0] ?? [] }
                ?? derivedCache.allTransactionsDateDescending
        case .uncleared:
            baseRows = ledgerID.map { derivedCache.unclearedTransactionsByLedgerDateDescending[$0] ?? [] }
                ?? derivedCache.allTransactionsDateDescending.filter { !$0.cleared }
        case .repeating:
            baseRows = ledgerID.map { derivedCache.repeatingTransactionsByLedgerDateDescending[$0] ?? [] }
                ?? derivedCache.allTransactionsDateDescending.filter { transaction in
                    guard let frequency = transaction.recurrenceRule?.frequency else { return false }
                    return frequency != .never
                }
        case .today:
            let rows = ledgerID.map { derivedCache.transactionsByLedgerDateDescending[$0] ?? [] }
                ?? derivedCache.allTransactionsDateDescending
            baseRows = rows.filter { Calendar.current.isDateInToday($0.date) }
        case .lastMonth:
            let calendar = Calendar.current
            let monthAgo = calendar.date(byAdding: .month, value: -1, to: Date()) ?? .distantFuture
            let rows = ledgerID.map { derivedCache.transactionsByLedgerDateDescending[$0] ?? [] }
                ?? derivedCache.allTransactionsDateDescending
            let interval = calendar.dateInterval(of: .month, for: monthAgo)
            baseRows = rows.filter { row in interval.map { row.date >= $0.start && row.date < $0.end } ?? false }
        case .account(let accountID):
            let rows = ensureAccountScopeTransactionsDateDescending(for: accountID)
            if let ledgerID {
                baseRows = rows.filter { $0.ledgerID == ledgerID }
            } else {
                baseRows = rows
            }
        case .currency(let commodityID):
            let rows = ensureCommodityTransactionsDateDescending(for: commodityID)
            if let ledgerID {
                baseRows = rows.filter { $0.ledgerID == ledgerID }
            } else {
                baseRows = rows
            }
        }

        let rows: [LedgerTransaction]
        if normalizedSearch.isEmpty {
            rows = baseRows
        } else {
            rows = baseRows.filter { transaction in
                ensureTransactionSearchText(for: transaction).contains(normalizedSearch)
            }
        }
        transactionRowsCache[cacheKey] = rows
        return rows
    }

    func unclearedTransactionCount(ledgerID: UUID, now: Date = Date(), calendar: Calendar = .current) -> Int {
        transactions(scope: .uncleared, ledgerID: ledgerID)
            .filter { calendar.compare($0.date, to: now, toGranularity: .day) != .orderedDescending }
            .count
    }

    func transactionDaySections(
        scope: MobileTransactionScope,
        ledgerID: UUID? = nil,
        search: String = ""
    ) -> [MobileTransactionDaySection] {
        let ledgerID = ledgerID ?? selectedLedgerID
        let normalizedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dayBucket = Calendar.current.startOfDay(for: Date())
        let cacheKey = MobileTransactionRowsCacheKey(
            scope: scope,
            ledgerID: ledgerID,
            normalizedSearch: normalizedSearch,
            dayBucket: dayBucket
        )
        if let cached = transactionDaySectionCache[cacheKey] {
            return cached
        }

        let calendar = Calendar.current
        var sections: [MobileTransactionDaySection] = []
        var currentDate: Date?
        var currentRows: [LedgerTransaction] = []

        func appendCurrentSection() {
            guard let currentDate else { return }
            sections.append(MobileTransactionDaySection(date: currentDate, transactions: currentRows))
        }

        for transaction in transactions(scope: scope, ledgerID: ledgerID, search: search) {
            let day = calendar.startOfDay(for: transaction.date)
            if currentDate == nil {
                currentDate = day
            } else if currentDate != day {
                appendCurrentSection()
                currentDate = day
                currentRows.removeAll(keepingCapacity: true)
            }
            currentRows.append(transaction)
        }
        appendCurrentSection()

        transactionDaySectionCache[cacheKey] = sections
        return sections
    }

    func searchLedgers(_ search: String, limit: Int = 12) -> [Ledger] {
        let normalizedSearch = normalizedSearch(search)
        guard !normalizedSearch.isEmpty else { return [] }
        let cacheKey = MobileSearchCacheKey(normalizedSearch: normalizedSearch, limit: limit)
        if let cached = ledgerSearchResultCache[cacheKey] {
            return cached
        }
        let rows = derivedCache.orderedLedgers
            .filter { derivedCache.ledgerSearchTextByID[$0.id]?.contains(normalizedSearch) ?? false }
            .prefix(limit)
            .map { $0 }
        ledgerSearchResultCache[cacheKey] = rows
        return rows
    }

    func searchAccounts(_ search: String, limit: Int = 30) -> [Account] {
        let normalizedSearch = normalizedSearch(search)
        guard !normalizedSearch.isEmpty else { return [] }
        let cacheKey = MobileSearchCacheKey(normalizedSearch: normalizedSearch, limit: limit)
        if let cached = accountSearchResultCache[cacheKey] {
            return cached
        }
        let rows = derivedCache.orderedLedgers
            .flatMap { derivedCache.accountsByLedger[$0.id] ?? [] }
            .filter { derivedCache.accountSearchTextByID[$0.id]?.contains(normalizedSearch) ?? false }
            .prefix(limit)
            .map { $0 }
        accountSearchResultCache[cacheKey] = rows
        return rows
    }

    func searchCommodities(_ search: String, limit: Int = 20) -> [Commodity] {
        let normalizedSearch = normalizedSearch(search)
        guard !normalizedSearch.isEmpty else { return [] }
        let cacheKey = MobileSearchCacheKey(normalizedSearch: normalizedSearch, limit: limit)
        if let cached = commoditySearchResultCache[cacheKey] {
            return cached
        }
        let rows = derivedCache.orderedLedgers
            .flatMap { derivedCache.commoditiesByLedger[$0.id] ?? [] }
            .filter { derivedCache.commoditySearchTextByID[$0.id]?.contains(normalizedSearch) ?? false }
            .prefix(limit)
            .map { $0 }
        commoditySearchResultCache[cacheKey] = rows
        return rows
    }

    func searchTransactionTemplates(_ search: String, limit: Int = 20) -> [TransactionTemplate] {
        let normalizedSearch = normalizedSearch(search)
        guard !normalizedSearch.isEmpty else { return [] }
        let cacheKey = MobileSearchCacheKey(normalizedSearch: normalizedSearch, limit: limit)
        if let cached = templateSearchResultCache[cacheKey] {
            return cached
        }
        let rows = derivedCache.orderedLedgers
            .flatMap { derivedCache.transactionTemplatesByLedger[$0.id] ?? [] }
            .filter { derivedCache.transactionTemplateSearchTextByID[$0.id]?.contains(normalizedSearch) ?? false }
            .prefix(limit)
            .map { $0 }
        templateSearchResultCache[cacheKey] = rows
        return rows
    }

    private func normalizedSearch(_ search: String) -> String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func balanceRows(for accountID: UUID) -> [MobileBalanceRow] {
        refreshBalancesForCurrentDayIfNeeded()
        return derivedCache.balanceRowsByAccount[accountID] ?? []
    }

    func ledgerTotalsByKind(ledgerID: UUID? = nil) -> [AccountKind: [MobileBalanceRow]] {
        refreshBalancesForCurrentDayIfNeeded()
        guard let ledgerID = ledgerID ?? selectedLedgerID else { return [:] }
        return derivedCache.ledgerTotalsByKind[ledgerID] ?? [:]
    }

    private func refreshBalancesForCurrentDayIfNeeded() {
        if derivedCache.balanceDateCutoff != Calendar.current.dateInterval(of: .day, for: Date())?.end {
            refreshDerivedCache()
        }
    }

    func registerAmountInfo(for transaction: LedgerTransaction) -> MobileBalanceRow {
        if let cached = derivedCache.registerAmountInfoByTransactionID[transaction.id] {
            return cached
        }
        let incomeExpense = transaction.postings.filter { posting in
            guard let account = account(posting.accountID) else { return false }
            return account.kind == .income || account.kind == .expense
        }
        let total = incomeExpense.reduce(Decimal.zero) { $0 + $1.amount }
        let commodityID = incomeExpense.first.flatMap { postingCommodityID($0, ledgerID: transaction.ledgerID) }
            ?? transaction.postings.first.flatMap { postingCommodityID($0, ledgerID: transaction.ledgerID) }
        if total != .zero {
            let row = MobileBalanceRow(commodityID: commodityID, symbol: symbol(for: commodityID), amount: -total)
            derivedCache.registerAmountInfoByTransactionID[transaction.id] = row
            return row
        }
        let positive = transaction.postings.first { $0.amount > .zero } ?? transaction.postings.first
        let positiveCommodityID = positive.flatMap { postingCommodityID($0, ledgerID: transaction.ledgerID) } ?? commodityID
        let row = MobileBalanceRow(
            commodityID: positiveCommodityID,
            symbol: symbol(for: positiveCommodityID),
            amount: positive?.amount ?? .zero
        )
        derivedCache.registerAmountInfoByTransactionID[transaction.id] = row
        return row
    }

    func addJournal(name: String, currencyName: String = "US Dollar", template: String = "Personal") {
        guard allowJournalMutation() else { return }
        validationError = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ledger = Ledger(name: trimmed.isEmpty ? "Untitled" : trimmed, listIndex: data.ledgers.count)
        data.ledgers.append(ledger)
        data.selectedLedgerID = ledger.id
        seedBaseAccounts(for: ledger, primaryCurrency: JournalCurrencyCatalog.choice(named: currencyName), template: template)
        refreshDerivedCacheForJournalInsertion(ledgerID: ledger.id)
        save(syncCloud: true, refreshCache: false)
    }

    func moveJournals(from offsets: IndexSet, to destination: Int) {
        guard allowJournalMutation() else { return }
        var ordered = orderedLedgers
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for (index, ledger) in ordered.enumerated() {
            if let stored = data.ledgers.firstIndex(where: { $0.id == ledger.id }) { data.ledgers[stored].listIndex = index }
        }
        save(syncCloud: true)
    }

    func renameJournal(_ ledgerID: UUID, name: String) {
        guard allowJournalMutation() else { return }
        validationError = nil
        guard let index = data.ledgers.firstIndex(where: { $0.id == ledgerID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationError = ValidationError(message: "Journal name is required.")
            return
        }
        data.ledgers[index].name = trimmed
        refreshDerivedCacheForLedgerMetadataChange(data.ledgers[index])
        save(syncCloud: true, refreshCache: false)
    }

    func deleteJournal(_ ledgerID: UUID) {
        guard allowJournalMutation() else { return }
        validationError = nil
        guard data.ledgers.count > 1 else {
            validationError = ValidationError(message: "At least one journal is required.")
            return
        }
        let removedAccountIDs = Set(data.accounts.filter { $0.ledgerID == ledgerID }.map(\.id))
        let removedCommodityIDs = Set(data.commodities.filter { $0.ledgerID == ledgerID }.map(\.id))
        let removedTransactionIDs = Set(data.transactions.filter { $0.ledgerID == ledgerID }.map(\.id))
        let removedTemplateIDs = Set(data.transactionTemplates.filter { $0.ledgerID == ledgerID }.map(\.id))
        data.ledgers.removeAll { $0.id == ledgerID }
        data.commodities.removeAll { $0.ledgerID == ledgerID }
        data.accounts.removeAll { $0.ledgerID == ledgerID }
        data.transactions.removeAll { $0.ledgerID == ledgerID }
        data.sources.removeAll { $0.ledgerID == ledgerID }
        data.transactionTemplates.removeAll { $0.ledgerID == ledgerID }
        if data.selectedLedgerID == ledgerID {
            data.selectedLedgerID = data.ledgers.sorted { $0.listIndex < $1.listIndex }.first?.id
        }
        refreshDerivedCacheForJournalDeletion(
            ledgerID: ledgerID,
            removedAccountIDs: removedAccountIDs,
            removedCommodityIDs: removedCommodityIDs,
            removedTransactionIDs: removedTransactionIDs,
            removedTemplateIDs: removedTemplateIDs
        )
        save(syncCloud: true, refreshCache: false)
    }

    func newAccountDraft(ledgerID: UUID) -> MobileAccountDraft {
        MobileAccountDraft(name: "", ledgerID: ledgerID)
    }

    func newCurrencyDraft(ledgerID: UUID) -> CurrencyDraft {
        var draft: CurrencyDraft = self.draft(for: nil)
        draft.ledgerID = ledgerID
        return draft
    }

    func draft(for account: Account?) -> MobileAccountDraft {
        guard let account else { return MobileAccountDraft(commodityID: selectedLedgerCurrencies.first?.id, ledgerID: selectedLedgerID) }
        return MobileAccountDraft(
            id: account.id,
            name: account.name,
            note: account.note,
            kind: account.kind,
            parentID: account.parentID,
            commodityID: account.commodityID,
            colorName: account.colorName,
            isGroup: account.parentID == nil,
            ledgerID: account.ledgerID
        )
    }

    func saveAccount(_ draft: MobileAccountDraft) {
        guard allowJournalMutation() else { return }
        validationError = nil
        guard let ledgerID = draft.ledgerID ?? selectedLedgerID, ledger(ledgerID) != nil else {
            validationError = ValidationError(message: "This journal no longer exists.")
            return
        }
        if let id = draft.id, !data.accounts.contains(where: { $0.id == id && $0.ledgerID == ledgerID }) {
            validationError = ValidationError(message: "This account no longer exists in this journal. Create a new account instead.")
            return
        }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationError = ValidationError(message: "Account name is required.")
            return
        }

        var parentID = draft.isGroup ? nil : draft.parentID
        if !draft.isGroup, parentID == nil {
            parentID = rootAccountID(for: draft.kind, ledgerID: ledgerID, excluding: draft.id)
        }
        if let parentID, parentID == draft.id {
            validationError = ValidationError(message: "An account cannot be its own group.")
            return
        }
        if let parentID {
            guard let parent = account(parentID), parent.ledgerID == ledgerID, parent.kind == draft.kind else {
                validationError = ValidationError(message: "The group must belong to this journal and match the account type.")
                return
            }
            if let id = draft.id, descendantIDs(of: id).contains(parentID) {
                validationError = ValidationError(message: "That group would create an account cycle.")
                return
            }
        }
        if let commodityID = draft.commodityID,
           !isValidCommodityID(commodityID, forLedger: ledgerID) {
            validationError = ValidationError(message: "The currency must belong to this journal.")
            return
        }

        if let id = draft.id,
           let index = data.accounts.firstIndex(where: { $0.id == id }) {
            guard data.accounts[index].ledgerID == ledgerID else { return }
            let previousAccount = data.accounts[index]
            if data.accounts[index].kind != draft.kind,
               (accountHasTransactions(id) || !descendantIDs(of: id).isEmpty) {
                validationError = ValidationError(message: "Accounts with child accounts or transactions cannot change type.")
                return
            }
            data.accounts[index].name = trimmed
            data.accounts[index].note = draft.note
            data.accounts[index].kind = draft.kind
            data.accounts[index].parentID = parentID
            data.accounts[index].commodityID = draft.commodityID
            data.accounts[index].colorName = draft.colorName
            if previousAccount.kind == draft.kind,
               previousAccount.parentID == parentID,
               previousAccount.commodityID == draft.commodityID {
                refreshDerivedCacheForAccountMetadataChange(data.accounts[index])
                save(syncCloud: true, refreshCache: false)
                return
            }
        } else {
            data.accounts.append(Account(
                ledgerID: ledgerID,
                parentID: parentID,
                commodityID: draft.commodityID,
                name: trimmed,
                note: draft.note,
                kind: draft.kind,
                colorName: draft.colorName,
                listIndex: data.accounts.count
            ))
            refreshDerivedCacheForAccountListChange(ledgerID: ledgerID)
            save(syncCloud: true, refreshCache: false)
            return
        }
        save(syncCloud: true)
    }

    func moveAccount(_ accountID: UUID, relativeTo targetID: UUID, placement: AccountMovePlacement) {
        guard allowJournalMutation() else { return }
        validationError = nil
        guard let plan = AccountMovePlan.make(accountID: accountID, targetID: targetID, placement: placement, accounts: data.accounts),
              let sourceIndex = data.accounts.firstIndex(where: { $0.id == accountID }) else {
            validationError = ValidationError(message: "Move accounts within the same journal and type, outside their own descendants.")
            return
        }
        data.accounts[sourceIndex].parentID = plan.parentID
        for (order, id) in plan.orderedSiblingIDs.enumerated() {
            if let index = data.accounts.firstIndex(where: { $0.id == id }) { data.accounts[index].listIndex = order }
        }
        refreshDerivedCacheForAccountListChange(ledgerID: plan.ledgerID)
        save(syncCloud: true, refreshCache: false)
    }

    func deleteAccount(_ accountID: UUID) {
        guard allowJournalMutation() else { return }
        validationError = nil
        let targets = descendantIDs(of: accountID).union([accountID])
        guard !accountsHaveTransactions(targets) else {
            validationError = ValidationError(message: "Accounts with transactions cannot be deleted.")
            return
        }
        guard !data.transactionTemplates.contains(where: { template in
            template.postings.contains { posting in
                posting.accountID.map { targets.contains($0) } ?? false
            }
        }) else {
            validationError = ValidationError(message: "Accounts used by transaction templates cannot be deleted.")
            return
        }
        let ledgerID = account(accountID)?.ledgerID ?? selectedLedgerID
        data.accounts.removeAll { targets.contains($0.id) }
        if let ledgerID {
            refreshDerivedCacheForAccountListChange(ledgerID: ledgerID)
            save(syncCloud: true, refreshCache: false)
        } else {
            save(syncCloud: true)
        }
    }

    func draft(for commodity: Commodity?) -> CurrencyDraft {
        guard let commodity else {
            var draft = CurrencyDraft()
            draft.applyCatalogOption(JournalCurrencyCatalog.option(matchingSymbol: "USD") ?? JournalCurrencyCatalog.commonFirstOptions[0])
            draft.ledgerID = selectedLedgerID
            return draft
        }
        return CurrencyDraft(id: commodity.id, ledgerID: commodity.ledgerID, symbol: commodity.symbol, name: commodity.name)
    }

    func saveCurrency(_ draft: CurrencyDraft) {
        guard allowJournalMutation() else { return }
        validationError = nil
        guard let ledgerID = draft.ledgerID ?? selectedLedgerID, ledger(ledgerID) != nil else {
            validationError = ValidationError(message: "This journal no longer exists.")
            return
        }
        if let id = draft.id, !data.commodities.contains(where: { $0.id == id && $0.ledgerID == ledgerID }) {
            validationError = ValidationError(message: "This currency no longer exists in this journal. Create a new currency instead.")
            return
        }
        let symbol = draft.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else {
            validationError = ValidationError(message: "Currency symbol is required.")
            return
        }
        guard !name.isEmpty else {
            validationError = ValidationError(message: "Currency name is required.")
            return
        }
        guard !data.commodities.contains(where: { $0.ledgerID == ledgerID && $0.symbol == symbol && $0.id != draft.id }) else {
            validationError = ValidationError(message: "That currency already exists in this journal.")
            return
        }
        if let id = draft.id,
           let index = data.commodities.firstIndex(where: { $0.id == id }) {
            data.commodities[index].symbol = symbol
            data.commodities[index].name = name
        } else {
            data.commodities.append(Commodity(ledgerID: ledgerID, symbol: symbol, name: name))
        }
        refreshDerivedCacheForCommodityListChange(ledgerID: ledgerID)
        save(syncCloud: true, refreshCache: false)
    }

    func deleteCurrency(_ commodityID: UUID) {
        guard allowJournalMutation() else { return }
        validationError = nil
        guard let commodity = derivedCache.commoditiesByID[commodityID] else { return }
        let isUsedByAccount = data.accounts.contains { $0.commodityID == commodityID }
        let isUsedByTransaction = data.transactions.contains { transaction in
            transaction.postings.contains { postingCommodityID($0, ledgerID: transaction.ledgerID) == commodityID }
        }
        guard !isUsedByAccount && !isUsedByTransaction else {
            validationError = ValidationError(message: "Currencies used by accounts or transactions cannot be deleted.")
            return
        }
        data.commodities.removeAll { $0.id == commodityID }
        refreshDerivedCacheForCommodityListChange(ledgerID: commodity.ledgerID)
        save(syncCloud: true, refreshCache: false)
    }

    func makeTransactionDraft(kind: MobileNewTransactionKind = .expense, ledgerID requestedLedgerID: UUID? = nil, accountID: UUID? = nil) -> TransactionDraft {
        guard let ledgerID = requestedLedgerID ?? selectedLedgerID else { return TransactionDraft() }
        let ledgerAccounts = accounts(for: ledgerID)
        let asset = ledgerAccounts.first { $0.kind == .asset && $0.parentID != nil }?.id
        let expense = ledgerAccounts.first { $0.kind == .expense && $0.parentID != nil }?.id
        let income = ledgerAccounts.first { $0.kind == .income && $0.parentID != nil }?.id
        let secondAsset = ledgerAccounts.first { $0.kind == .asset && $0.parentID != nil && $0.id != asset }?.id
        var draft = TransactionDraft(ledgerID: ledgerID)
        switch kind {
        case .expense:
            draft.postings = [
                PostingDraft(accountID: expense, amount: "0.00"),
                PostingDraft(accountID: asset, amount: "0.00")
            ]
        case .income:
            draft.postings = [
                PostingDraft(accountID: asset, amount: "0.00"),
                PostingDraft(accountID: income, amount: "0.00")
            ]
        case .transfer:
            draft.postings = [
                PostingDraft(accountID: asset, amount: "0.00"),
                PostingDraft(accountID: secondAsset ?? asset, amount: "0.00")
            ]
        }
        if let accountID, let context = account(accountID), context.ledgerID == ledgerID {
            let index = draft.postings.firstIndex { posting in
                guard let candidate = account(posting.accountID) else { return false }
                return candidate.kind == context.kind || ([AccountKind.asset, .liability].contains(candidate.kind) && [AccountKind.asset, .liability].contains(context.kind))
            } ?? 0
            draft.postings[index].accountID = accountID
            draft.postings[index].commodityID = context.commodityID
        }
        return draft
    }

    func draft(for transaction: LedgerTransaction?) -> TransactionDraft {
        guard let transaction else { return makeTransactionDraft() }
        var draft = TransactionDraft(ledgerID: transaction.ledgerID)
        draft.id = transaction.id
        draft.date = transaction.date
        draft.payee = transaction.payee
        draft.note = transaction.note
        draft.number = transaction.number
        draft.cleared = transaction.cleared
        draft.recurrenceRuleID = transaction.recurrenceRule?.id
        draft.repeatFrequency = transaction.recurrenceRule?.frequency ?? .never
        draft.repeatIntervalValue = max(transaction.recurrenceRule?.intervalValue ?? 1, 1)
        draft.repeatOnWorkdays = transaction.recurrenceRule?.onWorkdays ?? false
        draft.repeatOccurrenceCount = transaction.recurrenceRule?.occurrenceCount
        draft.repeatEndDate = transaction.recurrenceRule?.endDate
        draft.postings = transaction.postings.sortedForDisplay().map { posting in
            PostingDraft(
                id: posting.id,
                accountID: posting.accountID,
                amount: decimalInputString(posting.amount),
                commodityID: posting.commodityID,
                preservesNilCommodityID: posting.commodityID == nil
            )
        }
        draft.attachmentContainer = transaction.attachment
        draft.attachments = transaction.attachment?.assets ?? []
        return draft
    }

    func draft(for template: TransactionTemplate) -> TransactionDraft {
        var draft = makeTransactionDraft(ledgerID: template.ledgerID)
        draft.payee = template.payee
        draft.note = template.note
        draft.cleared = template.cleared
        let templatePostings = template.postings
            .sorted { $0.listIndex < $1.listIndex }
            .map { PostingDraft(accountID: $0.accountID, amount: "0.00") }
        if templatePostings.count >= 2 {
            draft.postings = templatePostings
        }
        return draft
    }

    private func refreshRecurringProjections(referenceDate: Date = Date(), syncCloud: Bool) {
        guard !backupFileOperationInProgress, !requiresJournalRecovery else { return }
        let day = Calendar.current.startOfDay(for: referenceDate)
        guard lastRecurrenceProjectionDay != day else { return }
        lastRecurrenceProjectionDay = day
        let candidate = RecurringJournalEditor.materialized(data, referenceDate: referenceDate, deletedIDs: deletedTransactionTombstoneIDs)
        guard candidate.transactions != data.transactions else { return }
        do {
            try Self.validateCandidateData(candidate, operation: "Recurring projection")
            data = candidate
            refreshDerivedCache()
            save(syncCloud: syncCloud, refreshCache: false)
        } catch { validationError = ValidationError(message: error.localizedDescription) }
    }

    func recurrenceAnchorID(ruleID: UUID) -> UUID? {
        RecurringJournalEditor.anchor(ruleID: ruleID, in: data.transactions)?.id
    }

    /// The editor confirms Save only after the journal and offline outbox are durable.
    func saveTransactionAndFlush(_ draft: TransactionDraft, scope: RecurringJournalEditor.Scope = .occurrence) {
        saveTransaction(draft, scope: scope)
        guard validationError == nil else { return }
        do { try flushLocalChanges() }
        catch { validationError = ValidationError(message: "Save failed: \(error.localizedDescription)") }
    }

    func saveTransaction(_ draft: TransactionDraft, scope: RecurringJournalEditor.Scope = .occurrence) {
        guard allowJournalMutation() else { return }
        validationError = nil
        let previousIndex = draft.id.flatMap { id in data.transactions.firstIndex { $0.id == id } }
        let previous = previousIndex.map { data.transactions[$0] }
        let draftLedgerIDs = Set(draft.postings.compactMap { posting in
            posting.accountID.flatMap { account($0)?.ledgerID }
        })
        let ledgerID = draft.ledgerID ?? previous?.ledgerID ?? (draftLedgerIDs.count == 1 ? draftLedgerIDs.first : selectedLedgerID)
        guard let ledgerID, data.ledgers.contains(where: { $0.id == ledgerID }) else {
            validationError = ValidationError(message: "Choose an existing journal for this transaction.")
            return
        }
        if draft.id != nil && previous == nil {
            validationError = ValidationError(message: "This transaction no longer exists. Create a new transaction instead.")
            return
        }
        if let previous, previous.ledgerID != ledgerID {
            validationError = ValidationError(message: "An existing transaction must stay in its journal.")
            return
        }
        guard draft.postings.count >= 2 else {
            validationError = ValidationError(message: "A transaction needs at least two postings.")
            return
        }

        var postings: [Posting] = []
        for (index, row) in draft.postings.enumerated() {
            guard let accountID = row.accountID else {
                validationError = ValidationError(message: "Choose an account for every posting.")
                return
            }
            guard let amount = decimalFromInput(row.amount) else {
                validationError = ValidationError(message: "Enter valid posting amounts.")
                return
            }
            let commodityID = row.preservesNilCommodityID
                ? row.commodityID
                : row.commodityID ?? account(accountID)?.commodityID ?? defaultCommodityID(forLedger: ledgerID)
            postings.append(Posting(id: row.id, accountID: accountID, commodityID: commodityID, amount: amount, listIndex: index))
        }

        do {
            try validate(postings: postings, ledgerID: ledgerID)
        } catch let error as ValidationError {
            validationError = error
            return
        } catch {
            validationError = ValidationError(message: error.localizedDescription)
            return
        }

        let transaction = LedgerTransaction(
            id: draft.id ?? UUID(),
            ledgerID: ledgerID,
            sourceID: previous?.sourceID,
            date: draft.date,
            payee: draft.payee,
            note: draft.note,
            number: draft.number,
            cleared: draft.cleared,
            postings: postings,
            recurrenceRule: recurrenceRule(from: draft),
            attachment: attachmentContainer(from: draft),
            externalTransactionID: previous?.externalTransactionID
        )
        do {
            let expectedSingleRowCount = data.transactions.count + (previous == nil ? 1 : 0)
            let candidate = try RecurringJournalEditor.apply(
                transaction, replacing: draft.id, in: data, scope: scope,
                deletedIDs: deletedTransactionTombstoneIDs
            )
            try Self.validateCandidateData(candidate, operation: "Transaction")
            data = candidate
            if previous?.recurrenceRule == nil && transaction.recurrenceRule == nil,
               candidate.transactions.count == expectedSingleRowCount {
                refreshDerivedCacheForTransactionReplacement(previous: previous, updated: transaction)
            } else {
                // A scope edit can affect several accounts, dates and summaries.
                refreshDerivedCache()
            }
            save(syncCloud: true, refreshCache: false)
        } catch {
            validationError = ValidationError(message: error.localizedDescription)
        }
    }

    func setTransactionCleared(_ transactionID: UUID, cleared: Bool) {
        guard allowJournalMutation() else { return }
        guard let index = data.transactions.firstIndex(where: { $0.id == transactionID }),
              data.transactions[index].cleared != cleared else {
            return
        }
        data.transactions[index].cleared = cleared
        refreshDerivedCacheForTransactionStatusChange(data.transactions[index])
        save(syncCloud: true, refreshCache: false)
    }

    func deleteTransaction(_ transactionID: UUID, scope: RecurringJournalEditor.Scope = .occurrence, expected: LedgerTransaction? = nil) {
        guard allowJournalMutation() else { return }
        validationError = nil
        if let expected, let current = transaction(transactionID), current.date != expected.date || current.recurrenceRule != expected.recurrenceRule {
            validationError = ValidationError(message: "The repeating schedule changed. Review the deletion again.")
            return
        }
        let deletion: RecurringJournalEditor.DeletionResult
        do { deletion = try RecurringJournalEditor.deleting(transactionID, scope: scope, in: data) }
        catch { validationError = ValidationError(message: error.localizedDescription); return }
        let ids = deletion.deletedIDs
        let removed = data.transactions.filter { ids.contains($0.id) }
        deletedTransactionTombstoneIDs.formUnion(ids)
        data = deletion.journal
        if removed.count == 1, !deletion.scheduleChanged, let row = removed.first {
            refreshDerivedCacheForTransactionDeletion(row)
        } else { refreshDerivedCache() }
        save(syncCloud: true, refreshCache: false)
        do { try flushLocalChanges() }
        catch { validationError = ValidationError(message: "Delete failed: \(error.localizedDescription)") }
    }

    func duplicateTransaction(_ transactionID: UUID, useToday: Bool = true) {
        guard allowJournalMutation() else { return }
        validationError = nil
        guard let transaction = data.transactions.first(where: { $0.id == transactionID }) else { return }
        var copy = transaction
        copy.id = UUID()
        copy.sourceID = nil
        copy.externalTransactionID = nil
        if useToday {
            copy.date = Date()
        }
        copy.postings = copy.postings.enumerated().map { index, posting in
            var posting = posting
            posting.id = UUID()
            posting.listIndex = index
            return posting
        }
        if var rule = copy.recurrenceRule {
            rule.id = UUID()
            rule.templateHistory = RecurrenceTemplateHistory(baseTemplate: RecurrenceTransactionTemplate(transaction: copy))
            copy.recurrenceRule = rule
        }
        if let attachment = copy.attachment {
            do {
                copy.attachment = try AttachmentDuplicator.duplicate(attachment, into: attachmentsDirectory) {
                    attachmentURL(for: $0)
                }
            } catch {
                validationError = ValidationError(message: "Transaction could not be duplicated: \(error.localizedDescription)")
                return
            }
        }
        do {
            data = try RecurringJournalEditor.apply(copy, replacing: nil, in: data, deletedIDs: deletedTransactionTombstoneIDs)
            if copy.recurrenceRule == nil { refreshDerivedCacheForTransactionInsertion(copy) }
            else { refreshDerivedCache() }
            save(syncCloud: true, refreshCache: false)
        } catch { validationError = ValidationError(message: error.localizedDescription) }
    }

    func templateDraft(for template: TransactionTemplate?) -> TransactionTemplateDraft {
        guard let template else {
            let ledgerID = selectedLedgerID
            let ledgerAccounts = ledgerID.map { accounts(for: $0) } ?? []
            return TransactionTemplateDraft(ledgerID: ledgerID, postings: [
                PostingTemplateDraft(accountID: ledgerAccounts.first { $0.kind == .asset && $0.parentID != nil }?.id),
                PostingTemplateDraft(accountID: ledgerAccounts.first { $0.kind == .expense && $0.parentID != nil }?.id)
            ])
        }
        return TransactionTemplateDraft(
            id: template.id,
            ledgerID: template.ledgerID,
            name: template.name,
            note: template.note,
            payee: template.payee,
            cleared: template.cleared,
            enabled: template.enabled,
            scanInvoice: template.scanInvoice,
            postings: template.postings.sorted { $0.listIndex < $1.listIndex }.map {
                PostingTemplateDraft(id: $0.id, accountID: $0.accountID)
            }
        )
    }

    func templateDraft(from transaction: LedgerTransaction) -> TransactionTemplateDraft {
        TransactionTemplateDraft(
            ledgerID: transaction.ledgerID,
            name: transaction.payee.isEmpty ? "Untitled" : transaction.payee,
            note: transaction.note,
            payee: transaction.payee,
            cleared: transaction.cleared,
            postings: transaction.postings.sortedForDisplay().map { PostingTemplateDraft(accountID: $0.accountID) }
        )
    }

    func moveTransactionTemplates(ledgerID: UUID, from offsets: IndexSet, to destination: Int) {
        guard allowJournalMutation() else { return }
        var templates = transactionTemplates(for: ledgerID)
        templates.move(fromOffsets: offsets, toOffset: destination)
        for (index, template) in templates.enumerated() {
            if let stored = data.transactionTemplates.firstIndex(where: { $0.id == template.id }) { data.transactionTemplates[stored].listIndex = index }
        }
        refreshDerivedCacheForTransactionTemplateListChange(ledgerID: ledgerID)
        save(syncCloud: true, refreshCache: false)
    }

    func saveTransactionTemplate(_ draft: TransactionTemplateDraft) {
        guard allowJournalMutation() else { return }
        validationError = nil
        guard let ledgerID = draft.ledgerID ?? selectedLedgerID, ledger(ledgerID) != nil else {
            validationError = ValidationError(message: "This journal no longer exists.")
            return
        }
        if let id = draft.id, !data.transactionTemplates.contains(where: { $0.id == id && $0.ledgerID == ledgerID }) {
            validationError = ValidationError(message: "This template no longer exists in this journal. Create a new template instead.")
            return
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            validationError = ValidationError(message: "Template name cannot be blank.")
            return
        }
        let postings = draft.postings.enumerated().map { index, posting in
            PostingTemplate(id: posting.id, accountID: posting.accountID, listIndex: index)
        }
        for posting in postings {
            guard let accountID = posting.accountID else { continue }
            guard let account = account(accountID), account.ledgerID == ledgerID else {
                validationError = ValidationError(message: "Template accounts must belong to this journal.")
                return
            }
        }
        if let id = draft.id,
           let index = data.transactionTemplates.firstIndex(where: { $0.id == id && $0.ledgerID == ledgerID }) {
            data.transactionTemplates[index].name = name
            data.transactionTemplates[index].note = draft.note
            data.transactionTemplates[index].payee = draft.payee
            data.transactionTemplates[index].cleared = draft.cleared
            data.transactionTemplates[index].enabled = draft.enabled
            data.transactionTemplates[index].scanInvoice = draft.scanInvoice
            data.transactionTemplates[index].postings = postings
        } else {
            let nextIndex = (data.transactionTemplates.filter { $0.ledgerID == ledgerID }.map(\.listIndex).max() ?? -1) + 1
            data.transactionTemplates.append(TransactionTemplate(
                ledgerID: ledgerID,
                name: name,
                note: draft.note,
                payee: draft.payee,
                cleared: draft.cleared,
                enabled: draft.enabled,
                scanInvoice: draft.scanInvoice,
                listIndex: nextIndex,
                postings: postings
            ))
        }
        refreshDerivedCacheForTransactionTemplateListChange(ledgerID: ledgerID)
        save(syncCloud: true, refreshCache: false)
    }

    func deleteTransactionTemplate(_ templateID: UUID) {
        guard allowJournalMutation() else { return }
        guard let template = data.transactionTemplates.first(where: { $0.id == templateID }) else { return }
        data.transactionTemplates.removeAll { $0.id == templateID }
        refreshDerivedCacheForTransactionTemplateListChange(ledgerID: template.ledgerID)
        save(syncCloud: true, refreshCache: false)
    }

    func importAttachment(from sourceURL: URL) throws -> AttachmentAsset {
        try requireWritableJournal()
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        return try Self.importAttachment(from: sourceURL, supportDirectory: supportDirectory)
    }

    func importAttachmentAsync(from sourceURL: URL) async throws -> AttachmentAsset {
        try requireWritableJournal()
        let supportDirectory = supportDirectory
        return try await Task.detached(priority: .userInitiated) {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            return try Self.importAttachment(from: sourceURL, supportDirectory: supportDirectory)
        }.value
    }

    private nonisolated static func importAttachment(from sourceURL: URL, supportDirectory: URL) throws -> AttachmentAsset {
        let attachmentsDirectory = supportDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let originalFilename = sourceURL.lastPathComponent.isEmpty ? "Attachment" : sourceURL.lastPathComponent
        let storedFilename = "\(UUID().uuidString)-\(sanitizedAttachmentFilenameValue(originalFilename))"
        let relativePath = "Attachments/\(storedFilename)"
        let destination = attachmentFileURL(forRelativePath: relativePath, supportDirectory: supportDirectory)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        return AttachmentAsset(
            originalFilename: originalFilename,
            storedPath: relativePath,
            mimeType: values?.contentType?.preferredMIMEType,
            sizeBytes: Int64(values?.fileSize ?? 0)
        )
    }

    func attachmentURL(for asset: AttachmentAsset) -> URL {
        if let relativePath = validatedAttachmentRelativePathIfPresent(asset.storedPath) {
            return attachmentFileURL(forRelativePath: relativePath)
        }
        if (asset.storedPath as NSString).isAbsolutePath {
            return URL(fileURLWithPath: asset.storedPath)
        }
        return supportDirectory.appending(path: asset.storedPath)
    }

    private nonisolated static func attachmentURL(for asset: AttachmentAsset, supportDirectory: URL) -> URL {
        if let relativePath = validatedAttachmentRelativePathIfPresent(asset.storedPath, supportDirectory: supportDirectory) {
            return attachmentFileURL(forRelativePath: relativePath, supportDirectory: supportDirectory)
        }
        if (asset.storedPath as NSString).isAbsolutePath {
            return URL(fileURLWithPath: asset.storedPath)
        }
        return supportDirectory.appending(path: asset.storedPath)
    }

    var backupAttachmentCount: Int {
        data.transactions.reduce(0) { $0 + ($1.attachment?.assets.count ?? 0) }
    }

    private func beginBackupFileOperation() throws {
        try requireWritableJournal()
        try flushLocalChanges()
        cancelCloudSync()
        backupFileOperationInProgress = true
    }

    private func endBackupFileOperation() {
        backupFileOperationInProgress = false
        if backupSelectionChanged {
            backupSelectionChanged = false
            save(syncCloud: true, refreshCache: false)
        }
        synchronizeIfEnabled()
    }

    private func newBackupURL() throws -> URL {
        let directory = supportDirectory.appendingPathComponent("BackupExports", isDirectory: true)
        try BackupArchive.createDirectory(directory)
        // Keep completed files available to share extensions after dismissal.
        // Only obsolete exports owned by this app are removed on a later export.
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) {
            if let date = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate,
               date < Date().addingTimeInterval(-7 * 24 * 60 * 60) { try? FileManager.default.removeItem(at: item) }
        }
        let job = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try BackupArchive.createDirectory(job)
        let day = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return job.appendingPathComponent("\(day) - Finances Backup.zip")
    }

    func latestExportedBackup() -> URL? {
        let directory = supportDirectory.appendingPathComponent("BackupExports", isDirectory: true)
        let jobs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var files: [(url: URL, date: Date)] = []
        for job in jobs {
            let contents = (try? FileManager.default.contentsOfDirectory(at: job, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for file in contents where file.pathExtension.lowercased() == "zip" {
                let values = try? file.resourceValues(forKeys: [.creationDateKey])
                files.append((file, values?.creationDate ?? .distantPast))
            }
        }
        return files.max { $0.date < $1.date }?.url
    }

    func exportBackupFile(progress: Progress = Progress(totalUnitCount: 1)) throws -> URL {
        try beginBackupFileOperation()
        defer { endBackupFileOperation() }
        let snapshot = data, directory = supportDirectory
        let destination = try newBackupURL()
        do {
            try Self.deferredPersistenceQueue.sync {
                try Self.validateCandidateData(snapshot, operation: "Backup")
                try BackupArchive.export(snapshot, to: destination, progress: progress) {
                    Self.attachmentURL(for: $0, supportDirectory: directory)
                }
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }

    func exportBackupFileAsync(progress: Progress) async throws -> URL {
        try beginBackupFileOperation()
        defer { endBackupFileOperation() }
        let snapshot = data, directory = supportDirectory
        let destination = try newBackupURL()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Self.deferredPersistenceQueue.async {
                    do {
                        try Self.validateCandidateData(snapshot, operation: "Backup")
                        try BackupArchive.export(snapshot, to: destination, progress: progress) {
                            Self.attachmentURL(for: $0, supportDirectory: directory)
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }

    func importBackup(from backupURL: URL) {
        validationError = nil
        let accessed = backupURL.startAccessingSecurityScopedResource()
        defer { if accessed { backupURL.stopAccessingSecurityScopedResource() } }
        do {
            try beginBackupFileOperation()
            defer { endBackupFileOperation() }
            let progress = Progress(totalUnitCount: 100)
            let prepared = try Self.prepareBackupRestore(from: backupURL, supportDirectory: supportDirectory, progress: progress)
            defer { try? FileManager.default.removeItem(at: prepared.workspace) }
            try commitBackupRestore(prepared)
        } catch { validationError = ValidationError(message: "Backup restore failed: \(error.localizedDescription)") }
    }

    func importBackupAsync(from backupURL: URL, progress: Progress) async throws {
        validationError = nil
        let accessed = backupURL.startAccessingSecurityScopedResource()
        defer { if accessed { backupURL.stopAccessingSecurityScopedResource() } }
        try beginBackupFileOperation()
        defer { endBackupFileOperation() }
        let directory = supportDirectory
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepareBackupRestore(from: backupURL, supportDirectory: directory, progress: progress)
        }.value
        defer { try? FileManager.default.removeItem(at: prepared.workspace) }
        try BackupArchive.checkCancellation(progress)
        try commitBackupRestore(prepared)
    }

    private nonisolated static func prepareBackupRestore(from url: URL, supportDirectory: URL, progress: Progress) throws -> PreparedBackupRestore {
        let workspace = supportDirectory.appendingPathComponent(".backup-import-" + UUID().uuidString, isDirectory: true)
        var error: NSError?
        var result: Result<PreparedBackupRestore, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { readableURL in
            result = Result {
                try BackupArchive.prepareRestore(from: readableURL, workspace: workspace, progress: progress,
                    localAttachmentURL: { attachmentURL(for: $0, supportDirectory: supportDirectory) },
                    validate: { try validateCandidateData($0, operation: "Imported backup") })
            }
        }
        if let error { throw error }
        guard let result else { throw ValidationError(message: "The selected backup could not be opened.") }
        return try result.get()
    }

    private func commitBackupRestore(_ prepared: PreparedBackupRestore) throws {
        let destination = attachmentFileURL(forRelativePath: prepared.relativeReceiptsPath)
        var moved = false, committed = false
        defer { if moved && !committed { try? FileManager.default.removeItem(at: destination) } }
        if FileManager.default.fileExists(atPath: prepared.receipts.path) {
            let attachmentsDirectory = attachmentsDirectory
            try Self.deferredPersistenceQueue.sync {
                try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: prepared.receipts, to: destination)
            }
            moved = true
        }
        // No suspension between releasing the edit guard and the atomic commit.
        backupFileOperationInProgress = false
        var imported = prepared.data
        try replaceDataFromImport(&imported)
        committed = true
    }

    func setSyncEnabled(_ enabled: Bool) {
        #if DEBUG
        if CommandLine.arguments.contains("--demo") {
            validationError = ValidationError(message: "The demo uses local sample data. Relaunch without demo mode to sync your journals.")
            return
        }
        #endif

        guard allowJournalMutation() else { return }
        validationError = nil
        let beforePreference = data
        if !enabled { cancelCloudSync() }
        data.syncEnabled = enabled
        do {
            // Track any preceding user edit, then save only this device's sync
            // preference without manufacturing a first-join metadata change.
            try Self.validateCandidateData(beforePreference, operation: "Journal")
            try persistSnapshot(beforePreference, trackSyncChanges: true)
            try persistSnapshot(data, trackSyncChanges: false)
            refreshCloudKitForegroundTriggers()
            if enabled {
                registerForCloudNotificationsIfAvailable()
                requestCloudSync(reportProgress: true)
            } else {
                cloudSyncProgress = .idle
            }
        } catch {
            cloudKitSyncDidFail("Could not save the sync preference: \(error.localizedDescription)")
        }
    }

    func synchronizeNow() {
        guard data.syncEnabled else { return }
        requestCloudSync(reportProgress: true)
    }

    func setSceneActive(_ active: Bool, sceneID: UUID) {
        let wasActive = isForegroundActive
        if active { activeSceneIDs.insert(sceneID) } else { activeSceneIDs.remove(sceneID) }
        guard wasActive != isForegroundActive else {
            if !isForegroundActive { cloudSyncCoordinator.suspendForegroundWork() }
            return
        }
        if !active && !backupFileOperationInProgress {
            do { try flushLocalChanges() }
            catch { validationError = ValidationError(message: "Save failed: \(error.localizedDescription)") }
        }
        refreshCloudKitForegroundTriggers()
        if isForegroundActive {
            synchronizeIfEnabled()
        } else {
            deferredCloudSaveToken = nil
            cloudSyncCoordinator.suspendForegroundWork()
        }
    }

    func synchronizeIfEnabled(requireFollowUpIfBusy: Bool = false) {
        guard cloudKitSyncDependencies.automaticTriggersEnabled, isForegroundActive, !requiresJournalRecovery else { return }
        refreshRecurringProjections(syncCloud: false)
        guard data.syncEnabled else { return }
        refreshCloudKitForegroundTriggers()
        registerForCloudNotificationsIfAvailable()
        requestCloudSync(reportProgress: false, requireFollowUpIfBusy: requireFollowUpIfBusy)
    }

    func prepareAfterInitialRender() async {
        warmTransactionSearchCacheInBackground()
        // The initial and subsequent scene-phase callbacks own sync activation.
    }

    func cloudKitAccountDidChange() {
        cancelCloudSync()
        cloudSyncProgress = .idle
        synchronizeIfEnabled()
    }

    func synchronizeFromNotification(isForeground: Bool) async -> CloudKitBackgroundRefreshOutcome {
        guard !backupFileOperationInProgress, data.syncEnabled, cloudKitSyncDependencies.automaticTriggersEnabled, !requiresJournalRecovery else { return .noData }
        // An active app keeps foreground ownership; the callback still has its own deadline.
        return await cloudSyncCoordinator.backgroundRefresh(isForeground: isForeground)
    }

    func requestCloudKitSync(reportProgress: Bool = true, requireFollowUpIfBusy: Bool = true) {
        requestCloudSync(reportProgress: reportProgress, requireFollowUpIfBusy: requireFollowUpIfBusy)
    }

    func waitForCloudKitSyncIdle() async {
        await cloudSyncCoordinator.waitUntilIdle()
        await withCheckedContinuation { continuation in
            Self.deferredPersistenceQueue.async { continuation.resume() }
        }
    }

    func cloudKitSyncConflicts() -> [CloudKitSyncConflict] {
        guard !requiresJournalRecovery else { return [] }
        return (try? cloudSyncCoordinator.conflicts()) ?? []
    }

    private func requestCloudSync(reportProgress: Bool, requireFollowUpIfBusy: Bool = true) {
        guard !backupFileOperationInProgress else { return }
        guard allowJournalMutation() else { return }
        guard data.syncEnabled else { return }
        cloudSyncCoordinator.synchronize(
            reportProgress: reportProgress,
            requireFollowUpIfBusy: requireFollowUpIfBusy
        )
    }

    private func cancelCloudSync() {
        stopCloudKitForegroundTriggers()
        deferredCloudSaveToken = nil
        cloudSyncCoordinator.cancel()
    }

    private func refreshCloudKitForegroundTriggers() {
        guard isForegroundActive, data.syncEnabled, !requiresJournalRecovery,
              cloudKitSyncDependencies.automaticTriggersEnabled else {
            stopCloudKitForegroundTriggers()
            return
        }
        if foregroundSyncTriggers == nil {
            foregroundSyncTriggers = CloudKitForegroundSyncTriggers(dependencies: foregroundTriggerDependencies) { [weak self] in
                self?.synchronizeIfEnabled(requireFollowUpIfBusy: true)
            }
        }
        if cloudKitAccountObservation == nil {
            let generation = foregroundTriggerGeneration
            cloudKitAccountObservation = MobileCloudKitAccountObservation { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.foregroundTriggerGeneration == generation,
                          self.isForegroundActive, self.data.syncEnabled, !self.requiresJournalRecovery else { return }
                    self.cloudKitAccountDidChange()
                }
            }
        }
        foregroundSyncTriggers?.update(isActive: true, isEnabled: true, isRecovering: false, automaticTriggersEnabled: true)
    }

    private func stopCloudKitForegroundTriggers() {
        foregroundTriggerGeneration = UUID()
        cloudKitAccountObservation = nil
        foregroundSyncTriggers?.stop()
    }

    private func registerForCloudNotificationsIfAvailable() {
        guard cloudKitSyncDependencies.automaticTriggersEnabled,
              CloudKitSyncConfiguration.availableConfiguration() != nil else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func refreshCloudSyncConflicts() {
        guard !requiresJournalRecovery else {
            cloudSyncConflicts = []
            return
        }
        if let conflicts = try? cloudSyncCoordinator.conflicts() {
            cloudSyncConflicts = conflicts
        }
    }

    func resolveCloudKitSyncConflict(id: String, keepLocal: Bool) {
        do {
            // The shared resolver cancels the active pass before inspecting and
            // atomically resolving the frozen local intent.
            try cloudSyncCoordinator.resolveConflict(id: id, keepLocal: keepLocal)
            validationError = nil
            refreshCloudSyncConflicts()
        } catch {
            cloudKitSyncDidFail(error.localizedDescription)
        }
    }

    private func refreshCloudSyncDataAvailability() {
        guard !requiresJournalRecovery else {
            cloudSyncDataAvailable = false
            cloudSyncConflicts = []
            return
        }
        let databaseURL = sqliteStore.databaseURL
        let hasMetadata = (try? Self.deferredPersistenceQueue.sync {
            let store = SQLiteJournalStore(databaseURL: databaseURL)
            guard let key = try store.cloudKitBoundContextKey() else { return false }
            return try store.hasCloudKitSyncState(contextKey: key)
        }) ?? false
        cloudSyncDataAvailable = data.lastSyncedAt != nil || hasMetadata
        refreshCloudSyncConflicts()
    }

    func resetCloudSync() {
        guard allowJournalMutation() else { return }
        guard !data.syncEnabled else {
            validationError = ValidationError(message: "Turn off iCloud Sync before resetting local sync state.")
            return
        }
        cancelCloudSync()
        do {
            try cloudKitFlushLocalChanges()
            var updated = data
            updated.lastSyncedAt = nil
            let snapshot = updated
            let databaseURL = sqliteStore.databaseURL
            let baseline = persistenceBaseline
            try Self.deferredPersistenceQueue.sync {
                do {
                    let store = SQLiteJournalStore(databaseURL: databaseURL)
                    if let key = try store.cloudKitBoundContextKey() {
                        try store.resetCloudKitSyncState(contextKey: key)
                    }
                    try store.persist(snapshot, previous: baseline.snapshot, trackSyncChanges: true)
                    baseline.snapshot = snapshot
                } catch {
                    baseline.snapshot = nil
                    throw error
                }
            }
            data = snapshot
            validationError = nil
            cloudSyncProgress = .idle
            refreshCloudSyncDataAvailability()
        } catch {
            cloudKitSyncDidFail("Local iCloud reset failed: \(error.localizedDescription)")
        }
    }

    func resetCloudSyncAsync() async {
        guard allowJournalMutation() else { return }
        guard !data.syncEnabled else {
            validationError = ValidationError(message: "Turn off iCloud Sync before resetting local sync state.")
            return
        }
        cancelCloudSync()
        await cloudSyncCoordinator.waitUntilIdle()
        resetCloudSync()
    }


    func setDateFormat(_ format: AppDateFormat) {
        guard allowJournalMutation() else { return }
        data.dateFormat = format
        save(syncCloud: true, refreshCache: false)
    }

    func setAppearance(_ appearance: AppAppearance) {
        guard allowJournalMutation() else { return }
        data.appearance = appearance
        save(syncCloud: true, refreshCache: false)
    }

    var isPasswordLockEnabled: Bool {
        data.security.passwordLockEnabled
    }

    var requiresUnlock: Bool {
        isPasswordLockEnabled && !isUnlocked
    }

    func setPasswordLock(password: String, confirmation: String) {
        guard allowJournalMutation() else { return }
        validationError = nil
        guard password.count >= 4 else {
            validationError = ValidationError(message: "Password must be at least 4 characters.")
            return
        }
        guard password == confirmation else {
            validationError = ValidationError(message: "Passwords do not match.")
            return
        }
        let salt = UUID().uuidString
        data.security = SecuritySettings(passwordHash: Self.passwordHash(password: password, salt: salt), passwordSalt: salt)
        isUnlocked = true
        save(syncCloud: true, refreshCache: false)
    }

    func disablePasswordLock(password: String) {
        guard allowJournalMutation() else { return }
        validationError = nil
        guard verifyPassword(password) else {
            validationError = ValidationError(message: "Password is incorrect.")
            return
        }
        data.security = SecuritySettings()
        isUnlocked = true
        save(syncCloud: true, refreshCache: false)
    }

    func unlock(password: String) {
        validationError = nil
        guard verifyPassword(password) else {
            validationError = ValidationError(message: "Password is incorrect.")
            return
        }
        isUnlocked = true
    }

    func lockApp() {
        guard isPasswordLockEnabled else { return }
        isUnlocked = false
    }

    func verifyPassword(_ password: String) -> Bool {
        guard let salt = data.security.passwordSalt,
              let expectedHash = data.security.passwordHash else {
            return false
        }
        return Self.passwordHash(password: password, salt: salt) == expectedHash
    }

    func flushLocalChanges() throws {
        try requireWritableJournal()
        try Self.validateCandidateData(data, operation: "Journal")
        try persistSnapshot(data, trackSyncChanges: true)
    }

    private func save(
        syncCloud: Bool,
        persistenceTiming: MobilePersistenceTiming = .deferredLocal,
        refreshCache: Bool = true,
        trackSyncChanges: Bool = true
    ) {
        guard allowJournalMutation() else { return }
        do {
            if refreshCache {
                refreshDerivedCache()
            }
            let shouldSyncCloud = data.syncEnabled && syncCloud
            if persistenceTiming == .deferredLocal {
                validationError = nil
                scheduleDeferredLocalSave(
                    trackSyncChanges: trackSyncChanges,
                    validateSnapshot: true,
                    scheduleCloudAfterSuccess: shouldSyncCloud
                )
                return
            }
            try Self.validateCandidateData(data, operation: "Journal")
            validationError = nil
            deferredCloudSaveToken = nil
            try persistSnapshot(data, trackSyncChanges: trackSyncChanges)
            refreshCloudSyncDataAvailability()
            if shouldSyncCloud {
                scheduleDeferredCloudSave()
            }
        } catch {
            validationError = ValidationError(message: "Save failed: \(error.localizedDescription)")
        }
    }

    /// All normal writes, including a sync flush, share one committed baseline.
    /// Waiting on this queue drains earlier edits before computing the next diff.
    private func persistSnapshot(_ snapshot: JournalData, trackSyncChanges: Bool, collectCompletedReceipts: Bool = false) throws {
        try requireWritableJournal()
        let databaseURL = sqliteStore.databaseURL
        let baseline = persistenceBaseline
        let supportDirectory = supportDirectory
        try Self.deferredPersistenceQueue.sync {
            do {
                let previous = baseline.snapshot
                try SQLiteJournalStore(databaseURL: databaseURL).persist(
                    snapshot, previous: previous, trackSyncChanges: trackSyncChanges
                )
                baseline.snapshot = snapshot
                Self.removeObsoleteAttachmentFiles(supportDirectory: supportDirectory, previous: previous, data: snapshot, collectCompletedClaims: collectCompletedReceipts)
            } catch {
                baseline.snapshot = nil
                throw error
            }
        }
    }

    private func scheduleDeferredLocalSave(
        trackSyncChanges: Bool = true,
        validateSnapshot: Bool = true,
        scheduleCloudAfterSuccess: Bool = false
    ) {
        guard allowJournalMutation() else { return }
        let snapshot = data
        let databaseURL = sqliteStore.databaseURL
        let baseline = persistenceBaseline
        let supportDirectory = supportDirectory
        Self.deferredPersistenceQueue.async { [weak self, snapshot, databaseURL, baseline, trackSyncChanges, validateSnapshot] in
            do {
                if validateSnapshot {
                    try Self.validateCandidateData(snapshot, operation: "Journal")
                }
                let store = SQLiteJournalStore(databaseURL: databaseURL)
                let previous = baseline.snapshot
                try store.persist(snapshot, previous: previous, trackSyncChanges: trackSyncChanges)
                baseline.snapshot = snapshot
                Self.removeObsoleteAttachmentFiles(supportDirectory: supportDirectory, previous: previous, data: snapshot)
                Task { @MainActor [weak self] in
                    self?.refreshCloudSyncDataAvailability()
                }
                if scheduleCloudAfterSuccess {
                    Task { @MainActor [weak self] in
                        self?.scheduleDeferredCloudSave()
                    }
                }
            } catch {
                baseline.snapshot = nil
                Task { @MainActor [weak self] in
                    self?.validationError = ValidationError(message: "Save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func scheduleDeferredCloudSave() {
        guard cloudKitSyncDependencies.automaticTriggersEnabled, isForegroundActive,
              data.syncEnabled, !requiresJournalRecovery else { return }
        let token = UUID()
        deferredCloudSaveToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.deferredCloudSaveToken == token, self.isForegroundActive, self.data.syncEnabled, !self.requiresJournalRecovery else { return }
                Self.deferredPersistenceQueue.async { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.deferredCloudSaveToken == token, self.isForegroundActive, self.data.syncEnabled, !self.requiresJournalRecovery else { return }
                        self.deferredCloudSaveToken = nil
                        self.requestCloudSync(reportProgress: false)
                    }
                }
            }
        }
    }

    private func replaceDataFromImport(_ importedData: inout JournalData, operation: String = "Imported backup") throws {
        try requireWritableJournal()
        try Self.validateCandidateData(importedData, operation: operation)
        cancelCloudSync()
        let snapshot = importedData
        let databaseURL = sqliteStore.databaseURL
        let baseline = persistenceBaseline
        let supportDirectory = supportDirectory
        try Self.deferredPersistenceQueue.sync {
            let previous = baseline.snapshot
            try SQLiteJournalStore(databaseURL: databaseURL).replaceData(snapshot, trackSyncChanges: true, resetCloudKitState: true)
            baseline.snapshot = snapshot
            Self.removeObsoleteAttachmentFiles(supportDirectory: supportDirectory, previous: previous, data: snapshot)
        }
        data = snapshot
        refreshDerivedCache()
        deletedTransactionTombstoneIDs = []
        cloudSyncProgress = .idle
        refreshCloudSyncDataAvailability()
        refreshUnlockStateForLoadedData()
    }

    private func reloadDeletedTransactionTombstones() {
        guard !requiresJournalRecovery else {
            deletedTransactionTombstoneIDs = []
            return
        }
        deletedTransactionTombstoneIDs = (try? sqliteStore.deletedTransactionIDs()) ?? []
    }

    private func validate(postings: [Posting], ledgerID: UUID) throws {
        guard postings.count >= 2 else {
            throw ValidationError(message: "A transaction needs at least two postings.")
        }
        guard postings.allSatisfy({ !$0.amount.isZero }) else {
            throw ValidationError(message: "Posting amounts cannot be zero.")
        }
        for posting in postings {
            guard let account = account(posting.accountID), account.ledgerID == ledgerID else {
                throw ValidationError(message: "All posting accounts must belong to this journal.")
            }
            guard let commodityID = postingCommodityID(posting, ledgerID: ledgerID),
                  isValidCommodityID(commodityID, forLedger: ledgerID) else {
                throw ValidationError(message: "All posting currencies must belong to this journal.")
            }
        }
        let totals = Dictionary(grouping: postings, by: { postingCommodityID($0, ledgerID: ledgerID) }).mapValues { rows in
            rows.reduce(Decimal.zero) { $0 + $1.amount }
        }
        guard totals.values.allSatisfy({ $0 == .zero }) else {
            throw ValidationError(message: "Double-entry totals must balance to zero for each currency.")
        }
    }

    private nonisolated static func validateCandidateData(_ candidate: JournalData, operation: String) throws {
        let ledgerIDs = Set(candidate.ledgers.map(\.id))
        let commodityIDs = Set(candidate.commodities.map(\.id))
        let accountIDs = Set(candidate.accounts.map(\.id))
        let sourceIDs = Set(candidate.sources.map(\.id))

        guard ledgerIDs.count == candidate.ledgers.count,
              commodityIDs.count == candidate.commodities.count,
              accountIDs.count == candidate.accounts.count,
              sourceIDs.count == candidate.sources.count,
              Set(candidate.transactions.map(\.id)).count == candidate.transactions.count,
              Set(candidate.transactionTemplates.map(\.id)).count == candidate.transactionTemplates.count else {
            throw ValidationError(message: "\(operation) contains duplicate record identifiers.")
        }

        if let selectedLedgerID = candidate.selectedLedgerID, !ledgerIDs.contains(selectedLedgerID) {
            throw ValidationError(message: "\(operation) selected journal is missing.")
        }
        for commodity in candidate.commodities where !ledgerIDs.contains(commodity.ledgerID) {
            throw ValidationError(message: "\(operation) contains a currency without a journal.")
        }
        for account in candidate.accounts {
            guard ledgerIDs.contains(account.ledgerID) else {
                throw ValidationError(message: "\(operation) contains an account without a journal.")
            }
            if let parentID = account.parentID {
                guard let parent = candidate.accounts.first(where: { $0.id == parentID }),
                      parent.ledgerID == account.ledgerID,
                      parent.kind == account.kind else {
                    throw ValidationError(message: "\(operation) contains an invalid account group.")
                }
            }
            if let commodityID = account.commodityID {
                guard let commodity = candidate.commodities.first(where: { $0.id == commodityID }),
                      commodity.ledgerID == account.ledgerID else {
                    throw ValidationError(message: "\(operation) contains an invalid account currency.")
                }
            }
        }
        guard accountIDs.count == candidate.accounts.count else {
            throw ValidationError(message: "\(operation) contains duplicate account identifiers.")
        }
        let parents = Dictionary(uniqueKeysWithValues: candidate.accounts.map { ($0.id, $0.parentID) })
        var validatedAccounts = Set<UUID>()
        for account in candidate.accounts {
            var path = Set<UUID>()
            var current: UUID? = account.id
            while let id = current, !validatedAccounts.contains(id) {
                guard path.insert(id).inserted else {
                    throw ValidationError(message: "\(operation) contains a circular account group.")
                }
                current = parents[id] ?? nil
            }
            validatedAccounts.formUnion(path)
        }
        for transaction in candidate.transactions {
            guard ledgerIDs.contains(transaction.ledgerID) else {
                throw ValidationError(message: "\(operation) contains a transaction without a journal.")
            }
            if let sourceID = transaction.sourceID, !sourceIDs.contains(sourceID) {
                throw ValidationError(message: "\(operation) contains a transaction without its source.")
            }
            guard transaction.postings.count >= 2 else {
                throw ValidationError(message: "\(operation) contains an incomplete transaction.")
            }
            for posting in transaction.postings {
                guard accountIDs.contains(posting.accountID),
                      candidate.accounts.first(where: { $0.id == posting.accountID })?.ledgerID == transaction.ledgerID else {
                    throw ValidationError(message: "\(operation) contains a posting with an invalid account.")
                }
                if let commodityID = posting.commodityID, !commodityIDs.contains(commodityID) {
                    throw ValidationError(message: "\(operation) contains a posting with an invalid currency.")
                }
            }
        }
        for template in candidate.transactionTemplates {
            guard ledgerIDs.contains(template.ledgerID) else {
                throw ValidationError(message: "\(operation) contains a template without a journal.")
            }
            for posting in template.postings {
                guard posting.accountID.map({ accountIDs.contains($0) }) ?? true else {
                    throw ValidationError(message: "\(operation) contains a template with an invalid account.")
                }
            }
        }
    }

    private func rootAccountID(for kind: AccountKind, ledgerID: UUID, excluding excludedID: UUID?) -> UUID? {
        accounts(for: ledgerID).first {
            $0.ledgerID == ledgerID &&
                $0.kind == kind &&
                $0.parentID == nil &&
                $0.id != excludedID
        }?.id
    }

    private func accountHasTransactions(_ accountID: UUID) -> Bool {
        accountsHaveTransactions([accountID])
    }

    private func accountsHaveTransactions(_ accountIDs: Set<UUID>) -> Bool {
        derivedCache.allTransactionsDateDescending.contains { transaction in
            transaction.postings.contains { accountIDs.contains($0.accountID) }
        }
    }

    private func descendantIDs(of accountID: UUID) -> Set<UUID> {
        derivedCache.descendantIDsByAccount[accountID] ?? []
    }

    private func accountScopeIDs(touchedBy transaction: LedgerTransaction) -> Set<UUID> {
        var result: Set<UUID> = []
        for posting in transaction.postings {
            var accountID: UUID? = posting.accountID
            while let currentID = accountID,
                  let account = derivedCache.accountsByID[currentID] {
                result.insert(currentID)
                accountID = account.parentID
            }
        }
        return result
    }

    private func commodityIDs(touchedBy transaction: LedgerTransaction) -> Set<UUID> {
        Set(transaction.postings.compactMap { postingCommodityID($0, ledgerID: transaction.ledgerID) })
    }

    private func defaultCommodityID(forLedger ledgerID: UUID) -> UUID? {
        derivedCache.defaultCommodityIDByLedger[ledgerID]
    }

    private func postingCommodityID(_ posting: Posting, ledgerID: UUID) -> UUID? {
        posting.commodityID ?? derivedCache.accountsByID[posting.accountID]?.commodityID ?? defaultCommodityID(forLedger: ledgerID)
    }

    private func isValidCommodityID(_ commodityID: UUID, forLedger ledgerID: UUID) -> Bool {
        derivedCache.commoditiesByID[commodityID]?.ledgerID == ledgerID
    }

    private func recurrenceRule(from draft: TransactionDraft) -> RecurrenceRule? {
        guard draft.repeatFrequency != .never else { return nil }
        let originalAnchor = draft.recurrenceRuleID.flatMap { ruleID in
            data.transactions.filter { $0.recurrenceRule?.id == ruleID }.min { $0.date < $1.date }
        }
        let history = originalAnchor.map { anchor in
            anchor.recurrenceRule?.templateHistory ?? RecurrenceTemplateHistory(baseTemplate: RecurrenceTransactionTemplate(transaction: anchor))
        }
        return RecurrenceRule(
            id: draft.recurrenceRuleID ?? UUID(),
            frequency: draft.repeatFrequency,
            intervalValue: max(draft.repeatIntervalValue, 1),
            occurrenceCount: draft.repeatOccurrenceCount,
            endDate: draft.repeatEndDate,
            onWorkdays: draft.repeatOnWorkdays,
            templateHistory: history
        )
    }

    private func attachmentContainer(from draft: TransactionDraft) -> AttachmentContainer? {
        guard draft.attachmentContainer != nil || !draft.attachments.isEmpty else { return nil }
        var container = draft.attachmentContainer ?? AttachmentContainer()
        container.assets = draft.attachments
        return container
    }

    private nonisolated static func sanitizedAttachmentFilenameValue(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        let scalars = name.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Attachment" : cleaned
    }

    private func validatedAttachmentRelativePathIfPresent(_ path: String) -> String? {
        let normalizedPath = normalizedAttachmentStoredPath(path)
        guard !(normalizedPath as NSString).isAbsolutePath else {
            return nil
        }
        let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1,
              components.first == "Attachments",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        guard let destination = Self.canonicalAttachmentPath(attachmentFileURL(forRelativePath: normalizedPath)),
              let attachmentsPath = Self.canonicalAttachmentPath(attachmentsDirectory),
              destination.hasPrefix(attachmentsPath + "/") else { return nil }
        return normalizedPath
    }

    private nonisolated static func validatedAttachmentRelativePathIfPresent(_ path: String, supportDirectory: URL) -> String? {
        let normalizedPath = normalizedAttachmentStoredPathValue(path)
        guard !(normalizedPath as NSString).isAbsolutePath else {
            return nil
        }
        let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1,
              components.first == "Attachments",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        guard let destination = canonicalAttachmentPath(attachmentFileURL(forRelativePath: normalizedPath, supportDirectory: supportDirectory)),
              let attachmentsPath = canonicalAttachmentPath(supportDirectory.appending(path: "Attachments", directoryHint: .isDirectory)),
              destination.hasPrefix(attachmentsPath + "/") else { return nil }
        return normalizedPath
    }

    /// Foundation can shorten an existing /private/var path to /var while
    /// retaining /private/var for a missing file. Resolve existing ancestors
    /// consistently so importing and deleting a receipt keep the same boundary.
    private nonisolated static func canonicalAttachmentPath(_ url: URL) -> String? {
        if let resolved = url.path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { return nil }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, let prefix = canonicalAttachmentPath(parent) else { return nil }
        return (prefix as NSString).appendingPathComponent(url.lastPathComponent)
    }

    private func normalizedAttachmentStoredPath(_ storedPath: String) -> String {
        Self.normalizedAttachmentStoredPathValue(storedPath)
    }

    private nonisolated static func normalizedAttachmentStoredPathValue(_ storedPath: String) -> String {
        var path = storedPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        if path.hasPrefix("file://"),
           let url = URL(string: path),
           url.isFileURL {
            path = url.path
        }

        if let attachmentsRange = path.range(of: "/Attachments/", options: .backwards) {
            path = "Attachments/" + path[attachmentsRange.upperBound...]
        }

        while path.hasPrefix("./") {
            path.removeFirst(2)
        }

        return path
    }

    private func attachmentFileURL(forRelativePath relativePath: String) -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).dropFirst()
        return components.reduce(attachmentsDirectory) { url, component in
            url.appending(path: String(component))
        }
    }

    private nonisolated static func attachmentFileURL(forRelativePath relativePath: String, supportDirectory: URL) -> URL {
        let attachmentsDirectory = supportDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).dropFirst()
        return components.reduce(attachmentsDirectory) { url, component in
            url.appending(path: String(component))
        }
    }

    private func refreshUnlockStateForLoadedData(previousSecurity: SecuritySettings? = nil) {
        guard previousSecurity != data.security else { return }
        isUnlocked = !data.security.passwordLockEnabled
    }

    private static func passwordHash(password: String, salt: String) -> String {
        let payload = Data("\(salt)\u{1f}\(password)".utf8)
        return SHA256.hash(data: payload).map { String(format: "%02x", Int($0)) }.joined()
    }

    private nonisolated static func removeObsoleteAttachmentFiles(supportDirectory: URL, previous: JournalData?, data: JournalData, collectCompletedClaims: Bool = false) {
        func storedPaths(in snapshot: JournalData?) -> Set<String> {
            Set(snapshot?.transactions.flatMap { $0.attachment?.assets.map { normalizedAttachmentStoredPathValue($0.storedPath) } ?? [] } ?? [])
        }
        let current = storedPaths(in: data)
        var candidates = storedPaths(in: previous).subtracting(current)
        guard !candidates.isEmpty || collectCompletedClaims else { return }
        let database = SQLiteJournalStore(databaseURL: supportDirectory.appendingPathComponent("journal.sqlite"))
        // Failed retention reads must never turn into destructive cleanup.
        guard let retention = try? database.attachmentFileRetention(includeCompletedClaims: collectCompletedClaims) else { return }
        candidates.formUnion(retention.completed.map(normalizedAttachmentStoredPathValue))
        let retained = current.union(retention.pending.map(normalizedAttachmentStoredPathValue))
        candidates.subtract(retained)
        guard !candidates.isEmpty else { return }
        func canonicalPath(_ path: String) -> String? {
            guard let relative = validatedAttachmentRelativePathIfPresent(path, supportDirectory: supportDirectory) else { return nil }
            return canonicalAttachmentPath(attachmentFileURL(forRelativePath: relative, supportDirectory: supportDirectory))
        }
        let retainedFiles = Set(retained.compactMap(canonicalPath))
        for path in candidates {
            guard let relative = validatedAttachmentRelativePathIfPresent(path, supportDirectory: supportDirectory),
                  let canonical = canonicalPath(relative), !retainedFiles.contains(canonical) else { continue }
            let url = attachmentFileURL(forRelativePath: relative, supportDirectory: supportDirectory)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func seedBaseAccounts(
        for ledger: Ledger,
        primaryCurrency: (symbol: String, name: String),
        template: String
    ) {
        let primary = Commodity(ledgerID: ledger.id, symbol: primaryCurrency.symbol, name: primaryCurrency.name)
        data.commodities.append(primary)

        @discardableResult
        func add(_ name: String, _ kind: AccountKind, parent: UUID? = nil, color: String = "gray") -> Account {
            let account = Account(
                ledgerID: ledger.id,
                parentID: parent,
                commodityID: primary.id,
                name: name,
                kind: kind,
                colorName: color,
                listIndex: data.accounts.count
            )
            data.accounts.append(account)
            return account
        }

        let assets = add("Assets", .asset)
        let liabilities = add("Liabilities", .liability)
        let income = add("Income", .income)
        let expenses = add("Expenses", .expense)
        let equity = add("Equity", .equity)

        if template == "Business" {
            _ = add("Business Checking", .asset, parent: assets.id, color: "green")
            _ = add("Accounts Receivable", .asset, parent: assets.id, color: "cyan")
            _ = add("Cash", .asset, parent: assets.id)
            let creditCard = add("Credit Card", .liability, parent: liabilities.id, color: "orange")
            _ = add("Company Card", .liability, parent: creditCard.id, color: "orange")
            _ = add("Accounts Payable", .liability, parent: liabilities.id)
            _ = add("Sales", .income, parent: income.id, color: "green")
            _ = add("Consulting", .income, parent: income.id, color: "green")
            _ = add("Payroll", .expense, parent: expenses.id, color: "red")
            _ = add("Software", .expense, parent: expenses.id, color: "blue")
            _ = add("Travel", .expense, parent: expenses.id, color: "orange")
            _ = add("Owner Equity", .equity, parent: equity.id)
            return
        }

        _ = add("Checking", .asset, parent: assets.id, color: "gray")
        _ = add("Cash", .asset, parent: assets.id)
        let creditCard = add("Credit Card", .liability, parent: liabilities.id, color: "orange")
        _ = add("Personal Card", .liability, parent: creditCard.id, color: "orange")
        _ = add("Salary", .income, parent: income.id, color: "green")
        let food = add("Food", .expense, parent: expenses.id, color: "blue")
        _ = add("Groceries", .expense, parent: food.id, color: "blue")
        _ = add("Eating Out", .expense, parent: food.id, color: "blue")
        _ = add("Transportation", .expense, parent: expenses.id, color: "orange")
        _ = add("Utilities", .expense, parent: expenses.id, color: "yellow")
        _ = add("Personal", .expense, parent: expenses.id, color: "purple")
        _ = add("Opening Balance", .equity, parent: equity.id)


    }


}

extension MobileLedgerStore: CloudKitJournalSyncHost {
    var cloudKitJournalData: JournalData { data }
    var cloudKitSQLiteStore: SQLiteJournalStore { sqliteStore }

    func cloudKitFlushLocalChanges() throws {
        try requireWritableJournal()
        let snapshot = data
        try Self.validateCandidateData(snapshot, operation: "Journal")
        try persistSnapshot(snapshot, trackSyncChanges: true)
    }

    func cloudKitValidate(_ candidate: JournalData) throws {
        try Self.validateCandidateData(candidate, operation: "iCloud sync")
    }

    func cloudKitCommitRemote(
        _ records: [CloudKitSyncRecord],
        data candidate: JournalData,
        contextKey: String,
        changeToken: Data?
    ) throws {
        try cloudKitFlushLocalChanges()
        try cloudKitValidate(candidate)
        let databaseURL = sqliteStore.databaseURL
        let baseline = persistenceBaseline
        let supportDirectory = supportDirectory
        try Self.deferredPersistenceQueue.sync {
            do {
                let previous = baseline.snapshot
                try SQLiteJournalStore(databaseURL: databaseURL).persistCloudKitPull(
                    records,
                    data: candidate,
                    previous: baseline.snapshot,
                    contextKey: contextKey,
                    changeToken: changeToken
                )
                baseline.snapshot = candidate
                Self.removeObsoleteAttachmentFiles(supportDirectory: supportDirectory, previous: previous, data: candidate)
            } catch {
                baseline.snapshot = nil
                throw error
            }
        }
        let previousSecurity = data.security
        data = candidate
        refreshDerivedCache()
        refreshUnlockStateForLoadedData(previousSecurity: previousSecurity)
        reloadDeletedTransactionTombstones()
        cloudSyncDataAvailable = true
    }


    func cloudKitCommitConflictResolution(
        id: String,
        keepLocal: Bool,
        data candidate: JournalData,
        contextKey: String
    ) throws {
        try cloudKitFlushLocalChanges()
        try cloudKitValidate(candidate)
        let databaseURL = sqliteStore.databaseURL
        let baseline = persistenceBaseline
        let supportDirectory = supportDirectory
        try Self.deferredPersistenceQueue.sync {
            do {
                let previous = baseline.snapshot
                try SQLiteJournalStore(databaseURL: databaseURL).resolveCloudKitConflict(
                    id: id,
                    keepLocal: keepLocal,
                    contextKey: contextKey,
                    data: candidate,
                    previous: baseline.snapshot
                )
                baseline.snapshot = candidate
                Self.removeObsoleteAttachmentFiles(supportDirectory: supportDirectory, previous: previous, data: candidate)
            } catch {
                baseline.snapshot = nil
                throw error
            }
        }
        let previousSecurity = data.security
        data = candidate
        refreshDerivedCache()
        refreshUnlockStateForLoadedData(previousSecurity: previousSecurity)
        reloadDeletedTransactionTombstones()
        refreshCloudSyncDataAvailability()
    }

    func cloudKitAttachmentURL(for asset: AttachmentAsset) throws -> URL {
        guard let relativePath = validatedAttachmentRelativePathIfPresent(asset.storedPath) else {
            throw ValidationError(message: "The receipt has an invalid local path.")
        }
        return attachmentFileURL(forRelativePath: relativePath)
    }

    func cloudKitSyncDidUpdate(_ progress: CloudSyncProgress) {
        cloudSyncProgress = progress
        // Page/batch progress cannot create a conflict. Refresh on the terminal
        // outcome so scrolling does not wait on SQLite for every progress tick.
        if !progress.isRunning { refreshCloudSyncConflicts() }
    }

    func cloudKitSyncDidFail(_ message: String) {
        cloudSyncProgress = .failed(message: "iCloud Sync failed", detail: message)
        validationError = ValidationError(message: message)
        refreshCloudSyncConflicts()
    }

    func cloudKitSyncDidFinish(at date: Date) throws {
        var updated = data
        updated.lastSyncedAt = date
        let snapshot = updated
        // Publish the completion timestamp only after the current journal and
        // any edit made during network awaits have reached the same save queue.
        try persistSnapshot(snapshot, trackSyncChanges: true, collectCompletedReceipts: true)
        data = snapshot
        validationError = nil
        refreshCloudSyncDataAvailability()
    }
}
