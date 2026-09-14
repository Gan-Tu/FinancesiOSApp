import CloudKit
import Foundation
import XCTest
#if os(iOS)
import SwiftUI
import UIKit
#endif

@testable import FinancesClone

private actor AssistTestTransport: CloudKitSyncTransport {
    var identity = "test-user"
    var rows: [CloudKitSyncRecord] = []
    var failing = false
    func accountIdentifier() async throws -> String { identity }
    func prepareZone() async throws {}
    func fetchChanges(since: Data?) async throws -> CloudKitSyncPage {
        if failing { throw AssistError.message("Offline") }
        return .init(records: rows, changeToken: nil, moreComing: false)
    }
    func modifyRecords(_ records: [CloudKitSyncRecord]) async throws -> CloudKitSyncModifyResult {
        for record in records {
            rows.removeAll { $0.recordID == record.recordID }
            rows.append(record)
        }
        return .init(saved: records, conflicts: [])
    }
    func setFailing(_ value: Bool) { failing = value }
    func setRows(_ values: [CloudKitSyncRecord]) { rows = values }
    func switchAccount() {
        identity = "another-user"
        rows = []
    }
    nonisolated func cancel() {}
}
@MainActor final class ReceiptAssistTests: XCTestCase {
    private func metadata() -> PaymentAccountMetadata {
        .init(
            id: UUID(), ledgerID: UUID(),
            identities: [
                .init(label: "Target", network: nil, last4: "0414"),
                .init(label: "Wallet", network: "visa", last4: "0691"),
            ])
    }
    func testWebCompatibleMetadataPreservesMultipleCardsAndLeadingZeros() throws {
        let value = metadata()
        let record = try value.record(previous: nil)
        XCTAssertEqual(try PaymentAccountMetadata.decode(record), value)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(record.payloadJSON!.utf8)) as? [String: Any])
        let cards = try XCTUnwrap(json["identities"] as? [[String: Any]])
        XCTAssertTrue(cards[0]["network"] is NSNull)
        XCTAssertEqual(cards[0]["last4"] as? String, "0414")
        var corrupted = record
        corrupted.payloadJSON = "{}"
        XCTAssertThrowsError(try PaymentAccountMetadata.decode(corrupted))
    }
    func testJournalZoneRejectsAssistRecordsAndAssistZoneRejectsJournalRecords() throws {
        let journal = CloudKitSyncRecordCodec(
            zoneID: .init(zoneName: "FinancesJournal_v1", ownerName: CKCurrentUserDefaultName))
        let assist = CloudKitSyncRecordCodec(
            zoneID: .init(zoneName: "FinancesAssist_v1", ownerName: CKCurrentUserDefaultName))
        XCTAssertThrowsError(try journal.recordID(type: "assist_account", id: UUID().uuidString))
        XCTAssertThrowsError(try assist.recordID(type: "transaction", id: UUID().uuidString))
        XCTAssertNoThrow(try assist.recordID(type: "assist_account", id: UUID().uuidString))
    }
    func testOfflinePendingWritesConflictsAndAccountIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = AssistTestTransport()
        let value = metadata()
        let store = PaymentMetadataStore(directory: directory, network: network)
        await store.refresh()
        XCTAssertTrue(store.error.isEmpty)
        await network.setFailing(true)
        try await store.save(value, expected: nil)
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertEqual(store.metadata[value.id], value)
        await network.setFailing(false)
        let restored = PaymentMetadataStore(directory: directory, network: network)
        await restored.refresh()
        XCTAssertEqual(restored.pendingCount, 0)
        XCTAssertEqual(restored.metadata[value.id], value)
        var remote = value
        remote.identities[0].label = "Edited on web"
        await network.setFailing(true)
        var local = value
        local.identities[0].label = "Edited locally"
        try await restored.save(local, expected: value)
        await network.setRows([try remote.record(previous: nil)])
        await network.setFailing(false)
        await restored.refresh()
        XCTAssertTrue(restored.conflicts.contains(value.id))
        XCTAssertEqual(restored.metadata[value.id], local)
        try await restored.resolve(value.id, keepLocal: false)
        XCTAssertEqual(restored.metadata[value.id], remote)
        await network.switchAccount()
        await restored.refresh()
        XCTAssertTrue(restored.metadata.isEmpty)
    }
    func testPartialCategoriesAndUserEditsArePreserved() throws {
        let ledger = UUID()
        let parent = UUID()
        let currency = Commodity(ledgerID: ledger, symbol: "USD", name: "Dollar")
        let expense = Account(
            ledgerID: ledger, parentID: parent, commodityID: currency.id, name: "Groceries", kind: .expense)
        let json = """
            {"suggestion":{"date":null,"note":"Fresh Groceries","payee":"Market","invoiceNumber":null,"orderNumber":null,"postings":[{"accountID":"\(expense.id)","commodityID":"\(currency.id)","amount":"12.30","role":"counter"}],"warnings":[]},"postingsApplicable":false}
            """
        let response = try JSONDecoder().decode(ReceiptAnalysisResponse.self, from: Data(json.utf8))
        let proposal = try ReceiptDraftProposal.make(response, accounts: [expense], commodities: [currency])
        XCTAssertNil(proposal.postings?.first?.accountID)
        XCTAssertEqual(proposal.postings?.last?.accountID, expense.id)
        let initial = TransactionDraft()
        var current = initial
        current.note = "My own note"
        let replacements = proposal.autofill(&current, initial: initial, protected: [.note])
        XCTAssertEqual(current.note, "My own note")
        XCTAssertEqual(current.payee, "Market")
        XCTAssertEqual(replacements, [.note])
        XCTAssertEqual(current.postings.last?.amount, "12.30")
    }
    func testBackupRestorationAndDeletedMetadataRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = AssistTestTransport()
        let value = metadata()
        let store = PaymentMetadataStore(directory: directory, network: network)
        await store.refresh()
        try await store.save(value, expected: nil)
        let backup = try store.backup()
        var deleted = try value.record(previous: nil)
        deleted.operation = "delete"
        deleted.payloadJSON = nil
        await network.setRows([deleted])
        await store.refresh()
        XCTAssertNil(store.metadata[value.id])
        let account = Account(
            id: value.id, ledgerID: value.ledgerID, parentID: UUID(), name: "Test", kind: .asset)
        try await store.restore(backup, validAccounts: [account])
        XCTAssertEqual(store.metadata[value.id], value)
        XCTAssertEqual(store.pendingCount, 0)
        let rows = await network.rows
        XCTAssertEqual(rows.first?.operation, "upsert")
        var changed = value
        changed.identities[0].last4 = "1234"
        try await store.save(changed, expected: value)
        do {
            try await store.restore(backup, validAccounts: [account])
            XCTFail("Must preserve later edits")
        } catch { XCTAssertEqual(store.metadata[value.id], changed) }
    }

    func testAttachmentCountLimitAndModelEfforts() throws {
        let asset = AttachmentAsset(originalFilename: "image.png", storedPath: "image.png", sizeBytes: 1)
        XCTAssertThrowsError(
            try ReceiptAnalysisClient.multipart(
                context: Data(),
                assets: Array(repeating: (asset, URL(fileURLWithPath: "/missing.png")), count: 11),
                boundary: "test"))
        var settings = ReceiptAISettings()
        XCTAssertEqual(settings.model, "gpt-5.6-terra")
        XCTAssertEqual(settings.effort, "medium")
        settings.model = "gpt-6-astra"
        XCTAssertFalse(settings.efforts.contains("none"))
    }
}

@MainActor final class ReceiptAssistLiveIntegrationTests: XCTestCase {
    func testSyntheticReceiptThroughLocalAPI() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["FINANCES_AI_INTEGRATION_URL"],
            let path = ProcessInfo.processInfo.environment["FINANCES_AI_INTEGRATION_PDF"]
        else { throw XCTSkip("Opt-in synthetic local API integration") }
        let ledger = UUID()
        let root = UUID()
        let currency = Commodity(ledgerID: ledger, symbol: "USD", name: "Dollar")
        let source = Account(
            ledgerID: ledger, parentID: root, commodityID: currency.id, name: "Test Visa", kind: .liability)
        let counter = Account(
            ledgerID: ledger, parentID: root, commodityID: currency.id, name: "Groceries", kind: .expense)
        let identity = PaymentAccountMetadata(
            id: source.id, ledgerID: ledger,
            identities: [.init(label: "Test Visa", network: "visa", last4: "0414")])
        let url = URL(fileURLWithPath: path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let asset = AttachmentAsset(
            originalFilename: "Synthetic Receipt.pdf", storedPath: path, mimeType: "application/pdf",
            sizeBytes: Int64(size))
        var settings = ReceiptAISettings()
        settings.endpoint = endpoint
        let result = try await ReceiptAnalysisClient().analyze(
            draft: TransactionDraft(ledgerID: ledger), ledgerID: ledger,
            accounts: [source, counter], commodities: [currency], metadata: [source.id: identity],
            assets: [(asset, url)], settings: settings)
        let proposed = try ReceiptDraftProposal.make(
            result, accounts: [source, counter], commodities: [currency])
        XCTAssertEqual(proposed.payee, "Example Market")
        XCTAssertTrue(proposed.postings?.contains { $0.accountID == source.id } == true)
        XCTAssertTrue(proposed.postings?.contains { $0.accountID == counter.id } == true)
    }
}

@MainActor private final class MemoryReceiptCredentials: ReceiptCredentialStore {
    var values: [String: Data] = [:]
    func load(endpoint: String) throws -> ReceiptSessionCredential? {
        try values[endpoint].map { try JSONDecoder().decode(ReceiptSessionCredential.self, from: $0) }
    }
    func save(_ value: ReceiptSessionCredential, endpoint: String) throws {
        values[endpoint] = try JSONEncoder().encode(value)
    }
    func remove(endpoint: String) throws { values[endpoint] = nil }
}
extension ReceiptAssistTests {
    private func syntheticSession() throws -> ReceiptSessionCredential {
        let data = try JSONSerialization.data(withJSONObject: [
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970
        ])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try ReceiptSessionCredential(token: "test.\(payload).synthetic")
    }
    func testReceiptSessionRestoresAcrossClientInstances() throws {
        let store = MemoryReceiptCredentials()
        try store.save(syntheticSession(), endpoint: "https://finances.tugan.app")
        let first = ReceiptAnalysisClient(credentialStore: store)
        try first.restoreSession(endpoint: "https://finances.tugan.app/")
        XCTAssertTrue(first.authenticated)
        let relaunched = ReceiptAnalysisClient(credentialStore: store)
        try relaunched.restoreSession(endpoint: "https://finances.tugan.app")
        XCTAssertTrue(relaunched.authenticated)
    }
    func testReceiptSessionIsScopedToTheAPIServer() throws {
        let store = MemoryReceiptCredentials()
        try store.save(syntheticSession(), endpoint: "https://finances.tugan.app")
        let client = ReceiptAnalysisClient(credentialStore: store)
        try client.restoreSession(endpoint: "https://finances.tugan.app")
        XCTAssertTrue(client.authenticated)
        try client.restoreSession(endpoint: "https://another.example")
        XCTAssertFalse(client.authenticated)
        try client.restoreSession(endpoint: "https://finances.tugan.app")
        XCTAssertTrue(client.authenticated)
    }
    func testExpiredReceiptSessionIsRemovedInsteadOfRestored() throws {
        let store = MemoryReceiptCredentials()
        var value = try syntheticSession()
        value.expiresAt = Date().addingTimeInterval(-1)
        try store.save(value, endpoint: "https://finances.tugan.app")
        let client = ReceiptAnalysisClient(credentialStore: store)
        try client.restoreSession(endpoint: "https://finances.tugan.app")
        XCTAssertFalse(client.authenticated)
        XCTAssertTrue(store.values.isEmpty)
    }
    func testAccountChangeClearsPersistedReceiptSession() async throws {
        let store = MemoryReceiptCredentials()
        try store.save(syntheticSession(), endpoint: "https://finances.tugan.app")
        let client = ReceiptAnalysisClient(credentialStore: store)
        try client.restoreSession(endpoint: "https://finances.tugan.app")
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        for _ in 0..<20 where client.authenticated { await Task.yield() }
        XCTAssertFalse(client.authenticated)
        XCTAssertTrue(store.values.isEmpty)
    }
    func testReceiptSessionKeychainRoundTrip() throws {
        #if SWIFT_PACKAGE
            throw XCTSkip("Keychain requires a signed app test host; covered by the iOS app-hosted test.")
        #else
            let store = ReceiptKeychainStore()
            let endpoint = "https://synthetic-" + UUID().uuidString.lowercased() + ".invalid"
            defer { try? store.remove(endpoint: endpoint) }
            let value = try syntheticSession()
            try store.save(value, endpoint: endpoint)
            XCTAssertEqual(try store.load(endpoint: endpoint)?.token, value.token)
            try store.remove(endpoint: endpoint)
            XCTAssertNil(try store.load(endpoint: endpoint))
        #endif
    }
}

extension ReceiptAssistTests {
    private func accountChoiceFixture() throws -> (ReceiptAnalysisResponse, TransactionDraft, [Account], Commodity) {
        let ledger = UUID(), parent = UUID()
        let currency = Commodity(ledgerID: ledger, symbol: "USD", name: "US Dollar")
        let bank = Account(ledgerID: ledger, parentID: parent, commodityID: currency.id, name: "AMEX Platinum", kind: .liability)
        let other = Account(ledgerID: ledger, parentID: parent, commodityID: currency.id, name: "BoA Premium Rewards", kind: .asset)
        let expense = Account(ledgerID: ledger, parentID: parent, commodityID: currency.id, name: "Dining", kind: .expense)
        let response = ReceiptAnalysisResponse(suggestion: .init(postings: [
            .init(accountID: nil, commodityID: currency.id, amount: "-52.14", role: "source"),
            .init(accountID: expense.id, commodityID: currency.id, amount: "52.14", role: "counter"),
        ], warnings: []), postingsApplicable: false)
        var draft = TransactionDraft(ledgerID: ledger)
        draft.postings = [PostingDraft(accountID: bank.id, amount: "-52.140", commodityID: currency.id),
                          PostingDraft(accountID: expense.id, amount: "52.14", commodityID: currency.id)]
        return (response, draft, [bank, other, expense], currency)
    }
    func testReviewKeepsCurrentAccountAndAppliesChosenReplacementOnlyOnRequest() throws {
        let (response, initial, accounts, currency) = try accountChoiceFixture()
        var proposal = try ReceiptDraftProposal.make(response, accounts: accounts, commodities: [currency])
        proposal.keepCurrentAccountsForReview(response: response, current: initial, accounts: accounts)
        XCTAssertEqual(proposal.postings?.first?.accountID, accounts[0].id)
        proposal.postings?[0].accountID = accounts[1].id
        XCTAssertEqual(initial.postings[0].accountID, accounts[0].id)
        var applied = initial
        proposal.apply(.postings, to: &applied)
        XCTAssertEqual(applied.postings[0].accountID, accounts[1].id)
        XCTAssertEqual(applied.postings[0].amount, "-52.14")
        XCTAssertEqual(applied.postings[1].accountID, accounts[2].id)
        XCTAssertEqual(applied.postings[1].amount, "52.14")
    }
    func testReviewDoesNotGuessAcrossAccountsOrCurrencies() throws {
        let (response, initial, accounts, currency) = try accountChoiceFixture()
        var ambiguous = initial
        ambiguous.postings.append(PostingDraft(accountID: accounts[1].id, amount: "-52.14", commodityID: currency.id))
        var proposal = try ReceiptDraftProposal.make(response, accounts: accounts, commodities: [currency])
        proposal.keepCurrentAccountsForReview(response: response, current: ambiguous, accounts: accounts)
        XCTAssertNil(proposal.postings?.first?.accountID)
        var foreign = initial
        foreign.postings[0].commodityID = UUID()
        proposal.keepCurrentAccountsForReview(response: response, current: foreign, accounts: accounts)
        XCTAssertNil(proposal.postings?.first?.accountID)
    }
    #if os(iOS)
    func testReceiptAccountChoicesFitNarrowLayout() async throws {
        let (_, draft, accounts, currency) = try accountChoiceFixture()
        let root = ReceiptPostingTable(title: "Suggested", postings: draft.postings, accounts: accounts,
            commodities: [currency], ledgerID: try XCTUnwrap(draft.ledgerID), onAccountChange: { _, _ in })
            .padding().font(.caption)
        let controller = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 340, height: 240)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Receipt account choices on narrow layout"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(controller.sizeThatFits(in: CGSize(width: 340, height: 1000)).height, 240)
    }
    #endif
}
