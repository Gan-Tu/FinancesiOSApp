import UIKit
import UniformTypeIdentifiers

/// Consumes the host's current item providers, including unsaved/cropped
/// screenshots. Provider URLs are valid only inside their completion callback.
@MainActor
enum SharedReceiptProviderLoader {
    static func stage(_ providers: [NSItemProvider], in inbox: SharedReceiptInbox,
                      progress: Progress = Progress(totalUnitCount: 1), awaitsHandoff: Bool = false) async throws -> SharedReceiptEntry {
        guard !providers.isEmpty, providers.count <= SharedReceiptInbox.maximumFiles else {
            throw SharedReceiptError(message: "Choose between 1 and \(SharedReceiptInbox.maximumFiles) images or PDF files.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ReceiptShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var urls: [URL] = []
        for provider in providers {
            try checkCancellation(progress)
            guard let type = provider.registeredTypeIdentifiers.compactMap({ UTType($0) }).first(where: {
                $0.conforms(to: .image) || $0.conforms(to: .pdf)
            }) else {
                throw SharedReceiptError(message: "Finances accepts images and PDF receipts.")
            }
            let directory = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suggestedName = provider.suggestedName
            do {
                urls.append(try await file(provider, type: type, name: suggestedName, directory: directory))
            } catch {
                try checkCancellation(progress)
                // Screenshot Markup can supply image bytes/an image object
                // without any file on disk. Materialize only that edited item.
                do {
                    urls.append(try await data(provider, type: type, name: suggestedName, directory: directory))
                } catch {
                    try checkCancellation(progress)
                    guard type.conforms(to: .image), provider.canLoadObject(ofClass: UIImage.self) else { throw error }
                    urls.append(try await image(provider, name: suggestedName, directory: directory))
                }
            }
        }
        try checkCancellation(progress)
        return try await inbox.stage(urls, progress: progress, awaitsHandoff: awaitsHandoff)
    }

    private static func file(_ provider: NSItemProvider, type: UTType, name: String?, directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                do {
                    guard let url else { throw error ?? SharedReceiptError(message: "The receipt file is unavailable.") }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw SharedReceiptError(message: "Choose a receipt file, not a folder or link.")
                    }
                    let target = destination(name ?? url.lastPathComponent, type: type, directory: directory)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func data(_ provider: NSItemProvider, type: UTType, name: String?, directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { bytes, error in
                do {
                    guard let bytes else { throw error ?? SharedReceiptError(message: "The shared image is unavailable.") }
                    continuation.resume(returning: try write(bytes, name: name, type: type, directory: directory))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func image(_ provider: NSItemProvider, name: String?, directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, error in
                do {
                    guard let image = object as? UIImage, let bytes = image.pngData() else {
                        throw error ?? SharedReceiptError(message: "The screenshot could not be read.")
                    }
                    continuation.resume(returning: try write(bytes, name: name, type: .png, directory: directory))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func destination(_ name: String?, type: UTType, directory: URL) -> URL {
        let leaf = (name ?? "Receipt").replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "Receipt"
        let stem = String((leaf as NSString).deletingPathExtension.prefix(100))
        let ext = type.preferredFilenameExtension ?? "png"
        return directory.appendingPathComponent((stem.isEmpty ? "Receipt" : stem) + "." + ext)
    }

    nonisolated private static func write(_ bytes: Data, name: String?, type: UTType, directory: URL) throws -> URL {
        guard !bytes.isEmpty, bytes.count <= SharedReceiptInbox.maximumInMemoryFileBytes else {
            throw SharedReceiptError(message: "This shared image is too large or empty. Share an individual receipt.")
        }
        let url = destination(name, type: type, directory: directory)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    private static func checkCancellation(_ progress: Progress) throws {
        try Task.checkCancellation()
        if progress.isCancelled { throw CancellationError() }
    }
}
