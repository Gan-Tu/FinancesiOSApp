import Foundation
import Darwin

/// Receipt paths and SQLite cannot share a filesystem transaction. This small
/// write-ahead manifest preserves the last committed files until SQLite records
/// the installation ID in the same transaction as its journal/checkpoint.
/// Recovery is idempotent even when the process stops during recovery itself.
final class CloudKitReceiptFileTransaction {
    struct Change {
        let destination: URL
        /// A verified transport-owned temporary file; preparation may consume
        /// it on filesystems without cloning. Nil deletes the destination.
        let source: URL?
    }

    private struct Entry: Codable {
        let relativeDestination: String
        let hadOriginal: Bool
        let stagedName: String?
        let backupName: String
    }

    private struct Manifest: Codable {
        let version: Int
        let id: UUID
        let entries: [Entry]
    }

    let id: UUID
    private let root: URL
    private let directory: URL
    private let manifest: Manifest
    private static let directoryName = ".icloud-receipt-installations"

    private init(root: URL, directory: URL, manifest: Manifest) {
        self.root = root; self.directory = directory; self.manifest = manifest
        id = manifest.id
    }

    static func prepare(_ changes: [Change], in supportDirectory: URL,
                        cloneFile: (URL, URL) -> Bool = cloneDownloadedFile) throws -> CloudKitReceiptFileTransaction {
        let manager = FileManager.default
        let root = supportDirectory.resolvingSymlinksInPath().standardizedFileURL
        let id = UUID()
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var prepared = false
        defer { if !prepared { try? manager.removeItem(at: directory) } }
        // Multiple asset identities can share a file. Preserve its pre-pass
        // contents once and install the final requested value for that path.
        var orderedPaths: [String] = []
        var byPath: [String: Change] = [:]
        for change in changes {
            let path = try relativePath(change.destination, root: root)
            if byPath[path] == nil { orderedPaths.append(path) }
            byPath[path] = change
        }
        var entries: [Entry] = []
        for (index, path) in orderedPaths.enumerated() {
            let change = byPath[path]!
            let destination = try destination(path, root: root)
            let existed = manager.fileExists(atPath: destination.path)
            if existed { try requireRegularFile(destination) }
            let stagedName = change.source.map { _ in "new-\(index)" }
            if let source = change.source, let stagedName {
                try requireRegularFile(source)
                guard !source.resolvingSymlinksInPath().path.hasPrefix(root.appendingPathComponent("Attachments").path + "/") else {
                    throw invalidManifest
                }
                let staged = directory.appendingPathComponent(stagedName)
                // Explicit APFS clone is O(1); fallback consumes the verified
                // transport-owned source using rename only. Never silently copy
                // or fsync gigabytes on the UI actor. A cross-volume or reused
                // source fails here, before any live receipt path is changed.
                if !cloneFile(source, staged) {
                    guard rename(source.path, staged.path) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
            }
            entries.append(Entry(relativeDestination: path, hadOriginal: existed,
                                 stagedName: stagedName, backupName: "old-\(index)"))
        }
        let manifest = Manifest(version: 1, id: id, entries: entries)
        let file = directory.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: file, options: .atomic)
        try synchronizeFile(file)
        prepared = true
        return CloudKitReceiptFileTransaction(root: root, directory: directory, manifest: manifest)
    }

    /// Does not delete a previous version. The manifest already describes every
    /// rename before the first one occurs, including originally absent paths.
    func install(afterEachChange: (() throws -> Void)? = nil) throws {
        let manager = FileManager.default
        for entry in manifest.entries {
            let target = try Self.destination(entry.relativeDestination, root: root)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if entry.hadOriginal {
                try manager.moveItem(at: target, to: directory.appendingPathComponent(entry.backupName))
            }
            if let stagedName = entry.stagedName {
                try manager.moveItem(at: directory.appendingPathComponent(stagedName), to: target)
            }
            try afterEachChange?()
        }
    }

    func finish(committed: Bool) throws {
        let manager = FileManager.default
        if !committed {
            for entry in manifest.entries.reversed() {
                let target = try Self.destination(entry.relativeDestination, root: root)
                let backup = directory.appendingPathComponent(entry.backupName)
                if entry.hadOriginal {
                    // Missing backup means the rename never happened, or an
                    // earlier recovery already put the original back.
                    if manager.fileExists(atPath: backup.path) {
                        try Self.requireRegularFile(backup)
                        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                        try manager.moveItem(at: backup, to: target)
                    }
                } else if manager.fileExists(atPath: target.path) {
                    try manager.removeItem(at: target)
                }
            }
        }
        // Keep the manifest if any rollback/cleanup fails. Startup must retry
        // instead of publishing a journal whose receipt recovery is incomplete.
        try manager.removeItem(at: directory)
    }

    static func recoverPending(in supportDirectory: URL,
                               isCommitted: (UUID) throws -> Bool,
                               removeCommit: (UUID) throws -> Void) throws {
        let root = supportDirectory.resolvingSymlinksInPath().standardizedFileURL
        let container = root.appendingPathComponent(directoryName, isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: container.path) else { return }
        let directories = try manager.contentsOfDirectory(at: container, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let id = UUID(uuidString: directory.lastPathComponent) else { throw invalidManifest }
            let file = directory.appendingPathComponent("manifest.json")
            guard manager.fileExists(atPath: file.path) else {
                // Preparation never changes live files before the manifest is
                // written, so interrupted staging is safe to discard.
                try manager.removeItem(at: directory)
                continue
            }
            try requireRegularFile(file)
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
            guard manifest.version == 1, manifest.id == id,
                  Set(manifest.entries.map(\.relativeDestination)).count == manifest.entries.count else { throw invalidManifest }
            for (index, entry) in manifest.entries.enumerated() {
                _ = try destination(entry.relativeDestination, root: root)
                guard entry.backupName == "old-\(index)", entry.stagedName == nil || entry.stagedName == "new-\(index)" else { throw invalidManifest }
            }
            let transaction = CloudKitReceiptFileTransaction(root: root, directory: directory, manifest: manifest)
            let committed = try isCommitted(id)
            try transaction.finish(committed: committed)
            if committed { try removeCommit(id) }
        }
    }

    private static func relativePath(_ url: URL, root: URL) throws -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") else { throw invalidManifest }
        let relative = String(path.dropFirst(root.path.count + 1))
        _ = try destination(relative, root: root)
        return relative
    }

    private static func destination(_ path: String, root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1, parts.first == "Attachments",
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains("\\"), !path.contains("\0") else { throw invalidManifest }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.appendingPathComponent("Attachments").path + "/") else { throw invalidManifest }
        return url
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw invalidManifest }
    }

    private static func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func cloneDownloadedFile(_ source: URL, _ target: URL) -> Bool {
        clonefile(source.path, target.path, 0) == 0
    }

    private static var invalidManifest: ValidationError {
        ValidationError(message: "An interrupted iCloud receipt update needs recovery. Its saved files have been preserved.")
    }
}
