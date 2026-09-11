import Foundation
import SQLite3
import XCTest
@testable import FinancesClone

@MainActor
final class CloudKitReceiptRecoveryTests: XCTestCase {
    private let context = "iCloud.synthetic.receipt-recovery|Development|Journal"
    private var fixtureStores: [MobileLedgerStore] = []
    private var fixtureDirectories: [URL] = []

    override func tearDown() async throws {
        for store in fixtureStores { await store.waitForCloudKitSyncIdle() }
        fixtureStores.removeAll()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for directory in fixtureDirectories { try FileManager.default.removeItem(at: directory) }
        fixtureDirectories.removeAll()
        try await super.tearDown()
    }

    private func reopen(_ root: URL) -> MobileLedgerStore {
        let store = MobileLedgerStore(supportDirectory: root)
        fixtureStores.append(store)
        return store
    }

    func testReopenBeforeFirstRenameKeepsCommittedReceipts() throws {
        let f = try fixture()
        _ = try CloudKitReceiptFileTransaction.prepare(f.changes, in: f.root)
        let reopened = reopen(f.root)
        XCTAssertFalse(reopened.requiresJournalRecovery)
        try assertOriginal(f)
        XCTAssertEqual(try f.store.cloudKitChangeToken(contextKey: context), Data([1]))
        try assertNoManifests(f)
    }

    func testReopenAfterEachPreCommitInterruptionRestoresOnlyOriginalFiles() throws {
        for stopAfter in 1...3 {
            let f = try fixture()
            let installation = try CloudKitReceiptFileTransaction.prepare(f.changes, in: f.root)
            var installed = 0
            XCTAssertThrowsError(try installation.install {
                installed += 1
                if installed == stopAfter { throw Interruption.stopped }
            })
            // Deliberately omit finish: discard all in-memory rollback knowledge,
            // just as a process termination would, then load through app startup.
            let reopened = reopen(f.root)
            XCTAssertFalse(reopened.requiresJournalRecovery)
            try assertOriginal(f)
            XCTAssertFalse(try f.store.isReceiptInstallationCommitted(installation.id))
            XCTAssertEqual(try f.store.cloudKitChangeToken(contextKey: context), Data([1]))
            try assertNoManifests(f)
        }
    }

    func testReopenBetweenOriginalBackupAndReplacementRestoresMissingPath() throws {
        let f = try fixture()
        let installation = try CloudKitReceiptFileTransaction.prepare(f.changes, in: f.root)
        let directory = f.root.appendingPathComponent(".icloud-receipt-installations/" + installation.id.uuidString)
        try FileManager.default.moveItem(at: f.replaced, to: directory.appendingPathComponent("old-0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.replaced.path))
        _ = reopen(f.root)
        try assertOriginal(f)
        try assertNoManifests(f)
    }

    func testReopenAfterSQLiteCommitKeepsNewFilesAndCleansOldVersions() throws {
        let f = try fixture()
        let installation = try CloudKitReceiptFileTransaction.prepare(f.changes, in: f.root)
        try installation.install()
        try f.store.persistCloudKitPull([], data: f.updatedData, previous: f.data, contextKey: context,
                                       changeToken: Data([2]), receiptInstallationID: installation.id)
        XCTAssertTrue(try f.store.isReceiptInstallationCommitted(installation.id))
        // Stop before file cleanup. The committed marker, not process memory,
        // decides whether recovery keeps or reverses this installation.
        let reopened = reopen(f.root)
        XCTAssertFalse(reopened.requiresJournalRecovery)
        XCTAssertEqual(try Data(contentsOf: f.replaced), Data("new replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.deleted.path))
        XCTAssertEqual(try Data(contentsOf: f.inserted), Data("new receipt".utf8))
        XCTAssertEqual(try Data(contentsOf: f.unrelated), Data("unrelated".utf8))
        XCTAssertEqual(try f.store.cloudKitChangeToken(contextKey: context), Data([2]))
        XCTAssertEqual(try f.store.loadData()?.transactions, f.updatedData.transactions)
        XCTAssertEqual(reopened.data.transactions, f.updatedData.transactions)
        XCTAssertFalse(try f.store.isReceiptInstallationCommitted(installation.id))
        try assertNoManifests(f)
        // Reopening again is a no-op, including after old backups are gone.
        _ = reopen(f.root)
        XCTAssertEqual(try Data(contentsOf: f.replaced), Data("new replacement".utf8))
    }

    func testFailedCommitMarkerRollsBackCheckpointAndRestoresFilesOnReopen() throws {
        let f = try fixture()
        let installation = try CloudKitReceiptFileTransaction.prepare(f.changes, in: f.root)
        try installation.install()
        try execute("""
            CREATE TRIGGER reject_receipt_commit BEFORE INSERT ON app_metadata
            WHEN NEW.key LIKE 'cloudkit_receipt_install:%'
            BEGIN SELECT RAISE(ABORT, 'synthetic receipt marker failure'); END;
            """, at: f.store.databaseURL)
        XCTAssertThrowsError(try f.store.persistCloudKitPull([], data: f.updatedData, previous: f.data,
            contextKey: context, changeToken: Data([2]), receiptInstallationID: installation.id))
        XCTAssertEqual(try f.store.cloudKitChangeToken(contextKey: context), Data([1]))
        XCTAssertFalse(try f.store.isReceiptInstallationCommitted(installation.id))
        _ = reopen(f.root)
        try assertOriginal(f)
        try assertNoManifests(f)
    }

    func testSecondRecoveryAfterPartialRollbackIsIdempotent() throws {
        let f = try fixture()
        let installation = try CloudKitReceiptFileTransaction.prepare(f.changes, in: f.root)
        try installation.install()
        let directory = f.root.appendingPathComponent(".icloud-receipt-installations/" + installation.id.uuidString)
        // Simulate recovery having restored one original before being killed.
        try FileManager.default.moveItem(at: directory.appendingPathComponent("old-1"), to: f.deleted)
        _ = reopen(f.root)
        try assertOriginal(f)
        try assertNoManifests(f)
    }

    func testCorruptManifestFailsStartupClosedWithoutDeletingSavedFiles() throws {
        let f = try fixture()
        let installation = try CloudKitReceiptFileTransaction.prepare(f.changes, in: f.root)
        let manifest = f.root.appendingPathComponent(".icloud-receipt-installations/\(installation.id.uuidString)/manifest.json")
        try Data("not a manifest".utf8).write(to: manifest)
        let reopened = reopen(f.root)
        XCTAssertTrue(reopened.requiresJournalRecovery)
        try assertOriginal(f)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }

    func testExistingHostRecoversInterruptedInstallBeforeExportingCommittedReceiptBytes() throws {
        let f = try fixture()
        let host = reopen(f.root)
        let installation = try CloudKitReceiptFileTransaction.prepare(f.changes, in: f.root)
        try installation.install()
        XCTAssertEqual(try Data(contentsOf: f.replaced), Data("new replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.deleted.path))

        let exported = try host.exportBackupFile()
        try assertOriginal(f)
        try assertNoManifests(f)
        let restored = try BackupArchive.prepareRestore(from: exported,
            workspace: f.root.appendingPathComponent("inspect-export"), progress: Progress(totalUnitCount: 1),
            localAttachmentURL: { host.attachmentURL(for: $0) }, validate: { try host.cloudKitValidate($0) })
        let assets = try XCTUnwrap(restored.data.transactions.first?.attachment?.assets)
        XCTAssertEqual(Set(assets.map(\.originalFilename)), ["replaced.txt", "deleted.txt"])
        for (filename, expected) in [("replaced.txt", "original replacement"), ("deleted.txt", "original deleted")] {
            let asset = try XCTUnwrap(assets.first { $0.originalFilename == filename })
            let file = restored.receipts.appendingPathComponent((asset.storedPath as NSString).lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: file), Data(expected.utf8))
        }
        XCTAssertEqual(host.data.transactions, f.data.transactions)
    }

    func testCorruptPendingManifestBlocksExportAndImportWithoutChangingJournalOrFiles() throws {
        let f = try fixture()
        let host = reopen(f.root)
        let installation = try CloudKitReceiptFileTransaction.prepare(f.changes, in: f.root)
        let manifest = f.root.appendingPathComponent(".icloud-receipt-installations/\(installation.id.uuidString)/manifest.json")
        try Data("corrupt pending recovery".utf8).write(to: manifest)
        XCTAssertThrowsError(try host.exportBackupFile())
        try assertOriginal(f)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))

        // A valid, receipt-free replacement would otherwise import successfully.
        var replacement = f.data
        replacement.transactions[0].note = "Must not replace the committed journal"
        replacement.transactions[0].attachment = nil
        let backup = f.root.appendingPathComponent("valid-replacement.json")
        try JSONEncoder.appEncoder.encode(replacement).write(to: backup)
        host.importBackup(from: backup)
        XCTAssertNotNil(host.validationError)
        XCTAssertEqual(host.data.transactions, f.data.transactions)
        try assertOriginal(f)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }

    func testCloneUnavailableUsesOwnedSourceRenameAndCanRecover() throws {
        let f = try fixture()
        let installation = try CloudKitReceiptFileTransaction.prepare(f.changes, in: f.root, cloneFile: { _, _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.changes[0].source!.path))
        try installation.install()
        _ = reopen(f.root)
        try assertOriginal(f)
        try assertNoManifests(f)
    }

    func testDuplicateOwnedSourceWithoutCloningFailsBeforeLiveFilesChange() throws {
        let f = try fixture()
        let reusedSource = try XCTUnwrap(f.changes[0].source)
        XCTAssertThrowsError(try CloudKitReceiptFileTransaction.prepare([
            .init(destination: f.replaced, source: reusedSource),
            .init(destination: f.inserted, source: reusedSource)
        ], in: f.root, cloneFile: { _, _ in false }))
        try assertOriginal(f)
        try assertNoManifests(f)
    }

    private enum Interruption: Error { case stopped }

    private struct Fixture {
        let root: URL
        let store: SQLiteJournalStore
        let data: JournalData
        let updatedData: JournalData
        let replaced: URL
        let deleted: URL
        let inserted: URL
        let unrelated: URL
        let changes: [CloudKitReceiptFileTransaction.Change]
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReceiptRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        fixtureDirectories.append(root)
        let replaced = root.appendingPathComponent("Attachments/replaced.txt")
        let deleted = root.appendingPathComponent("Attachments/deleted.txt")
        let inserted = root.appendingPathComponent("Attachments/inserted.txt")
        let unrelated = root.appendingPathComponent("Attachments/unrelated.txt")
        let replacement = root.appendingPathComponent("download-replacement")
        let insertion = root.appendingPathComponent("download-insert")
        try Data("original replacement".utf8).write(to: replaced)
        try Data("original deleted".utf8).write(to: deleted)
        try Data("unrelated".utf8).write(to: unrelated)
        try Data("new replacement".utf8).write(to: replacement)
        try Data("new receipt".utf8).write(to: insertion)
        let ledger = Ledger(name: "Receipt recovery fixture")
        let currency = Commodity(ledgerID: ledger.id, symbol: "USD", name: "Dollar")
        let checking = Account(ledgerID: ledger.id, commodityID: currency.id, name: "Checking", kind: .asset)
        let expense = Account(ledgerID: ledger.id, commodityID: currency.id, name: "Expense", kind: .expense)
        let receiptA = AttachmentAsset(originalFilename: "replaced.txt", storedPath: "Attachments/replaced.txt", mimeType: "text/plain", sizeBytes: 20)
        let receiptB = AttachmentAsset(originalFilename: "deleted.txt", storedPath: "Attachments/deleted.txt", mimeType: "text/plain", sizeBytes: 16)
        let transaction = LedgerTransaction(ledgerID: ledger.id, date: Date(timeIntervalSince1970: 1_700_000_000),
            payee: "Fixture", note: "Original receipt selection", number: "", cleared: true,
            postings: [Posting(accountID: checking.id, commodityID: currency.id, amount: -2),
                       Posting(accountID: expense.id, commodityID: currency.id, amount: 2, listIndex: 1)],
            attachment: AttachmentContainer(assets: [receiptA, receiptB], createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let data = JournalData(ledgers: [ledger], commodities: [currency], accounts: [checking, expense],
                               transactions: [transaction], selectedLedgerID: ledger.id)
        var updated = data
        updated.transactions[0].note = "New receipt selection"
        updated.transactions[0].attachment?.assets = [receiptA,
            AttachmentAsset(originalFilename: "inserted.txt", storedPath: "Attachments/inserted.txt", mimeType: "text/plain", sizeBytes: 11)]
        let store = SQLiteJournalStore(databaseURL: root.appendingPathComponent("journal.sqlite"))
        try store.replaceData(data, trackSyncChanges: false)
        _ = try store.bindCloudKitAccount(contextKey: context, accountID: "synthetic-user")
        try store.persistCloudKitPull([], data: data, previous: data, contextKey: context, changeToken: Data([1]))
        return Fixture(root: root, store: store, data: data, updatedData: updated, replaced: replaced, deleted: deleted,
                       inserted: inserted, unrelated: unrelated,
                       changes: [.init(destination: replaced, source: replacement),
                                 .init(destination: deleted, source: nil),
                                 .init(destination: inserted, source: insertion)])
    }

    private func assertOriginal(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: f.replaced), Data("original replacement".utf8), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: f.deleted), Data("original deleted".utf8), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.inserted.path), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: f.unrelated), Data("unrelated".utf8), file: file, line: line)
        XCTAssertEqual(try f.store.loadData()?.transactions, f.data.transactions, file: file, line: line)
    }

    private func assertNoManifests(_ f: Fixture) throws {
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent(".icloud-receipt-installations").path).isEmpty)
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ReceiptRecoveryTests", code: 1)
        }
    }
}
