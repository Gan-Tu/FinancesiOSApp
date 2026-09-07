import Foundation

/// A duplicate owns independent receipt identities and bytes. Copy every asset
/// before returning; failure removes only files created by this attempt.
enum AttachmentDuplicator {
    static func duplicate(
        _ original: AttachmentContainer,
        into attachmentsDirectory: URL,
        sourceURL: (AttachmentAsset) throws -> URL
    ) throws -> AttachmentContainer {
        var copiedURLs: [URL] = []
        do {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            var copy = original
            copy.id = UUID()
            copy.assets = try original.assets.map { originalAsset in
                let source = try sourceURL(originalAsset).resolvingSymlinksInPath()
                guard source.isFileURL,
                      try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw ValidationError(message: "Receipt could not be copied: \(originalAsset.originalFilename)")
                }
                var asset = originalAsset
                asset.id = UUID()
                let leaf = originalAsset.originalFilename
                    .replacingOccurrences(of: "\\", with: "/")
                    .split(separator: "/").last.map(String.init) ?? "Receipt"
                var safeName = ""
                for scalar in leaf.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) && scalar != ":" {
                    let fragment = String(scalar)
                    guard safeName.utf8.count + fragment.utf8.count <= 160 else { break }
                    safeName += fragment
                }
                let filename = "\(asset.id.uuidString)-\(safeName.isEmpty ? "Receipt" : safeName)"
                let destination = attachmentsDirectory.appendingPathComponent(filename)
                // The generated destination never aliases an existing receipt.
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw ValidationError(message: "A unique receipt filename could not be allocated.")
                }
                copiedURLs.append(destination)
                try FileManager.default.copyItem(at: source, to: destination)
                asset.storedPath = "Attachments/\(filename)"
                return asset
            }
            return copy
        } catch {
            for url in copiedURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}
