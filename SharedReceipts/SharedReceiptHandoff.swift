import Foundation

/// An Open In document identifies an already-owned receipt batch. It never
/// accepts file paths or journal data from the sending app.
struct SharedReceiptHandoff: Codable, Equatable, Sendable {
    static let typeIdentifier = "dev.gan.FinancesApp.receipt-handoff"
    static let filenameExtension = "finances-receipt"
    let version: Int
    let receiptID: UUID

    init(receiptID: UUID) {
        version = 1
        self.receiptID = receiptID
    }

    static func recognizes(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == filenameExtension
    }

    func write(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("New Transaction").appendingPathExtension(Self.filenameExtension)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    static func read(_ url: URL) throws -> Self {
        guard recognizes(url) else { throw invalidDocument }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw invalidDocument }
        var coordinationError: NSError?
        var result: Result<Self, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
            result = Result {
                let metadata = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                      let size = metadata.fileSize, size > 0, size <= 1_024 else { throw invalidDocument }
                let file = try FileHandle(forReadingFrom: readable)
                defer { try? file.close() }
                let bytes = try file.read(upToCount: 1_025) ?? Data()
                guard !bytes.isEmpty, bytes.count <= 1_024 else { throw invalidDocument }
                let handoff = try JSONDecoder().decode(Self.self, from: bytes)
                guard handoff.version == 1 else { throw invalidDocument }
                return handoff
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw invalidDocument }
        return try result.get()
    }

    private static var invalidDocument: SharedReceiptError {
        SharedReceiptError(message: "This receipt link could not be opened. Share the screenshot again.")
    }
}
