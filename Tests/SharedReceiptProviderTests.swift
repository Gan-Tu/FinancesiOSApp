import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import FinancesClone

@MainActor
final class SharedReceiptProviderTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testUnsavedEditedScreenshotBytesSurviveProviderAndInboxRecreation() async throws {
        let root = try directory()
        let inbox = SharedReceiptInbox(directory: root)
        let bytes = screenshot().pngData()!
        let provider = NSItemProvider()
        provider.suggestedName = "../../Edited Screenshot.png"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(bytes, nil)
            return nil
        }
        let entry = try await SharedReceiptProviderLoader.stage([provider], in: inbox)
        let reopened = SharedReceiptInbox(directory: root)
        let entries = try await reopened.pendingEntries()
        XCTAssertEqual(entries, [entry])
        let urls = try await reopened.fileURLs(for: entry)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), bytes, "Use the edited share payload without fetching an original from Photos")
        XCTAssertEqual(entry.files.first?.filename, "Edited Screenshot.png")
    }

    func testImageObjectWithoutOriginalFileOrPhotoAssetCanBeShared() async throws {
        let inbox = SharedReceiptInbox(directory: try directory())
        let provider = NSItemProvider(object: screenshot())
        let entry = try await SharedReceiptProviderLoader.stage([provider], in: inbox)
        let urls = try await inbox.fileURLs(for: entry)
        let image = try XCTUnwrap(UIImage(contentsOfFile: XCTUnwrap(urls.first).path))
        XCTAssertEqual(image.size.width, 23)
        XCTAssertEqual(image.size.height, 17, "Cropped screenshot dimensions must survive sharing")
    }

    func testFileProviderCopySurvivesRemovalOfItsTemporarySource() async throws {
        let root = try directory()
        let inbox = SharedReceiptInbox(directory: root.appendingPathComponent("inbox"))
        let source = root.appendingPathComponent("Receipt.pdf")
        let bytes = Data("%PDF-1.4 synthetic receipt".utf8)
        try bytes.write(to: source)
        let provider = NSItemProvider()
        provider.suggestedName = "Receipt.pdf"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        let entry = try await SharedReceiptProviderLoader.stage([provider], in: inbox)
        try FileManager.default.removeItem(at: source)
        let urls = try await inbox.fileURLs(for: entry)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), bytes)
    }

    func testFailedOrCancelledProviderBatchPublishesNothing() async throws {
        let inbox = SharedReceiptInbox(directory: try directory())
        let image = NSItemProvider(object: screenshot())
        let text = NSItemProvider(object: "Unsupported" as NSString)
        do {
            _ = try await SharedReceiptProviderLoader.stage([image, text], in: inbox)
            XCTFail("A partially loaded batch must not publish a receipt")
        } catch {}
        let progress = Progress(totalUnitCount: 1)
        progress.cancel()
        do {
            _ = try await SharedReceiptProviderLoader.stage([image], in: inbox, progress: progress)
            XCTFail("Cancelled providers must not be published")
        } catch is CancellationError {}
        let entries = try await inbox.pendingEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testReaderDoesNotDeleteAnotherProcessesUnfinishedShare() async throws {
        let root = try directory()
        let partial = root.appendingPathComponent(".preparing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let entries = try await SharedReceiptInbox(directory: root).pendingEntries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    func testEmbeddedShareExtensionAcceptsUnsavedImagesAndPDFsOnly() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let infoURL = plugins.appendingPathComponent("FinancesShareExtension.appex/Info.plist")
        let info = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        let configuration = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        XCTAssertEqual(configuration["NSExtensionPointIdentifier"] as? String, "com.apple.share-services")
        let attributes = try XCTUnwrap(configuration["NSExtensionAttributes"] as? [String: Any])
        let predicate = NSPredicate(format: try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String))
        func accepts(_ identifiers: [String]) -> Bool {
            let attachments = identifiers.map { ["registeredTypeIdentifiers": [$0]] }
            return predicate.evaluate(with: ["extensionItems": [["attachments": attachments]]])
        }
        XCTAssertTrue(accepts([UTType.png.identifier]))
        XCTAssertTrue(accepts([UTType.image.identifier]))
        XCTAssertTrue(accepts([UTType.pdf.identifier]))
        XCTAssertTrue(accepts([UTType.jpeg.identifier, UTType.pdf.identifier]))
        XCTAssertFalse(accepts([UTType.url.identifier]))
        XCTAssertFalse(accepts([UTType.png.identifier, UTType.plainText.identifier]))
        XCTAssertFalse(accepts(Array(repeating: UTType.png.identifier, count: 65)))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReceiptProviders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories.append(root)
        return root
    }

    private func screenshot() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 23, height: 17), format: format).image { context in
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 23, height: 17))
            UIColor.black.setFill()
            context.fill(CGRect(x: 4, y: 4, width: 12, height: 2))
        }
    }
}
