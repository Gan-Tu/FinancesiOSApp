import Foundation
import UniformTypeIdentifiers

extension AssistantTools {
    func safeFilename(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Attachment" : String(clean.prefix(240))
    }
    func checkFile(_ url: URL, maximum: Int) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= maximum else { throw AssistantFailure("file_unavailable", "This file is unavailable, empty or too large.") }
    }
    func stage(_ source: URL) throws -> AssistantJSON {
        let accessed = source.startAccessingSecurityScopedResource(); defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        try checkFile(source, maximum: 100 * 1024 * 1024)
        let files = directory.appending(path: "Files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let existing = (try? FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])) ?? []
        var total = 0, count = 0
        for folder in existing {
            if let created = try folder.resourceValues(forKeys: [.creationDateKey]).creationDate, created < Date().addingTimeInterval(-5 * 86400) { try? FileManager.default.removeItem(at: folder); continue }
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            count += urls.count; total += urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard count < 20, total + size <= 100 * 1024 * 1024 else { throw AssistantFailure("staging_limit", "At most 20 files and 100 MiB can be staged. Remove older uploads first.") }
        let id = UUID().uuidString, folder = files.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let destination = folder.appending(path: safeFilename(source.lastPathComponent))
        try FileManager.default.copyItem(at: source, to: destination)
        staged[id] = destination
        return .object(["file_id": .string(id), "filename": .string(destination.lastPathComponent), "size_bytes": .number(Double(size))])
    }
    func stagedFile(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw AssistantFailure("file_expired", "Choose the file again.") }
        let folder = directory.appending(path: "Files").appending(path: uuid.uuidString)
        guard let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate, created > Date().addingTimeInterval(-5 * 86400),
              let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil), urls.count == 1 else {
            throw AssistantFailure("file_expired", "The temporary file expired. Select it again; saved transaction receipts are unaffected.")
        }
        try checkFile(urls[0], maximum: 100 * 1024 * 1024); return urls[0]
    }
    func export(_ name: String, _ a: AssistantJSON) async throws -> AssistantJSON {
        try access()
        let url: URL
        if name == "export_backup" {
            let progress = Progress(totalUnitCount: 100)
            url = try await withTaskCancellationHandler { try await store.exportBackupFileAsync(progress: progress) } onCancel: { progress.cancel() }
            try access()
        }
        else {
            let columns = a["columns"].array.compactMap(\.string)
            let fields = columns.isEmpty ? ["Date", "Payee", "Note", "Number", "Cleared", "Account", "Currency", "Amount"] : columns
            let delimiter = a["delimiter"].string ?? ","
            func quote(_ value: String, text: Bool = true) -> String {
                var value = value
                if text, let first = value.first, "=+-@\t\r\n".contains(first) { value = "'" + value }
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            var lines = [fields.map { quote($0) }.joined(separator: delimiter)]
            for tx in try filtered(a) { for p in tx.postings {
                let values = ["Date": a["date_only"].bool == false ? ISO8601DateFormatter().string(from: tx.date) : day(tx.date), "Payee": tx.payee, "Note": tx.note, "Number": tx.number, "Cleared": tx.cleared ? "true" : "false", "Account": store.account(p.accountID)?.name ?? "", "Currency": store.commodity(postingCurrency(p, ledger: tx.ledgerID))?.symbol ?? "", "Amount": NSDecimalNumber(decimal: p.amount).stringValue]
                lines.append(fields.map { quote(values[$0] ?? "", text: $0 != "Amount") }.joined(separator: delimiter))
            } }
            let exports = directory.appending(path: "Exports")
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            url = exports.appending(path: "Finances-\(UUID().uuidString.prefix(8)).csv")
            try Data(((a["bom"].bool == false ? "" : "\u{FEFF}") + lines.joined(separator: "\r\n")).utf8).write(to: url, options: [.atomic, .completeFileProtection])
        }
        showArtifact?(url)
        return .object(["status": .string("export_ready"), "filename": .string(url.lastPathComponent), "next_step": .string("Use the Share button in the assistant.")])
    }
    func preview(_ a: AssistantJSON) async throws -> AssistantJSON {
        guard previews.count < 2 else { throw AssistantFailure("staging_limit", "Two backup previews are already open. Start a new assistant session to clear them.") }
        let id = UUID().uuidString
        let source = try stagedFile(a.required("file_id")), workspace = directory.appending(path: "Previews/" + id), progress = Progress(totalUnitCount: 100)
        let value = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try BackupArchive.prepareRestore(from: source, workspace: workspace, progress: progress, localAttachmentURL: { _ in throw AssistantFailure("missing_receipt", "Select a complete ZIP backup including receipt files.") }, validate: MobileLedgerStore.assistantValidateBackup)
            }.value
        } onCancel: { progress.cancel() }
        do { try access() } catch { try? FileManager.default.removeItem(at: workspace); throw error }
        previews[id] = value
        return .object(["preview_id": .string(id), "journals": .array(value.data.ledgers.map { .object(["id": .string($0.id.uuidString), "name": .string($0.name)]) }), "accounts": .number(Double(value.data.accounts.count)), "transactions": .number(Double(value.data.transactions.count)), "behavior": .string("Import as NEW journals; existing journals are preserved.")])
    }
    func prepareImport(_ a: AssistantJSON) async throws -> AssistantPreparedImport {
        guard let value = previews[try a.required("preview_id")] else { throw AssistantFailure("preview_expired", "Preview the selected backup again before importing. Existing journals are unchanged.") }
        let relative = "Attachments/AssistantImport-" + UUID().uuidString
        let destination = store.assistantDirectory.deletingLastPathComponent().appending(path: relative)
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: destination) } }
        let progress = Progress(totalUnitCount: 100)
        let imported = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try BackupArchive.checkCancellation(progress)
                let assets = value.data.transactions.flatMap { $0.attachment?.assets ?? [] }
                var paths: [String: String] = [:], sizes: [String: Int64] = [:]
                for asset in assets { paths[asset.storedPath] = relative + "/" + URL(fileURLWithPath: asset.storedPath).lastPathComponent; sizes[asset.storedPath] = asset.sizeBytes }
                let imported = try AssistantBackup.remap(value.data, names: [:], paths: paths, sizes: sizes)
                if FileManager.default.fileExists(atPath: value.receipts.path) {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: value.receipts, to: destination)
                }
                if progress.isCancelled { try? FileManager.default.removeItem(at: destination); throw CancellationError() }
                return imported
            }.value
        } onCancel: { progress.cancel() }
        do { try access() } catch { try? FileManager.default.removeItem(at: destination); throw error }
        handedOff = true
        return AssistantPreparedImport(data: imported, directory: destination)
    }
    func importPreview(_ a: AssistantJSON) throws -> AssistantJSON {
        guard let imported = preparedImports[try a.required("request_id")] else {
            throw AssistantFailure("preview_expired", "Prepare this backup import again before committing.")
        }
        try store.assistantAppendBackup(imported)
        return .object(["journal_ids": .array(imported.ledgers.map { .string($0.id.uuidString) })])
    }
    func discardPreview(_ id: String) {
        if let preview = previews.removeValue(forKey: id) { try? FileManager.default.removeItem(at: preview.workspace) }
    }
    func clearPreviews() {
        for id in Array(previews.keys) { discardPreview(id) }
    }
}
