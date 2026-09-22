import XCTest
import Security
@testable import FinancesClone

@MainActor
final class SharedReceiptAITests: XCTestCase {
    private func fixture() -> (SharedTransactionCatalog, SharedTransaction, ReceiptAnalysisResponse) {
        let data = DemoData.fixture()
        var catalog = SharedTransactionCatalog(data: data, hiddenLedgerIDs: [])
        var settings = ReceiptAISettings(); settings.model = "gpt-6-luna"; settings.effort = "low"
        settings.instructions = "Preserve merchant spelling."
        catalog.receiptAI = .init(settings: settings)
        let draft = SharedTransaction(catalog: catalog)
        let response = ReceiptAnalysisResponse(suggestion: .init(date: nil, payee: "Receipt Cafe", note: "Coffee", invoiceNumber: "123", orderNumber: nil,
            postings: [.init(accountID: draft.postings[0].accountID, commodityID: draft.postings[0].currencyID, amount: "-18.75", role: "source"),
                       .init(accountID: draft.postings[1].accountID, commodityID: draft.postings[1].currencyID, amount: "18.75", role: "counter")], warnings: []), postingsApplicable: true)
        return (catalog, draft, response)
    }

    func testAutofillUsesMainEditorPolicyAndPreservesUserEdits() throws {
        let (catalog, initial, response) = fixture()
        var edited = initial
        edited.note = "My own notes"
        edited.cleared = false
        edited.recurrence = RecurrenceRule(frequency: .monthly, occurrenceCount: 3)
        let proposal = try SharedReceiptAutofill.proposal(response, catalog: catalog, journalID: XCTUnwrap(edited.journalID))
        let replacements = SharedReceiptAutofill.apply(proposal, to: &edited, initial: initial.draft(operationID: UUID()), protected: [.note])
        XCTAssertEqual(replacements, [.note])
        XCTAssertEqual(edited.note, "My own notes")
        XCTAssertEqual(edited.payee, "Receipt Cafe")
        XCTAssertEqual(edited.number, "123")
        XCTAssertEqual(edited.postings.map(\.amount), ["-18.75", "18.75"])
        XCTAssertFalse(edited.cleared)
        XCTAssertEqual(edited.date, initial.date)
        XCTAssertEqual(edited.recurrence?.frequency, .monthly)
        try edited.validate(in: catalog)
    }

    func testFieldsChangedWhileRequestIsRunningRequireReview() throws {
        let (catalog, initial, response) = fixture()
        var current = initial; current.payee = "Typed while waiting"; current.setAmount("-25", at: 0)
        let proposal = try SharedReceiptAutofill.proposal(response, catalog: catalog, journalID: XCTUnwrap(current.journalID))
        let review = SharedReceiptAutofill.apply(proposal, to: &current, initial: initial.draft(operationID: UUID()), protected: [.payee, .postings])
        XCTAssertTrue(review.contains(.payee)); XCTAssertTrue(review.contains(.postings))
        XCTAssertEqual(current.payee, "Typed while waiting"); XCTAssertEqual(current.postings[0].amount, "-25")
        XCTAssertEqual(current.note, "Coffee")
    }

    func testAutofillRejectsUnknownAndOtherJournalAccounts() throws {
        let (catalog, draft, result) = fixture()
        var response = result
        response.suggestion.postings[0].accountID = UUID()
        XCTAssertThrowsError(try SharedReceiptAutofill.proposal(response, catalog: catalog, journalID: XCTUnwrap(draft.journalID)))
        response = result; response.suggestion.postings[1].commodityID = UUID()
        XCTAssertThrowsError(try SharedReceiptAutofill.proposal(response, catalog: catalog, journalID: XCTUnwrap(draft.journalID)))
    }

    func testAutofillWithAccountCurrencyCanBeSavedAndBalanced() throws {
        let (catalog, initial, original) = fixture()
        var response = original
        response.suggestion.postings = response.suggestion.postings.map { row in
            var row = row; row.commodityID = nil; return row
        }
        var draft = initial
        let proposal = try SharedReceiptAutofill.proposal(response, catalog: catalog, journalID: XCTUnwrap(draft.journalID))
        _ = SharedReceiptAutofill.apply(proposal, to: &draft, initial: initial.draft(operationID: UUID()), protected: [])
        try draft.validate(in: catalog)
        draft.setAmount("-23", at: 0, catalog: catalog)
        XCTAssertEqual(draft.postings[1].amount, "23")
        try draft.validate(in: catalog)
    }

    func testSharedContextUsesConfiguredModelEffortInstructionsAndAccountColors() throws {
        let (catalog, draft, _) = fixture()
        let journal = try XCTUnwrap(draft.journalID)
        let context = try ReceiptAnalysisClient.context(draft: draft.draft(operationID: UUID()), ledgerID: journal,
            accounts: catalog.nativeAccounts(journalID: journal), commodities: catalog.nativeCurrencies(journalID: journal),
            metadata: [:], settings: XCTUnwrap(catalog.receiptAI?.settings))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: context) as? [String: Any])
        XCTAssertEqual(json["surface"] as? String, "ios")
        XCTAssertEqual(json["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(json["effort"] as? String, "low")
        XCTAssertEqual(json["instructions"] as? String, "Preserve merchant spelling.")
        let rows = try XCTUnwrap(json["accounts"] as? [[String: Any]])
        XCTAssertTrue(rows.allSatisfy { $0["ledgerID"] as? String == journal.uuidString })
        XCTAssertTrue(catalog.accounts.allSatisfy { $0.colorName != nil && $0.parentID != nil })
        let decoded = try JSONDecoder().decode(SharedTransactionCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded, catalog)
    }

    func testOldCatalogAndSavedTransactionsRemainReadable() throws {
        let (catalog, draft, _) = fixture()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any])
        json.removeValue(forKey: "receiptAI")
        json["accounts"] = (json["accounts"] as! [[String: Any]]).map { row in
            var row = row; row.removeValue(forKey: "colorName"); row.removeValue(forKey: "parentID"); return row
        }
        let old = try JSONDecoder().decode(SharedTransactionCatalog.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.receiptAI)
        XCTAssertEqual(old.nativeAccounts(journalID: try XCTUnwrap(draft.journalID)).count, catalog.nativeAccounts(journalID: draft.journalID!).count)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        saved.removeValue(forKey: "recurrence")
        XCTAssertNil(try JSONDecoder().decode(SharedTransaction.self, from: JSONSerialization.data(withJSONObject: saved)).recurrence)
    }

    func testLegacySignInMigratesToSharedKeychainAndRemovalDoesNotRestoreIt() throws {
        let service = "synthetic-share-" + UUID().uuidString
        let endpoint = "https://synthetic.invalid"
        let legacy = ReceiptKeychainStore(service: service, accessGroup: nil)
        let shared = ReceiptKeychainStore(service: service)
        defer { try? shared.remove(endpoint: endpoint) }
        let value = try SharedReceiptAnalysis.syntheticCredential()
        try legacy.save(value, endpoint: endpoint)
        XCTAssertEqual(try shared.load(endpoint: endpoint)?.token, value.token)
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: endpoint, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain as String: true]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let rows = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?[kSecAttrAccessGroup as String] as? String, SharedReceiptStorage.groupIdentifier)
        try shared.remove(endpoint: endpoint)
        XCTAssertNil(try shared.load(endpoint: endpoint))
        XCTAssertNil(try legacy.load(endpoint: endpoint))
    }
}
