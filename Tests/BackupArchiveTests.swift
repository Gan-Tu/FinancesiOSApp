import XCTest
import CryptoKit
import Darwin
import ZIPFoundation
@testable import FinancesClone

final class BackupArchiveTests: XCTestCase {
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
                LedgerTransaction(ledgerID: journal.id, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), payee: "Shop", note: "Receipt \(index)", number: "", cleared: true, postings: [Posting(accountID: cash.id, amount: -10), Posting(accountID: expense.id, amount: 10)], attachment: AttachmentContainer(assets: [AttachmentAsset(originalFilename: "Receipt.txt", storedPath: "Attachments/shared.txt", mimeType: "text/plain", sizeBytes: receiptSize)]))
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
