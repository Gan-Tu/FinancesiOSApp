import CryptoKit
import Foundation
import XCTest
@testable import FinancesClone

@MainActor
final class CloudKitJournalSyncTests: XCTestCase {
    private let context = "iCloud.dev.gan.FinanceApp|Development|FinancesJournal_v1"

    func testActualMobileStoresExchangeReceiptEditAndDeletionThroughSharedProtocol() async throws {
        let server = try CKJournalTestServer()
        let networkA = CKJournalNetwork(server: server, automatic: true)
        let networkB = CKJournalNetwork(server: server, automatic: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobilePeers-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = MobileLedgerStore(supportDirectory: directory.appendingPathComponent("A"), initialData: CKTestData.make(), cloudKitSyncDependencies: .init(configuration: { CloudKitSyncConfiguration() }, makeClient: { _ in networkA.makeClient() }, automaticTriggersEnabled: false))
        let b = MobileLedgerStore(supportDirectory: directory.appendingPathComponent("B"), initialData: JournalData(), cloudKitSyncDependencies: .init(configuration: { CloudKitSyncConfiguration() }, makeClient: { _ in networkB.makeClient() }, automaticTriggersEnabled: false))
        let source = directory.appendingPathComponent("synthetic-receipt.txt")
        let receiptBytes = Data("Companion receipt 25.00".utf8)
        try receiptBytes.write(to: source)
        let row = try XCTUnwrap(a.data.transactions.first)
        var draft = a.draft(for: row)
        draft.attachments = [try a.importAttachment(from: source)]
        a.saveTransaction(draft)
        XCTAssertNil(a.validationError)
        a.setSyncEnabled(true); await a.waitForCloudKitSyncIdle()
        XCTAssertEqual(a.cloudSyncProgress.state, .succeeded)
        b.setSyncEnabled(true); await b.waitForCloudKitSyncIdle()
        XCTAssertEqual(b.cloudSyncProgress.state, .succeeded)
        let downloaded = try XCTUnwrap(b.transaction(row.id))
        let asset = try XCTUnwrap(downloaded.attachment?.assets.first)
        XCTAssertEqual(try Data(contentsOf: b.attachmentURL(for: asset)), receiptBytes)
        b.setSyncEnabled(false)
        var edited = b.draft(for: downloaded); edited.note = "Edited offline on mobile B"
        b.saveTransaction(edited)
        b.setSyncEnabled(true); await b.waitForCloudKitSyncIdle()
        a.synchronizeNow(); await a.waitForCloudKitSyncIdle()
        XCTAssertEqual(a.transaction(row.id)?.note, "Edited offline on mobile B")
        b.deleteTransaction(row.id, scope: .occurrence)
        b.synchronizeNow(); await b.waitForCloudKitSyncIdle()
        a.synchronizeNow(); await a.waitForCloudKitSyncIdle()
        XCTAssertNil(a.transaction(row.id))
        XCTAssertTrue(a.cloudKitSyncConflicts().isEmpty)
        a.setSyncEnabled(false); b.setSyncEnabled(false)
        let reopened = MobileLedgerStore(supportDirectory: directory.appendingPathComponent("A"), initialData: JournalData())
        XCTAssertNil(reopened.transaction(row.id))
    }

    func testOffDuringAccountRejectsLateResultAndRemainsOffAfterReopen() async throws {
        let fixture = try fixture(controlled: true)
        fixture.enable()
        let account = try await next(fixture, .account)
        fixture.coordinator.synchronize()
        fixture.coordinator.synchronize()
        try fixture.disable()
        fixture.network.reply(account, .account("same-apple-account"))
        try await settled(fixture)
        XCTAssertEqual(fixture.network.calls.map(\.kind), [.account])
        XCTAssertEqual(fixture.network.clientCount, 1, "Canceled coalesced follow-ups must not start")
        XCTAssertTrue(fixture.network.canceledSessions.contains(account.session))
        XCTAssertFalse(try XCTUnwrap(fixture.host.sqlite.loadData()).syncEnabled)
        XCTAssertNil(try fixture.host.sqlite.cloudKitBoundContextKey())
        XCTAssertNil(fixture.host.data.lastSyncedAt)
        XCTAssertEqual(fixture.host.progress.state, .idle)
    }

    func testOffDuringZonePreparationStartsNoFetch() async throws {
        let fixture = try fixture(controlled: true)
        fixture.enable()
        fixture.network.reply(try await next(fixture, .account), .account("same-apple-account"))
        let prepare = try await next(fixture, .prepare)
        try fixture.disable()
        fixture.network.reply(prepare, .prepared)
        try await settled(fixture)
        XCTAssertEqual(fixture.network.calls.map(\.kind), [.account, .prepare])
        XCTAssertNil(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context))
        XCTAssertFalse(fixture.host.data.syncEnabled)
    }

    func testPartialPagesDoNotPublishGraphOrAdvanceTokenWhenCanceled() async throws {
        let fixture = try fixture(empty: true, controlled: true)
        let source = CKTestData.make()
        let records = try CKTestData.records(source)
        fixture.enable()
        try await completeInitialHandshake(fixture)
        let first = try await next(fixture, .fetch)
        let transaction = try XCTUnwrap(records.first { $0.recordType == "transaction" })
        fixture.network.reply(first, .page(CloudKitSyncPage(records: [transaction], changeToken: Data("page-1".utf8), moreComing: true)))
        let second = try await next(fixture, .fetch)
        XCTAssertEqual(second.since, Data("page-1".utf8))
        XCTAssertTrue(fixture.host.data.ledgers.isEmpty)
        XCTAssertTrue(try XCTUnwrap(fixture.host.sqlite.loadData()).transactions.isEmpty)
        XCTAssertNil(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context))
        try fixture.disable()
        fixture.network.reply(second, .page(CloudKitSyncPage(records: records.filter { $0.key != transaction.key }, changeToken: Data("page-2".utf8), moreComing: false)))
        try await settled(fixture)
        XCTAssertTrue(fixture.host.data.ledgers.isEmpty)
        XCTAssertNil(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context))
        XCTAssertFalse(fixture.network.calls.contains { $0.kind == .modify })
    }

    func testLateReceiptPageAfterOffDoesNotInstallFileOrTransaction() async throws {
        let fixture = try fixture(controlled: true)
        var incoming = fixture.host.data
        let bytes = Data("late receipt".utf8)
        let asset = AttachmentAsset(originalFilename: "late.txt", storedPath: "Attachments/late.txt", mimeType: "text/plain", sizeBytes: Int64(bytes.count))
        incoming.transactions[0].attachment = AttachmentContainer(assets: [asset])
        var records = try CKTestData.records(incoming).filter { ["transaction", "attachment_asset"].contains($0.recordType) }
        let temporary = fixture.directory.appendingPathComponent("late-network-file")
        try bytes.write(to: temporary)
        let index = try XCTUnwrap(records.firstIndex { $0.recordType == "attachment_asset" })
        records[index].assetFileURL = temporary; records[index].assetSHA256 = ckJournalHash(bytes)
        fixture.enable()
        try await completeInitialHandshake(fixture)
        let page = try await next(fixture, .fetch)
        try fixture.disable()
        fixture.network.reply(page, .page(CloudKitSyncPage(records: records, changeToken: Data("late".utf8), moreComing: false)))
        try await settled(fixture)
        XCTAssertNil(fixture.host.data.transactions.first?.attachment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(asset.storedPath).path))
        XCTAssertNil(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context))
    }

    func testAcceptedLateBatchEchoResumesWithoutNewMutationIDsOrRepush() async throws {
        let server = try CKJournalTestServer()
        let fixture = try fixture(server: server, transactionCount: 1)
        fixture.network.hold = { $0.kind == .modify }
        fixture.enable()
        let upload = try await next(fixture, .modify)
        let ids = Set(upload.records.compactMap(\.clientChangeID))
        XCTAssertFalse(ids.isEmpty)
        let accepted = try server.answer(upload)
        try fixture.disable()
        fixture.network.reply(upload, accepted)
        try await settled(fixture)
        XCTAssertEqual(Set(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context).values.compactMap(\.clientChangeID)), ids)
        XCTAssertNil(fixture.host.data.lastSyncedAt)
        fixture.network.hold = nil
        fixture.enable()
        try await settled(fixture)
        XCTAssertTrue(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertEqual(fixture.network.calls.filter { $0.kind == .modify }.count, 1)
        XCTAssertEqual(server.savedMutationIDs.count, ids.count)
        XCTAssertNil(fixture.host.failure)
        XCTAssertNotNil(fixture.host.data.lastSyncedAt)
    }

    func testBackgroundConflictAndQuotaPublishFailedStatusWithoutModalAlert() async throws {
        for producesConflict in [true, false] {
            let fixture = try fixture()
            fixture.enable()
            try await settled(fixture)
            let dateBefore = fixture.host.data.lastSyncedAt
            var remoteTransaction = fixture.host.data.transactions[0]
            fixture.host.data.transactions[0].note = "Unsynced background local edit"
            try fixture.host.cloudKitFlushLocalChanges()
            if producesConflict {
                remoteTransaction.note = "Conflicting background remote edit"
                let remote = try CKTestData.record(remoteTransaction, type: "transaction", parent: remoteTransaction.ledgerID)
                try fixture.server.inject(remote)
            } else {
                fixture.network.override = { call in
                    call.kind == .modify ? .failure(CloudKitSyncError.quotaExceeded) : nil
                }
            }
            fixture.coordinator.synchronize(reportProgress: false)
            try await settled(fixture)
            XCTAssertEqual(fixture.host.progress.state, .failed, producesConflict ? "Background conflict" : "Background quota")
            XCTAssertFalse(fixture.host.progress.detail?.isEmpty ?? true)
            XCTAssertNil(fixture.host.failure, "Background errors should not invoke the modal failure callback")
            XCTAssertEqual(fixture.host.modalFailureCount, 0)
            XCTAssertEqual(fixture.host.data.lastSyncedAt, dateBefore)
            XCTAssertEqual(fixture.host.data.transactions[0].note, "Unsynced background local edit")
            XCTAssertFalse(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context).isEmpty)
        }
    }

    func testCanceledReceiptUploadEchoPreservesNewerLocalDeletion() async throws {
        let fixture = try fixture(receipt: true)
        let asset = try XCTUnwrap(fixture.host.data.transactions[0].attachment?.assets.first)
        let source = fixture.directory.appendingPathComponent(asset.storedPath)
        fixture.network.hold = { $0.kind == .modify }
        fixture.enable()
        let upload = try await next(fixture, .modify)
        let uploadedReceipt = try XCTUnwrap(upload.records.first { $0.recordType == "attachment_asset" && $0.recordID == asset.id.uuidString })
        let acceptedWhileCanceling = try fixture.server.answer(upload)
        try fixture.disable()
        fixture.host.data.transactions[0].attachment = nil
        try fixture.host.cloudKitFlushLocalChanges()
        try FileManager.default.removeItem(at: source)
        fixture.network.reply(upload, acceptedWhileCanceling)
        try await settled(fixture)
        let deletion = try XCTUnwrap(fixture.host.sqlite.pendingCloudKitRecords(contextKey: context)[uploadedReceipt.key])
        XCTAssertEqual(deletion.operation, "delete")
        XCTAssertNotEqual(deletion.clientChangeID, uploadedReceipt.clientChangeID)

        fixture.network.hold = nil
        fixture.enable()
        try await settled(fixture)
        XCTAssertNil(fixture.host.failure)
        XCTAssertTrue(try fixture.coordinator.conflicts().isEmpty)
        XCTAssertNil(fixture.host.data.transactions[0].attachment)
        XCTAssertNil(try fixture.host.sqlite.loadData()?.transactions.first?.attachment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "An old upload echo must not reinstall a deleted receipt")
        XCTAssertTrue(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertEqual(fixture.server.records[uploadedReceipt.key]?.operation, "delete")
        let laterReceiptChanges = fixture.network.calls.filter { $0.kind == .modify && $0.id != upload.id }.flatMap(\.records).filter { $0.key == uploadedReceipt.key }
        XCTAssertFalse(laterReceiptChanges.isEmpty)
        XCTAssertTrue(laterReceiptChanges.allSatisfy { $0.operation == "delete" })
        XCTAssertEqual(laterReceiptChanges.first?.clientChangeID, deletion.clientChangeID)
        XCTAssertNotNil(fixture.host.data.lastSyncedAt)
    }

    func testRapidOffOnRetiredPassCannotClearReplacementOwnership() async throws {
        let fixture = try fixture(controlled: true)
        fixture.enable()
        let first = try await next(fixture, .account)
        try fixture.disable()
        fixture.enable()
        let replacement = try await next(fixture, .account)
        XCTAssertNotEqual(first.session, replacement.session)
        fixture.network.reply(first, .account("obsolete-account"))
        try await settled(fixture, retiredOnly: true)
        XCTAssertTrue(fixture.coordinator.isSyncing)
        XCTAssertNil(try fixture.host.sqlite.cloudKitBoundContextKey())
        fixture.network.automatic = true
        fixture.network.reply(replacement, .account("same-apple-account"))
        try await settled(fixture)
        XCTAssertEqual(fixture.network.clientCount, 2)
        XCTAssertEqual(fixture.host.progress.state, .succeeded)
        XCTAssertTrue(fixture.host.data.syncEnabled)
        XCTAssertNil(fixture.host.failure)
    }

    func testCloudflareAcceptedJournalMigratesInBoundedBatchesWithoutDataLoss() async throws {
        let server = try CKJournalTestServer()
        let fixture = try fixture(server: server, transactionCount: 61, legacyAccepted: true)
        XCTAssertTrue(try fixture.host.sqlite.pendingSyncChanges(limit: 1_000).isEmpty)
        let originalIDs = Set(fixture.host.data.transactions.map(\.id))
        fixture.enable()
        try await settled(fixture)
        let batches = fixture.network.calls.filter { $0.kind == .modify }
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy { !$0.records.isEmpty && $0.records.count <= 50 })
        let submitted = batches.flatMap(\.records)
        XCTAssertEqual(Set(submitted.map(\.key)).count, submitted.count)
        XCTAssertEqual(Set(server.records.values.filter { $0.recordType == "transaction" }.map(\.recordID)), Set(originalIDs.map(\.uuidString)))
        XCTAssertTrue(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertEqual(Set(try XCTUnwrap(fixture.host.sqlite.loadData()).transactions.map(\.id)), originalIDs)
        XCTAssertNil(fixture.host.failure)
    }

    func testEmptySecondDeviceDownloadsThenExchangesDeltasTombstonesAndReceipt() async throws {
        let server = try CKJournalTestServer(pageSize: 3)
        let first = try fixture(server: server)
        first.host.data.preservesImportedRecurringMaterializations = true
        first.enable()
        try await settled(first)
        let second = try fixture(server: server, empty: true)
        second.enable()
        try await settled(second)
        XCTAssertEqual(second.host.data.transactions, first.host.data.transactions)
        XCTAssertEqual(second.host.data.accounts.sorted { $0.id.uuidString < $1.id.uuidString }, first.host.data.accounts.sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertTrue(second.host.data.preservesImportedRecurringMaterializations)
        XCTAssertFalse(second.network.calls.contains { $0.kind == .modify }, "Initial pull must not echo the complete journal back")
        XCTAssertNil(second.host.failure)

        let bytes = Data("multi-device receipt".utf8)
        let asset = AttachmentAsset(originalFilename: "shared.txt", storedPath: "Attachments/shared.txt", mimeType: "text/plain", sizeBytes: Int64(bytes.count))
        let file = first.directory.appendingPathComponent(asset.storedPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        first.host.data.transactions[0].note = "Edit from first Mac"
        first.host.data.transactions[0].attachment = AttachmentContainer(assets: [asset])
        try first.host.cloudKitFlushLocalChanges()
        first.coordinator.synchronize()
        try await settled(first)
        second.coordinator.synchronize()
        try await settled(second)
        XCTAssertEqual(second.host.data.transactions.first?.note, "Edit from first Mac")
        XCTAssertEqual(try Data(contentsOf: second.directory.appendingPathComponent(asset.storedPath)), bytes)
        XCTAssertFalse(second.network.calls.contains { $0.kind == .modify }, "Downloaded records must stay acknowledged")

        let deletedID = try XCTUnwrap(second.host.data.transactions.first?.id)
        second.host.data.transactions.removeAll { $0.id == deletedID }
        try second.host.cloudKitFlushLocalChanges()
        second.coordinator.synchronize()
        try await settled(second)
        XCTAssertEqual(server.records["transaction:\(deletedID.uuidString)"]?.operation, "delete")
        first.coordinator.synchronize()
        try await settled(first)
        XCTAssertFalse(first.host.data.transactions.contains { $0.id == deletedID })
        XCTAssertFalse(try XCTUnwrap(first.host.sqlite.loadData()).transactions.contains { $0.id == deletedID })
        XCTAssertNil(first.host.failure)
    }

    func testConcurrentEditsPreserveLocalAndStoreRemoteConflict() async throws {
        let server = try CKJournalTestServer()
        let first = try fixture(server: server)
        first.enable(); try await settled(first)
        let second = try fixture(server: server, empty: true)
        second.enable(); try await settled(second)
        first.host.data.transactions[0].note = "First Mac edit"
        second.host.data.transactions[0].note = "Second Mac edit"
        try first.host.cloudKitFlushLocalChanges(); try second.host.cloudKitFlushLocalChanges()
        first.coordinator.synchronize(); try await settled(first)
        let tokenBefore = try second.host.sqlite.cloudKitChangeToken(contextKey: context)
        second.coordinator.synchronize(); try await settled(second)
        XCTAssertEqual(second.host.data.transactions[0].note, "Second Mac edit")
        XCTAssertEqual(try second.host.sqlite.cloudKitChangeToken(contextKey: context), tokenBefore)
        let conflicts = try second.coordinator.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(try JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: Data(try XCTUnwrap(conflicts.first?.remote.payloadJSON).utf8)).note, "First Mac edit")
        XCTAssertFalse(try second.host.sqlite.pendingCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertNotNil(second.host.failure)
    }

    func testExpiredTokenRetriesOnceFromNilAndCommitsCompleteReplacement() async throws {
        let fixture = try fixture()
        fixture.enable(); try await settled(fixture)
        let before = try fixture.host.sqlite.cloudKitChangeToken(contextKey: context)
        let failures = CKJournalLocked(0)
        fixture.network.override = { call in
            guard call.kind == .fetch else { return nil }
            return failures.change { count in
                count += 1
                return count == 1 ? .failure(CloudKitSyncError.changeTokenExpired) : nil
            }
        }
        let offset = fixture.network.calls.count
        fixture.coordinator.synchronize(); try await settled(fixture)
        let fetches = fixture.network.calls.dropFirst(offset).filter { $0.kind == .fetch }
        XCTAssertEqual(fetches.count, 2)
        XCTAssertEqual(fetches[0].since, before)
        XCTAssertNil(fetches[1].since)
        XCTAssertEqual(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context), fixture.server.token)
        XCTAssertNil(fixture.host.failure)
        XCTAssertEqual(fixture.host.progress.state, .succeeded)
    }

    func testNonAdvancingPageLeavesJournalAndCheckpointUntouched() async throws {
        let fixture = try fixture()
        fixture.enable(); try await settled(fixture)
        let before = try fixture.host.sqlite.cloudKitChangeToken(contextKey: context)
        let original = fixture.host.data.transactions
        fixture.network.override = { call in
            guard call.kind == .fetch else { return nil }
            return .page(CloudKitSyncPage(records: [], changeToken: call.since, moreComing: true))
        }
        fixture.coordinator.synchronize(); try await settled(fixture)
        XCTAssertEqual(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context), before)
        XCTAssertEqual(fixture.host.data.transactions, original)
        XCTAssertNotNil(fixture.host.failure)
    }

    func testRemotePayloadIdentityMismatchCannotPublishOrAdvanceToken() async throws {
        let fixture = try fixture()
        fixture.enable(); try await settled(fixture)
        let before = try fixture.host.sqlite.cloudKitChangeToken(contextKey: context)
        let original = fixture.host.data.transactions
        var remote = try CKTestData.record(original[0], type: "transaction", parent: original[0].ledgerID)
        remote.recordID = UUID().uuidString
        let bad = remote
        fixture.network.override = { call in
            guard call.kind == .fetch else { return nil }
            return .page(CloudKitSyncPage(records: [bad], changeToken: Data("bad-identity-token".utf8), moreComing: false))
        }
        fixture.coordinator.synchronize(); try await settled(fixture)
        XCTAssertEqual(fixture.host.data.transactions, original)
        XCTAssertEqual(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context), before)
        XCTAssertNotNil(fixture.host.failure)
    }

    func testFailedSQLiteCommitRestoresPreviouslyInstalledReceiptBytes() async throws {
        let fixture = try fixture(receipt: true)
        fixture.enable(); try await settled(fixture)
        let asset = try XCTUnwrap(fixture.host.data.transactions.first?.attachment?.assets.first)
        let file = fixture.directory.appendingPathComponent(asset.storedPath)
        let oldBytes = try Data(contentsOf: file)
        let original = fixture.host.data.transactions
        let before = try fixture.host.sqlite.cloudKitChangeToken(contextKey: context)
        var remote = try XCTUnwrap(fixture.server.records["attachment_asset:\(asset.id.uuidString)"])
        let newBytes = Data(repeating: 0x42, count: oldBytes.count)
        remote.assetSHA256 = ckJournalHash(newBytes)
        try fixture.server.inject(remote, assetBytes: newBytes)
        fixture.host.failNextRemoteCommit = true
        fixture.coordinator.synchronize(); try await settled(fixture)
        XCTAssertEqual(try Data(contentsOf: file), oldBytes)
        XCTAssertEqual(fixture.host.data.transactions, original)
        XCTAssertEqual(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context), before)
        XCTAssertNotNil(fixture.host.failure)
    }

    func testSameMetadataDifferentReceiptBytesIsNotAnEcho() {
        let id = UUID().uuidString
        var local = CloudKitSyncRecord(recordType: "attachment_asset", recordID: id, contentHash: String(repeating: "1", count: 64), assetSHA256: String(repeating: "a", count: 64))
        var remote = local; remote.assetSHA256 = String(repeating: "b", count: 64)
        XCTAssertFalse(CloudKitJournalMerger.sameValue(local, remote))
        local.assetSHA256 = remote.assetSHA256
        XCTAssertTrue(CloudKitJournalMerger.sameValue(local, remote))
    }

    func testDifferentAppleAccountDoesNotUploadPreviouslyBoundJournal() async throws {
        let fixture = try fixture()
        fixture.enable(); try await settled(fixture)
        let original = fixture.host.data.transactions
        let count = fixture.network.calls.count
        fixture.network.override = { call in call.kind == .account ? .account("different-apple-account") : nil }
        fixture.coordinator.synchronize(); try await settled(fixture)
        XCTAssertEqual(fixture.network.calls.dropFirst(count).map(\.kind), [.account])
        XCTAssertEqual(fixture.host.data.transactions, original)
        XCTAssertNotNil(fixture.host.failure)
    }

    func testPushHintAfterCurrentPullCoalescesExactlyOneFollowUp() async throws {
        let fixture = try fixture()
        fixture.enable(); try await settled(fixture)
        fixture.host.data.transactions[0].note = "Local upload in progress"
        try fixture.host.cloudKitFlushLocalChanges()
        fixture.network.hold = { $0.kind == .modify }
        fixture.coordinator.synchronize()
        let upload = try await next(fixture, .modify)
        let fetchesBeforePush = fixture.network.calls.filter { $0.kind == .fetch }.count
        var remote = fixture.host.data.transactions[0]
        remote.id = UUID(); remote.note = "Arrived after pull checkpoint"
        for index in remote.postings.indices { remote.postings[index].id = UUID() }
        try fixture.server.inject(CKTestData.record(remote, type: "transaction", parent: remote.ledgerID))
        fixture.coordinator.synchronize(reportProgress: false, requireFollowUpIfBusy: true)
        fixture.coordinator.synchronize(reportProgress: false, requireFollowUpIfBusy: true)
        fixture.network.hold = nil
        fixture.network.reply(upload, try fixture.server.answer(upload))
        try await settled(fixture)
        XCTAssertEqual(fixture.network.calls.filter { $0.kind == .fetch }.count, fetchesBeforePush + 1)
        XCTAssertTrue(fixture.host.data.transactions.contains { $0.id == remote.id })
    }

    func testBackgroundPushesAfterPullShareOneFollowUpAndReportCommittedData() async throws {
        let deadline = ControlledRefreshDeadline(expectedRequests: 2)
        let fixture = try fixture(deadline: deadline)
        fixture.enable(); try await settled(fixture)
        fixture.host.data.transactions[0].note = "Manual upload"
        try fixture.host.cloudKitFlushLocalChanges()
        fixture.network.hold = { $0.kind == .modify }
        fixture.coordinator.synchronize()
        let upload = try await next(fixture, .modify)
        let previousFetchCount = fixture.network.calls.filter { $0.kind == .fetch }.count
        let first = BackgroundRefreshRun(fixture.coordinator), second = BackgroundRefreshRun(fixture.coordinator)
        try await deadline.waitUntilRegistered()
        var remote = fixture.host.data.transactions[0]
        remote.id = UUID(); remote.note = "New remote row"
        for index in remote.postings.indices { remote.postings[index].id = UUID() }
        try fixture.server.inject(CKTestData.record(remote, type: "transaction", parent: remote.ledgerID))
        fixture.network.hold = nil
        fixture.network.reply(upload, try fixture.server.answer(upload))
        let firstResult = try await first.result(), secondResult = try await second.result()
        XCTAssertEqual(firstResult, .newData); XCTAssertEqual(secondResult, .newData)
        try await settled(fixture)
        XCTAssertEqual(fixture.network.calls.filter { $0.kind == .fetch }.count, previousFetchCount + 1)
        XCTAssertTrue(fixture.host.data.transactions.contains { $0.id == remote.id })
    }

    func testOwnedBackgroundDeadlineDuringUploadPreservesExactRetryAndRejectsLateAcceptance() async throws {
        let deadline = ControlledRefreshDeadline()
        let fixture = try fixture(deadline: deadline)
        fixture.enable(); try await settled(fixture)
        fixture.host.data.transactions[0].note = "Deadline pending upload"
        try fixture.host.cloudKitFlushLocalChanges()
        fixture.network.hold = { $0.kind == .modify }
        let refresh = BackgroundRefreshRun(fixture.coordinator)
        let upload = try await next(fixture, .modify)
        try await deadline.waitUntilRegistered()
        let before = try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context)
        let accepted = try fixture.server.answer(upload)
        XCTAssertTrue(deadline.fireNext())
        let result = try await refresh.result()
        XCTAssertEqual(result, .failed)
        XCTAssertFalse(fixture.coordinator.isSyncing)
        XCTAssertTrue(fixture.host.data.syncEnabled, "A background deadline must not persist Off")
        XCTAssertTrue(fixture.network.canceledSessions.contains(upload.session))
        XCTAssertEqual(fixture.host.modalFailureCount, 0)
        XCTAssertEqual(fixture.host.progress.state, .failed)
        XCTAssertEqual(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context), before)
        fixture.network.reply(upload, accepted)
        try await settled(fixture)
        XCTAssertEqual(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context), before)
        fixture.network.hold = nil
        fixture.coordinator.synchronize(); try await settled(fixture)
        XCTAssertTrue(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertEqual(fixture.network.calls.filter { $0.kind == .modify }.count, 2, "Only initial bootstrap plus the accepted upload should have been sent")
    }

    func testDeadlineAfterCommittedPullReportsNewDataAndPreservesHeldUpload() async throws {
        let deadline = ControlledRefreshDeadline()
        let fixture = try fixture(deadline: deadline)
        fixture.enable(); try await settled(fixture)
        fixture.host.data.transactions[0].note = "Local edit awaiting upload"
        try fixture.host.cloudKitFlushLocalChanges()
        var remote = fixture.host.data.transactions[0]
        remote.id = UUID(); remote.note = "Durably downloaded before the deadline"
        for index in remote.postings.indices { remote.postings[index].id = UUID() }
        try fixture.server.inject(CKTestData.record(remote, type: "transaction", parent: remote.ledgerID))
        let committedToken = fixture.server.token
        fixture.network.hold = { $0.kind == .modify }
        let refresh = BackgroundRefreshRun(fixture.coordinator)
        let upload = try await next(fixture, .modify)
        try await deadline.waitUntilRegistered()
        let pending = try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context)
        XCTAssertTrue(fixture.host.data.transactions.contains { $0.id == remote.id })
        XCTAssertEqual(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context), committedToken)
        let accepted = try fixture.server.answer(upload)
        XCTAssertTrue(deadline.fireNext())
        let outcome = try await refresh.result()
        XCTAssertEqual(outcome, .newData)
        XCTAssertFalse(fixture.coordinator.isSyncing)
        XCTAssertEqual(fixture.host.progress.state, .failed, "Completion reports durable data even though the unfinished upload is paused")
        XCTAssertEqual(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context), pending)
        fixture.network.reply(upload, accepted)
        try await settled(fixture)
        XCTAssertEqual(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context), pending)
        XCTAssertEqual(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context), committedToken)
        XCTAssertEqual(fixture.host.modalFailureCount, 0)
    }

    func testOwnedDeadlineReturnsBeforeAdmittedDatabaseWorkFinishes() async throws {
        let deadline = ControlledRefreshDeadline(), database = ControlledDatabaseOperation()
        let fixture = try fixture(deadline: deadline, database: database)
        fixture.enable(); try await settled(fixture)
        let initialCalls = fixture.network.calls.count
        let token = try fixture.host.sqlite.cloudKitChangeToken(contextKey: context)
        database.arm()
        defer { database.release() }
        let refresh = BackgroundRefreshRun(fixture.coordinator)
        try await database.waitUntilEntered()
        try await deadline.waitUntilRegistered()
        XCTAssertTrue(deadline.fireNext())
        let outcome = try await refresh.result()
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(database.hasExited, "The background callback must return while the admitted database operation is still held")
        XCTAssertFalse(fixture.coordinator.isSyncing)
        XCTAssertEqual(fixture.network.calls.dropFirst(initialCalls).map(\.kind), [.account])
        database.release()
        try await settled(fixture)
        XCTAssertEqual(fixture.network.calls.dropFirst(initialCalls).map(\.kind), [.account], "No fetch or successor database work may be admitted after retirement")
        XCTAssertEqual(try fixture.host.sqlite.cloudKitChangeToken(contextKey: context), token)
        XCTAssertTrue(fixture.host.data.syncEnabled)
        XCTAssertEqual(fixture.host.progress.state, .failed)
    }

    func testWatcherJoiningDuringConflictDatabaseWriteReportsNewConflict() async throws {
        let deadline = ControlledRefreshDeadline(), database = ControlledDatabaseOperation()
        let fixture = try fixture(deadline: deadline, database: database)
        fixture.enable(); try await settled(fixture)
        fixture.host.data.transactions[0].note = "Local conflicting upload"
        try fixture.host.cloudKitFlushLocalChanges()
        fixture.network.hold = { $0.kind == .modify }
        fixture.coordinator.synchronize(reportProgress: false)
        let upload = try await next(fixture, .modify)
        var remote = fixture.host.data.transactions[0]
        remote.note = "Changed remotely after the pull"
        try fixture.server.inject(CKTestData.record(remote, type: "transaction", parent: remote.ledgerID))
        let response = try fixture.server.answer(upload)
        database.arm()
        defer { database.release() }
        fixture.network.reply(upload, response)
        try await database.waitUntilEntered()
        // No watcher existed when the async conflict write began.
        let refresh = BackgroundRefreshRun(fixture.coordinator)
        try await deadline.waitUntilRegistered()
        database.release()
        let outcome = try await refresh.result()
        XCTAssertEqual(outcome, .newData)
        try await settled(fixture)
        XCTAssertEqual(try fixture.coordinator.conflicts().count, 1)
        XCTAssertEqual(fixture.host.modalFailureCount, 0)
    }

    func testBackgroundDeadlineJoiningUnresponsiveManualPassReturnsWithoutCancelOrFollowUp() async throws {
        let deadline = ControlledRefreshDeadline()
        let fixture = try fixture(controlled: true, deadline: deadline)
        fixture.enable()
        let account = try await next(fixture, .account)
        let refresh = BackgroundRefreshRun(fixture.coordinator)
        try await deadline.waitUntilRegistered()
        XCTAssertTrue(deadline.fireNext())
        let result = try await refresh.result()
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(fixture.coordinator.isSyncing)
        XCTAssertFalse(fixture.network.canceledSessions.contains(account.session))
        fixture.network.automatic = true
        fixture.network.reply(account, .account("same-apple-account"))
        try await settled(fixture)
        XCTAssertEqual(fixture.network.clientCount, 1, "An expired push must not leave a self-follow-up queued")
    }

    func testForegroundReconnectAndFallbackAfterPullEachRequestOneFollowUp() async throws {
        for reconnect in [true, false] {
            let fixture = try fixture()
            fixture.enable(); try await settled(fixture)
            fixture.host.data.transactions[0].note = "Local edit during a foreground pass"
            try fixture.host.cloudKitFlushLocalChanges()
            fixture.network.hold = { $0.kind == .modify }
            fixture.coordinator.synchronize(reportProgress: false)
            let upload = try await next(fixture, .modify)
            let previousFetchCount = fixture.network.calls.filter { $0.kind == .fetch }.count
            var remote = fixture.host.data.transactions[0]
            remote.id = UUID(); remote.note = "Became available after the current pull"
            for index in remote.postings.indices { remote.postings[index].id = UUID() }
            try fixture.server.inject(CKTestData.record(remote, type: "transaction", parent: remote.ledgerID))
            let monitor = ControlledForegroundNetwork(), fallback = ControlledRefreshDeadline()
            let triggers = CloudKitForegroundSyncTriggers(dependencies: .init(
                makeNetworkMonitor: { monitor }, waitForFallback: { try await fallback.wait() }
            )) { fixture.coordinator.synchronize(reportProgress: false, requireFollowUpIfBusy: true) }
            defer { triggers.stop(); fallback.fireAll() }
            triggers.update(isActive: true, isEnabled: true, isRecovering: false, automaticTriggersEnabled: true)
            try await fallback.waitUntilRegistered()
            if reconnect {
                monitor.send(false); monitor.send(true); monitor.send(true)
            } else {
                XCTAssertTrue(fallback.fireNext())
                try await fallback.waitUntilRegistered(count: 2)
            }
            fixture.network.hold = nil
            fixture.network.reply(upload, try fixture.server.answer(upload))
            try await settled(fixture)
            XCTAssertEqual(fixture.network.calls.filter { $0.kind == .fetch }.count, previousFetchCount + 1)
            XCTAssertTrue(fixture.host.data.transactions.contains { $0.id == remote.id })
        }
    }

    func testForegroundReconnectRetriesQueuedOfflineEditWithoutAnotherEditOrActivation() async throws {
        let now = CKJournalLocked(Date(timeIntervalSince1970: 1_800_000_000))
        let fixture = try fixture(now: { now.value })
        fixture.enable(); try await settled(fixture)
        let monitor = ControlledForegroundNetwork(), fallback = ControlledRefreshDeadline()
        let triggers = CloudKitForegroundSyncTriggers(dependencies: .init(
            makeNetworkMonitor: { monitor }, waitForFallback: { try await fallback.wait() }
        )) { fixture.coordinator.synchronize(reportProgress: false, requireFollowUpIfBusy: true) }
        defer { triggers.stop(); fallback.fireAll() }
        triggers.update(isActive: true, isEnabled: true, isRecovering: false, automaticTriggersEnabled: true)
        monitor.send(false)
        fixture.host.data.transactions[0].note = "Edited while the active app was offline"
        try fixture.host.cloudKitFlushLocalChanges()
        fixture.network.override = { call in
            call.kind == .account ? .failure(CloudKitSyncError.retryable("Network temporarily unavailable", nil)) : nil
        }
        fixture.coordinator.synchronize(reportProgress: false)
        try await settled(fixture)
        XCTAssertEqual(fixture.host.progress.state, .failed)
        XCTAssertFalse(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context).isEmpty)
        now.change { $0 = $0.addingTimeInterval(300) }
        fixture.network.override = nil
        monitor.send(true)
        try await settled(fixture)
        XCTAssertTrue(try fixture.host.sqlite.pendingCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertEqual(fixture.host.progress.state, .succeeded)
        XCTAssertTrue(fixture.host.data.syncEnabled)
    }

    func testActiveApplicationPushDeadlineDoesNotCancelForegroundOwnedPass() async throws {
        let deadline = ControlledRefreshDeadline()
        let fixture = try fixture(controlled: true, deadline: deadline)
        fixture.host.data.syncEnabled = true
        let refresh = BackgroundRefreshRun(fixture.coordinator, isForeground: true)
        let account = try await next(fixture, .account)
        try await deadline.waitUntilRegistered()
        XCTAssertTrue(deadline.fireNext())
        let result = try await refresh.result()
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(fixture.coordinator.isSyncing)
        XCTAssertFalse(fixture.network.canceledSessions.contains(account.session))
        fixture.network.automatic = true
        fixture.network.reply(account, .account("same-apple-account"))
        try await settled(fixture)
        XCTAssertEqual(fixture.host.progress.state, .succeeded)
        XCTAssertEqual(fixture.network.clientCount, 1)
    }

    func testLeavingForegroundRetiresUnbudgetedWorkButPreservesQueuedChanges() async throws {
        let fixture = try fixture(controlled: true)
        fixture.enable()
        let account = try await next(fixture, .account)
        fixture.coordinator.suspendForegroundWork()
        XCTAssertFalse(fixture.coordinator.isSyncing)
        XCTAssertTrue(fixture.network.canceledSessions.contains(account.session))
        XCTAssertTrue(fixture.host.data.syncEnabled)
        fixture.network.reply(account, .account("same-apple-account"))
        try await settled(fixture)
        XCTAssertEqual(fixture.network.calls.map(\.kind), [.account])
        XCTAssertEqual(fixture.host.progress.state, .idle)
    }

    func testLeavingForegroundKeepsOnlyTheExistingBoundedPushLease() async throws {
        let deadline = ControlledRefreshDeadline()
        let fixture = try fixture(controlled: true, deadline: deadline)
        fixture.host.data.syncEnabled = true
        let refresh = BackgroundRefreshRun(fixture.coordinator, isForeground: true)
        let account = try await next(fixture, .account)
        try await deadline.waitUntilRegistered()
        fixture.coordinator.suspendForegroundWork()
        XCTAssertTrue(fixture.coordinator.isSyncing)
        XCTAssertFalse(fixture.network.canceledSessions.contains(account.session))
        XCTAssertTrue(deadline.fireNext())
        let result = try await refresh.result()
        XCTAssertEqual(result, .failed)
        XCTAssertFalse(fixture.coordinator.isSyncing)
        XCTAssertTrue(fixture.network.canceledSessions.contains(account.session))
        fixture.network.reply(account, .account("same-apple-account"))
        try await settled(fixture)
        XCTAssertEqual(fixture.network.calls.map(\.kind), [.account])
    }

    func testActivePushKeepsForegroundFollowUpAfterItsCallbackDeadline() async throws {
        let deadline = ControlledRefreshDeadline()
        let fixture = try fixture(deadline: deadline)
        fixture.enable(); try await settled(fixture)
        fixture.host.data.transactions[0].note = "Foreground upload in progress"
        try fixture.host.cloudKitFlushLocalChanges()
        fixture.network.hold = { $0.kind == .modify }
        fixture.coordinator.synchronize(reportProgress: false)
        let upload = try await next(fixture, .modify)
        let previousFetchCount = fixture.network.calls.filter { $0.kind == .fetch }.count
        var remote = fixture.host.data.transactions[0]
        remote.id = UUID(); remote.note = "Available after the foreground checkpoint"
        for index in remote.postings.indices { remote.postings[index].id = UUID() }
        try fixture.server.inject(CKTestData.record(remote, type: "transaction", parent: remote.ledgerID))
        let refresh = BackgroundRefreshRun(fixture.coordinator, isForeground: true)
        try await deadline.waitUntilRegistered()
        XCTAssertTrue(deadline.fireNext())
        let result = try await refresh.result()
        XCTAssertEqual(result, .failed)
        XCTAssertFalse(fixture.network.canceledSessions.contains(upload.session))
        fixture.network.hold = nil
        fixture.network.reply(upload, try fixture.server.answer(upload))
        try await settled(fixture)
        XCTAssertEqual(fixture.network.calls.filter { $0.kind == .fetch }.count, previousFetchCount + 1)
        XCTAssertTrue(fixture.host.data.transactions.contains { $0.id == remote.id })
    }

    func testManualAndForegroundRequestsPromoteBackgroundPassBeyondItsDeadline() async throws {
        for manual in [true, false] {
            let deadline = ControlledRefreshDeadline()
            let fixture = try fixture(controlled: true, deadline: deadline)
            fixture.host.data.syncEnabled = true
            let refresh = BackgroundRefreshRun(fixture.coordinator)
            let account = try await next(fixture, .account)
            try await deadline.waitUntilRegistered()
            fixture.coordinator.synchronize(reportProgress: manual, requireFollowUpIfBusy: manual)
            XCTAssertTrue(deadline.fireNext())
            let result = try await refresh.result()
            XCTAssertEqual(result, .failed)
            XCTAssertTrue(fixture.coordinator.isSyncing)
            XCTAssertFalse(fixture.network.canceledSessions.contains(account.session), manual ? "Manual promotion" : "Foreground promotion")
            fixture.network.automatic = true
            fixture.network.reply(account, .account("same-apple-account"))
            try await settled(fixture)
            XCTAssertEqual(fixture.host.progress.state, .succeeded)
        }
    }

    func testOffReenableAndLateDeadlineCannotCancelNewSession() async throws {
        let deadline = ControlledRefreshDeadline(ignoresCancellation: true)
        let fixture = try fixture(controlled: true, deadline: deadline)
        fixture.host.data.syncEnabled = true
        let refresh = BackgroundRefreshRun(fixture.coordinator)
        let old = try await next(fixture, .account)
        try await deadline.waitUntilRegistered()
        try fixture.disable()
        let offResult = try await refresh.result()
        XCTAssertEqual(offResult, .noData)
        fixture.enable()
        let current = try await next(fixture, .account)
        XCTAssertTrue(deadline.fireNext())
        fixture.network.reply(old, .account("obsolete-account"))
        try await settled(fixture, retiredOnly: true)
        XCTAssertTrue(fixture.coordinator.isSyncing)
        XCTAssertFalse(fixture.network.canceledSessions.contains(current.session))
        fixture.network.automatic = true
        fixture.network.reply(current, .account("same-apple-account"))
        try await settled(fixture)
        XCTAssertTrue(fixture.host.data.syncEnabled)
        XCTAssertEqual(fixture.host.progress.state, .succeeded)
    }

    func testBackgroundOutcomeExcludesEchoAndTimestampButIncludesRemoteDomainAndConflict() async throws {
        let deadline = ControlledRefreshDeadline()
        let fixture = try fixture(deadline: deadline)
        fixture.enable(); try await settled(fixture)
        let echo = try await BackgroundRefreshRun(fixture.coordinator).result()
        XCTAssertEqual(echo, .noData)
        var remote = fixture.host.data.transactions[0]
        remote.note = "Changed on another device"
        try fixture.server.inject(CKTestData.record(remote, type: "transaction", parent: remote.ledgerID))
        let changed = try await BackgroundRefreshRun(fixture.coordinator).result()
        XCTAssertEqual(changed, .newData)
        XCTAssertEqual(fixture.host.data.transactions[0].note, remote.note)
        fixture.host.data.transactions[0].note = "New local conflict"
        try fixture.host.cloudKitFlushLocalChanges()
        remote.note = "New remote conflict"
        try fixture.server.inject(CKTestData.record(remote, type: "transaction", parent: remote.ledgerID))
        let conflict = try await BackgroundRefreshRun(fixture.coordinator).result()
        XCTAssertEqual(conflict, .newData)
        XCTAssertEqual(try fixture.coordinator.conflicts().count, 1)
        XCTAssertEqual(fixture.host.modalFailureCount, 0)
        let duplicate = try await BackgroundRefreshRun(fixture.coordinator).result()
        XCTAssertEqual(duplicate, .failed, "Repeated identical conflict is a failure without new fetched content")
    }

    func testBackgroundRefreshWhileOffStartsNothingAndReturnsNoData() async throws {
        let fixture = try fixture()
        let result = try await BackgroundRefreshRun(fixture.coordinator).result()
        XCTAssertEqual(result, .noData)
        XCTAssertTrue(fixture.network.calls.isEmpty)
        XCTAssertFalse(fixture.host.data.syncEnabled)
    }

    func testOnePushDeadlineDoesNotCancelAnotherActivePushLease() async throws {
        let deadline = ControlledRefreshDeadline(expectedRequests: 2)
        let fixture = try fixture(controlled: true, deadline: deadline)
        fixture.host.data.syncEnabled = true
        let first = BackgroundRefreshRun(fixture.coordinator)
        let account = try await next(fixture, .account)
        try await deadline.waitUntilRegistered(count: 1)
        let second = BackgroundRefreshRun(fixture.coordinator)
        try await deadline.waitUntilRegistered()
        XCTAssertTrue(deadline.fireNext())
        let firstResult = try await first.result()
        XCTAssertEqual(firstResult, .failed)
        XCTAssertTrue(fixture.coordinator.isSyncing)
        XCTAssertFalse(fixture.network.canceledSessions.contains(account.session))
        XCTAssertTrue(deadline.fireNext())
        let secondResult = try await second.result()
        XCTAssertEqual(secondResult, .failed)
        XCTAssertFalse(fixture.coordinator.isSyncing)
        XCTAssertTrue(fixture.network.canceledSessions.contains(account.session))
        fixture.network.reply(account, .account("same-apple-account"))
        try await settled(fixture)
    }

    private func fixture(server: CKJournalTestServer? = nil, empty: Bool = false, controlled: Bool = false, transactionCount: Int = 1, legacyAccepted: Bool = false, receipt: Bool = false, deadline: ControlledRefreshDeadline? = nil, database: ControlledDatabaseOperation? = nil, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }) throws -> CKJournalFixture {
        let fixture = try CKJournalFixture(server: server ?? CKJournalTestServer(), empty: empty, controlled: controlled, transactionCount: transactionCount, legacyAccepted: legacyAccepted, receipt: receipt, deadline: deadline, database: database, now: now)
        addTeardownBlock { await fixture.close() }
        return fixture
    }
    private func next(_ fixture: CKJournalFixture, _ kind: CKJournalCall.Kind) async throws -> CKJournalCall {
        let ready = fixture.network.nextExpectation()
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 10) == .completed, let call = fixture.network.takeNext() else {
            throw CloudKitSyncError.service("Controlled CloudKit call did not arrive.")
        }
        XCTAssertEqual(call.kind, kind)
        return call
    }
    private func completeInitialHandshake(_ fixture: CKJournalFixture) async throws {
        fixture.network.reply(try await next(fixture, .account), .account("same-apple-account"))
        fixture.network.reply(try await next(fixture, .prepare), .prepared)
    }
    private func settled(_ fixture: CKJournalFixture, retiredOnly: Bool = false) async throws {
        let done = XCTestExpectation(description: "owned CloudKit passes settled")
        let task = Task {
            if retiredOnly { await fixture.coordinator.waitForRetiredPasses() }
            else { await fixture.coordinator.waitUntilIdle() }
            done.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [done], timeout: 10) == .completed else {
            fixture.coordinator.cancel(); fixture.network.abort(); task.cancel()
            throw CloudKitSyncError.service("Controlled CloudKit pass did not settle.")
        }
        await task.value
    }
}

@MainActor
private final class CKJournalFixture {
    let directory: URL
    let host: CKJournalHost
    let server: CKJournalTestServer
    let network: CKJournalNetwork
    let coordinator: CloudKitJournalSyncCoordinator
    private let deadline: ControlledRefreshDeadline?
    private let database: ControlledDatabaseOperation?
    init(server: CKJournalTestServer, empty: Bool, controlled: Bool, transactionCount: Int, legacyAccepted: Bool, receipt: Bool, deadline: ControlledRefreshDeadline?, database: ControlledDatabaseOperation?, now: @escaping @Sendable () -> Date) throws {
        self.deadline = deadline
        self.database = database
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudKitJournalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = empty ? JournalData() : CKTestData.make(transactionCount: transactionCount)
        if receipt {
            let bytes = Data("original receipt bytes".utf8)
            let asset = AttachmentAsset(originalFilename: "original.txt", storedPath: "Attachments/original.txt", mimeType: "text/plain", sizeBytes: Int64(bytes.count))
            data.transactions[0].attachment = AttachmentContainer(assets: [asset])
            let file = directory.appendingPathComponent(asset.storedPath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        host = try CKJournalHost(data: data, directory: directory, legacyAccepted: legacyAccepted)
        self.server = server
        network = CKJournalNetwork(server: server, automatic: !controlled)
        let network = network
        var dependencies = CloudKitSyncDependencies(configuration: { CloudKitSyncConfiguration() }, makeClient: { _ in network.makeClient() }, automaticTriggersEnabled: false, now: now)
        if let deadline { dependencies.backgroundRefreshDeadline = { try await deadline.wait() } }
        if let database { dependencies.beforeDatabaseOperation = { database.enterIfArmed() } }
        coordinator = CloudKitJournalSyncCoordinator(host: host, dependencies: dependencies)
    }
    func enable() { host.data.syncEnabled = true; coordinator.synchronize() }
    func disable() throws { host.data.syncEnabled = false; coordinator.cancel(); try host.cloudKitFlushLocalChanges() }
    func close() async {
        database?.release(); coordinator.cancel(); deadline?.fireAll(); network.abort(); await coordinator.waitUntilIdle()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class CKJournalHost: CloudKitJournalSyncHost {
    var data: JournalData
    private var baseline: JournalData
    let sqlite: SQLiteJournalStore
    let directory: URL
    var progress = CloudSyncProgress.idle
    var failure: String?
    var modalFailureCount = 0
    var failNextRemoteCommit = false
    var cloudKitJournalData: JournalData { data }
    var cloudKitSQLiteStore: SQLiteJournalStore { sqlite }
    init(data: JournalData, directory: URL, legacyAccepted: Bool) throws {
        self.data = data; baseline = data; self.directory = directory
        sqlite = SQLiteJournalStore(databaseURL: directory.appendingPathComponent("journal.sqlite"))
        try sqlite.replaceData(data, trackSyncChanges: true)
        if legacyAccepted {
            let pending = try sqlite.claimPendingSyncChanges(limit: 10_000)
            try sqlite.markSyncChangesAccepted(pending.enumerated().map { SQLiteAcceptedSyncChange(clientChangeID: $0.element.clientChangeID, recordType: $0.element.recordType, recordID: $0.element.recordID, serverRevision: Int64($0.offset + 1)) })
            try sqlite.setLastPulledServerRevision(Int64(pending.count))
        }
    }
    func cloudKitFlushLocalChanges() throws { try sqlite.persist(data, previous: baseline, trackSyncChanges: true); baseline = data }
    func cloudKitValidate(_ candidate: JournalData) throws {
        let ledgers = Set(candidate.ledgers.map(\.id))
        guard ledgers.count == candidate.ledgers.count, Set(candidate.accounts.map(\.id)).count == candidate.accounts.count else { throw CloudKitSyncError.invalidData("Duplicate fixture identities") }
        let accounts = Dictionary(uniqueKeysWithValues: candidate.accounts.map { ($0.id, $0) })
        for account in candidate.accounts {
            guard ledgers.contains(account.ledgerID), account.parentID == nil || accounts[account.parentID!]?.ledgerID == account.ledgerID else { throw CloudKitSyncError.invalidData("Incomplete account graph") }
        }
        for transaction in candidate.transactions {
            guard ledgers.contains(transaction.ledgerID), transaction.postings.count >= 2,
                  transaction.postings.allSatisfy({ accounts[$0.accountID]?.ledgerID == transaction.ledgerID }),
                  transaction.postings.reduce(Decimal.zero, { $0 + $1.amount }) == .zero else { throw CloudKitSyncError.invalidData("Incomplete transaction graph") }
        }
    }
    func cloudKitCommitRemote(_ records: [CloudKitSyncRecord], data candidate: JournalData, contextKey: String, changeToken: Data?) throws {
        if failNextRemoteCommit { failNextRemoteCommit = false; throw CloudKitSyncError.service("Injected SQLite commit failure") }
        try sqlite.persistCloudKitPull(records, data: candidate, previous: baseline, contextKey: contextKey, changeToken: changeToken)
        data = candidate; baseline = candidate
    }
    func cloudKitCommitConflictResolution(id: String, keepLocal: Bool, data: JournalData, contextKey: String) throws {
        throw CloudKitSyncError.service("Conflict choice is outside this host fixture's scope")
    }
    func cloudKitAttachmentURL(for asset: AttachmentAsset) throws -> URL {
        let path = asset.storedPath
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw CloudKitSyncError.invalidData("Invalid fixture receipt path") }
        return directory.appendingPathComponent(path)
    }
    func cloudKitSyncDidUpdate(_ value: CloudSyncProgress) { progress = value }
    func cloudKitSyncDidFail(_ message: String) { modalFailureCount += 1; failure = message }
    func cloudKitSyncDidFinish(at date: Date) throws {
        var snapshot = data; snapshot.lastSyncedAt = date
        try sqlite.persist(snapshot, previous: baseline, trackSyncChanges: false)
        data = snapshot; baseline = snapshot; failure = nil
    }
}

private enum CKTestData {
    static func make(transactionCount: Int = 1) -> JournalData {
        let ledger = Ledger(name: "Synthetic CloudKit journal")
        let currency = Commodity(ledgerID: ledger.id, symbol: "USD", name: "US Dollar")
        let assets = Account(ledgerID: ledger.id, name: "Assets", kind: .asset)
        let expenses = Account(ledgerID: ledger.id, name: "Expenses", kind: .expense)
        let checking = Account(ledgerID: ledger.id, parentID: assets.id, commodityID: currency.id, name: "Checking", kind: .asset)
        let food = Account(ledgerID: ledger.id, parentID: expenses.id, commodityID: currency.id, name: "Food", kind: .expense)
        let transactions = (0..<transactionCount).map { index in LedgerTransaction(ledgerID: ledger.id, date: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)), payee: "Fixture", note: "Synthetic \(index)", number: "", cleared: true, postings: [Posting(accountID: checking.id, commodityID: currency.id, amount: -2), Posting(accountID: food.id, commodityID: currency.id, amount: 2, listIndex: 1)]) }
        return JournalData(ledgers: [ledger], commodities: [currency], accounts: [assets, expenses, checking, food], transactions: transactions, selectedLedgerID: ledger.id)
    }
    static func record<T: Encodable & Identifiable>(_ value: T, type: String, parent: UUID?) throws -> CloudKitSyncRecord where T.ID == UUID {
        let bytes = try JSONEncoder.appEncoder.encode(value)
        return CloudKitSyncRecord(recordType: type, recordID: value.id.uuidString, parentRecordID: parent?.uuidString, contentHash: ckJournalHash(bytes), payloadJSON: String(decoding: bytes, as: UTF8.self), clientChangeID: UUID().uuidString, systemFields: Data("remote-metadata".utf8))
    }
    static func records(_ data: JournalData) throws -> [CloudKitSyncRecord] {
        var records = try data.ledgers.map { try record($0, type: "ledger", parent: nil) }
        records += try data.commodities.map { try record($0, type: "commodity", parent: $0.ledgerID) }
        records += try data.accounts.map { try record($0, type: "account", parent: $0.parentID ?? $0.ledgerID) }
        records += try data.transactions.map { try record($0, type: "transaction", parent: $0.ledgerID) }
        for transaction in data.transactions {
            guard let container = transaction.attachment else { continue }
            records += try container.assets.map { try record($0, type: "attachment_asset", parent: container.id) }
        }
        return records
    }
}

private struct CKJournalCall: Sendable {
    enum Kind: String, Sendable { case account, prepare, fetch, modify }
    let id = UUID()
    let session: UUID
    let kind: Kind
    var since: Data? = nil
    var records: [CloudKitSyncRecord] = []
}
private enum CKJournalReply: Sendable {
    case account(String), prepared, page(CloudKitSyncPage), modified(CloudKitSyncModifyResult), failure(Error)
}

private final class CKJournalNetwork: @unchecked Sendable {
    private struct State {
        var calls: [CKJournalCall] = []
        var pending: [UUID: @Sendable (CKJournalReply) -> Void] = [:]
        var consumed: Set<UUID> = []
        var controlled: Set<UUID> = []
        var waiters: [XCTestExpectation] = []
        var canceled: Set<UUID> = []
        var clientCount = 0
        var automatic: Bool
        var hold: (@Sendable (CKJournalCall) -> Bool)?
        var override: (@Sendable (CKJournalCall) -> CKJournalReply?)?
    }
    private let state: CKJournalLocked<State>
    private let server: CKJournalTestServer
    init(server: CKJournalTestServer, automatic: Bool) { self.server = server; state = CKJournalLocked(State(automatic: automatic)) }
    var calls: [CKJournalCall] { state.value.calls }
    var canceledSessions: Set<UUID> { state.value.canceled }
    var clientCount: Int { state.value.clientCount }
    var automatic: Bool { get { state.value.automatic } set { state.change { $0.automatic = newValue } } }
    var hold: (@Sendable (CKJournalCall) -> Bool)? { get { state.value.hold } set { state.change { $0.hold = newValue } } }
    var override: (@Sendable (CKJournalCall) -> CKJournalReply?)? { get { state.value.override } set { state.change { $0.override = newValue } } }
    func makeClient() -> any CloudKitSyncTransport { state.change { $0.clientCount += 1 }; return CKJournalTransport(network: self) }
    func cancel(_ session: UUID) { state.change { $0.canceled.insert(session) } }
    func issue(_ call: CKJournalCall) async throws -> CKJournalReply {
        let result: CKJournalReply = await withCheckedContinuation { continuation in
            let controls = state.change { current -> (Bool, Bool, CKJournalReply?, [XCTestExpectation]) in
                current.calls.append(call); current.pending[call.id] = { continuation.resume(returning: $0) }
                let automatic = current.automatic, held = current.hold?(call) == true
                let response = current.override?(call)
                let controlled = response == nil && (!automatic || held)
                let waiters: [XCTestExpectation]
                if controlled {
                    current.controlled.insert(call.id)
                    waiters = current.waiters; current.waiters = []
                } else { waiters = [] }
                return (automatic, held, response, waiters)
            }
            if let response = controls.2 { reply(call, response) }
            else if controls.0 && !controls.1 {
                do { reply(call, try server.answer(call)) } catch { reply(call, .failure(error)) }
            }
            for waiter in controls.3 { waiter.fulfill() }
        }
        if case .failure(let error) = result { throw error }
        return result
    }
    func reply(_ call: CKJournalCall, _ response: CKJournalReply) { state.change { $0.pending.removeValue(forKey: call.id) }?(response) }
    func nextExpectation() -> XCTestExpectation {
        let ready = XCTestExpectation(description: "controlled CloudKit request")
        let available = state.change { current -> Bool in
            if current.calls.contains(where: { current.controlled.contains($0.id) && current.pending[$0.id] != nil && !current.consumed.contains($0.id) }) { return true }
            current.waiters.append(ready); return false
        }
        if available { ready.fulfill() }
        return ready
    }
    func takeNext() -> CKJournalCall? {
        state.change { current in
            guard let call = current.calls.first(where: { current.controlled.contains($0.id) && current.pending[$0.id] != nil && !current.consumed.contains($0.id) }) else { return nil }
            current.consumed.insert(call.id); return call
        }
    }
    func abort() {
        let pending = state.change { current in let values = Array(current.pending.values); current.pending = [:]; return values }
        for completion in pending { completion(.failure(CancellationError())) }
    }
}
private struct CKJournalTransport: CloudKitSyncTransport {
    let network: CKJournalNetwork
    let session = UUID()
    func accountIdentifier() async throws -> String {
        guard case .account(let value) = try await network.issue(CKJournalCall(session: session, kind: .account)) else { throw CloudKitSyncError.service("Wrong fake account response") }; return value
    }
    func prepareZone() async throws {
        guard case .prepared = try await network.issue(CKJournalCall(session: session, kind: .prepare)) else { throw CloudKitSyncError.service("Wrong fake prepare response") }
    }
    func fetchChanges(since: Data?) async throws -> CloudKitSyncPage {
        guard case .page(let value) = try await network.issue(CKJournalCall(session: session, kind: .fetch, since: since)) else { throw CloudKitSyncError.service("Wrong fake page response") }; return value
    }
    func modifyRecords(_ records: [CloudKitSyncRecord]) async throws -> CloudKitSyncModifyResult {
        guard case .modified(let value) = try await network.issue(CKJournalCall(session: session, kind: .modify, records: records)) else { throw CloudKitSyncError.service("Wrong fake modify response") }; return value
    }
    func cancel() { network.cancel(session) } // Deliberately leave responses pending for late-result tests.
}

private final class CKJournalTestServer: @unchecked Sendable {
    private struct State {
        var records: [String: CloudKitSyncRecord] = [:]
        var changes: [CloudKitSyncRecord] = []
        var blobs: [String: Data] = [:]
        var savedMutationIDs: Set<String> = []
    }
    private let state = CKJournalLocked(State())
    private let directory: URL
    private let pageSize: Int
    init(pageSize: Int = 200) throws {
        self.pageSize = pageSize
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudKitFakeServer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    var records: [String: CloudKitSyncRecord] { state.value.records }
    var savedMutationIDs: Set<String> { state.value.savedMutationIDs }
    var token: Data { Self.token(state.value.changes.count) }
    private static func token(_ value: Int) -> Data { Data("cursor-\(value)".utf8) }
    private static func position(_ token: Data?) -> Int {
        guard let token, let text = String(data: token, encoding: .utf8), text.hasPrefix("cursor-") else { return 0 }
        return Int(text.dropFirst(7)) ?? 0
    }
    func inject(_ record: CloudKitSyncRecord, assetBytes: Data? = nil) throws {
        state.change { current in
            var record = record
            record.systemFields = Data("server-version-\(current.changes.count + 1)".utf8)
            record.assetFileURL = nil
            current.records[record.key] = record; current.changes.append(record)
            if let assetBytes { current.blobs[record.key] = assetBytes }
        }
    }
    func answer(_ call: CKJournalCall) throws -> CKJournalReply {
        try state.change { current in
            switch call.kind {
            case .account: return .account("same-apple-account")
            case .prepare: return .prepared
            case .fetch:
                let start = Self.position(call.since)
                let end = min(start + pageSize, current.changes.count)
                guard start <= end else { return .failure(CloudKitSyncError.changeTokenExpired) }
                var records = Array(current.changes[start..<end])
                for index in records.indices where records[index].recordType == "attachment_asset" && records[index].operation != "delete" {
                    guard let bytes = current.blobs[records[index].key] else { continue }
                    let file = directory.appendingPathComponent(UUID().uuidString)
                    try bytes.write(to: file)
                    records[index].assetFileURL = file
                }
                return .page(CloudKitSyncPage(records: records, changeToken: Self.token(end), moreComing: end < current.changes.count))
            case .modify:
                var saved: [CloudKitSyncRecord] = [], conflicts: [CloudKitSyncRecord] = []
                for input in call.records {
                    if let existing = current.records[input.key], input.systemFields != existing.systemFields {
                        conflicts.append(existing); continue
                    }
                    var record = input
                    if record.recordType == "attachment_asset", record.operation != "delete" {
                        guard let file = record.assetFileURL else { throw CloudKitSyncError.invalidData("Fake upload needs receipt bytes") }
                        let bytes = try Data(contentsOf: file)
                        guard record.assetSHA256 == ckJournalHash(bytes) else { throw CloudKitSyncError.invalidData("Fake upload checksum mismatch") }
                        current.blobs[record.key] = bytes
                    }
                    record.assetFileURL = nil
                    record.systemFields = Data("server-version-\(current.changes.count + 1)".utf8)
                    current.records[record.key] = record; current.changes.append(record)
                    if let id = record.clientChangeID { current.savedMutationIDs.insert(id) }
                    saved.append(record)
                }
                return .modified(CloudKitSyncModifyResult(saved: saved, conflicts: conflicts))
            }
        }
    }
}

private final class CKJournalLocked<Value>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    @discardableResult func change<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock(); defer { lock.unlock() }; return try body(&storage)
    }
}
private func ckJournalHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@MainActor
private final class BackgroundRefreshRun {
    private let done = XCTestExpectation(description: "background callback returned without waiting for unrelated work")
    private let task: Task<CloudKitBackgroundRefreshOutcome, Never>
    init(_ coordinator: CloudKitJournalSyncCoordinator, isForeground: Bool = false) {
        let done = done
        task = Task {
            let value = await coordinator.backgroundRefresh(isForeground: isForeground)
            done.fulfill()
            return value
        }
    }
    func result() async throws -> CloudKitBackgroundRefreshOutcome {
        guard await XCTWaiter.fulfillment(of: [done], timeout: 5) == .completed else {
            task.cancel()
            throw CloudKitSyncError.service("Background completion exceeded its controlled deadline")
        }
        return await task.value
    }
}

private final class ControlledRefreshDeadline: @unchecked Sendable {
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var canceled: Set<UUID> = []
    private let ignoresCancellation: Bool
    private let expectedRequests: Int
    private var registrationCount = 0
    private var registrationWaiters: [(Int, XCTestExpectation)] = []
    init(expectedRequests: Int = 1, ignoresCancellation: Bool = false) {
        self.expectedRequests = expectedRequests
        self.ignoresCancellation = ignoresCancellation
    }
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if canceled.remove(id) != nil { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                waiters.append(Waiter(id: id, continuation: continuation))
                registrationCount += 1
                let ready = registrationWaiters.filter { $0.0 <= registrationCount }.map { $0.1 }
                registrationWaiters.removeAll { $0.0 <= registrationCount }
                lock.unlock()
                for expectation in ready { expectation.fulfill() }
            }
        } onCancel: { self.cancel(id) }
    }
    private func cancel(_ id: UUID) {
        guard !ignoresCancellation else { return }
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let value = waiters.remove(at: index); lock.unlock()
            value.continuation.resume(throwing: CancellationError())
        } else { canceled.insert(id); lock.unlock() }
    }
    @discardableResult func fireNext() -> Bool {
        lock.lock()
        guard !waiters.isEmpty else { lock.unlock(); return false }
        let value = waiters.removeFirst(); lock.unlock(); value.continuation.resume()
        return true
    }
    func fireAll() { while fireNext() {} }
    private func registrationExpectation(count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "background deadline registered")
        lock.lock()
        let ready = registrationCount >= count
        if !ready { registrationWaiters.append((count, expectation)) }
        lock.unlock()
        if ready { expectation.fulfill() }
        return expectation
    }
    @MainActor func waitUntilRegistered(count: Int? = nil) async throws {
        let expectation = registrationExpectation(count: count ?? expectedRequests)
        guard await XCTWaiter.fulfillment(of: [expectation], timeout: 5) == .completed else { throw CloudKitSyncError.service("Deadline was not registered") }
    }
}

/// Holds an actual admitted coordinator database operation, with a watchdog only
/// to release resources if a regression blocks the MainActor callback itself.
private final class ControlledDatabaseOperation: @unchecked Sendable {
    private struct State { var armed = false; var exited = false }
    private let state = CKJournalLocked(State())
    private let entered = XCTestExpectation(description: "database operation admitted")
    private let resume = DispatchSemaphore(value: 0)
    var hasExited: Bool { state.value.exited }
    func arm() { state.change { $0.armed = true } }
    func enterIfArmed() {
        let hold = state.change { value in let armed = value.armed; value.armed = false; return armed }
        guard hold else { return }
        entered.fulfill()
        _ = resume.wait(timeout: .now() + 15)
        state.change { $0.exited = true }
    }
    func release() { resume.signal() }
    @MainActor func waitUntilEntered() async throws {
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 5) == .completed else {
            throw CloudKitSyncError.service("Database operation was not admitted")
        }
    }
}

private final class ControlledForegroundNetwork: CloudKitForegroundNetworkMonitoring, @unchecked Sendable {
    private let callback = CKJournalLocked<(@MainActor @Sendable (Bool) -> Void)?>(nil)
    func start(onAvailabilityChange: @escaping @MainActor @Sendable (Bool) -> Void) { callback.change { $0 = onAvailabilityChange } }
    func cancel() {} // Tests may deliberately deliver a late event after cancellation.
    @MainActor func send(_ available: Bool) { callback.value?(available) }
}
