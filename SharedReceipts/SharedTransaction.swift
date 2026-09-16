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
    }
    struct Currency: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var journalID: UUID
        var symbol: String
    }
    var journals: [Journal]
    var accounts: [Account]
    var currencies: [Currency]
    var selectedJournalID: UUID?
    var locked = false
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
    var postings: [Posting] = []

    init(catalog: SharedTransactionCatalog, now: Date = Date()) {
        date = now
        selectJournal(catalog.journals.first(where: { $0.id == catalog.selectedJournalID })?.id
                      ?? catalog.journals.first?.id, catalog: catalog)
    }

    mutating func selectJournal(_ id: UUID?, catalog: SharedTransactionCatalog) {
        journalID = id
        let accounts = catalog.accounts.filter { $0.journalID == id }
        let funding = accounts.first { $0.kind == 0 || $0.kind == 1 }
        let expense = accounts.first { $0.kind == 3 }
        let currency = funding?.currencyID ?? catalog.currencies.first { $0.journalID == id }?.id
        postings = [.init(accountID: funding?.id, currencyID: currency, amount: "-"),
                    .init(accountID: expense?.id, currencyID: currency)]
    }

    mutating func setAmount(_ text: String, at index: Int) {
        postings[index].amount = text
        if postings.count == 2, postings[0].currencyID == postings[1].currencyID,
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
        var total: [UUID: Decimal] = [:]
        var hasAmount = false
        for posting in postings {
            guard catalog.accounts.contains(where: { $0.id == posting.accountID && $0.journalID == journalID }),
                  let currency = posting.currencyID,
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
