import AppIntents
import Foundation
import XCTest
@testable import FinancesClone

@MainActor
final class SharedReceiptEntryTests: XCTestCase {
    private final class ScopeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var begins = 0
        private var ends = 0
        private var usedMainThread = false
        func begin(_ url: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            begins += 1; usedMainThread = usedMainThread || Thread.isMainThread
            return true
        }
        func end(_ url: URL) { lock.lock(); ends += 1; lock.unlock() }
        func counts() -> (Int, Int, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (begins, ends, usedMainThread)
        }
    }

    private var directories: [URL] = []
    override func tearDown() async throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testMultipleFilesAreOwnedBeforeUnlockAndSurviveInboxRecreation() async throws {
        let root = try directory()
        let first = try source("one/Receipt.pdf", bytes: Data("first pdf".utf8), in: root)
        let second = try source("two/Receipt.pdf", bytes: Data("second pdf".utf8), in: root)
        let probe = ScopeProbe()
        let location = root.appendingPathComponent("inbox")
        let inbox = SharedReceiptInbox(directory: location, access: .init(begin: probe.begin, end: probe.end))
        let entry = try await inbox.stage([first, second])
        XCTAssertEqual(entry.files.map(\.filename), ["Receipt.pdf", "Receipt.pdf"])
        XCTAssertEqual(Set(entry.files.map(\.id)).count, 2)
        XCTAssertEqual(probe.counts().0, 2)
        XCTAssertEqual(probe.counts().1, 2)
        XCTAssertFalse(probe.counts().2, "File scopes and provider reads must execute off the main actor")
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        // Waiting for app unlock or an existing editor no longer depends on
        // ephemeral sender URLs or an unreleased security scope.
        let reopened = SharedReceiptInbox(directory: location)
        let pending = try await reopened.pendingEntries()
        XCTAssertEqual(pending, [entry])
        let files = try await reopened.fileURLs(for: entry)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, [Data("first pdf".utf8), Data("second pdf".utf8)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("journal.sqlite").path))
    }

    func testFailedBatchPublishesNothingAndClosesEverySourceScope() async throws {
        let root = try directory()
        let source = try source("Receipt.pdf", bytes: Data("keep source".utf8), in: root)
        let probe = ScopeProbe()
        let inbox = SharedReceiptInbox(directory: root.appendingPathComponent("inbox"), access: .init(begin: probe.begin, end: probe.end))
        do {
            _ = try await inbox.stage([source, root.appendingPathComponent("missing.pdf")])
            XCTFail("A partial receipt batch must not be published")
        } catch {}
        let pending = try await inbox.pendingEntries()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(probe.counts().0, 2)
        XCTAssertEqual(probe.counts().1, 2)
        XCTAssertEqual(try Data(contentsOf: source), Data("keep source".utf8))
        let children = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("inbox").path)
        XCTAssertTrue(children.isEmpty)
    }

    func testCancellationBeforeStagingLeavesOriginalAndPendingEntriesUntouched() async throws {
        let root = try directory()
        let source = try source("Receipt.png", bytes: Data([137, 80, 78, 71]), in: root)
        let inbox = SharedReceiptInbox(directory: root.appendingPathComponent("inbox"))
        let existing = try await inbox.stage([source])
        let progress = Progress(totalUnitCount: 1); progress.cancel()
        do { _ = try await inbox.stage([source], progress: progress); XCTFail("Canceled staging must not publish") }
        catch is CancellationError {}
        let pending = try await inbox.pendingEntries()
        XCTAssertEqual(pending, [existing])
        XCTAssertEqual(try Data(contentsOf: source), Data([137, 80, 78, 71]))
    }

    func testDiscardRemovesOnlySelectedBatchAndDoesNotDeleteSenderFiles() async throws {
        let root = try directory()
        let source = try source("Receipt.pdf", bytes: Data("source".utf8), in: root)
        let inbox = SharedReceiptInbox(directory: root.appendingPathComponent("inbox"))
        let first = try await inbox.stage([source])
        let second = try await inbox.stage([source])
        try await inbox.discard(first.id)
        try await inbox.discard(first.id)
        let pending = try await inbox.pendingEntries()
        XCTAssertEqual(pending, [second])
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        let secondFiles = try await inbox.fileURLs(for: second)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(secondFiles.first)), Data("source".utf8))
    }

    func testRawScreenshotIntentDataIsStagedWithSafeFilenameAndNoJournalSave() async throws {
        let root = try directory()
        let inbox = SharedReceiptInbox(directory: root.appendingPathComponent("inbox"))
        let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let entry = try await inbox.stage(intentFiles: [IntentFile(data: bytes, filename: "../../Screenshot.png", type: .png)])
        XCTAssertEqual(entry.files.first?.filename, "Screenshot.png")
        XCTAssertEqual(entry.files.first?.contentTypeIdentifier, "public.png")
        let files = try await inbox.fileURLs(for: entry)
        let file = try XCTUnwrap(files.first)
        XCTAssertTrue(file.path.hasPrefix(root.appendingPathComponent("inbox").path + "/"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Screenshot.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("journal.sqlite").path))
    }

    func testURLBackedPDFLargerThanMemoryInputLimitUsesBoundedFileCopy() async throws {
        let root = try directory()
        let source = try source("Large.pdf", bytes: Data("%PDF-1.4\n".utf8), in: root)
        let size = UInt64(SharedReceiptInbox.maximumInMemoryFileBytes + 4_096)
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: size)
        try writer.close()
        let inbox = SharedReceiptInbox(directory: root.appendingPathComponent("inbox"))
        let entry = try await inbox.stage(intentFiles: [IntentFile(fileURL: source, filename: "Large.pdf", type: .pdf)])
        XCTAssertEqual(entry.files.first?.sizeBytes, Int64(size))
        let files = try await inbox.fileURLs(for: entry)
        XCTAssertEqual(try XCTUnwrap(files.first).resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(size))
    }

    func testUnsupportedLinksFoldersAndOversizedInMemoryInputAreRejected() async throws {
        let root = try directory()
        let text = try source("Other.txt", bytes: Data("not a receipt type".utf8), in: root)
        let inbox = SharedReceiptInbox(directory: root.appendingPathComponent("inbox"))
        for urls in [[], [URL(string: "https://example.com/receipt.pdf")!], [root], [text]] {
            do { _ = try await inbox.stage(urls); XCTFail("Unsupported input should fail") } catch {}
        }
        let tooLarge = IntentFile(data: Data(repeating: 1, count: SharedReceiptInbox.maximumInMemoryFileBytes + 1), filename: "Huge.png", type: .png)
        do { _ = try await inbox.stage(intentFiles: [tooLarge]); XCTFail("In-memory input must be capped") } catch {}
        let pending = try await inbox.pendingEntries()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path))
    }

    func testMalformedManifestCannotRedirectOwnedURLsOutsideItsBatch() async throws {
        let root = try directory()
        let source = try source("Receipt.pdf", bytes: Data("original".utf8), in: root)
        let inbox = SharedReceiptInbox(directory: root.appendingPathComponent("inbox"))
        let entry = try await inbox.stage([source])
        let invalid = SharedReceiptEntry(id: entry.id, createdAt: entry.createdAt,
            files: [.init(id: entry.files[0].id, filename: "../../Receipt.pdf", contentTypeIdentifier: "com.adobe.pdf", sizeBytes: 8)])
        let manifest = root.appendingPathComponent("inbox/\(entry.id.uuidString)/entry.json")
        try JSONEncoder().encode(invalid).write(to: manifest)
        do { _ = try await inbox.pendingEntries(); XCTFail("Escaping file paths must fail closed") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedReceiptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories.append(root)
        return root
    }

    private func source(_ name: String, bytes: Data, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
}
