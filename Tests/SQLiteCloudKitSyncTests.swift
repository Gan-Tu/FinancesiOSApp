import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import FinancesClone

final class SQLiteCloudKitSyncTests: XCTestCase {
    private let context = "iCloud.example.test|Development|Journal"
    private let account = "synthetic-user-record"

    func testAccountAndContextBindingCannotSilentlySwitchOrChangeJournal() throws {
        let f = try fixture(bind: false)
        XCTAssertTrue(try f.store.bindCloudKitAccount(contextKey: context, accountID: account))
        XCTAssertFalse(try f.store.bindCloudKitAccount(contextKey: context, accountID: account))
        XCTAssertThrowsError(try f.store.bindCloudKitAccount(contextKey: context, accountID: "another-user"))
        XCTAssertThrowsError(try f.store.bindCloudKitAccount(contextKey: "another-context", accountID: account))
        XCTAssertEqual(try f.store.cloudKitBoundContextKey(), context)
        XCTAssertEqual(try f.store.loadData()?.transactions, f.data.transactions)
        XCTAssertFalse(try XCTUnwrap(f.store.loadData()).syncEnabled)
    }

    func testMigrationFromVersionOnePreservesLegacyRowsAndOpaqueStateIsSeparate() throws {
        let f = try fixture(bind: false)
        try f.store.enqueueFullSyncSnapshot(f.data)
        let oldClaims = try f.store.claimPendingSyncChanges(limit: 1_000)
        try f.store.setLastPulledServerRevision(71)
        try makeVersionOne(f)
        XCTAssertEqual(try scalar("PRAGMA user_version", f), 1)
        XCTAssertTrue(try f.store.bindCloudKitAccount(contextKey: context, accountID: account))
        XCTAssertEqual(try scalar("PRAGMA user_version", f), 2)
        XCTAssertEqual(try f.store.claimPendingSyncChanges(limit: 1_000), oldClaims)
        XCTAssertEqual(try f.store.lastPulledServerRevision(), 71)
        XCTAssertNil(try f.store.cloudKitChangeToken(contextKey: context))
        XCTAssertTrue(try f.store.knownCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertEqual(try f.store.loadData()?.transactions, f.data.transactions)
        XCTAssertFalse(try XCTUnwrap(f.store.loadData()).syncEnabled)
    }

    func testFailedAdditiveMigrationDoesNotPublishVersionOrPartialTables() throws {
        let f = try fixture(bind: false)
        try makeVersionOne(f)
        try execute("CREATE VIEW cloudkit_records AS SELECT 1 AS incompatible", f)
        XCTAssertThrowsError(try f.store.bindCloudKitAccount(contextKey: context, accountID: account))
        XCTAssertEqual(try scalar("PRAGMA user_version", f), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='cloudkit_contexts'", f), 0)
        XCTAssertEqual(try f.store.loadData()?.transactions, f.data.transactions)
    }

    func testFirstCloudKitPreparationQueuesCFAcceptedRecordsAndReceiptsWithoutUsingIntegerTags() throws {
        let f = try fixture(receipt: true)
        try f.store.enqueueFullSyncSnapshot(f.data)
        let legacy = try f.store.claimPendingSyncChanges(limit: 1_000)
        try f.store.markSyncChangesAccepted(legacy.enumerated().map { index, row in
            SQLiteAcceptedSyncChange(clientChangeID: row.clientChangeID, recordType: row.recordType, recordID: row.recordID, serverRevision: Int64(100 + index))
        })
        try f.store.setLastPulledServerRevision(200)
        try f.store.markAttachmentUploaded(assetID: try XCTUnwrap(f.asset).id, serverRevision: 150)
        XCTAssertTrue(try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context))
        let claimed = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        XCTAssertEqual(claimed.count, legacy.count)
        XCTAssertTrue(Set(claimed.compactMap(\.clientChangeID)).isDisjoint(with: legacy.map(\.clientChangeID)))
        XCTAssertTrue(claimed.allSatisfy { $0.systemFields == nil })
        let receipt = try XCTUnwrap(claimed.first { $0.recordType == "attachment_asset" })
        XCTAssertNotNil(receipt.assetSHA256)
        XCTAssertEqual(receipt.parentRecordID, f.data.transactions[0].attachment?.id.uuidString)
        XCTAssertEqual(receipt.assetFilename, f.asset?.originalFilename)
        XCTAssertEqual(receipt.assetFileURL, f.directory.appending(path: try XCTUnwrap(f.asset).storedPath))
        XCTAssertEqual(try f.store.lastPulledServerRevision(), 200)
    }

    func testPreparationUsesPersistedRowsAndKeepsEveryExistingPendingAndInFlightID() throws {
        let f = try fixture()
        var first = f.data; first.ledgers[0].name = "First local edit"
        try f.store.persist(first, previous: f.data)
        let claimed = try f.store.claimPendingSyncChanges()
        var newer = first; newer.ledgers[0].name = "Newer local edit"
        try f.store.persist(newer, previous: first)
        let before = try scalar("SELECT COUNT(*) FROM sync_outbox WHERE record_type='ledger'", f)
        XCTAssertTrue(try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sync_outbox WHERE record_type='ledger'", f), before)
        let ckClaim = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context, limit: 1_000).first { $0.recordType == "ledger" })
        XCTAssertEqual(ckClaim.clientChangeID, claimed.first?.clientChangeID)
        XCTAssertEqual(ckClaim.payloadJSON, claimed.first?.payloadJSON)
        XCTAssertEqual(try f.store.loadData()?.ledgers, newer.ledgers)
        let count = try scalar("SELECT COUNT(*) FROM sync_outbox", f)
        XCTAssertFalse(try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sync_outbox", f), count)
    }

    func testEmptyDeviceDefaultMetadataDoesNotConflictOrReuploadOverRemotePreferences() throws {
        let f = try fixture(empty: true)
        try f.store.enqueueFullSyncSnapshot(f.data)
        XCTAssertTrue(try f.store.pendingCloudKitRecords(contextKey: context).isEmpty)
        var remoteData = f.data; remoteData.dateFormat = .iso
        let remote = try record("journal_metadata", id: SQLiteSyncedJournalMetadata.recordID, payload: SQLiteSyncedJournalMetadata(data: remoteData), tag: 1)
        try f.store.persistCloudKitPull([remote], data: remoteData, previous: f.data, contextKey: context, changeToken: Data([0, 1, 0, 255]))
        XCTAssertTrue(try f.store.pendingCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertTrue(try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context))
        XCTAssertTrue(try f.store.claimCloudKitChanges(contextKey: context).isEmpty)
        XCTAssertEqual(try f.store.loadData()?.dateFormat, .iso)
        XCTAssertEqual(try f.store.cloudKitChangeToken(contextKey: context), Data([0, 1, 0, 255]))
    }

    func testNondefaultLocalPreferencesRemainProtectedOnAnEmptyDevice() throws {
        let f = try fixture(empty: true)
        var edited = f.data; edited.appearance = .dark
        try f.store.persist(edited, previous: f.data)
        XCTAssertFalse(try f.store.pendingCloudKitRecords(contextKey: context).isEmpty)
        let remote = try record("journal_metadata", id: SQLiteSyncedJournalMetadata.recordID, payload: SQLiteSyncedJournalMetadata(data: f.data), tag: 1)
        XCTAssertThrowsError(try f.store.persistCloudKitPull([remote], data: f.data, previous: edited, contextKey: context, changeToken: Data([1])))
        XCTAssertEqual(try f.store.loadData()?.appearance, .dark)
        XCTAssertNil(try f.store.cloudKitChangeToken(contextKey: context))
    }

    func testPartialAcknowledgementPreservesNewerLocalEditAndUsesOpaqueCASFields() throws {
        let f = try fixture()
        try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context)
        let claimed = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        let original = try XCTUnwrap(claimed.first { $0.recordType == "ledger" })
        var edited = f.data; edited.ledgers[0].name = "Newer local edit"
        try f.store.persist(edited, previous: f.data)
        var saved = original; saved.systemFields = Data([0, 42, 0, 7])
        try f.store.acknowledgeCloudKitRecords([saved], submitted: claimed, contextKey: context)
        let successor = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context, limit: 1_000).first { $0.recordType == "ledger" })
        XCTAssertNotEqual(successor.clientChangeID, original.clientChangeID)
        XCTAssertTrue(successor.payloadJSON?.contains("Newer local edit") == true)
        XCTAssertEqual(successor.systemFields, saved.systemFields)
        XCTAssertEqual(try f.store.lastPulledServerRevision(), 0)
        XCTAssertNil(try f.store.cloudKitChangeToken(contextKey: context))
        var malformed = saved; malformed.contentHash = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try f.store.acknowledgeCloudKitRecords([malformed], submitted: claimed, contextKey: context))
    }

    func testOtherDeviceEquivalentRecordAcknowledgesOurIDAndKeepsServerIdentity() throws {
        let f = try fixture()
        try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context)
        let claimed = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        let local = try XCTUnwrap(claimed.first { $0.recordType == "ledger" })
        var remote = local; remote.clientChangeID = UUID().uuidString; remote.systemFields = Data([8, 3])
        XCTAssertThrowsError(try f.store.acknowledgeCloudKitRecords([remote], submitted: [local], contextKey: context))
        try f.store.acknowledgeCloudKitEquivalentRecords([remote], submitted: [local], contextKey: context)
        XCTAssertTrue(try f.store.hasAcknowledgedCloudKitMutation(local, contextKey: context))
        XCTAssertEqual(try f.store.knownCloudKitRecord(forKey: local.key, contextKey: context)?.clientChangeID, remote.clientChangeID)
        XCTAssertFalse(try f.store.pendingCloudKitRecords(contextKey: context).keys.contains(local.key))
    }

    func testReceiptEchoRequiresFrozenBlobChecksumEvenAfterLocalFileDeletion() throws {
        let f = try fixture(receipt: true)
        try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context)
        let claimed = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        let local = try XCTUnwrap(claimed.first { $0.recordType == "attachment_asset" })
        try FileManager.default.removeItem(at: try XCTUnwrap(local.assetFileURL))
        var remote = local; remote.assetFileURL = nil; remote.systemFields = Data([2, 3])
        XCTAssertTrue(try f.store.isCloudKitReceiptUploadEcho(remote, contextKey: context))
        var wrongBytes = remote; wrongBytes.assetSHA256 = String(repeating: "0", count: 64)
        XCTAssertFalse(try f.store.isCloudKitReceiptUploadEcho(wrongBytes, contextKey: context))
        XCTAssertThrowsError(try f.store.acknowledgeCloudKitRecords([wrongBytes], submitted: [local], contextKey: context))
        var missingSHA = remote; missingSHA.assetSHA256 = nil
        XCTAssertFalse(try f.store.isCloudKitReceiptUploadEcho(missingSHA, contextKey: context))
        XCTAssertFalse(try f.store.pendingCloudKitRecords(contextKey: context).isEmpty)
    }

    func testPullCursorRecordsAndEchoAcceptanceRollBackTogether() throws {
        let f = try fixture()
        try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context)
        let claimed = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        let before = try f.store.pendingSyncChanges(limit: 1_000)
        let remote = claimed.map { row -> CloudKitSyncRecord in var copy = row; copy.systemFields = Data([4]); return copy }
        try execute("CREATE TRIGGER reject_cloudkit_cursor BEFORE UPDATE OF change_token ON cloudkit_contexts BEGIN SELECT RAISE(ABORT, 'injected cursor failure'); END", f)
        XCTAssertThrowsError(try f.store.persistCloudKitPull(remote, data: f.data, previous: f.data, contextKey: context, changeToken: Data([1, 2])))
        XCTAssertTrue(try f.store.knownCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertEqual(try f.store.pendingSyncChanges(limit: 1_000), before)
        XCTAssertNil(try f.store.cloudKitChangeToken(contextKey: context))
        try execute("DROP TRIGGER reject_cloudkit_cursor", f)
        try f.store.persistCloudKitPull(remote, data: f.data, previous: f.data, contextKey: context, changeToken: Data([1, 2]))
        XCTAssertTrue(try f.store.pendingCloudKitRecords(contextKey: context).isEmpty)
    }

    func testResetFullRefetchDrainsEquivalentBootstrapIncludingReceiptsAndRebuildsCASState() throws {
        let f = try fixture(receipt: true)
        try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context)
        let claimed = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        let saved = claimed.map { row -> CloudKitSyncRecord in var copy = row; copy.systemFields = Data([8]); return copy }
        try f.store.acknowledgeCloudKitRecords(saved, submitted: claimed, contextKey: context)
        try f.store.resetCloudKitSyncState(contextKey: context)
        XCTAssertTrue(try f.store.knownCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertEqual(try f.store.cloudKitBoundContextKey(), context)
        XCTAssertTrue(try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context))
        let queued = try f.store.pendingCloudKitRecords(contextKey: context)
        XCTAssertEqual(queued.count, saved.count)
        XCTAssertNotNil(queued.values.first { $0.recordType == "attachment_asset" })
        try f.store.persistCloudKitPull(saved, data: f.data, previous: f.data, contextKey: context, changeToken: Data())
        XCTAssertTrue(try f.store.pendingCloudKitRecords(contextKey: context).isEmpty)
        XCTAssertTrue(try f.store.claimCloudKitChanges(contextKey: context).isEmpty, "Equal refetched records and receipt must not be pushed/uploaded again")
        XCTAssertTrue(try f.store.pendingAttachmentUploads().isEmpty)
        XCTAssertEqual(try f.store.knownCloudKitRecords(contextKey: context).count, saved.count)
        XCTAssertEqual(try f.store.cloudKitSystemFields(forKey: saved[0].key, contextKey: context), Data([8]))
        XCTAssertEqual(try f.store.cloudKitChangeToken(contextKey: context), Data())
        var enabled = f.data; enabled.syncEnabled = true
        try f.store.persist(enabled, previous: f.data)
        XCTAssertThrowsError(try f.store.resetCloudKitSyncState(contextKey: context))
        XCTAssertEqual(try f.store.cloudKitChangeToken(contextKey: context), Data())
    }

    func testOldAcknowledgedEchoDoesNotRollBackNewerKnownRecordWithoutPendingEdits() throws {
        let f = try fixture()
        try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context)
        let initial = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        let savedInitial = initial.map { row -> CloudKitSyncRecord in var copy = row; copy.systemFields = Data([1]); return copy }
        try f.store.acknowledgeCloudKitRecords(savedInitial, submitted: initial, contextKey: context)
        let old = try XCTUnwrap(savedInitial.first { $0.recordType == "ledger" })
        var updated = f.data; updated.ledgers[0].name = "Newer acknowledged value"
        try f.store.persist(updated, previous: f.data)
        let next = try f.store.claimCloudKitChanges(contextKey: context)
        var latest = try XCTUnwrap(next.first); latest.systemFields = Data([2])
        try f.store.acknowledgeCloudKitRecords([latest], submitted: next, contextKey: context)
        XCTAssertTrue(try f.store.hasAcknowledgedCloudKitMutation(old, contextKey: context))
        try f.store.persistCloudKitPull([old], data: updated, previous: updated, contextKey: context, changeToken: Data([3]))
        XCTAssertEqual(try f.store.knownCloudKitRecord(forKey: latest.key, contextKey: context)?.systemFields, latest.systemFields)
        XCTAssertEqual(try f.store.loadData()?.ledgers, updated.ledgers)
        // A user may subsequently choose to revert to A. The old A echo is
        // still not proof that this new intent exists on the known-B server.
        try f.store.persist(f.data, previous: updated)
        let reversion = try XCTUnwrap(f.store.pendingCloudKitRecords(contextKey: context)[old.key])
        XCTAssertNotEqual(reversion.clientChangeID, old.clientChangeID)
        try f.store.persistCloudKitPull([old], data: f.data, previous: f.data, contextKey: context, changeToken: Data([4]))
        XCTAssertEqual(try f.store.pendingCloudKitRecords(contextKey: context)[old.key]?.clientChangeID, reversion.clientChangeID)
        XCTAssertEqual(try f.store.knownCloudKitRecord(forKey: latest.key, contextKey: context)?.systemFields, latest.systemFields)
    }

    func testFirstJoinIncludesHistoricalTombstonesAndRemoteUnknownDeletePreventsRecurrenceResurrection() throws {
        let f = try fixture(empty: true)
        let id = UUID()
        try execute("INSERT INTO sync_tombstones(record_type, record_id, content_hash, deleted_at, server_revision) VALUES ('transaction', '\(id.uuidString)', 'legacy-hash', '2026-01-01', 77)", f)
        XCTAssertTrue(try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context))
        let deletion = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context).first { $0.recordID == id.uuidString })
        XCTAssertEqual(deletion.operation, "delete")
        let other = try fixture(empty: true)
        var remote = deletion; remote.clientChangeID = UUID().uuidString; remote.contentHash = nil; remote.systemFields = Data([5])
        try other.store.persistCloudKitPull([remote], data: other.data, previous: other.data, contextKey: context, changeToken: Data([6]))
        XCTAssertTrue(try other.store.deletedTransactionIDs().contains(id))
        let restarted = SQLiteJournalStore(databaseURL: other.store.databaseURL)
        XCTAssertTrue(try restarted.deletedTransactionIDs().contains(id))
        try f.store.acknowledgeCloudKitEquivalentRecords([remote], submitted: [deletion], contextKey: context)
        XCTAssertTrue(try f.store.hasAcknowledgedCloudKitMutation(deletion, contextKey: context))
    }

    func testConflictVersionsKeepBothPayloadsAndOnlyLatestDialogCanResolve() throws {
        let f = try fixture()
        try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context)
        let local = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context, limit: 1_000).first { $0.recordType == "ledger" })
        var remoteLedger = f.data.ledgers[0]; remoteLedger.name = "First remote choice"
        let first = try record("ledger", id: remoteLedger.id, payload: remoteLedger, tag: 1)
        try f.store.saveCloudKitConflict(local: local, remote: first, contextKey: context)
        let oldID = try XCTUnwrap(f.store.unresolvedCloudKitConflicts(contextKey: context).first?.id)
        remoteLedger.name = "Latest remote choice"
        let second = try record("ledger", id: remoteLedger.id, payload: remoteLedger, tag: 2)
        try f.store.saveCloudKitConflict(local: local, remote: second, contextKey: context)
        let conflicts = try f.store.unresolvedCloudKitConflicts(contextKey: context)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertNotEqual(conflicts[0].id, oldID)
        XCTAssertEqual(conflicts[0].local.payloadJSON, local.payloadJSON)
        XCTAssertEqual(conflicts[0].remote.payloadJSON, second.payloadJSON)
        XCTAssertThrowsError(try f.store.resolveCloudKitConflict(id: oldID, keepLocal: true, contextKey: context, data: f.data, previous: f.data))
        try f.store.resolveCloudKitConflict(id: conflicts[0].id, keepLocal: true, contextKey: context, data: f.data, previous: f.data)
        XCTAssertTrue(try f.store.unresolvedCloudKitConflicts(contextKey: context).isEmpty)
        let retry = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context, limit: 1_000).first { $0.key == local.key })
        XCTAssertEqual(retry.clientChangeID, local.clientChangeID)
        XCTAssertEqual(retry.payloadJSON, local.payloadJSON)
        XCTAssertEqual(retry.systemFields, second.systemFields)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM cloudkit_conflicts", f), 2)
    }

    func testUseRemoteCannotDiscardNewerUnacknowledgedLocalEdit() throws {
        let f = try fixture()
        try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context)
        let local = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context, limit: 1_000).first { $0.recordType == "ledger" })
        var remoteData = f.data; remoteData.ledgers[0].name = "Remote value"
        let remote = try record("ledger", id: remoteData.ledgers[0].id, payload: remoteData.ledgers[0], tag: 9)
        try f.store.saveCloudKitConflict(local: local, remote: remote, contextKey: context)
        let id = try XCTUnwrap(f.store.unresolvedCloudKitConflicts(contextKey: context).first?.id)
        var newer = f.data; newer.ledgers[0].name = "Newer local value"
        try f.store.persist(newer, previous: f.data)
        let pending = try f.store.pendingSyncChanges(limit: 1_000)
        XCTAssertThrowsError(try f.store.resolveCloudKitConflict(id: id, keepLocal: false, contextKey: context, data: remoteData, previous: newer))
        XCTAssertEqual(try f.store.loadData()?.ledgers, newer.ledgers)
        XCTAssertEqual(try f.store.pendingSyncChanges(limit: 1_000), pending)
        try f.store.resolveCloudKitConflict(id: id, keepLocal: false, contextKey: context, data: newer, previous: newer)
        let next = try XCTUnwrap(f.store.pendingCloudKitRecords(contextKey: context)[local.key])
        XCTAssertNotEqual(next.clientChangeID, local.clientChangeID)
        XCTAssertTrue(next.payloadJSON?.contains("Newer local value") == true)
    }

    func testRemoteTransactionMirrorEnablesLaterLocalDeleteWithItsCloudKitCASBase() throws {
        let f = try fixture()
        var added = f.data.transactions[0]
        added.id = UUID()
        added.postings = added.postings.map { posting in var copy = posting; copy.id = UUID(); return copy }
        added.payee = "Remote-only purchase"
        var received = f.data; received.transactions.append(added)
        let remote = try record("transaction", id: added.id, payload: added, tag: 12)
        try f.store.persistCloudKitPull([remote], data: received, previous: f.data, contextKey: context, changeToken: Data([12]))
        try f.store.persist(f.data, previous: received)
        let deletion = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context).first { $0.recordID == added.id.uuidString })
        XCTAssertEqual(deletion.operation, "delete")
        XCTAssertEqual(deletion.systemFields, remote.systemFields)
    }

    func testIdlePullDoesNotRewriteCanonicalSyncRecords() throws {
        let f = try fixture()
        try execute("CREATE TRIGGER reject_idle_mirror_rewrite BEFORE UPDATE ON sync_records BEGIN SELECT RAISE(ABORT, 'idle mirror rewrite'); END", f)
        try f.store.persistCloudKitPull([], data: f.data, previous: f.data, contextKey: context, changeToken: Data([42]))
        XCTAssertEqual(try f.store.cloudKitChangeToken(contextKey: context), Data([42]))
        XCTAssertEqual(try f.store.loadData()?.transactions, f.data.transactions)
    }

    func testSameMetadataSameSizeRemoteReceiptRefreshesCachedSHAForLaterClaims() throws {
        let f = try fixture(receipt: true)
        try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context)
        let claimed = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        let saved = claimed.map { value -> CloudKitSyncRecord in var copy = value; copy.systemFields = Data([1]); copy.assetFileURL = nil; return copy }
        try f.store.acknowledgeCloudKitRecords(saved, submitted: claimed, contextKey: context)
        let original = try XCTUnwrap(saved.first { $0.recordType == "attachment_asset" })
        let file = f.directory.appending(path: try XCTUnwrap(f.asset).storedPath)
        let count = try Data(contentsOf: file).count
        let replacement = Data(repeating: 66, count: count)
        let replacementSHA = SHA256.hash(data: replacement).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(original.assetSHA256, replacementSHA)
        try replacement.write(to: file, options: .atomic)
        var remote = original
        remote.clientChangeID = UUID().uuidString
        remote.assetSHA256 = replacementSHA
        remote.systemFields = Data([2])
        try f.store.persistCloudKitPull([remote], data: f.data, previous: f.data, contextKey: context, changeToken: Data([2]))
        XCTAssertTrue(try f.store.pendingAttachmentUploads().isEmpty)

        var renamed = f.data
        renamed.transactions[0].attachment?.assets[0].originalFilename = "renamed.txt"
        try f.store.persist(renamed, previous: f.data)
        let next = try XCTUnwrap(f.store.claimCloudKitChanges(contextKey: context).first { $0.recordType == "attachment_asset" })
        XCTAssertEqual(next.assetSHA256, replacementSHA, "Same-sized verified remote bytes must replace the old cached SHA")
        XCTAssertEqual(next.systemFields, remote.systemFields)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(next.assetFileURL)), replacement)
    }

    func testOldReceiptEchoDoesNotReplaceNewerLocalSHAOrBytes() throws {
        let f = try fixture(receipt: true)
        try f.store.prepareInitialCloudKitSnapshot(f.data, contextKey: context)
        let claimed = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        let saved = claimed.map { value -> CloudKitSyncRecord in var copy = value; copy.systemFields = Data([1]); copy.assetFileURL = nil; return copy }
        try f.store.acknowledgeCloudKitRecords(saved, submitted: claimed, contextKey: context)
        let oldEcho = try XCTUnwrap(saved.first { $0.recordType == "attachment_asset" })
        let file = f.directory.appending(path: try XCTUnwrap(f.asset).storedPath)
        let newerBytes = Data(repeating: 67, count: try Data(contentsOf: file).count)
        let newerSHA = SHA256.hash(data: newerBytes).map { String(format: "%02x", $0) }.joined()
        try newerBytes.write(to: file, options: .atomic)
        // Model a newer durable local blob version with unchanged JSON/size.
        try execute("UPDATE attachment_assets SET sha256='\(newerSHA)', upload_state='pending' WHERE id='\(oldEcho.recordID)'", f)
        try f.store.enqueueFullSyncSnapshot(f.data)
        let pending = try f.store.claimCloudKitChanges(contextKey: context, limit: 1_000)
        let newer = try XCTUnwrap(pending.first { $0.recordType == "attachment_asset" })
        XCTAssertEqual(newer.assetSHA256, newerSHA)
        try f.store.persistCloudKitPull([oldEcho], data: f.data, previous: f.data, contextKey: context, changeToken: Data([3]))
        XCTAssertEqual(try f.store.pendingAttachmentUploads().first?.sha256, newerSHA)
        XCTAssertEqual(try f.store.pendingCloudKitRecords(contextKey: context)[oldEcho.key]?.clientChangeID, newer.clientChangeID)
        XCTAssertEqual(try Data(contentsOf: file), newerBytes)
    }

    private struct Fixture {
        var store: SQLiteJournalStore
        var data: JournalData
        var directory: URL
        var asset: AttachmentAsset?
    }

    private func fixture(receipt: Bool = false, empty: Bool = false, bind: Bool = true) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SQLiteCloudKitSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var data = JournalData()
        var asset: AttachmentAsset?
        if !empty {
            let ledger = Ledger(name: "Synthetic journal")
            let cash = Account(ledgerID: ledger.id, name: "Cash", kind: .asset)
            let expense = Account(ledgerID: ledger.id, name: "Expense", kind: .expense)
            var attachment: AttachmentContainer?
            if receipt {
                let bytes = Data("Synthetic CloudKit receipt".utf8)
                asset = AttachmentAsset(originalFilename: "receipt.txt", storedPath: "Attachments/receipt.txt", mimeType: "text/plain", sizeBytes: Int64(bytes.count))
                try FileManager.default.createDirectory(at: directory.appending(path: "Attachments"), withIntermediateDirectories: true)
                try bytes.write(to: directory.appending(path: "Attachments/receipt.txt"))
                attachment = AttachmentContainer(assets: [asset!], createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            }
            data.ledgers = [ledger]; data.accounts = [cash, expense]
            data.transactions = [LedgerTransaction(ledgerID: ledger.id, date: Date(timeIntervalSince1970: 1_700_000_000), payee: "Synthetic purchase", note: "", number: "", cleared: false, postings: [Posting(accountID: cash.id, amount: -10), Posting(accountID: expense.id, amount: 10)], attachment: attachment)]
        }
        let store = SQLiteJournalStore(databaseURL: directory.appending(path: "journal.sqlite"))
        try store.replaceData(data, trackSyncChanges: false)
        if bind { _ = try store.bindCloudKitAccount(contextKey: context, accountID: account) }
        return Fixture(store: store, data: data, directory: directory, asset: asset)
    }

    private func record<T: Encodable>(_ type: String, id: UUID, payload: T, tag: UInt8) throws -> CloudKitSyncRecord {
        let bytes = try JSONEncoder.appEncoder.encode(payload)
        return CloudKitSyncRecord(recordType: type, recordID: id.uuidString, contentHash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), payloadJSON: String(decoding: bytes, as: UTF8.self), clientChangeID: UUID().uuidString, systemFields: Data([tag]))
    }

    private func makeVersionOne(_ f: Fixture) throws {
        try execute("DROP TABLE cloudkit_conflicts; DROP TABLE cloudkit_receipt_claims; DROP TABLE cloudkit_mutation_receipts; DROP TABLE cloudkit_records; DROP TABLE cloudkit_contexts; PRAGMA user_version=1", f)
    }

    private func execute(_ sql: String, _ f: Fixture) throws {
        var db: OpaquePointer?
        guard sqlite3_open(f.store.databaseURL.path, &db) == SQLITE_OK, let db else { throw SQLiteJournalStoreError.openFailed("Synthetic fixture") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteJournalStoreError.stepFailed(String(cString: sqlite3_errmsg(db))) }
    }

    private func scalar(_ sql: String, _ f: Fixture) throws -> Int {
        var db: OpaquePointer?; var statement: OpaquePointer?
        guard sqlite3_open(f.store.databaseURL.path, &db) == SQLITE_OK, let db else { throw SQLiteJournalStoreError.openFailed("Synthetic fixture") }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteJournalStoreError.stepFailed("Synthetic scalar query") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
