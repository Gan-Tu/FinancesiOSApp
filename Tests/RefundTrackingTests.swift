import Foundation
import XCTest
@testable import FinancesClone

final class RefundTrackingTests: XCTestCase {
    func testPartialPaymentsSettleWithoutChangingAnyTransaction() throws {
        let f = RefundFixture()
        var data = try RefundTracking.saving(f.draft, in: f.data)
        XCTAssertEqual(RefundTracking.overview(in: data, ledgerID: f.ledger.id).outstandingByCurrency, [f.usd.id: 100])
        data = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 60, in: data)
        XCTAssertEqual(try summary(data, f).receivedAmount, 60)
        XCTAssertEqual(try summary(data, f).outstandingAmount, 40)
        data = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund40.id, amount: 40, in: data)
        XCTAssertTrue(try summary(data, f).isSettled)
        XCTAssertEqual(data.transactions, f.data.transactions, "Tracking must never rewrite money, dates, recurrence, notes or receipts")
        // Repeating the operation after a disk failure replaces the same link.
        data = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund40.id, amount: 40, in: data)
        XCTAssertEqual(try RefundTracking.record(for: f.purchase.id, in: data)?.links.count, 2)
        XCTAssertEqual(data.sources.count, 1)
    }

    func testAllocationCannotDoubleCountIncomingPaymentAcrossPurchases() throws {
        let f = RefundFixture()
        var data = try RefundTracking.saving(f.draft, in: f.data)
        var secondDraft = f.draft; secondDraft.purchaseTransactionID = f.secondPurchase.id
        secondDraft.kind = .reimbursement; secondDraft.person = "Friend"
        data = try RefundTracking.saving(secondDraft, in: data)
        data = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 40, in: data)
        XCTAssertThrowsError(try RefundTracking.linking(purchaseID: f.secondPurchase.id, incomingTransactionID: f.refund60.id, amount: 21, in: data))
        data = try RefundTracking.linking(purchaseID: f.secondPurchase.id, incomingTransactionID: f.refund60.id, amount: 20, in: data)
        XCTAssertEqual(RefundTracking.overview(in: data, ledgerID: f.ledger.id).outstandingByCurrency[f.usd.id], 140)
        data = try RefundTracking.cancelling(purchaseID: f.purchase.id, in: data)
        data = try RefundTracking.linking(purchaseID: f.secondPurchase.id, incomingTransactionID: f.refund60.id, amount: 60, in: data)
        XCTAssertThrowsError(try RefundTracking.saving(f.draft, in: data), "Resuming cancelled tracking must recheck released allocations")
        XCTAssertEqual(data.transactions, f.data.transactions)
    }

    func testRejectsFXTransfersFuturePaymentsInvalidAmountsAndOverExpected() throws {
        let f = RefundFixture()
        let data = try RefundTracking.saving(f.draft, in: f.data)
        for amount in [Decimal.zero, -1, Decimal.nan, 101] {
            XCTAssertThrowsError(try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: amount, in: data))
        }
        XCTAssertThrowsError(try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.euroRefund.id, amount: 10, in: data))
        XCTAssertThrowsError(try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.transfer.id, amount: 10, in: data))
        var future = data
        future.transactions[future.transactions.firstIndex(where: { $0.id == f.refund60.id })!].date = Date.distantFuture
        XCTAssertThrowsError(try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 10, in: future))
        var invalidDraft = f.draft; invalidDraft.expectedAmount = 0
        XCTAssertThrowsError(try RefundTracking.saving(invalidDraft, in: data))
        invalidDraft = f.draft; invalidDraft.commodityID = f.eur.id
        XCTAssertThrowsError(try RefundTracking.saving(invalidDraft, in: data), "Do not infer a purchase amount in another currency")
        let linked = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 60, in: data)
        invalidDraft = f.draft; invalidDraft.expectedAmount = 50
        XCTAssertThrowsError(try RefundTracking.saving(invalidDraft, in: linked), "Expected amount cannot silently fall below linked payments")
    }

    func testOrphanMovedAndChangedIncomingAmountsRequireAttentionAndCanBeRepaired() throws {
        let f = RefundFixture()
        var data = try RefundTracking.saving(f.draft, in: f.data)
        data = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 60, in: data)
        var changed = data
        let index = changed.transactions.firstIndex(where: { $0.id == f.refund60.id })!
        changed.transactions[index].postings[0].amount = 50
        changed.transactions[index].postings[1].amount = -50
        XCTAssertNil(try summary(changed, f).outstandingAmount)
        XCTAssertFalse(try summary(changed, f).issues.isEmpty)
        XCTAssertTrue(RefundTracking.overview(in: changed, ledgerID: f.ledger.id).outstandingByCurrency.isEmpty)
        changed = try RefundTracking.unlinking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, in: changed)
        XCTAssertEqual(try summary(changed, f).outstandingAmount, 100)
        var deleted = data; deleted.transactions.removeAll { $0.id == f.refund60.id }
        XCTAssertNil(try summary(deleted, f).receivedAmount)
        deleted = try RefundTracking.unlinking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, in: deleted)
        XCTAssertEqual(try summary(deleted, f).outstandingAmount, 100)
        var moved = data
        moved.transactions[moved.transactions.firstIndex(where: { $0.id == f.purchase.id })!].ledgerID = UUID()
        XCTAssertNil(try summary(moved, f).outstandingAmount)
        XCTAssertThrowsError(try RefundTracking.saving(f.draft, in: moved))
        XCTAssertTrue(try RefundTracking.removing(purchaseID: f.purchase.id, in: moved).sources.isEmpty)
    }

    func testConcurrentRemoteAllocationsAreFlaggedInsteadOfDoubleCounted() throws {
        let f = RefundFixture()
        var first = try RefundTracking.saving(f.draft, in: f.data)
        first = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 60, in: first)
        var otherDraft = f.draft; otherDraft.purchaseTransactionID = f.secondPurchase.id
        var second = try RefundTracking.saving(otherDraft, in: f.data)
        second = try RefundTracking.linking(purchaseID: f.secondPurchase.id, incomingTransactionID: f.refund60.id, amount: 60, in: second)
        var merged = first; merged.sources += second.sources
        let overview = RefundTracking.overview(in: merged, ledgerID: f.ledger.id)
        XCTAssertEqual(overview.summaries.count, 2)
        XCTAssertTrue(overview.summaries.allSatisfy { !$0.issues.isEmpty && $0.receivedAmount == nil })
        XCTAssertTrue(overview.outstandingByCurrency.isEmpty)
        merged = try RefundTracking.unlinking(purchaseID: f.secondPurchase.id, incomingTransactionID: f.refund60.id, in: merged)
        XCTAssertTrue(RefundTracking.overview(in: merged, ledgerID: f.ledger.id).summaries.allSatisfy { $0.issues.isEmpty })
    }

    func testExistingSourceFormatAndExplicitCloneRemappingPreserveTracking() throws {
        let f = RefundFixture()
        var data = try RefundTracking.saving(f.draft, in: f.data)
        data = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 20, in: data)
        let source = try XCTUnwrap(data.sources.first)
        // This is the pre-feature source schema already used by Mac. Its
        // decode/encode cycle must preserve the opaque string byte-for-byte.
        struct LegacySource: Codable {
            let id: UUID; let ledgerID: UUID; let type: Int; let date: Date?; let externalID: String?
        }
        let old = try JSONDecoder.appDecoder.decode(LegacySource.self, from: JSONEncoder.appEncoder.encode(source))
        let roundTrip = try JSONDecoder.appDecoder.decode(TransactionSource.self, from: JSONEncoder.appEncoder.encode(old))
        XCTAssertEqual(roundTrip, source)
        XCTAssertEqual(try RefundTracking.decode(roundTrip), try RefundTracking.decode(source))
        let ids = Dictionary(uniqueKeysWithValues: [f.ledger.id, f.purchase.id, f.refund60.id, f.usd.id].map { ($0, UUID()) })
        let remapped = try XCTUnwrap(RefundTracking.decode(RefundTracking.remapping(source, using: ids)))
        XCTAssertEqual(remapped.purchaseTransactionID, ids[f.purchase.id])
        XCTAssertEqual(remapped.ledgerID, ids[f.ledger.id])
        XCTAssertEqual(remapped.commodityID, ids[f.usd.id])
        XCTAssertEqual(remapped.links.first?.transactionID, ids[f.refund60.id])
        XCTAssertEqual(remapped.links.first?.amount, 20)
        XCTAssertThrowsError(try RefundTracking.remapping(source, using: [:]))
        var oldMacClone = source; oldMacClone.id = UUID(); oldMacClone.ledgerID = UUID()
        XCTAssertThrowsError(try RefundTracking.decode(oldMacClone), "An old client's opaque clone must not be silently associated with original transactions")
    }

    func testUnreadableMetadataDoesNotSilentlyReportSettled() throws {
        let f = RefundFixture()
        var data = try RefundTracking.saving(f.draft, in: f.data)
        data.sources[0].externalID = RefundTracking.externalIDPrefix + "{}"
        let overview = RefundTracking.overview(in: data, ledgerID: f.ledger.id)
        XCTAssertFalse(overview.issues.isEmpty)
        XCTAssertThrowsError(try RefundTracking.record(for: f.purchase.id, in: data))
        XCTAssertTrue(try RefundTracking.removing(purchaseID: f.purchase.id, in: data).sources.isEmpty)
    }

    private func summary(_ data: JournalData, _ f: RefundFixture) throws -> RefundTrackingSummary {
        try XCTUnwrap(RefundTracking.overview(in: data, ledgerID: f.ledger.id).summaries.first { $0.record.purchaseTransactionID == f.purchase.id })
    }
}

@MainActor
final class RefundTrackingPersistenceTests: XCTestCase {
    private var stores: [MobileLedgerStore] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for store in stores { await store.waitForCloudKitSyncIdle() }
        stores.removeAll()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    func testReadPresentationMatchesDomainAndReusesRevisionWithoutStalePaymentCapacity() async throws {
        let f = RefundFixture()
        var data = try RefundTracking.saving(f.draft, in: f.data)
        data = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 40, in: data)
        var otherDraft = f.draft; otherDraft.purchaseTransactionID = f.secondPurchase.id
        data = try RefundTracking.saving(otherDraft, in: data)
        data = try RefundTracking.linking(purchaseID: f.secondPurchase.id, incomingTransactionID: f.refund60.id, amount: 20, in: data)
        let cache = RefundPresentationCache()
        let presentation = try await cache.presentation(data: data, ledgerID: f.ledger.id, revision: 1)
        let again = try await cache.presentation(data: data, ledgerID: f.ledger.id, revision: 1)
        XCTAssertEqual(presentation.id, again.id)
        let record = try XCTUnwrap(presentation.recordsByPurchase[f.purchase.id])
        let candidates = try await cache.candidates(in: presentation, record: record, matching: "refund")
        XCTAssertEqual(Set(candidates.map(\.id)), [f.refund60.id, f.refund40.id])
        let partial = try XCTUnwrap(candidates.first { $0.id == f.refund60.id })
        XCTAssertEqual(presentation.available(partial, for: record), 40, "The other purchase's allocation must be excluded")
        let expected = RefundTracking.overview(in: data, ledgerID: f.ledger.id)
        for summary in expected.summaries {
            let actual = try XCTUnwrap(presentation.summariesByPurchase[summary.record.purchaseTransactionID])
            XCTAssertEqual(actual.receivedAmount, summary.receivedAmount)
            XCTAssertEqual(actual.outstandingAmount, summary.outstandingAmount)
            XCTAssertEqual(actual.issues, summary.issues)
        }
        data.transactions.removeAll { $0.id == f.refund60.id }
        let updated = try await cache.presentation(data: data, ledgerID: f.ledger.id, revision: 2)
        XCTAssertNotEqual(updated.id, presentation.id)
        XCTAssertNil(updated.summariesByPurchase[f.purchase.id]?.outstandingAmount)
        let updatedCandidates = try await cache.candidates(in: updated, record: record, matching: "refund")
        XCTAssertEqual(updatedCandidates.map(\.id), [f.refund40.id])
    }

    func testAsyncSaveLinkUnlinkCancelReopenAndDiskFailureRetry() async throws {
        let f = RefundFixture(), directory = try directory()
        let store = makeStore(directory, initialData: f.data)
        try await store.flushLocalChangesAsync()
        let saved = await store.saveRefundTrackingAsync(f.draft)
        XCTAssertTrue(saved)
        let linked = await store.linkRefundAsync(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 35)
        XCTAssertTrue(linked)
        let loaded = try XCTUnwrap(store.cloudKitSQLiteStore.loadData())
        XCTAssertEqual(loaded.transactions, f.data.transactions)
        XCTAssertEqual(try RefundTracking.record(for: f.purchase.id, in: loaded)?.links.first?.amount, 35)
        let reopened = makeStore(directory)
        XCTAssertEqual(try reopened.refundTracking(for: f.purchase.id)?.links.first?.amount, 35)
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        try SQLiteWriteAudit.execute("CREATE TRIGGER reject_refund_update BEFORE UPDATE ON sources BEGIN SELECT RAISE(ABORT, 'Synthetic refund write failure'); END", at: store.cloudKitSQLiteStore.databaseURL)
        let failed = await store.linkRefundAsync(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 40)
        XCTAssertFalse(failed)
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(try store.refundTracking(for: f.purchase.id)?.links.first?.amount, 40)
        XCTAssertEqual(try RefundTracking.record(for: f.purchase.id, in: XCTUnwrap(store.cloudKitSQLiteStore.loadData()))?.links.first?.amount, 35)
        try SQLiteWriteAudit.execute("DROP TRIGGER reject_refund_update", at: store.cloudKitSQLiteStore.databaseURL)
        let retry = await store.linkRefundAsync(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 40)
        XCTAssertTrue(retry)
        XCTAssertEqual(store.data.sources.count, 1)
        XCTAssertEqual(try store.refundTracking(for: f.purchase.id)?.links.count, 1)
        let unlinked = await store.unlinkRefundAsync(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id)
        XCTAssertTrue(unlinked)
        let cancelled = await store.cancelRefundTrackingAsync(purchaseID: f.purchase.id)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try RefundTracking.record(for: f.purchase.id, in: XCTUnwrap(store.cloudKitSQLiteStore.loadData()))?.state, .cancelled)
        XCTAssertEqual(store.data.transactions, f.data.transactions)
    }

    func testSQLiteOutboxAndFakeCloudPullCarryOnlyCompatibleSourceMetadata() throws {
        let f = RefundFixture(), firstDirectory = try directory(), secondDirectory = try directory()
        let first = SQLiteJournalStore(databaseURL: firstDirectory.appendingPathComponent("journal.sqlite"))
        let second = SQLiteJournalStore(databaseURL: secondDirectory.appendingPathComponent("journal.sqlite"))
        try first.replaceData(f.data, trackSyncChanges: false)
        try second.replaceData(f.data, trackSyncChanges: false)
        var changed = try RefundTracking.saving(f.draft, in: f.data)
        changed = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 25, in: changed)
        try SQLiteWriteAudit.install(at: first.databaseURL)
        try first.persist(changed, previous: f.data)
        let writes = try SQLiteWriteAudit.counts(at: first.databaseURL)
        XCTAssertNil(writes["transactions"]); XCTAssertNil(writes["postings"])
        let changes = try first.claimPendingSyncChanges(limit: 100)
        XCTAssertEqual(changes.map(\.recordType), ["source"])
        let change = try XCTUnwrap(changes.first)
        let record = CloudKitSyncRecord(recordType: "source", recordID: change.recordID, parentRecordID: f.ledger.id.uuidString,
            contentHash: change.contentHash, payloadJSON: change.payloadJSON, clientChangeID: change.clientChangeID,
            systemFields: Data("Synthetic source CAS".utf8))
        let merged = try CloudKitJournalMerger.applying([record], to: f.data)
        _ = try second.bindCloudKitAccount(contextKey: "refund-synthetic", accountID: "Synthetic")
        try second.persistCloudKitPull([record], data: merged, previous: f.data, contextKey: "refund-synthetic", changeToken: Data("checkpoint".utf8))
        let reloaded = try XCTUnwrap(second.loadData())
        XCTAssertEqual(reloaded.sources, changed.sources)
        XCTAssertEqual(reloaded.transactions, f.data.transactions)
        XCTAssertEqual(RefundTracking.overview(in: reloaded, ledgerID: f.ledger.id).summaries.first?.outstandingAmount, 75)
        // An ordinary older-client transaction edit leaves separate metadata.
        var macEdit = reloaded; macEdit.transactions[0].note = "Edited on an older Mac"
        try second.persist(macEdit, previous: reloaded)
        XCTAssertEqual(try second.loadData()?.sources, changed.sources)
    }

    func testFullZIPBackupRestoresTrackingAndPartialPayments() throws {
        let f = RefundFixture(), workspace = try directory()
        var data = try RefundTracking.saving(f.draft, in: f.data)
        data = try RefundTracking.linking(purchaseID: f.purchase.id, incomingTransactionID: f.refund60.id, amount: 30, in: data)
        let archive = workspace.appendingPathComponent("refund-backup.zip")
        try BackupArchive.export(data, to: archive, progress: Progress(totalUnitCount: 100)) { _ in
            throw ValidationError(message: "Synthetic fixture contains no receipts")
        }
        let restored = try BackupArchive.prepareRestore(from: archive, workspace: workspace.appendingPathComponent("restore"),
            progress: Progress(totalUnitCount: 100), localAttachmentURL: { _ in throw ValidationError(message: "No receipts") }, validate: { _ in })
        XCTAssertEqual(restored.data.sources, data.sources)
        XCTAssertEqual(restored.data.transactions, data.transactions)
        let target = SQLiteJournalStore(databaseURL: workspace.appendingPathComponent("restored.sqlite"))
        try target.replaceData(restored.data, trackSyncChanges: false)
        let reloaded = try XCTUnwrap(target.loadData())
        XCTAssertEqual(RefundTracking.overview(in: reloaded, ledgerID: f.ledger.id).summaries.first?.outstandingAmount, 70)
        XCTAssertEqual(try RefundTracking.record(for: f.purchase.id, in: reloaded)?.note, f.draft.note)
        XCTAssertEqual(try RefundTracking.record(for: f.purchase.id, in: reloaded)?.dueDate, f.draft.dueDate)
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RefundTrackingTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory); return directory
    }

    private func makeStore(_ directory: URL, initialData: JournalData? = nil) -> MobileLedgerStore {
        var dependencies = CloudKitSyncDependencies.live; dependencies.automaticTriggersEnabled = false
        let store = MobileLedgerStore(supportDirectory: directory, initialData: initialData, cloudKitSyncDependencies: dependencies)
        stores.append(store); return store
    }
}

private struct RefundFixture {
    let ledger: Ledger
    let usd: Commodity
    let eur: Commodity
    let purchase: LedgerTransaction
    let secondPurchase: LedgerTransaction
    let refund60: LedgerTransaction
    let refund40: LedgerTransaction
    let euroRefund: LedgerTransaction
    let transfer: LedgerTransaction
    let data: JournalData

    var draft: RefundTrackingDraft {
        RefundTrackingDraft(purchaseTransactionID: purchase.id, expectedAmount: 100, commodityID: usd.id,
                            person: "Merchant", note: "Return delivered", dueDate: Date(timeIntervalSince1970: 1_700_086_400))
    }

    init() {
        let ledger = Ledger(name: "Synthetic refunds")
        let usd = Commodity(ledgerID: ledger.id, symbol: "USD", name: "Dollar")
        let eur = Commodity(ledgerID: ledger.id, symbol: "EUR", name: "Euro")
        let bank = Account(ledgerID: ledger.id, commodityID: usd.id, name: "Bank", kind: .asset)
        let card = Account(ledgerID: ledger.id, commodityID: usd.id, name: "Card", kind: .liability)
        let expenses = Account(ledgerID: ledger.id, commodityID: usd.id, name: "Expenses", kind: .expense)
        func transaction(_ amount: Decimal, note: String, currency: UUID, financial: Account, counterpart: Account) -> LedgerTransaction {
            LedgerTransaction(ledgerID: ledger.id, date: Date(timeIntervalSince1970: 1_700_000_000), payee: "Synthetic Merchant", note: note,
                number: "", cleared: true, postings: [Posting(accountID: financial.id, commodityID: currency, amount: amount),
                    Posting(accountID: counterpart.id, commodityID: currency, amount: -amount, listIndex: 1)])
        }
        let purchase = transaction(-100, note: "Purchase", currency: usd.id, financial: card, counterpart: expenses)
        let secondPurchase = transaction(-100, note: "Second purchase", currency: usd.id, financial: bank, counterpart: expenses)
        let refund60 = transaction(60, note: "Partial refund", currency: usd.id, financial: card, counterpart: expenses)
        let refund40 = transaction(40, note: "Remaining refund", currency: usd.id, financial: bank, counterpart: expenses)
        let euroRefund = transaction(50, note: "Euro refund", currency: eur.id, financial: bank, counterpart: expenses)
        let transfer = transaction(50, note: "Internal transfer", currency: usd.id, financial: bank, counterpart: card)
        self.ledger = ledger; self.usd = usd; self.eur = eur; self.purchase = purchase; self.secondPurchase = secondPurchase
        self.refund60 = refund60; self.refund40 = refund40; self.euroRefund = euroRefund; self.transfer = transfer
        data = JournalData(ledgers: [ledger], commodities: [usd, eur], accounts: [bank, card, expenses],
                           transactions: [purchase, secondPurchase, refund60, refund40, euroRefund, transfer].sorted { $0.id.canonicallyPrecedes($1.id) },
                           selectedLedgerID: ledger.id)
    }
}
