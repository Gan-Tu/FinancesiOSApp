import XCTest
import CryptoKit
import Darwin
import ZIPFoundation
@testable import FinancesClone

final class BackupArchiveTests: XCTestCase {
    @MainActor
    func testAsyncBackupDownloadsOnlyMissingReceiptsAndPreservesTheLiveJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackupDownload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        let remoteBytes = Data("Cloud receipt".utf8), localBytes = Data("Local receipt".utf8)
        let missing = AttachmentAsset(originalFilename: "Cloud.txt", storedPath: "Attachments/missing.txt", mimeType: "text/plain", sizeBytes: Int64(remoteBytes.count))
        let local = AttachmentAsset(originalFilename: "Local.txt", storedPath: "Attachments/local.txt", mimeType: "text/plain", sizeBytes: Int64(localBytes.count))
        try localBytes.write(to: directory.appendingPathComponent(local.storedPath))
        let cloudFile = directory.appendingPathComponent("RemoteBytes")
        try remoteBytes.write(to: cloudFile)
        let ledger = Ledger(name: "Backup QA"), currency = Commodity(ledgerID: ledger.id, symbol: "USD", name: "Dollar")
        let bank = Account(ledgerID: ledger.id, name: "Bank", kind: .asset), expense = Account(ledgerID: ledger.id, name: "Expense", kind: .expense)
        let container = AttachmentContainer(assets: [missing, local])
        let row = LedgerTransaction(ledgerID: ledger.id, date: Date(), payee: "Merchant", note: "Keep", number: "", cleared: true,
            postings: [Posting(accountID: bank.id, amount: -10), Posting(accountID: expense.id, amount: 10)], attachment: container)
        let data = JournalData(ledgers: [ledger], commodities: [currency], accounts: [bank, expense], transactions: [row], selectedLedgerID: ledger.id, syncEnabled: false)
        let remote = CloudKitSyncRecord(recordType: "attachment_asset", recordID: missing.id.uuidString,
            parentRecordID: container.id.uuidString, payloadJSON: String(decoding: try JSONEncoder.appEncoder.encode(missing), as: UTF8.self),
            assetFileURL: cloudFile, assetSHA256: SHA256.hash(data: remoteBytes).map { String(format: "%02x", $0) }.joined())
        let client = ExportReceiptTestTransport(record: remote)
        let dependencies = CloudKitSyncDependencies(configuration: { CloudKitSyncConfiguration() }, makeClient: { _ in client }, automaticTriggersEnabled: false)
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data, cloudKitSyncDependencies: dependencies)
        _ = try store.cloudKitSQLiteStore.bindCloudKitAccount(contextKey: "iCloud.dev.gan.FinanceApp|Development|FinancesJournal_v1", accountID: "backup-user")
        let before = try JSONEncoder.appEncoder.encode(store.data)
        let progress = Progress(totalUnitCount: 1)
        let output = try await store.exportBackupFileAsync(progress: progress)
        let zip = try Archive(url: output, accessMode: .read)
        func read(_ path: String) throws -> Data {
            let entry = try XCTUnwrap(zip[path]); var bytes = Data()
            _ = try zip.extract(entry) { bytes.append($0) }
            return bytes
        }
        let exported = try JSONDecoder.appDecoder.decode(JournalData.self, from: read("Journal.json"))
        for asset in try XCTUnwrap(exported.transactions.first?.attachment?.assets) {
            XCTAssertEqual(try read(asset.storedPath), asset.id == missing.id ? remoteBytes : localBytes)
        }
        XCTAssertEqual(client.requestedIDs, [missing.id.uuidString])
        XCTAssertTrue(client.wasCancelled, "The export must release the client's temporary download files")
        XCTAssertEqual(try JSONEncoder.appEncoder.encode(store.data), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.attachmentURL(for: missing).path))
        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertNil(try store.cloudKitSQLiteStore.cloudKitChangeToken(contextKey: "iCloud.dev.gan.FinanceApp|Development|FinancesJournal_v1"))
    }

    @MainActor
    func testAsyncBackupRejectsMissingChangedCorruptAndCancelledDownloads() async throws {
        for mode in ["unavailable", "corrupt", "changed", "version", "account", "unbound", "cancelled"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackupFailure-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bytes = Data("Cloud receipt".utf8), remoteFile = directory.appendingPathComponent("RemoteBytes")
            try bytes.write(to: remoteFile)
            let missing = AttachmentAsset(originalFilename: "Receipt.txt", storedPath: "Attachments/missing.txt", mimeType: "text/plain", sizeBytes: Int64(bytes.count))
            let ledger = Ledger(name: "Backup QA"), currency = Commodity(ledgerID: ledger.id, symbol: "USD", name: "Dollar")
            let bank = Account(ledgerID: ledger.id, name: "Bank", kind: .asset), expense = Account(ledgerID: ledger.id, name: "Expense", kind: .expense)
            let container = AttachmentContainer(assets: [missing])
            let row = LedgerTransaction(ledgerID: ledger.id, date: Date(), payee: "Merchant", note: "", number: "", cleared: true,
                postings: [Posting(accountID: bank.id, amount: -10), Posting(accountID: expense.id, amount: 10)], attachment: container)
            let data = JournalData(ledgers: [ledger], commodities: [currency], accounts: [bank, expense], transactions: [row], selectedLedgerID: ledger.id, syncEnabled: false)
            let remote = CloudKitSyncRecord(recordType: "attachment_asset", recordID: missing.id.uuidString,
                parentRecordID: mode == "changed" ? UUID().uuidString : container.id.uuidString,
                payloadJSON: String(decoding: try JSONEncoder.appEncoder.encode(missing), as: UTF8.self),
                assetFileURL: mode == "unavailable" ? nil : remoteFile,
                assetSHA256: mode == "corrupt" ? String(repeating: "0", count: 64) : SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            let progress = Progress(totalUnitCount: 1)
            let client = ExportReceiptTestTransport(record: remote, account: mode == "account" ? "different-user" : "backup-user", onFetch: {
                if mode == "cancelled" { progress.cancel() }
            })
            let dependencies = CloudKitSyncDependencies(configuration: { CloudKitSyncConfiguration() }, makeClient: { _ in client }, automaticTriggersEnabled: false)
            let store = MobileLedgerStore(supportDirectory: directory, initialData: data, cloudKitSyncDependencies: dependencies)
            if mode != "unbound" {
                _ = try store.cloudKitSQLiteStore.bindCloudKitAccount(contextKey: "iCloud.dev.gan.FinanceApp|Development|FinancesJournal_v1", accountID: "backup-user")
            }
            if mode == "version" {
                try store.cloudKitFlushLocalChanges()
                var known = remote; known.assetSHA256 = String(repeating: "f", count: 64)
                known.contentHash = SHA256.hash(data: Data(known.payloadJSON!.utf8)).map { String(format: "%02x", $0) }.joined()
                try store.cloudKitSQLiteStore.persistCloudKitPull([known], data: store.data, previous: store.data,
                    contextKey: "iCloud.dev.gan.FinanceApp|Development|FinancesJournal_v1", changeToken: nil)
            }
            let before = try JSONEncoder.appEncoder.encode(store.data)
            do { _ = try await store.exportBackupFileAsync(progress: progress); XCTFail("Expected \(mode) to fail") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
            XCTAssertNil(store.latestExportedBackup())
            XCTAssertEqual(try JSONEncoder.appEncoder.encode(store.data), before, mode)
            if mode == "account" || mode == "unbound" { XCTAssertTrue(client.requestedIDs.isEmpty) }
        }
    }

    @MainActor
    func testRetiredSourceMetadataDoesNotBlockRestoreEditOrReopen() throws {
        var fixture = try Fixture()
        defer { fixture.remove() }
        let ledgerID = try XCTUnwrap(fixture.data.ledgers.first?.id)
        // Historical feature metadata stays opaque, even when its contents are
        // unreadable. No retired feature decoder is needed to open the journal.
        fixture.data.sources = [
            TransactionSource(ledgerID: ledgerID, type: 0x4652,
                externalID: "finances.refund-tracking.v1:invalid historical metadata"),
            TransactionSource(ledgerID: ledgerID, type: 1, externalID: "existing-import-source")
        ]
        let archive = fixture.root.appendingPathComponent("Historical.zip")
        try BackupArchive.export(fixture.data, to: archive, progress: Progress(totalUnitCount: 1)) { _ in fixture.receipt }
        let directory = fixture.root.appendingPathComponent("restored-app")
        let store = MobileLedgerStore(supportDirectory: directory, initialData: JournalData())
        store.importBackup(from: archive)
        XCTAssertNil(store.validationError)
        XCTAssertFalse(store.requiresJournalRecovery)
        XCTAssertFalse(store.data.syncEnabled)
        XCTAssertEqual(Set(store.data.sources), Set(fixture.data.sources))
        let transaction = try XCTUnwrap(store.data.transactions.first)
        var draft = store.draft(for: transaction)
        draft.note = "Edited after historical restore"
        store.saveTransaction(draft)
        XCTAssertNil(store.validationError)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: directory)
        XCTAssertFalse(reopened.requiresJournalRecovery)
        XCTAssertEqual(Set(reopened.data.sources), Set(fixture.data.sources))
        let saved = try XCTUnwrap(reopened.transaction(transaction.id))
        XCTAssertEqual(saved.note, draft.note)
        XCTAssertEqual(saved.postings, transaction.postings)
        let receipt = try XCTUnwrap(saved.attachment?.assets.first)
        XCTAssertEqual(try Data(contentsOf: reopened.attachmentURL(for: receipt)), fixture.bytes)
    }

    func testZIPRoundTripPreservesMetadataAndSharedReceiptBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archiveURL = fixture.root.appendingPathComponent("Backup.zip")
        let progress = Progress(totalUnitCount: 1)
        try BackupArchive.export(fixture.data, to: archiveURL, progress: progress) { _ in fixture.receipt }
        XCTAssertEqual(progress.fractionCompleted, 1)
        let archive = try Archive(url: archiveURL, accessMode: .read)
        XCTAssertEqual(Array(archive).filter { $0.type == .file }.count, 2, "Shared receipt bytes are exported once")
        let restored = try fixture.restore(archiveURL)
        XCTAssertEqual(restored.data.ledgers, fixture.data.ledgers)
        XCTAssertEqual(restored.data.accounts, fixture.data.accounts)
        XCTAssertEqual(restored.data.commodities, fixture.data.commodities)
        XCTAssertEqual(restored.data.transactions.map(\.postings), fixture.data.transactions.map(\.postings))
        XCTAssertEqual(restored.data.transactions.map(\.date), fixture.data.transactions.map(\.date))
        XCTAssertEqual(restored.data.transactionTemplates, fixture.data.transactionTemplates)
        XCTAssertEqual(restored.data.security, fixture.data.security)
        XCTAssertFalse(restored.data.syncEnabled)
        XCTAssertNil(restored.data.lastSyncedAt)
        let assets = restored.data.transactions.flatMap { $0.attachment?.assets ?? [] }
        XCTAssertEqual(Set(assets.map(\.id)), Set(fixture.data.transactions.flatMap { $0.attachment?.assets.map(\.id) ?? [] }))
        XCTAssertEqual(Set(assets.map(\.storedPath)).count, 1)
        let file = restored.receipts.appendingPathComponent((try XCTUnwrap(assets.first).storedPath as NSString).lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: file), fixture.bytes)
    }

    func testLargeReceiptUsesBoundedMemoryAndRestoresItsDigest() throws {
        var fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = 192 * 1024 * 1024
        let writer = try FileHandle(forWritingTo: fixture.receipt)
        try writer.truncate(atOffset: 0)
        let chunk = Data(repeating: 0x6d, count: BackupArchive.bufferSize)
        for _ in 0..<(bytes / chunk.count) { try autoreleasepool { try writer.write(contentsOf: chunk) } }
        try writer.close()
        for index in fixture.data.transactions.indices { fixture.data.transactions[index].attachment?.assets[0].sizeBytes = Int64(bytes) }
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        let archive = fixture.root.appendingPathComponent("Large.zip")
        try BackupArchive.export(fixture.data, to: archive, progress: Progress(totalUnitCount: 1)) { _ in fixture.receipt }
        let restored = try fixture.restore(archive)
        let asset = try XCTUnwrap(restored.data.transactions[0].attachment?.assets.first)
        let received = restored.receipts.appendingPathComponent((asset.storedPath as NSString).lastPathComponent)
        XCTAssertEqual(try digest(received), try digest(fixture.receipt))
        XCTAssertEqual(try received.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes)
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        let growth = max(0, after.ru_maxrss - before.ru_maxrss)
        XCTAssertLessThan(growth, 96 * 1024 * 1024, "Receipt size must not become an in-memory JSON/base64 allocation")
        print("192 MiB backup round trip, peak RSS growth: \(growth) bytes")
    }

    func testPackagesAndLegacyMobileBackupsStillImport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = fixture.root.appendingPathComponent("Existing.fin", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try JSONEncoder.appEncoder.encode(fixture.data).write(to: package.appendingPathComponent("Journal.json"))
        try fixture.bytes.write(to: package.appendingPathComponent("Attachments/shared.txt"))
        let legacy = fixture.root.appendingPathComponent("Legacy.financesbackup")
        try JSONEncoder.appEncoder.encode(MobileBackupPayload(journalData: fixture.data, attachments: [MobileBackupAttachment(storedPath: "Attachments/shared.txt", originalFilename: "Receipt.txt", data: fixture.bytes)])).write(to: legacy)
        for input in [package, legacy] {
            let restored = try fixture.restore(input)
            XCTAssertEqual(restored.data.transactions.count, 2)
            let asset = try XCTUnwrap(restored.data.transactions[0].attachment?.assets.first)
            XCTAssertEqual(try Data(contentsOf: restored.receipts.appendingPathComponent((asset.storedPath as NSString).lastPathComponent)), fixture.bytes)
        }
    }

    func testWrappedMacZIPPackageImports() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archiveURL = fixture.root.appendingPathComponent("Mac.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let journal = try JSONEncoder.appEncoder.encode(fixture.data)
        try archive.addEntry(with: "Backup.fin/Journal.json", type: .file, uncompressedSize: Int64(journal.count)) { offset, count in journal.subdata(in: Int(offset)..<Int(offset) + count) }
        try archive.addEntry(with: "Backup.fin/Attachments/shared.txt", fileURL: fixture.receipt)
        let restored = try fixture.restore(archiveURL)
        XCTAssertEqual(restored.data.transactions.count, 2)
    }

    func testMissingCorruptAndUnrecognizedBackupsFailWithoutLeavingRestoreFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archiveURL = fixture.root.appendingPathComponent("Broken.zip")
        try BackupArchive.export(fixture.data, to: archiveURL, progress: Progress(totalUnitCount: 1)) { _ in fixture.receipt }
        var corrupt = try Data(contentsOf: archiveURL)
        let bytesRange = try XCTUnwrap(corrupt.range(of: fixture.bytes))
        corrupt[bytesRange.lowerBound] ^= 0xff
        try corrupt.write(to: archiveURL)
        let unrelated = fixture.root.appendingPathComponent("Other.json")
        try Data("{\"hello\":\"world\"}".utf8).write(to: unrelated)
        let malformedLegacy = fixture.root.appendingPathComponent("Malformed.json")
        try Data("{\"formatVersion\":1,\"journalData\":{}}".utf8).write(to: malformedLegacy)
        let missing = fixture.root.appendingPathComponent("Missing.fin", isDirectory: true)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try JSONEncoder.appEncoder.encode(fixture.data).write(to: missing.appendingPathComponent("Journal.json"))
        for input in [archiveURL, unrelated, malformedLegacy, missing] {
            let workspace = fixture.root.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(try BackupArchive.prepareRestore(from: input, workspace: workspace, progress: Progress(totalUnitCount: 1), localAttachmentURL: { _ in fixture.receipt }, validate: { _ in }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
            XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.bytes)
        }
    }

    func testCancellationAndInvalidPathsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let output = fixture.root.appendingPathComponent("Cancelled.zip")
        let progress = Progress(totalUnitCount: 1); progress.cancel()
        XCTAssertThrowsError(try BackupArchive.export(fixture.data, to: output, progress: progress) { _ in fixture.receipt })
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathExtension("partial").path))
        for path in ["../outside", "/absolute", "Attachments/../outside", "C:\\file", "a//b"] {
            XCTAssertThrowsError(try BackupArchive.safePath(path))
        }
        let oversized = fixture.root.appendingPathComponent("LargeLegacy.json")
        _ = FileManager.default.createFile(atPath: oversized.path, contents: Data())
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(BackupArchive.maximumLegacySize + 1)); try handle.close()
        XCTAssertThrowsError(try fixture.restore(oversized))
    }

    private func digest(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            let data = try autoreleasepool { try file.read(upToCount: BackupArchive.bufferSize) ?? Data() }
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize()
    }

    private struct Fixture {
        let root: URL
        let receipt: URL
        let bytes = Data("Unique synthetic receipt bytes for round-trip verification".utf8)
        var data: JournalData
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupArchiveTests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            receipt = root.appendingPathComponent("Receipt.txt")
            try bytes.write(to: receipt)
            let journal = Ledger(name: "Synthetic journal")
            let currency = Commodity(ledgerID: journal.id, symbol: "USD", name: "US Dollar")
            let cash = Account(ledgerID: journal.id, commodityID: currency.id, name: "Cash", kind: .asset)
            let expense = Account(ledgerID: journal.id, commodityID: currency.id, name: "Expense", kind: .expense)
            let receiptSize = Int64(bytes.count)
            let rows = (0..<2).map { index in
                LedgerTransaction(ledgerID: journal.id, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), payee: "Shop", note: "Receipt \(index)", number: "", cleared: true, postings: [Posting(accountID: cash.id, amount: -10), Posting(accountID: expense.id, amount: 10, listIndex: 1)], attachment: AttachmentContainer(assets: [AttachmentAsset(originalFilename: "Receipt.txt", storedPath: "Attachments/shared.txt", mimeType: "text/plain", sizeBytes: receiptSize)]))
            }
            data = JournalData(ledgers: [journal], commodities: [currency], accounts: [cash, expense], transactions: rows, selectedLedgerID: journal.id, lastSyncedAt: Date(), syncEnabled: true, security: SecuritySettings(passwordHash: "synthetic", passwordSalt: "salt"))
        }
        func restore(_ url: URL) throws -> PreparedBackupRestore {
            try BackupArchive.prepareRestore(from: url, workspace: root.appendingPathComponent("restore-" + UUID().uuidString), progress: Progress(totalUnitCount: 1), localAttachmentURL: { _ in receipt }, validate: { journal in
                XCTAssertEqual(journal.ledgers.count, data.ledgers.count)
                XCTAssertEqual(journal.transactions.count, data.transactions.count)
            })
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class ExportReceiptTestTransport: CloudKitSyncTransport, @unchecked Sendable {
    let record: CloudKitSyncRecord
    let account: String
    let onFetch: @Sendable () -> Void
    private let lock = NSLock()
    private var requests: [String] = []
    private var cancelled = false
    var requestedIDs: [String] { lock.withLock { requests } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    init(record: CloudKitSyncRecord, account: String = "backup-user", onFetch: @escaping @Sendable () -> Void = {}) {
        self.record = record; self.account = account; self.onFetch = onFetch
    }
    func accountIdentifier() async throws -> String { account }
    func prepareZone() async throws { throw CloudKitSyncError.service("Backup must not create a zone") }
    func fetchChanges(since: Data?) async throws -> CloudKitSyncPage { throw CloudKitSyncError.service("Backup must not run a global sync") }
    func modifyRecords(_ records: [CloudKitSyncRecord]) async throws -> CloudKitSyncModifyResult { throw CloudKitSyncError.service("Backup must not upload") }
    func fetchRecord(recordType: String, recordID: String) async throws -> CloudKitSyncRecord {
        lock.withLock { requests.append(recordID) }
        onFetch()
        return record
    }
    func cancel() { lock.withLock { cancelled = true } }
}
