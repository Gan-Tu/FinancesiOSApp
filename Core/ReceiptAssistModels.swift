import CryptoKit
import Foundation

struct PaymentIdentity: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var label = ""
    var network: String?
    var last4 = ""
    private enum CodingKeys: String, CodingKey { case id, label, network, last4 }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        if let network {
            try container.encode(network, forKey: .network)
        } else {
            try container.encodeNil(forKey: .network)
        }
        try container.encode(last4, forKey: .last4)
    }
    static let networks = ["visa", "mastercard", "amex", "discover", "unionpay"]
    func validate() throws {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 160,
            last4.range(of: "^[0-9]{4}$", options: .regularExpression) != nil,
            network == nil || Self.networks.contains(network!)
        else {
            throw AssistError.message("Enter a label and exactly four card digits.")
        }
    }
}
struct PaymentAccountMetadata: Codable, Equatable, Sendable {
    var id: UUID
    var ledgerID: UUID
    var identities: [PaymentIdentity]
    func validate() throws {
        guard Set(identities.map(\.id)).count == identities.count else {
            throw AssistError.message("Duplicate card identity.")
        }
        try identities.forEach { try $0.validate() }
    }
    static func decode(_ record: CloudKitSyncRecord) throws -> Self? {
        guard record.recordType == "assist_account" else {
            throw AssistError.message("Unexpected card metadata record.")
        }
        if record.operation == "delete" { return nil }
        guard let raw = record.payloadJSON, let data = raw.data(using: .utf8), data.count <= 2_000_000,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == record.contentHash
        else {
            throw AssistError.message("Card metadata integrity check failed.")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.id.uuidString == record.recordID, value.ledgerID.uuidString == record.parentRecordID
        else { throw AssistError.message("Card metadata belongs to another account.") }
        try value.validate()
        return value
    }
    func record(previous: CloudKitSyncRecord?) throws -> CloudKitSyncRecord {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return CloudKitSyncRecord(
            recordType: "assist_account", recordID: id.uuidString, operation: "upsert",
            parentRecordID: ledgerID.uuidString,
            contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            payloadJSON: String(decoding: data, as: UTF8.self), clientChangeID: UUID().uuidString,
            systemFields: previous?.systemFields)
    }
}
enum AssistError: LocalizedError {
    case message(String)
    case attachmentLimit(String)
    var errorDescription: String? {
        switch self {
        case .message(let text), .attachmentLimit(let text): text
        }
    }
}
struct ReceiptAISettings: Codable, Equatable, Sendable {
    static let changeNotification = Notification.Name("FinancesReceiptAISettingsChanged")
    #if DEBUG
        var endpoint = "http://127.0.0.1:5176"
    #else
        var endpoint = "https://finances.tugan.app"
    #endif
    var model = "gpt-5.6-terra"
    var effort = "medium"
    var instructions = ""
    static let models = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra"]
    var efforts: [String] {
        (model == "gpt-6-astra" ? [] : ["none"]) + ["low", "medium", "high", "xhigh", "max"]
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "receipt-ai-settings-v1"),
            let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return value
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "receipt-ai-settings-v1")
            NotificationCenter.default.post(name: Self.changeNotification, object: nil)
        }
    }
}
struct ReceiptAnalysisResponse: Decodable, Sendable {
    struct Posting: Decodable, Sendable {
        var accountID: UUID?
        var commodityID: UUID?
        var amount: String?
        var role: String
    }
    struct Suggestion: Decodable, Sendable {
        var date: String?
        var payee: String?
        var note: String?
        var invoiceNumber: String?
        var orderNumber: String?
        var postings: [Posting]
        var warnings: [String]
    }
    var suggestion: Suggestion
    var postingsApplicable: Bool
}
enum ReceiptProposalField: String, CaseIterable, Identifiable {
    case date, note, payee, number, postings
    var id: String { rawValue }
    var title: String { self == .postings ? "Accounts and amounts" : rawValue.capitalized }
}
struct ReceiptDraftProposal {
    var date: Date?
    var note: String?
    var payee: String?
    var number: String?
    var postings: [PostingDraft]?
    static func make(_ response: ReceiptAnalysisResponse, accounts: [Account], commodities: [Commodity])
        throws -> Self
    {
        let suggestion = response.suggestion
        let knownAccounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let currencyIDs = Set(commodities.map(\.id))
        var postings: [PostingDraft] = []
        var hasCounter = false
        for row in suggestion.postings {
            guard ["source", "counter"].contains(row.role) else {
                throw AssistError.message("Invalid proposed posting.")
            }
            if let id = row.accountID {
                guard let account = knownAccounts[id], account.parentID != nil,
                    row.role == "source"
                        ? [.asset, .liability, .equity].contains(account.kind)
                        : [.expense, .income].contains(account.kind)
                else { throw AssistError.message("A proposed account is unavailable.") }
                if row.role == "counter" { hasCounter = true }
            }
            if let id = row.commodityID, !currencyIDs.contains(id) {
                throw AssistError.message("A proposed currency is unavailable.")
            }
            if let amount = row.amount {
                guard amount.count <= 100,
                    amount.range(of: "^-?[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil,
                    Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) != nil
                else { throw AssistError.message("Invalid proposed amount.") }
            }
            postings.append(
                PostingDraft(accountID: row.accountID, amount: row.amount ?? "", commodityID: row.commodityID)
            )
        }
        if hasCounter && !suggestion.postings.contains(where: { $0.role == "source" }) {
            postings.insert(PostingDraft(), at: 0)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let date = suggestion.date.flatMap { formatter.date(from: $0) }.flatMap {
            Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: $0)
        }
        return Self(
            date: date, note: suggestion.note, payee: suggestion.payee,
            number: suggestion.invoiceNumber ?? suggestion.orderNumber,
            postings: response.postingsApplicable || hasCounter ? postings : nil)
    }
    mutating func keepCurrentAccountsForReview(
        response: ReceiptAnalysisResponse, current: TransactionDraft, accounts: [Account]
    ) {
        guard var rows = postings else { return }
        var roles = response.suggestion.postings.map(\.role)
        if !roles.contains("source") { roles.insert("source", at: 0) }
        for index in rows.indices where rows[index].accountID == nil {
            let row = rows[index]
            guard let currency = row.commodityID, !row.amount.isEmpty,
                let amount = Decimal(string: row.amount, locale: Locale(identifier: "en_US_POSIX")),
                roles.indices.contains(index) else { continue }
            let matches = current.postings.compactMap { existing -> UUID? in
                guard let account = accounts.first(where: { $0.id == existing.accountID }),
                    account.ledgerID == current.ledgerID, account.parentID != nil,
                    (roles[index] == "source" ? [.asset, .liability, .equity] : [.expense, .income]).contains(account.kind),
                    (existing.commodityID ?? account.commodityID) == currency,
                    account.commodityID == nil || account.commodityID == currency,
                    !existing.amount.isEmpty,
                    Decimal(string: existing.amount, locale: Locale(identifier: "en_US_POSIX")) == amount
                else { return nil }
                return account.id
            }
            let ids = Set(matches)
            if ids.count == 1 { rows[index].accountID = ids.first }
        }
        postings = rows
    }
    var fields: [ReceiptProposalField] {
        ReceiptProposalField.allCases.filter { field in
            switch field {
            case .date: date != nil
            case .note: note != nil
            case .payee: payee != nil
            case .number: number != nil
            case .postings: postings != nil
            }
        }
    }
    func apply(_ field: ReceiptProposalField, to draft: inout TransactionDraft) {
        switch field {
        case .date: if let date { draft.date = date }
        case .note: if let note { draft.note = note }
        case .payee: if let payee { draft.payee = payee }
        case .number: if let number { draft.number = number }
        case .postings: if let postings { draft.postings = postings }
        }
    }
    static func equal(_ field: ReceiptProposalField, _ a: TransactionDraft, _ b: TransactionDraft) -> Bool {
        switch field {
        case .date: Calendar.current.isDate(a.date, inSameDayAs: b.date)
        case .note: a.note == b.note
        case .payee: a.payee == b.payee
        case .number: a.number == b.number
        case .postings:
            a.postings.count == b.postings.count
                && zip(a.postings, b.postings).allSatisfy { left, right in
                    guard left.accountID == right.accountID, left.commodityID == right.commodityID else {
                        return false
                    }
                    let lhs = Decimal(string: left.amount, locale: Locale(identifier: "en_US_POSIX"))
                    let rhs = Decimal(string: right.amount, locale: Locale(identifier: "en_US_POSIX"))
                    return lhs != nil && rhs != nil ? lhs == rhs : left.amount == right.amount
                }
        }
    }
    func autofill(
        _ draft: inout TransactionDraft, initial: TransactionDraft, protected: Set<ReceiptProposalField>
    ) -> [ReceiptProposalField] {
        var replacements: [ReceiptProposalField] = []
        for field in fields {
            var proposed = draft
            apply(field, to: &proposed)
            if Self.equal(field, draft, proposed) { continue }
            let empty: Bool =
                switch field {
                case .note: draft.note.isEmpty
                case .payee: draft.payee.isEmpty
                case .number: draft.number.isEmpty
                case .date: false
                case .postings: draft.postings.isEmpty
                }
            if empty || (!protected.contains(field) && initial.id == nil && Self.equal(field, initial, draft))
            {
                apply(field, to: &draft)
            } else {
                replacements.append(field)
            }
        }
        return replacements
    }
}
