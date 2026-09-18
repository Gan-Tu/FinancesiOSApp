import Foundation

/// Only the journal/account picker catalog is shared with the extension. The
/// extension never opens or rewrites the app's journal database.
struct SharedTransactionCatalog: Codable, Equatable, Sendable {
    struct Journal: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
    }
    struct Account: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var journalID: UUID
        var name: String
        var kind: Int
        var currencyID: UUID?
        var parentID: UUID? = nil
        var colorName: String? = nil
        var note: String? = nil
        var listIndex: Int? = nil
    }
    struct Currency: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var journalID: UUID
        var symbol: String
        var name: String? = nil
    }
    var journals: [Journal]
    var accounts: [Account]
    var currencies: [Currency]
    var selectedJournalID: UUID?
    var locked = false
    var receiptAI: SharedReceiptAIContext? = nil
}

struct SharedReceiptAIContext: Codable, Equatable, Sendable {
    var settings: ReceiptAISettings
    var metadata: [UUID: PaymentAccountMetadata] = [:]
    var accountScope: String = ""
    var unavailableReason: String? = nil
}

/// Save publishes the user's complete transaction together with its receipts.
/// The app consumes it exactly once using the receipt batch's stable identity.
struct SharedTransaction: Codable, Equatable, Sendable {
    struct Posting: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var accountID: UUID?
        var currencyID: UUID?
        var amount = ""
    }
    var journalID: UUID?
    var date = Date()
    var payee = ""
    var note = ""
    var number = ""
    var cleared = true
    var recurrence: RecurrenceRule? = nil
    var postings: [Posting] = []

    init(catalog: SharedTransactionCatalog, now: Date = Date()) {
        date = now
        selectJournal(catalog.journals.first(where: { $0.id == catalog.selectedJournalID })?.id
                      ?? catalog.journals.first?.id, catalog: catalog)
    }

    mutating func selectJournal(_ id: UUID?, catalog: SharedTransactionCatalog) {
        journalID = id
        let accounts = catalog.accounts.filter { $0.journalID == id }
        let parentIDs = Set(accounts.compactMap(\.parentID))
        let leaves = accounts.filter { !parentIDs.contains($0.id) }
        let funding = leaves.first { $0.kind == 0 || $0.kind == 1 }
        let expense = leaves.first { $0.kind == 3 }
        let currency = funding?.currencyID ?? catalog.currencies.first { $0.journalID == id }?.id
        postings = [.init(accountID: funding?.id, currencyID: currency, amount: "-"),
                    .init(accountID: expense?.id, currencyID: currency)]
    }

    mutating func setAmount(_ text: String, at index: Int, catalog: SharedTransactionCatalog? = nil) {
        guard postings.indices.contains(index) else { return }
        postings[index].amount = text
        if postings.count == 2,
           let currency = catalog?.currencyID(for: postings[0], journalID: journalID) ?? postings[0].currencyID,
           currency == (catalog?.currencyID(for: postings[1], journalID: journalID) ?? postings[1].currencyID),
           let value = AmountExpressionEvaluator.evaluate(text) {
            postings[1 - index].amount = NSDecimalNumber(decimal: -value).stringValue
        }
    }

    func validate(in catalog: SharedTransactionCatalog) throws {
        guard !catalog.locked else {
            throw SharedReceiptError(message: "Your journals are password protected. Create this transaction in Finances.")
        }
        guard let journalID, catalog.journals.contains(where: { $0.id == journalID }) else {
            throw SharedReceiptError(message: "Choose an available journal. Open Finances once if your journals are missing.")
        }
        guard date.timeIntervalSinceReferenceDate.isFinite, postings.count >= 2, postings.count <= 64,
              Set(postings.map(\.id)).count == postings.count,
              payee.utf8.count <= 8_000, note.utf8.count <= 128_000, number.utf8.count <= 4_000 else {
            throw SharedReceiptError(message: "Add at least two valid postings.")
        }
        if let recurrence {
            guard [.daily, .weekly, .monthly, .yearly].contains(recurrence.frequency),
                  (1...99).contains(recurrence.intervalValue),
                  recurrence.occurrenceCount.map({ $0 >= 1 }) ?? true,
                  recurrence.endDate.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= date }) ?? true else {
                throw SharedReceiptError(message: "Check the repeat interval and end date.")
            }
        }
        var total: [UUID: Decimal] = [:]
        var hasAmount = false
        for posting in postings {
            guard catalog.accounts.contains(where: { $0.id == posting.accountID && $0.journalID == journalID }),
                  let currency = catalog.currencyID(for: posting, journalID: journalID),
                  catalog.currencies.contains(where: { $0.id == currency && $0.journalID == journalID }),
                  posting.amount.utf8.count <= 512,
                  let amount = AmountExpressionEvaluator.evaluate(posting.amount), !amount.isNaN else {
                throw SharedReceiptError(message: "Choose an account and currency and enter a valid amount for each posting.")
            }
            hasAmount = hasAmount || amount != 0
            total[currency, default: 0] += amount
        }
        guard hasAmount, total.values.allSatisfy({ $0 == 0 }) else {
            throw SharedReceiptError(message: "Enter an amount and balance the postings in each currency.")
        }
    }
}

extension SharedTransactionCatalog {
    func currencyID(for posting: SharedTransaction.Posting, journalID: UUID?) -> UUID? {
        posting.currencyID ?? accounts.first { $0.id == posting.accountID && $0.journalID == journalID }?.currencyID
            ?? currencies.first { $0.journalID == journalID }?.id
    }
}
