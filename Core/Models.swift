import Foundation
import SwiftUI

enum AccountKind: Int, Codable, CaseIterable, Identifiable {
    case asset = 0
    case liability = 1
    case income = 2
    case expense = 3
    case equity = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .asset: "Assets"
        case .liability: "Liabilities"
        case .income: "Income"
        case .expense: "Expenses"
        case .equity: "Equity"
        }
    }
}

enum TransactionFilter: String, Codable, CaseIterable, Identifiable {
    case all = "All"
    case uncleared = "Uncleared"
    case repeating = "Repeating"

    var id: String { rawValue }
}

enum RecurrenceFrequency: String, Codable, CaseIterable, Identifiable {
    case never = "Never"
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case yearly = "Yearly"
    case custom = "Custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .daily: "Every Day"
        case .weekly: "Every Week"
        case .monthly: "Every Month"
        case .yearly: "Every Year"
        case .custom: "Custom"
        }
    }
}

enum AppDateFormat: String, Codable, CaseIterable, Identifiable {
    case medium = "Apr 14, 2017"
    case iso = "2017-04-14"

    var id: String { rawValue }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct JournalCurrencyOption: Identifiable, Equatable {
    let symbol: String
    let name: String

    var id: String { name }
}

enum JournalCurrencyCatalog {
    private static let prioritySymbols = ["EUR", "USD", "CNY", "GBP"]

    static let options: [JournalCurrencyOption] = [
        JournalCurrencyOption(symbol: "USD", name: "US Dollar"),
        JournalCurrencyOption(symbol: "EUR", name: "Euro"),
        JournalCurrencyOption(symbol: "GBP", name: "British Pound"),
        JournalCurrencyOption(symbol: "JPY", name: "Japanese Yen"),
        JournalCurrencyOption(symbol: "CHF", name: "Swiss Franc"),
        JournalCurrencyOption(symbol: "RUB", name: "Russian Ruble"),
        JournalCurrencyOption(symbol: "BTC", name: "Bitcoin"),
        JournalCurrencyOption(symbol: "ETH", name: "Ether"),
        JournalCurrencyOption(symbol: "AFN", name: "Afghan Afghani"),
        JournalCurrencyOption(symbol: "ALL", name: "Albanian Lek"),
        JournalCurrencyOption(symbol: "DZD", name: "Algerian Dinar"),
        JournalCurrencyOption(symbol: "AOA", name: "Angolan Kwanza"),
        JournalCurrencyOption(symbol: "ARS", name: "Argentine Peso"),
        JournalCurrencyOption(symbol: "AMD", name: "Armenian Dram"),
        JournalCurrencyOption(symbol: "AUD", name: "Australian Dollar"),
        JournalCurrencyOption(symbol: "AZN", name: "Azerbaijani Manat"),
        JournalCurrencyOption(symbol: "BHD", name: "Bahraini Dinar"),
        JournalCurrencyOption(symbol: "BDT", name: "Bangladeshi Taka"),
        JournalCurrencyOption(symbol: "BYN", name: "Belarusian Ruble"),
        JournalCurrencyOption(symbol: "BRL", name: "Brazilian Real"),
        JournalCurrencyOption(symbol: "BGN", name: "Bulgarian Lev"),
        JournalCurrencyOption(symbol: "CAD", name: "Canadian Dollar"),
        JournalCurrencyOption(symbol: "CLP", name: "Chilean Peso"),
        JournalCurrencyOption(symbol: "CNY", name: "Chinese Yuan"),
        JournalCurrencyOption(symbol: "COP", name: "Colombian Peso"),
        JournalCurrencyOption(symbol: "CZK", name: "Czech Koruna"),
        JournalCurrencyOption(symbol: "DKK", name: "Danish Krone"),
        JournalCurrencyOption(symbol: "EGP", name: "Egyptian Pound"),
        JournalCurrencyOption(symbol: "HKD", name: "Hong Kong Dollar"),
        JournalCurrencyOption(symbol: "HUF", name: "Hungarian Forint"),
        JournalCurrencyOption(symbol: "INR", name: "Indian Rupee"),
        JournalCurrencyOption(symbol: "IDR", name: "Indonesian Rupiah"),
        JournalCurrencyOption(symbol: "ILS", name: "Israeli New Shekel"),
        JournalCurrencyOption(symbol: "KRW", name: "South Korean Won"),
        JournalCurrencyOption(symbol: "MXN", name: "Mexican Peso"),
        JournalCurrencyOption(symbol: "NZD", name: "New Zealand Dollar"),
        JournalCurrencyOption(symbol: "NOK", name: "Norwegian Krone"),
        JournalCurrencyOption(symbol: "PHP", name: "Philippine Peso"),
        JournalCurrencyOption(symbol: "PLN", name: "Polish Zloty"),
        JournalCurrencyOption(symbol: "RON", name: "Romanian Leu"),
        JournalCurrencyOption(symbol: "SAR", name: "Saudi Riyal"),
        JournalCurrencyOption(symbol: "SGD", name: "Singapore Dollar"),
        JournalCurrencyOption(symbol: "ZAR", name: "South African Rand"),
        JournalCurrencyOption(symbol: "SEK", name: "Swedish Krona"),
        JournalCurrencyOption(symbol: "THB", name: "Thai Baht"),
        JournalCurrencyOption(symbol: "TRY", name: "Turkish Lira"),
        JournalCurrencyOption(symbol: "UAH", name: "Ukrainian Hryvnia"),
        JournalCurrencyOption(symbol: "AED", name: "United Arab Emirates Dirham"),
        JournalCurrencyOption(symbol: "VND", name: "Vietnamese Dong")
    ]

    static var commonFirstOptions: [JournalCurrencyOption] {
        let priority = prioritySymbols.compactMap { symbol in
            options.first { $0.symbol == symbol }
        }
        let prioritySet = Set(prioritySymbols)
        let remaining = options
            .filter { !prioritySet.contains($0.symbol) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        return priority + remaining
    }

    static var names: [String] {
        commonFirstOptions.map(\.name)
    }

    static func choice(named name: String) -> (symbol: String, name: String) {
        guard let option = option(matchingName: name) else {
            return ("USD", "US Dollar")
        }
        return (option.symbol, option.name)
    }

    static func option(matchingName name: String) -> JournalCurrencyOption? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.first {
            $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    static func option(matchingSymbol symbol: String) -> JournalCurrencyOption? {
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return options.first { $0.symbol.uppercased() == normalized }
    }
}

struct Ledger: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var listIndex: Int = 0
    /// A backup imported as a separate journal can retain its existing
    /// recurrence materializations without changing other journals' policy.
    var preservesImportedRecurringMaterializations: Bool? = nil
}

struct Commodity: Identifiable, Codable, Hashable {
    var id = UUID()
    var ledgerID: UUID
    var symbol: String
    var name: String
}

struct Account: Identifiable, Codable, Hashable {
    var id = UUID()
    var ledgerID: UUID
    var parentID: UUID?
    var commodityID: UUID?
    var name: String
    var note: String = ""
    var kind: AccountKind
    var colorName: String = "green"
    var listIndex: Int = 0

    var isGroup: Bool { parentID == nil }
}

struct Posting: Identifiable, Codable, Hashable {
    var id = UUID()
    var accountID: UUID
    var commodityID: UUID?
    var amount: Decimal
    var listIndex: Int = 0
}

struct RecurrenceRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var frequency: RecurrenceFrequency = .never
    var intervalValue: Int = 1
    var occurrenceCount: Int?
    var endDate: Date?
    var onWorkdays: Bool = false
    // Optional for existing SQLite, backup, and sync payloads. Schedule fields
    // and occurrence identity remain separate from changes to future details.
    var templateHistory: RecurrenceTemplateHistory? = nil
    /// Protect the covered imported snapshot, including on older clients.
    /// A portable continuation cursor enables safe future top-up on new clients.
    var preservesImportedMaterializations: Bool? = nil
    var continuation: RecurrenceContinuation? = nil
}

struct RecurrenceTransactionTemplate: Codable, Hashable {
    var payee: String
    var note: String
    var number: String
    var postings: [Posting]

    init(transaction: LedgerTransaction) {
        payee = transaction.payee
        note = transaction.note
        number = transaction.number
        postings = transaction.postings
    }

    func apply(to transaction: inout LedgerTransaction) {
        transaction.payee = payee
        transaction.note = note
        transaction.number = number
        transaction.postings = postings
    }
}

struct RecurrenceTemplateChange: Codable, Hashable {
    var effectiveDate: Date
    var template: RecurrenceTransactionTemplate
}

struct RecurrenceTemplateHistory: Codable, Hashable {
    var baseTemplate: RecurrenceTransactionTemplate
    var changes: [RecurrenceTemplateChange] = []
    var scheduleAnchorDate: Date? = nil

    func template(on date: Date) -> RecurrenceTransactionTemplate {
        changes.filter { $0.effectiveDate <= date }
            .max { $0.effectiveDate < $1.effectiveDate }?.template ?? baseTemplate
    }

    mutating func replaceFutureTemplate(_ template: RecurrenceTransactionTemplate, from date: Date) {
        changes.removeAll { $0.effectiveDate >= date }
        changes.append(RecurrenceTemplateChange(effectiveDate: date, template: template))
        changes.sort { $0.effectiveDate < $1.effectiveDate }
    }
}

struct AttachmentAsset: Identifiable, Codable, Hashable {
    var id = UUID()
    var originalFilename: String
    var storedPath: String
    var mimeType: String?
    var sizeBytes: Int64
}

struct AttachmentContainer: Identifiable, Codable, Hashable {
    var id = UUID()
    var assets: [AttachmentAsset] = []
    var createdAt = Date()
}

struct LedgerTransaction: Identifiable, Codable, Hashable {
    var id = UUID()
    var ledgerID: UUID
    var sourceID: UUID? = nil
    var date: Date
    var payee: String
    var note: String
    var number: String
    var cleared: Bool
    var postings: [Posting]
    var recurrenceRule: RecurrenceRule?
    var attachment: AttachmentContainer?
    var externalTransactionID: String? = nil
}

struct TransactionSource: Identifiable, Codable, Hashable {
    var id = UUID()
    var ledgerID: UUID
    var type: Int
    var date: Date?
    var externalID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case ledgerID
        case type
        case date
        case externalID
    }

    init(id: UUID = UUID(), ledgerID: UUID, type: Int = 0, date: Date? = nil, externalID: String? = nil) {
        self.id = id
        self.ledgerID = ledgerID
        self.type = type
        self.date = date
        self.externalID = externalID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        ledgerID = try container.decode(UUID.self, forKey: .ledgerID)
        type = try container.decodeIfPresent(Int.self, forKey: .type) ?? 0
        date = try container.decodeIfPresent(Date.self, forKey: .date)
        externalID = try container.decodeIfPresent(String.self, forKey: .externalID)
    }
}

struct PostingTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var accountID: UUID?
    var listIndex: Int = 0

    private enum CodingKeys: String, CodingKey {
        case id
        case accountID
        case listIndex
    }

    init(id: UUID = UUID(), accountID: UUID? = nil, listIndex: Int = 0) {
        self.id = id
        self.accountID = accountID
        self.listIndex = listIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        accountID = try container.decodeIfPresent(UUID.self, forKey: .accountID)
        listIndex = try container.decodeIfPresent(Int.self, forKey: .listIndex) ?? 0
    }
}

struct TransactionTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var ledgerID: UUID
    var name: String
    var note: String
    var payee: String
    var cleared: Bool
    var enabled: Bool
    var scanInvoice: Bool
    var listIndex: Int = 0
    var postings: [PostingTemplate] = []

    private enum CodingKeys: String, CodingKey {
        case id
        case ledgerID
        case name
        case note
        case payee
        case cleared
        case enabled
        case scanInvoice
        case listIndex
        case postings
    }

    init(
        id: UUID = UUID(),
        ledgerID: UUID,
        name: String = "Untitled",
        note: String = "",
        payee: String = "",
        cleared: Bool = true,
        enabled: Bool = true,
        scanInvoice: Bool = false,
        listIndex: Int = 0,
        postings: [PostingTemplate] = []
    ) {
        self.id = id
        self.ledgerID = ledgerID
        self.name = name
        self.note = note
        self.payee = payee
        self.cleared = cleared
        self.enabled = enabled
        self.scanInvoice = scanInvoice
        self.listIndex = listIndex
        self.postings = postings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        ledgerID = try container.decode(UUID.self, forKey: .ledgerID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        payee = try container.decodeIfPresent(String.self, forKey: .payee) ?? ""
        cleared = try container.decodeIfPresent(Bool.self, forKey: .cleared) ?? true
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        scanInvoice = try container.decodeIfPresent(Bool.self, forKey: .scanInvoice) ?? false
        listIndex = try container.decodeIfPresent(Int.self, forKey: .listIndex) ?? 0
        postings = try container.decodeIfPresent([PostingTemplate].self, forKey: .postings) ?? []
    }
}

struct SecuritySettings: Codable, Equatable {
    var passwordHash: String?
    var passwordSalt: String?

    var passwordLockEnabled: Bool {
        passwordHash?.isEmpty == false && passwordSalt?.isEmpty == false
    }
}

struct JournalData: Codable {
    var ledgers: [Ledger] = []
    var commodities: [Commodity] = []
    var accounts: [Account] = []
    var transactions: [LedgerTransaction] = []
    var sources: [TransactionSource] = []
    var transactionTemplates: [TransactionTemplate] = []
    var selectedLedgerID: UUID?
    var lastSyncedAt: Date?
    var syncEnabled = false
    var dateFormat: AppDateFormat = .medium
    var appearance: AppAppearance = .automatic
    var security = SecuritySettings()
    /// Marks journals imported from the original Finances SQLite database.
    ///
    /// The original app persists its own set of materialized recurring
    /// transactions instead of relying on this clone's one-year generated
    /// horizon. Keeping this provenance flag in the journal payload lets reloads
    /// preserve the original transaction count and future-row coverage instead
    /// of silently adding clone-generated recurrence rows.
    var preservesImportedRecurringMaterializations = false

    init(
        ledgers: [Ledger] = [],
        commodities: [Commodity] = [],
        accounts: [Account] = [],
        transactions: [LedgerTransaction] = [],
        sources: [TransactionSource] = [],
        transactionTemplates: [TransactionTemplate] = [],
        selectedLedgerID: UUID? = nil,
        lastSyncedAt: Date? = nil,
        syncEnabled: Bool = false,
        dateFormat: AppDateFormat = .medium,
        appearance: AppAppearance = .automatic,
        security: SecuritySettings = SecuritySettings(),
        preservesImportedRecurringMaterializations: Bool = false
    ) {
        self.ledgers = ledgers
        self.commodities = commodities
        self.accounts = accounts
        self.transactions = transactions
        self.sources = sources
        self.transactionTemplates = transactionTemplates
        self.selectedLedgerID = selectedLedgerID
        self.lastSyncedAt = lastSyncedAt
        self.syncEnabled = syncEnabled
        self.dateFormat = dateFormat
        self.appearance = appearance
        self.security = security
        self.preservesImportedRecurringMaterializations = preservesImportedRecurringMaterializations
    }

    func preservesRecurringMaterializations(for transaction: LedgerTransaction) -> Bool {
        transaction.recurrenceRule?.preservesImportedMaterializations
            ?? preservesRecurringMaterializations(in: transaction.ledgerID)
    }

    func shouldExtendRecurrences(for transaction: LedgerTransaction) -> Bool {
        transaction.recurrenceRule?.continuation?.allowsAutomaticExtension
            ?? !preservesRecurringMaterializations(for: transaction)
    }

    func preservesRecurringMaterializations(in ledgerID: UUID) -> Bool {
        ledgers.first(where: { $0.id == ledgerID })?.preservesImportedRecurringMaterializations
            ?? preservesImportedRecurringMaterializations
    }

    private enum CodingKeys: String, CodingKey {
        case ledgers
        case commodities
        case accounts
        case transactions
        case sources
        case transactionTemplates
        case selectedLedgerID
        case lastSyncedAt
        case syncEnabled
        case dateFormat
        case appearance
        case security
        case preservesImportedRecurringMaterializations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ledgers = try container.decodeIfPresent([Ledger].self, forKey: .ledgers) ?? []
        commodities = try container.decodeIfPresent([Commodity].self, forKey: .commodities) ?? []
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        transactions = try container.decodeIfPresent([LedgerTransaction].self, forKey: .transactions) ?? []
        sources = try container.decodeIfPresent([TransactionSource].self, forKey: .sources) ?? []
        transactionTemplates = try container.decodeIfPresent([TransactionTemplate].self, forKey: .transactionTemplates) ?? []
        selectedLedgerID = try container.decodeIfPresent(UUID.self, forKey: .selectedLedgerID)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        syncEnabled = try container.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
        dateFormat = try container.decodeIfPresent(AppDateFormat.self, forKey: .dateFormat) ?? .medium
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .automatic
        security = try container.decodeIfPresent(SecuritySettings.self, forKey: .security) ?? SecuritySettings()
        preservesImportedRecurringMaterializations = try container.decodeIfPresent(
            Bool.self,
            forKey: .preservesImportedRecurringMaterializations
        ) ?? false
    }
}

struct ValidationError: LocalizedError, Identifiable {
    var id = UUID()
    var message: String

    var errorDescription: String? { message }
}

struct PostingDraft: Identifiable, Equatable {
    var id = UUID()
    var accountID: UUID?
    var amount = ""
    var commodityID: UUID?
    var preservesNilCommodityID = false
}

struct TransactionDraft: Identifiable, Equatable {
    var id: UUID?
    var ledgerID: UUID? = nil
    var date = Date()
    var payee = ""
    var note = ""
    var number = ""
    var cleared = true
    var recurrenceRuleID: UUID?
    var repeatFrequency: RecurrenceFrequency = .never
    var repeatIntervalValue = 1
    var repeatOnWorkdays = false
    var repeatOccurrenceCount: Int?
    var repeatEndDate: Date?
    var postings: [PostingDraft] = []
    var attachmentContainer: AttachmentContainer?
    var attachments: [AttachmentAsset] = []

    static func new(defaultDebit: UUID?, defaultCredit: UUID?, ledgerID: UUID? = nil) -> TransactionDraft {
        var draft = TransactionDraft(ledgerID: ledgerID)
        draft.postings = [
            PostingDraft(accountID: defaultCredit, amount: "0.00"),
            PostingDraft(accountID: defaultDebit, amount: "0.00")
        ]
        return draft
    }
}

struct PostingTemplateDraft: Identifiable, Equatable {
    var id = UUID()
    var accountID: UUID?
}

struct TransactionTemplateDraft: Identifiable, Equatable {
    var id: UUID?
    var ledgerID: UUID?
    var name = "Untitled"
    var note = ""
    var payee = ""
    var cleared = true
    var enabled = true
    var scanInvoice = false
    var postings: [PostingTemplateDraft] = []
}

struct AccountDraft: Identifiable, Equatable {
    var id: UUID?
    var ledgerID: UUID? = nil
    var name = "Untitled"
    var note = ""
    var kind: AccountKind = .expense
    var parentID: UUID?
    var commodityID: UUID?
    var colorName = "red"
}

struct CurrencyDraft: Identifiable, Equatable {
    var id: UUID?
    var ledgerID: UUID? = nil
    var symbol = ""
    var name = "Untitled"

    mutating func applyCatalogOption(_ option: JournalCurrencyOption) {
        symbol = option.symbol
        name = option.name
    }

    mutating func syncFromCatalogName() {
        guard let option = JournalCurrencyCatalog.option(matchingName: name) else { return }
        applyCatalogOption(option)
    }

    mutating func syncFromCatalogSymbol() {
        guard let option = JournalCurrencyCatalog.option(matchingSymbol: symbol) else { return }
        applyCatalogOption(option)
    }
}

struct JournalDraft: Identifiable, Equatable {
    var id: UUID?
    var name = "Untitled"
}
