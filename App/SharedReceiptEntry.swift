import AppIntents
import Foundation
import UniformTypeIdentifiers

/// An owned, durable batch waiting for the user to choose a journal and review a
/// new transaction. This manifest never contains or mutates a journal snapshot.
struct SharedReceiptEntry: Identifiable, Codable, Equatable, Sendable {
    struct File: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        let filename: String
        let contentTypeIdentifier: String?
        let sizeBytes: Int64
    }

    let id: UUID
    let createdAt: Date
    let files: [File]
}

/// The actor owns file-provider coordination and bounded copying off the main
/// actor. A manifest becomes visible only after every file in the batch exists.
/// Original URLs are never edited/deleted and their security scopes end here,
/// before an incoming request waits behind a lock screen or an unsaved editor.
actor SharedReceiptInbox {
    static let maximumFiles = 64
    static let maximumInMemoryFileBytes = 64 * 1024 * 1024
    static let copyBufferBytes = 256 * 1024

    static let shared = SharedReceiptInbox(directory: SystemIntegrationStorage.directory
        .appendingPathComponent("Receipts", isDirectory: true))

    struct Access: Sendable {
        var begin: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var end: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    }

    private enum Source: Sendable {
        case url(URL)
        case intent(IntentFile)
    }

    private let directory: URL
    private let access: Access

    init(directory: URL, access: Access = Access()) {
        self.directory = directory.standardizedFileURL
        self.access = access
    }

    func stage(_ urls: [URL], progress: Progress = Progress(totalUnitCount: 1)) async throws -> SharedReceiptEntry {
        try stageSources(urls.map(Source.url), progress: progress)
    }

    func stage(intentFiles: [IntentFile], progress: Progress = Progress(totalUnitCount: 1)) async throws -> SharedReceiptEntry {
        try stageSources(intentFiles.map(Source.intent), progress: progress)
    }

    func pendingEntries() throws -> [SharedReceiptEntry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try validateDirectory(directory)
        var entries: [SharedReceiptEntry] = []
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            // A crash while copying leaves no published request. Only these
            // private partial directories can be discarded without user action.
            if child.lastPathComponent.hasPrefix(".preparing-") {
                try validateDirectory(child)
                try FileManager.default.removeItem(at: child)
                continue
            }
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            let entry = try readEntry(id)
            _ = try fileURLs(for: entry)
            entries.append(entry)
        }
        return entries.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
    }

    func fileURLs(for entry: SharedReceiptEntry) throws -> [URL] {
        let saved = try readEntry(entry.id)
        guard saved == entry else { throw invalidEntry }
        let batch = directory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        return try entry.files.map { file in
            guard Self.safeFilename(file.filename) == file.filename, file.sizeBytes >= 0 else { throw invalidEntry }
            let parent = batch.appendingPathComponent(file.id.uuidString, isDirectory: true)
            try validateDirectory(parent)
            let url = parent.appendingPathComponent(file.filename)
            let values = try regularFileValues(url)
            guard Int64(values.fileSize ?? -1) == file.sizeBytes else { throw invalidEntry }
            return url
        }
    }

    /// Called only after receipt copies belong to an editor session, or after
    /// the user cancels the incoming request. Other pending batches are retained.
    func discard(_ id: UUID) throws {
        let batch = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: batch.path) else { return }
        try validateDirectory(directory)
        try validateDirectory(batch)
        try FileManager.default.removeItem(at: batch)
    }

    private func stageSources(_ sources: [Source], progress: Progress) throws -> SharedReceiptEntry {
        try checkCancellation(progress)
        guard !sources.isEmpty, sources.count <= Self.maximumFiles else {
            throw ValidationError(message: "Choose between 1 and \(Self.maximumFiles) images or PDF files for one transaction.")
        }
        try makeDirectory(directory)
        let id = UUID()
        let partial = directory.appendingPathComponent(".preparing-" + id.uuidString, isDirectory: true)
        let final = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try makeDirectory(partial)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: partial) } }
        progress.totalUnitCount = Int64(sources.count)
        var files: [SharedReceiptEntry.File] = []
        for source in sources {
            try checkCancellation(progress)
            let fileID = UUID()
            let parent = partial.appendingPathComponent(fileID.uuidString, isDirectory: true)
            try makeDirectory(parent)
            let file: SharedReceiptEntry.File
            switch source {
            case .url(let url):
                file = try copyURL(url, filename: nil, type: nil, id: fileID, to: parent, progress: progress)
            case .intent(let input):
                if let url = input.fileURL {
                    // Never materialize the data property of a URL-backed PDF.
                    file = try copyURL(url, filename: input.filename, type: input.type, id: fileID, to: parent, progress: progress)
                } else {
                    // Shortcuts may supply an in-memory screenshot. Process one
                    // at a time, cap it, and write in bounded chunks on this actor.
                    let bytes = input.data
                    guard bytes.count <= Self.maximumInMemoryFileBytes else {
                        throw ValidationError(message: "This shared image is too large. Save it to Files, then share that file with Finances.")
                    }
                    let filename = Self.safeFilename(input.filename)
                    let type = try supportedType(input.type, filename: filename)
                    try ensureSpace(Int64(bytes.count), at: parent)
                    let target = parent.appendingPathComponent(filename)
                    try writeData(bytes, to: target, progress: progress)
                    file = .init(id: fileID, filename: filename, contentTypeIdentifier: type.identifier, sizeBytes: Int64(bytes.count))
                }
            }
            files.append(file)
            progress.completedUnitCount += 1
        }
        try checkCancellation(progress)
        let entry = SharedReceiptEntry(id: id, createdAt: Date(), files: files)
        let manifest = partial.appendingPathComponent("entry.json")
        try JSONEncoder().encode(entry).write(to: manifest, options: .atomic)
        try synchronize(manifest)
        try checkCancellation(progress)
        try FileManager.default.moveItem(at: partial, to: final)
        published = true
        return entry
    }

    private func copyURL(_ source: URL, filename requestedName: String?, type requestedType: UTType?, id: UUID,
                         to parent: URL, progress: Progress) throws -> SharedReceiptEntry.File {
        guard source.isFileURL else { throw ValidationError(message: "Share an image or PDF file, rather than a website link.") }
        let scoped = access.begin(source)
        defer { if scoped { access.end(source) } }
        if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ValidationError(message: "Choose the receipt file itself, rather than a file link.")
        }
        var coordinationError: NSError?
        var outcome: Result<SharedReceiptEntry.File, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            outcome = Result {
                try checkCancellation(progress)
                let before = try regularFileValues(readable)
                let filename = Self.safeFilename(requestedName ?? source.lastPathComponent)
                let type = try supportedType(requestedType ?? before.contentType, filename: filename)
                guard let size = before.fileSize else { throw invalidEntry }
                try ensureSpace(Int64(size), at: parent)
                let target = parent.appendingPathComponent(filename)
                let input = try FileHandle(forReadingFrom: readable)
                defer { try? input.close() }
                guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                var copied: Int64 = 0
                while true {
                    try checkCancellation(progress)
                    let chunk = try autoreleasepool { try input.read(upToCount: Self.copyBufferBytes) ?? Data() }
                    if chunk.isEmpty { break }
                    guard copied <= Int64(size) - Int64(chunk.count) else { throw changedSource }
                    try output.write(contentsOf: chunk)
                    copied += Int64(chunk.count)
                }
                let after = try regularFileValues(readable)
                guard copied == Int64(size), after.fileSize == size,
                      after.contentModificationDate == before.contentModificationDate else { throw changedSource }
                try output.synchronize()
                return .init(id: id, filename: filename, contentTypeIdentifier: type.identifier, sizeBytes: copied)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw invalidEntry }
        return try outcome.get()
    }

    private func writeData(_ bytes: Data, to url: URL, progress: Progress) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var offset = 0
        while offset < bytes.count {
            try checkCancellation(progress)
            let end = min(bytes.count, offset + Self.copyBufferBytes)
            try output.write(contentsOf: bytes.subdata(in: offset..<end))
            offset = end
        }
        try output.synchronize()
    }

    private func readEntry(_ id: UUID) throws -> SharedReceiptEntry {
        try validateDirectory(directory)
        let batch = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try validateDirectory(batch)
        let manifest = batch.appendingPathComponent("entry.json")
        let values = try regularFileValues(manifest)
        guard let size = values.fileSize, size <= 256 * 1024 else { throw invalidEntry }
        let entry = try JSONDecoder().decode(SharedReceiptEntry.self, from: Data(contentsOf: manifest))
        guard entry.id == id, entry.createdAt.timeIntervalSinceReferenceDate.isFinite,
              !entry.files.isEmpty, entry.files.count <= Self.maximumFiles,
              Set(entry.files.map(\.id)).count == entry.files.count else { throw invalidEntry }
        return entry
    }

    private func supportedType(_ proposed: UTType?, filename: String) throws -> UTType {
        for type in [proposed, UTType(filenameExtension: (filename as NSString).pathExtension)].compactMap({ $0 }) {
            if type.conforms(to: .image) || type.conforms(to: .pdf) { return type }
        }
        throw ValidationError(message: "Finances accepts shared images and PDF receipts. Other file types can be attached from the transaction editor.")
    }

    private func regularFileValues(_ url: URL) throws -> URLResourceValues {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ValidationError(message: "Choose individual receipt files, not folders or links.")
        }
        return values
    }

    private func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw invalidEntry }
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try validateDirectory(url)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var value = url
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try? value.setResourceValues(resources)
    }

    private func ensureSpace(_ bytes: Int64, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        if let available = attributes[.systemFreeSize] as? NSNumber, bytes > max(0, available.int64Value - 32 * 1024 * 1024) {
            throw ValidationError(message: "There is not enough free space to prepare these receipts.")
        }
    }

    private func synchronize(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    private func checkCancellation(_ progress: Progress) throws {
        try Task.checkCancellation()
        if progress.isCancelled { throw CancellationError() }
    }

    private static func safeFilename(_ name: String) -> String {
        let leaf = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "Receipt"
        let cleaned = String(leaf.map { $0 == ":" || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "_" : $0 })
        let ext = (cleaned as NSString).pathExtension
        let suffix = ext.utf8.count <= 20 && !ext.isEmpty ? "." + ext : ""
        let stem = suffix.isEmpty ? cleaned : String(cleaned.dropLast(suffix.count))
        var result = ""
        for character in stem {
            guard result.utf8.count + String(character).utf8.count + suffix.utf8.count <= 220 else { break }
            result.append(character)
        }
        result += suffix
        return result.isEmpty || result == "." || result == ".." ? "Receipt" : result
    }

    private var invalidEntry: ValidationError {
        ValidationError(message: "This shared receipt could not be opened. Its pending files have been preserved; share it again from the original app.")
    }
    private var changedSource: ValidationError {
        ValidationError(message: "A receipt changed while it was being copied. Please share it again.")
    }
}

struct NewReceiptTransactionIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let title: LocalizedStringResource = "New Transaction with Receipts"
    static let description = IntentDescription("Open a new transaction with images or PDF receipts attached. Review it and choose Save in Finances when ready.")
    static var openAppWhenRun: Bool { true }

    // The broad file parameter keeps the action available on iOS 17. The inbox
    // validates image/PDF types before publishing any incoming receipt request.
    @Parameter(title: "Receipts", inputConnectionBehavior: .connectToPreviousIntentResult)
    var receipts: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Create a transaction with \(\.$receipts)")
    }

    func perform() async throws -> some IntentResult {
        let entry = try await SharedReceiptInbox.shared.stage(intentFiles: receipts)
        try await SystemEntryRouter.shared.openSharedReceipt(entry)
        return .result()
    }
}
