import Foundation
import ZIPFoundation

// Kept for importing backups produced by earlier iPhone versions.
struct MobileBackupAttachment: Codable, Hashable {
    var storedPath: String
    var originalFilename: String
    var data: Data
}

struct MobileBackupPayload: Codable {
    var formatVersion = 1
    var exportedAt = Date()
    var journalData: JournalData
    var attachments: [MobileBackupAttachment]
}

struct PreparedBackupRestore {
    var data: JournalData
    let workspace: URL
    let receipts: URL
    let relativeReceiptsPath: String
}

/// Receipt contents always travel through bounded file buffers, never a giant
/// base64 JSON document. Only the journal's metadata is decoded in memory.
enum BackupArchive {
    static let bufferSize = 256 * 1024
    static let maximumMetadataSize = 128 * 1024 * 1024
    static let maximumLegacySize = 64 * 1024 * 1024

    static func checkCancellation(_ progress: Progress) throws {
        if progress.isCancelled { throw CancellationError() }
    }

    static func safePath(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ValidationError(message: "The backup contains an invalid file path.")
        }
        return path
    }

    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw ValidationError(message: "A backup attachment is missing or is not a regular file: \(url.lastPathComponent)")
        }
        return Int64(size)
    }

    private static func ensureSpace(_ bytes: Int64, at directory: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let free = attributes[.systemFreeSize] as? NSNumber, bytes > max(0, free.int64Value - 32 * 1024 * 1024) {
            throw ValidationError(message: "There is not enough free space to prepare this backup. Free some storage and try again.")
        }
    }

    private static func name(_ original: String, index: Int) -> String {
        let allowed = String(original.map { "/\\:\0".contains($0) ? Character("_") : $0 })
        let ext = (allowed as NSString).pathExtension
        let suffix = ext.utf8.count <= 12 && !ext.isEmpty ? "." + ext : ""
        let stem = suffix.isEmpty ? allowed : String(allowed.dropLast(suffix.count))
        var result = String(format: "%06d-", index)
        for character in stem {
            if result.utf8.count + String(character).utf8.count + suffix.utf8.count > 220 { break }
            result.append(character)
        }
        return result + suffix
    }

    static func export(_ data: JournalData, to destination: URL, progress: Progress,
                       attachmentURL: (AttachmentAsset) throws -> URL) throws {
        try checkCancellation(progress)
        try createDirectory(destination.deletingLastPathComponent())
        let partial = destination.appendingPathExtension("partial")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: partial) } }
        var snapshot = data
        snapshot.syncEnabled = false; snapshot.lastSyncedAt = nil
        var files: [(path: String, url: URL, size: Int64)] = []
        var pathsBySource: [String: String] = [:]
        for transactionIndex in snapshot.transactions.indices {
            guard var attachment = snapshot.transactions[transactionIndex].attachment else { continue }
            for index in attachment.assets.indices {
                try checkCancellation(progress)
                let asset = attachment.assets[index]
                let source = try attachmentURL(asset).standardizedFileURL
                let path: String
                if let existing = pathsBySource[source.path] { path = existing }
                else {
                    path = "Attachments/" + name(asset.originalFilename, index: files.count)
                    files.append((path, source, try fileSize(source)))
                    pathsBySource[source.path] = path
                }
                attachment.assets[index].storedPath = path
            }
            snapshot.transactions[transactionIndex].attachment = attachment
        }
        let metadata = try JSONEncoder.appEncoder.encode(snapshot)
        guard metadata.count <= maximumMetadataSize else { throw ValidationError(message: "The journal metadata is too large for a mobile backup.") }
        var total = Int64(metadata.count)
        for file in files {
            let sum = total.addingReportingOverflow(max(1, file.size))
            guard !sum.overflow else { throw ValidationError(message: "The backup is too large.") }
            total = sum.partialValue
        }
        try ensureSpace(total, at: destination.deletingLastPathComponent())
        progress.totalUnitCount = max(1, total)
        do {
            let archive = try Archive(url: partial, accessMode: .create)
            let journalProgress = Progress(totalUnitCount: Int64(metadata.count))
            progress.addChild(journalProgress, withPendingUnitCount: Int64(metadata.count))
            try archive.addEntry(with: "Journal.json", type: .file, uncompressedSize: Int64(metadata.count), compressionMethod: .deflate, bufferSize: bufferSize, progress: journalProgress) { offset, count in
                try checkCancellation(progress)
                return metadata.subdata(in: Int(offset)..<Int(offset) + count)
            }
            for file in files {
                try checkCancellation(progress)
                let input = try FileHandle(forReadingFrom: file.url)
                defer { try? input.close() }
                let child = Progress(totalUnitCount: max(1, file.size))
                progress.addChild(child, withPendingUnitCount: max(1, file.size))
                try archive.addEntry(with: file.path, type: .file, uncompressedSize: file.size, compressionMethod: .none, bufferSize: bufferSize, progress: child) { _, count in
                    try checkCancellation(progress)
                    let bytes = try autoreleasepool { try input.read(upToCount: count) ?? Data() }
                    guard bytes.count == count else { throw ValidationError(message: "An attachment changed while preparing the backup. Please try again.") }
                    return bytes
                }
                child.totalUnitCount = max(1, child.totalUnitCount)
                child.completedUnitCount = child.totalUnitCount
                guard try fileSize(file.url) == file.size else { throw ValidationError(message: "An attachment changed while preparing the backup.") }
            }
        } // Close the ZIP before exposing its final filename to a share extension.
        try checkCancellation(progress)
        try FileManager.default.moveItem(at: partial, to: destination)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        #endif
        progress.completedUnitCount = progress.totalUnitCount
        completed = true
    }

    private static func readJSON(_ url: URL, limit: Int) throws -> Data {
        guard try fileSize(url) <= limit else {
            throw ValidationError(message: "This JSON backup is too large to open safely. Use a ZIP backup with receipt files instead.")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private struct RootShape: Decodable {
        let legacy: Bool
        let journal: Bool
        enum Keys: String, CodingKey { case formatVersion, journalData, ledgers, accounts, commodities, transactions }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            legacy = container.contains(.formatVersion) || container.contains(.journalData)
            journal = [.ledgers, .accounts, .commodities, .transactions].allSatisfy(container.contains)
        }
    }

    private static func decodeJournal(_ bytes: Data) throws -> JournalData {
        guard try JSONDecoder.appDecoder.decode(RootShape.self, from: bytes).journal else {
            throw ValidationError(message: "This file is not a Finances journal backup.")
        }
        return try JSONDecoder.appDecoder.decode(JournalData.self, from: bytes)
    }

    private static func extract(_ url: URL, to directory: URL, progress: Progress) throws -> URL {
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [Entry] = []
        for entry in archive {
            guard entries.count < 100_000 else { throw ValidationError(message: "The backup contains too many files.") }
            entries.append(entry)
        }
        var seen = Set<String>()
        var journalPaths: [String] = []
        var total: Int64 = 0
        for entry in entries {
            guard entry.type != .symlink else { throw ValidationError(message: "Backup archives cannot contain symbolic links.") }
            let path = try safePath(entry.type == .directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path)
            guard seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  entry.uncompressedSize <= UInt64(Int64.max) else { throw ValidationError(message: "The backup contains duplicate or oversized files.") }
            let sum = total.addingReportingOverflow(max(1, Int64(entry.uncompressedSize)))
            guard !sum.overflow else { throw ValidationError(message: "The backup is too large.") }
            total = sum.partialValue
            let components = path.split(separator: "/")
            if entry.type == .file, components.last == "Journal.json",
               components.count == 1 || (components.count == 2 && components[0].hasSuffix(".fin")) { journalPaths.append(path) }
        }
        guard journalPaths.count == 1 else { throw ValidationError(message: "The ZIP must contain exactly one Finances backup with Journal.json.") }
        try createDirectory(directory)
        try ensureSpace(total, at: directory)
        progress.totalUnitCount = max(1, total)
        for entry in entries {
            try checkCancellation(progress)
            let path = try safePath(entry.type == .directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path)
            let target = directory.appendingPathComponent(path)
            if entry.type == .directory {
                try createDirectory(target); progress.completedUnitCount += 1; continue
            }
            try createDirectory(target.deletingLastPathComponent())
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            let child = Progress(totalUnitCount: max(1, Int64(entry.uncompressedSize)))
            progress.addChild(child, withPendingUnitCount: max(1, Int64(entry.uncompressedSize)))
            var written: UInt64 = 0
            let checksum = try archive.extract(entry, bufferSize: bufferSize, progress: child) { bytes in
                try checkCancellation(progress)
                guard UInt64(bytes.count) <= entry.uncompressedSize - written else { throw ValidationError(message: "A backup file has an invalid size.") }
                try autoreleasepool { try output.write(contentsOf: bytes) }
                written += UInt64(bytes.count)
            }
            guard checksum == entry.checksum, written == entry.uncompressedSize else { throw ValidationError(message: "A backup file failed its integrity check.") }
            child.totalUnitCount = max(1, child.totalUnitCount); child.completedUnitCount = child.totalUnitCount
        }
        return directory.appendingPathComponent(journalPaths[0]).deletingLastPathComponent()
    }

    static func prepareRestore(from source: URL, workspace: URL, progress: Progress,
                               localAttachmentURL: (AttachmentAsset) throws -> URL,
                               validate: (JournalData) throws -> Void) throws -> PreparedBackupRestore {
        try checkCancellation(progress)
        try createDirectory(workspace)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: workspace) } }
        var package: URL?
        var files: [String: Data]?
        var journal: JournalData
        progress.totalUnitCount = 100
        let readProgress = Progress(totalUnitCount: 1)
        progress.addChild(readProgress, withPendingUnitCount: 50)
        let isZIP = source.pathExtension.lowercased() == "zip"
        if isZIP {
            package = try extract(source, to: workspace.appendingPathComponent("extracted"), progress: readProgress)
        } else if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            package = source
        }
        if let package {
            journal = try decodeJournal(readJSON(package.appendingPathComponent("Journal.json"), limit: maximumMetadataSize))
        } else {
            let bytes = try readJSON(source, limit: maximumLegacySize)
            if try JSONDecoder.appDecoder.decode(RootShape.self, from: bytes).legacy {
                let legacy = try JSONDecoder.appDecoder.decode(MobileBackupPayload.self, from: bytes)
                guard legacy.formatVersion == 1 else { throw ValidationError(message: "Unsupported backup version.") }
                journal = legacy.journalData
                files = [:]
                for file in legacy.attachments {
                    let path = try safePath(file.storedPath)
                    if let previous = files?[path], previous != file.data { throw ValidationError(message: "The backup contains conflicting attachment files.") }
                    files?[path] = file.data
                }
            } else { journal = try decodeJournal(bytes) }
        }
        journal.syncEnabled = false; journal.lastSyncedAt = nil
        // Backup payloads have materialized rows but no deleted-occurrence
        // tombstones. Keep each restored series exact until explicitly rescheduled;
        // newly created series can still generate normally in these journals.
        for index in journal.transactions.indices where journal.transactions[index].recurrenceRule != nil {
            journal.transactions[index].recurrenceRule?.preservesImportedMaterializations = true
        }
        if !journal.ledgers.contains(where: { $0.id == journal.selectedLedgerID }) { journal.selectedLedgerID = journal.ledgers.sorted { $0.listIndex < $1.listIndex }.first?.id }
        try validate(journal)
        readProgress.completedUnitCount = readProgress.totalUnitCount
        let receipts = workspace.appendingPathComponent("receipts")
        let relative = "Attachments/Restore-" + UUID().uuidString
        var copied: [String: String] = [:]
        let copyProgress = Progress(totalUnitCount: Int64(max(1, journal.transactions.reduce(0) { $0 + ($1.attachment?.assets.count ?? 0) })))
        progress.addChild(copyProgress, withPendingUnitCount: 50)
        for transactionIndex in journal.transactions.indices {
            guard var attachment = journal.transactions[transactionIndex].attachment else { continue }
            for index in attachment.assets.indices {
                try checkCancellation(progress)
                let asset = attachment.assets[index]
                if let existing = copied[asset.storedPath] { attachment.assets[index].storedPath = existing; copyProgress.completedUnitCount += 1; continue }
                let filename = name(asset.originalFilename, index: copied.count)
                let target = receipts.appendingPathComponent(filename)
                try createDirectory(receipts)
                if let files {
                    guard let bytes = files[try safePath(asset.storedPath)] else { throw ValidationError(message: "The backup is missing attachment: \(asset.originalFilename)") }
                    try bytes.write(to: target)
                } else {
                    let original: URL
                    if let package {
                        original = package.appendingPathComponent(try safePath(asset.storedPath))
                        let canonicalRoot = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                        guard original.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(canonicalRoot) else { throw ValidationError(message: "An attachment is outside the backup package.") }
                    } else { original = try localAttachmentURL(asset) }
                    _ = try fileSize(original)
                    if isZIP { try FileManager.default.moveItem(at: original, to: target) }
                    else { try copyFile(original, to: target, progress: progress) }
                }
                let relocated = relative + "/" + filename
                copied[asset.storedPath] = relocated
                attachment.assets[index].storedPath = relocated
                copyProgress.completedUnitCount += 1
            }
            journal.transactions[transactionIndex].attachment = attachment
        }
        try validate(journal)
        try checkCancellation(progress)
        copyProgress.completedUnitCount = copyProgress.totalUnitCount
        complete = true
        return PreparedBackupRestore(data: journal, workspace: workspace, receipts: receipts, relativeReceiptsPath: relative)
    }

    private static func copyFile(_ source: URL, to target: URL, progress: Progress) throws {
        let size = try fileSize(source)
        try ensureSpace(size, at: target.deletingLastPathComponent())
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var count: Int64 = 0
        while true {
            try checkCancellation(progress)
            let bytes = try autoreleasepool { try input.read(upToCount: bufferSize) ?? Data() }
            if bytes.isEmpty { break }
            guard count <= size - Int64(bytes.count) else { throw ValidationError(message: "An attachment changed during import.") }
            try autoreleasepool { try output.write(contentsOf: bytes) }; count += Int64(bytes.count)
        }
        guard count == size else { throw ValidationError(message: "An attachment changed during import.") }
    }
}
