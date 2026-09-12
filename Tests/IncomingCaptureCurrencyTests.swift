import XCTest
@testable import FinancesClone

final class IncomingCaptureCurrencyTests: XCTestCase {
    private func draft(ledgerID: UUID?, currencyID: UUID? = nil) -> TransactionDraft {
        var draft = TransactionDraft(ledgerID: ledgerID)
        draft.payee = "Synthetic EUR purchase"
        draft.postings = [
            PostingDraft(accountID: UUID(), amount: "-42.50", commodityID: currencyID),
            PostingDraft(accountID: UUID(), amount: "42.50", commodityID: currencyID)
        ]
        return draft
    }

    func testMissingCaptureCurrencyResolvesWhenItArrivesWithoutChangingAccountsOrAmounts() {
        let ledgerID = UUID()
        let dollars = Commodity(ledgerID: ledgerID, symbol: "USD", name: "US Dollar")
        let euros = Commodity(ledgerID: ledgerID, symbol: "EUR", name: "Euro")
        var draft = draft(ledgerID: ledgerID)
        let original = draft
        var capture = IncomingCaptureCurrency(code: "eur", draft: draft)

        capture.reconcile(draft: &draft, commodities: [dollars])
        XCTAssertTrue(capture.preventsSaving(draft: draft, commodities: [dollars]))
        XCTAssertEqual(draft, original)

        capture.reconcile(draft: &draft, commodities: [dollars, euros])
        XCTAssertFalse(capture.preventsSaving(draft: draft, commodities: [dollars, euros]))
        XCTAssertEqual(draft.postings.map(\.commodityID), [euros.id, euros.id])
        XCTAssertEqual(draft.postings.map(\.accountID), original.postings.map(\.accountID))
        XCTAssertEqual(draft.postings.map(\.amount), original.postings.map(\.amount))
        XCTAssertEqual(draft.payee, original.payee)
        XCTAssertEqual(draft.saveOperationID, original.saveOperationID)
    }

    func testCatalogAvailabilityAloneCannotEnableSaveBeforeDraftReconciliation() {
        let ledgerID = UUID()
        let euros = Commodity(ledgerID: ledgerID, symbol: "EUR", name: "Euro")
        var draft = draft(ledgerID: ledgerID)
        var capture = IncomingCaptureCurrency(code: "EUR", draft: draft)

        XCTAssertTrue(capture.preventsSaving(draft: draft, commodities: [euros]))
        capture.reconcile(draft: &draft, commodities: [euros])
        XCTAssertFalse(capture.preventsSaving(draft: draft, commodities: [euros]))
        XCTAssertTrue(draft.postings.allSatisfy { $0.commodityID == euros.id })
    }

    func testResolvedCapturePreservesExplicitCurrencyEditsAcrossCatalogChanges() {
        let ledgerID = UUID()
        let euros = Commodity(ledgerID: ledgerID, symbol: "EUR", name: "Euro")
        let dollars = Commodity(ledgerID: ledgerID, symbol: "USD", name: "US Dollar")
        var draft = draft(ledgerID: ledgerID, currencyID: euros.id)
        var capture = IncomingCaptureCurrency(code: "EUR", draft: draft)
        draft.postings[0].commodityID = dollars.id
        draft.postings[1].commodityID = nil // Deliberate Account Currency choice.
        let edited = draft

        capture.reconcile(draft: &draft, commodities: [euros, dollars])
        XCTAssertEqual(draft, edited)
        XCTAssertFalse(capture.preventsSaving(draft: draft, commodities: [euros, dollars]))
    }

    func testLateResolutionAlsoPreservesSubsequentExplicitEdits() {
        let ledgerID = UUID()
        let euros = Commodity(ledgerID: ledgerID, symbol: "EUR", name: "Euro")
        let dollars = Commodity(ledgerID: ledgerID, symbol: "USD", name: "US Dollar")
        var draft = draft(ledgerID: ledgerID)
        var capture = IncomingCaptureCurrency(code: "EUR", draft: draft)
        capture.reconcile(draft: &draft, commodities: [euros])
        draft.postings[0].commodityID = dollars.id
        draft.postings[1].commodityID = nil

        capture.reconcile(draft: &draft, commodities: [euros, dollars])
        XCTAssertEqual(draft.postings.map(\.commodityID), [dollars.id, nil])
    }

    func testJournalChangeRequiresItsOwnCurrencyAndClearsOldAccounts() {
        let firstJournal = UUID(), nextJournal = UUID()
        let firstEuros = Commodity(ledgerID: firstJournal, symbol: "EUR", name: "Euro")
        let nextEuros = Commodity(ledgerID: nextJournal, symbol: "EUR", name: "Euro")
        var draft = draft(ledgerID: firstJournal, currencyID: firstEuros.id)
        var capture = IncomingCaptureCurrency(code: "EUR", draft: draft)
        draft.ledgerID = nextJournal

        XCTAssertTrue(capture.preventsSaving(draft: draft, commodities: [firstEuros, nextEuros]))
        capture.reconcile(draft: &draft, commodities: [firstEuros])
        XCTAssertTrue(capture.preventsSaving(draft: draft, commodities: [firstEuros]))
        XCTAssertTrue(draft.postings.allSatisfy { $0.accountID == nil && $0.commodityID == nil })

        capture.reconcile(draft: &draft, commodities: [firstEuros, nextEuros])
        XCTAssertFalse(capture.preventsSaving(draft: draft, commodities: [firstEuros, nextEuros]))
        XCTAssertEqual(draft.postings.map(\.commodityID), [nextEuros.id, nextEuros.id])
        XCTAssertEqual(draft.postings.map(\.amount), ["-42.50", "42.50"])
    }

    func testNoJournalCannotResolveAndReceiptOnlyEntryKeepsAccountCurrencyBehavior() {
        let ledgerID = UUID()
        let euros = Commodity(ledgerID: ledgerID, symbol: "EUR", name: "Euro")
        var unresolved = draft(ledgerID: nil)
        var capture = IncomingCaptureCurrency(code: "EUR", draft: unresolved)
        capture.reconcile(draft: &unresolved, commodities: [euros])
        XCTAssertTrue(capture.preventsSaving(draft: unresolved, commodities: [euros]))
        XCTAssertTrue(unresolved.postings.allSatisfy { $0.commodityID == nil })

        var receipt = draft(ledgerID: ledgerID, currencyID: euros.id)
        var receiptCurrency = IncomingCaptureCurrency(code: "", draft: receipt)
        receiptCurrency.reconcile(draft: &receipt, commodities: [euros])
        XCTAssertEqual(receipt.postings.map(\.commodityID), [euros.id, euros.id])
        receipt.ledgerID = UUID()
        receiptCurrency.reconcile(draft: &receipt, commodities: [euros])
        XCTAssertTrue(receipt.postings.allSatisfy { $0.accountID == nil && $0.commodityID == nil })
        XCTAssertFalse(receiptCurrency.preventsSaving(draft: receipt, commodities: [euros]))
    }
}
