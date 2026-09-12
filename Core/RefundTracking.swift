import CryptoKit
import Foundation

enum RefundTrackingKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case refund
    case reimbursement
    var id: String { rawValue }
    var title: String { self == .refund ? "Refund" : "Reimbursement" }
}

enum RefundTrackingState: String, Codable, Sendable {
    case active
    case cancelled
}

struct RefundTrackingLink: Codable, Hashable, Identifiable, Sendable {
    var transactionID: UUID
    var amount: Decimal
    var id: UUID { transactionID }
}

struct RefundTrackingDraft: Equatable, Sendable {
    var purchaseTransactionID: UUID
    var kind: RefundTrackingKind = .refund
    var expectedAmount: Decimal
    var commodityID: UUID
    var person = ""
    var note = ""
    var dueDate: Date? = nil

    init(purchaseTransactionID: UUID, kind: RefundTrackingKind = .refund, expectedAmount: Decimal,
         commodityID: UUID, person: String = "", note: String = "", dueDate: Date? = nil) {
        self.purchaseTransactionID = purchaseTransactionID; self.kind = kind
        self.expectedAmount = expectedAmount; self.commodityID = commodityID
        self.person = person; self.note = note; self.dueDate = dueDate
    }

    init(_ record: RefundTrackingRecord) {
        self.init(purchaseTransactionID: record.purchaseTransactionID, kind: record.kind,
                  expectedAmount: record.expectedAmount, commodityID: record.commodityID,
                  person: record.person, note: record.note, dueDate: record.dueDate)
    }
}

struct RefundTrackingRecord: Codable, Hashable, Identifiable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var ledgerID: UUID
    var purchaseTransactionID: UUID
    var kind: RefundTrackingKind
    var expectedAmount: Decimal
    var commodityID: UUID
    var person: String
    var note: String
    var dueDate: Date?
    var state: RefundTrackingState = .active
    var links: [RefundTrackingLink] = []
}

struct RefundTrackingSummary: Identifiable, Sendable {
    let record: RefundTrackingRecord
    /// Nil amounts mean the linked data needs attention; they must not be
    /// presented as settled or silently included in aggregate totals.
    let receivedAmount: Decimal?
    let outstandingAmount: Decimal?
    let issues: [String]
    var id: UUID { record.id }
    var isSettled: Bool { record.state == .active && outstandingAmount == Decimal.zero }
}

struct RefundTrackingOverview: Sendable {
    let summaries: [RefundTrackingSummary]
    let issues: [String]
    var outstandingByCurrency: [UUID: Decimal] {
        summaries.reduce(into: [:]) { result, summary in
            guard summary.record.state == .active, let amount = summary.outstandingAmount else { return }
            result[summary.record.commodityID, default: .zero] += amount
        }
    }
}

/// Uses an existing, opaque TransactionSource field rather than an unknown
/// transaction property: older Mac clients already preserve source records in
/// SQLite, backups and CloudKit, even when editing the associated transaction.
/// No transaction sourceID or monetary posting is modified by these operations.
enum RefundTracking {
    static let sourceType = 0x4652
    static let externalIDPrefix = "finances.refund-tracking.v1:"
    private static let maximumPayloadBytes = 256 * 1_024

    static func sourceID(for purchaseID: UUID) -> UUID {
        let bytes = SHA256.hash(data: Data("finances.refund-tracking.v1/\(purchaseID.uuidString)".utf8)).prefix(16)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))")!
    }

    static func decode(_ source: TransactionSource) throws -> RefundTrackingRecord? {
        guard source.type == sourceType else { return nil }
        guard let externalID = source.externalID, externalID.hasPrefix(externalIDPrefix),
              externalID.utf8.count <= maximumPayloadBytes,
              let bytes = String(externalID.dropFirst(externalIDPrefix.count)).data(using: .utf8),
              let record = try? JSONDecoder.appDecoder.decode(RefundTrackingRecord.self, from: bytes),
              record.schemaVersion == 1, record.id == source.id, record.ledgerID == source.ledgerID,
              record.id == sourceID(for: record.purchaseTransactionID) else {
            throw invalid("Refund tracking metadata is unreadable or its journal identity has changed.")
        }
        try validateStructure(record)
        return record
    }

    static func source(for record: RefundTrackingRecord) throws -> TransactionSource {
        try validateStructure(record)
        guard record.schemaVersion == 1, record.id == sourceID(for: record.purchaseTransactionID) else {
            throw invalid("Refund tracking identity is invalid.")
        }
        let payload = externalIDPrefix + String(decoding: try JSONEncoder.appEncoder.encode(record), as: UTF8.self)
        guard payload.utf8.count <= maximumPayloadBytes else { throw invalid("This tracking record has too many linked payments or too much text.") }
        return TransactionSource(id: record.id, ledgerID: record.ledgerID, type: sourceType, externalID: payload)
    }

    static func record(for purchaseID: UUID, in data: JournalData) throws -> RefundTrackingRecord? {
        let id = sourceID(for: purchaseID)
        guard let source = data.sources.first(where: { $0.id == id }) else { return nil }
        guard let record = try decode(source) else { throw invalid("A source identifier is already in use by another record.") }
        return record
    }

    static func records(in data: JournalData, ledgerID: UUID? = nil) throws -> [RefundTrackingRecord] {
        try data.sources.filter { ledgerID == nil || $0.ledgerID == ledgerID }.compactMap(decode)
    }

    static func overview(in data: JournalData, ledgerID: UUID) -> RefundTrackingOverview {
        var records: [RefundTrackingRecord] = [], issues: [String] = []
        for source in data.sources where source.ledgerID == ledgerID && source.type == sourceType {
            do { if let record = try decode(source) { records.append(record) } }
            catch { issues.append(error.localizedDescription) }
        }
        let summaries = records.map { record -> RefundTrackingSummary in
            do {
                guard issues.isEmpty else { throw invalid("Some tracking metadata is unreadable. Linked amounts cannot be verified.") }
                let received = try validateReferences(record, among: records, in: data)
                return RefundTrackingSummary(record: record, receivedAmount: received,
                    outstandingAmount: record.state == .cancelled ? .zero : max(.zero, record.expectedAmount - received), issues: [])
            } catch {
                return RefundTrackingSummary(record: record, receivedAmount: nil, outstandingAmount: nil, issues: [error.localizedDescription])
            }
        }.sorted { $0.record.id.uuidString < $1.record.id.uuidString }
        return RefundTrackingOverview(summaries: summaries, issues: issues)
    }

    static func saving(_ draft: RefundTrackingDraft, in data: JournalData) throws -> JournalData {
        guard let purchase = data.transactions.first(where: { $0.id == draft.purchaseTransactionID }) else {
            throw invalid("The purchase transaction no longer exists.")
        }
        var value = try record(for: purchase.id, in: data) ?? RefundTrackingRecord(
            id: sourceID(for: purchase.id), ledgerID: purchase.ledgerID, purchaseTransactionID: purchase.id,
            kind: draft.kind, expectedAmount: draft.expectedAmount, commodityID: draft.commodityID,
            person: draft.person, note: draft.note, dueDate: draft.dueDate)
        guard value.ledgerID == purchase.ledgerID else { throw invalid("The purchase moved to another journal. Remove its old tracking and start again.") }
        guard value.commodityID == draft.commodityID || value.links.isEmpty else {
            throw invalid("Unlink received payments before changing the tracking currency.")
        }
        value.kind = draft.kind; value.expectedAmount = draft.expectedAmount; value.commodityID = draft.commodityID
        value.person = draft.person.trimmingCharacters(in: .whitespacesAndNewlines)
        value.note = draft.note; value.dueDate = draft.dueDate; value.state = .active
        return try replacing(value, in: data, validate: true)
    }

    /// Replacing the same incoming-transaction allocation is idempotent, so a
    /// durable-save retry cannot append a second allocation.
    static func linking(purchaseID: UUID, incomingTransactionID: UUID, amount: Decimal, in data: JournalData) throws -> JournalData {
        var value = try requiredRecord(purchaseID, in: data)
        guard value.state == .active else { throw invalid("Resume tracking before linking a payment.") }
        guard !amount.isNaN, amount > .zero else { throw invalid("The linked amount must be greater than zero.") }
        value.links.removeAll { $0.transactionID == incomingTransactionID }
        value.links.append(RefundTrackingLink(transactionID: incomingTransactionID, amount: amount))
        value.links.sort { $0.transactionID.uuidString < $1.transactionID.uuidString }
        return try replacing(value, in: data, validate: true)
    }

    static func unlinking(purchaseID: UUID, incomingTransactionID: UUID, in data: JournalData) throws -> JournalData {
        var value = try requiredRecord(purchaseID, in: data)
        value.links.removeAll { $0.transactionID == incomingTransactionID }
        // Allow repairs even if another linked transaction has since vanished.
        return try replacing(value, in: data, validate: false)
    }

    static func cancelling(purchaseID: UUID, in data: JournalData) throws -> JournalData {
        var value = try requiredRecord(purchaseID, in: data)
        value.state = .cancelled
        return try replacing(value, in: data, validate: false)
    }

    static func removing(purchaseID: UUID, in data: JournalData) throws -> JournalData {
        let id = sourceID(for: purchaseID)
        guard !data.sources.contains(where: { $0.id == id && $0.type != sourceType }) else {
            throw invalid("A source identifier is already in use by another record.")
        }
        var result = data
        result.sources.removeAll { $0.id == id }
        return result
    }

    static func incomingAmount(transactionID: UUID, commodityID: UUID, ledgerID: UUID, in data: JournalData) throws -> Decimal {
        guard let transaction = data.transactions.first(where: { $0.id == transactionID }), transaction.ledgerID == ledgerID else {
            throw invalid("A linked payment was deleted or moved to another journal.")
        }
        guard transaction.date <= Date() else { throw invalid("A future-dated payment has not been received yet.") }
        let net = try financialAmount(transaction, commodityID: commodityID, in: data)
        guard net > .zero else { throw invalid("The linked transaction has no incoming amount in the tracking currency. Currency conversion is not inferred.") }
        return net
    }

    /// Call on the ORIGINAL source during an import that changes graph IDs.
    /// Older Mac import-as-new-journal does not understand this opaque payload;
    /// such cloned metadata is flagged by decode, never attached by guessing.
    static func remapping(_ source: TransactionSource, using ids: [UUID: UUID]) throws -> TransactionSource {
        guard var value = try decode(source) else { return source }
        func mapped(_ id: UUID) throws -> UUID {
            guard let mapped = ids[id] else { throw invalid("Refund tracking references a record missing from the imported journal.") }
            return mapped
        }
        value.ledgerID = try mapped(value.ledgerID)
        value.purchaseTransactionID = try mapped(value.purchaseTransactionID)
        value.commodityID = try mapped(value.commodityID)
        for index in value.links.indices { value.links[index].transactionID = try mapped(value.links[index].transactionID) }
        value.id = sourceID(for: value.purchaseTransactionID)
        return try self.source(for: value)
    }

    private static func requiredRecord(_ purchaseID: UUID, in data: JournalData) throws -> RefundTrackingRecord {
        guard let value = try record(for: purchaseID, in: data) else { throw invalid("This purchase is not being tracked.") }
        return value
    }

    private static func replacing(_ record: RefundTrackingRecord, in data: JournalData, validate: Bool) throws -> JournalData {
        let source = try source(for: record)
        var result = data
        if let index = result.sources.firstIndex(where: { $0.id == source.id }) { result.sources[index] = source }
        else { result.sources.append(source) }
        if validate {
            let all = try records(in: result, ledgerID: record.ledgerID)
            _ = try validateReferences(record, among: all, in: result)
        }
        return result
    }

    private static func validateStructure(_ record: RefundTrackingRecord) throws {
        guard !record.expectedAmount.isNaN, record.expectedAmount > .zero,
              record.dueDate?.timeIntervalSinceReferenceDate.isFinite != false,
              Set(record.links.map(\.transactionID)).count == record.links.count,
              record.links.allSatisfy({ !$0.amount.isNaN && $0.amount > .zero && $0.transactionID != record.purchaseTransactionID }) else {
            throw invalid("Refund tracking has an invalid amount, date or duplicate payment link.")
        }
    }

    private static func validateReferences(_ record: RefundTrackingRecord, among records: [RefundTrackingRecord], in data: JournalData) throws -> Decimal {
        try validateStructure(record)
        guard data.ledgers.contains(where: { $0.id == record.ledgerID }),
              data.commodities.contains(where: { $0.id == record.commodityID && $0.ledgerID == record.ledgerID }),
              let purchase = data.transactions.first(where: { $0.id == record.purchaseTransactionID }), purchase.ledgerID == record.ledgerID else {
            throw invalid("The tracked purchase or its currency was deleted or moved to another journal.")
        }
        guard try financialAmount(purchase, commodityID: record.commodityID, in: data) < .zero else {
            throw invalid("The purchase no longer has an outgoing amount in the tracking currency.")
        }
        var received = Decimal.zero
        for link in record.links {
            let available = try incomingAmount(transactionID: link.transactionID, commodityID: record.commodityID, ledgerID: record.ledgerID, in: data)
            if record.state == .active {
                let allocated = records.filter { $0.state == .active && $0.commodityID == record.commodityID }
                    .flatMap(\.links).filter { $0.transactionID == link.transactionID }.reduce(Decimal.zero) { $0 + $1.amount }
                guard !allocated.isNaN, allocated <= available else {
                    throw invalid("Linked allocations exceed this payment's incoming amount. Reduce or unlink an allocation.")
                }
            }
            received += link.amount
        }
        guard !received.isNaN, received <= record.expectedAmount else {
            throw invalid("Linked payments exceed the expected amount. Increase the expected amount or reduce an allocation.")
        }
        return received
    }

    private static func financialAmount(_ transaction: LedgerTransaction, commodityID: UUID, in data: JournalData) throws -> Decimal {
        var total = Decimal.zero
        let fallback = data.commodities.first(where: { $0.ledgerID == transaction.ledgerID })?.id
        for posting in transaction.postings {
            guard let account = data.accounts.first(where: { $0.id == posting.accountID }), account.ledgerID == transaction.ledgerID,
                  !posting.amount.isNaN else { throw invalid("A transaction account or amount is invalid.") }
            let resolvedCurrency = posting.commodityID ?? account.commodityID ?? fallback
            guard let resolvedCurrency, data.commodities.contains(where: { $0.id == resolvedCurrency && $0.ledgerID == transaction.ledgerID }) else {
                throw invalid("A transaction currency is missing or belongs to another journal.")
            }
            if resolvedCurrency == commodityID, account.kind == .asset || account.kind == .liability { total += posting.amount }
        }
        guard !total.isNaN else { throw invalid("The transaction amount is too large.") }
        return total
    }

    private static func invalid(_ message: String) -> ValidationError { ValidationError(message: message) }
}
