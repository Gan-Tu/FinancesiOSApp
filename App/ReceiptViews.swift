import SwiftUI
import PhotosUI
import QuickLook
import QuickLookThumbnailing
import VisionKit

/// File/Photo pickers may append again while the transaction's durable save is
/// suspended. Keep the cumulative selection and persist it in order, including
/// after the detail view is dismissed. The save closure reads the latest row.
@MainActor
final class ReceiptAttachmentSaveState: ObservableObject {
    @Published private(set) var pendingAssets: [AttachmentAsset]?
    @Published private(set) var isSaving = false
    @Published private(set) var needsRetry = false
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private let onSettled: @MainActor () -> Void

    init(onSettled: @escaping @MainActor () -> Void = {}) { self.onSettled = onSettled }

    func update(_ assets: [AttachmentAsset], save: @escaping @MainActor ([AttachmentAsset]) async -> Bool) {
        pendingAssets = assets
        guard task == nil else { return }
        needsRetry = false
        isSaving = true
        let generation = self.generation
        task = Task {
            defer {
                if self.generation == generation { task = nil; isSaving = false; onSettled() }
            }
            while self.generation == generation, !Task.isCancelled, let assets = pendingAssets {
                let saved = await save(assets)
                guard self.generation == generation, !Task.isCancelled else { return }
                guard saved else { needsRetry = true; return }
                if pendingAssets == assets { pendingAssets = nil }
            }
        }
    }

    func retry(save: @escaping @MainActor ([AttachmentAsset]) async -> Bool) {
        guard let assets = pendingAssets, task == nil else { return }
        update(assets, save: save)
    }

    func invalidatePendingSaves() {
        // Only stop this coordinator. A store write it already accepted remains
        // independently owned and ordered before the journal replacement.
        generation &+= 1
        task?.cancel()
        task = nil
        pendingAssets = nil
        needsRetry = false
        isSaving = false
        onSettled()
    }

    func waitForPendingSave() async { await task?.value }
}

/// Store ownership keeps failed or in-flight selections available after a
/// detail screen is popped. Only successful, unobserved idle states are evicted.
@MainActor
final class ReceiptAttachmentSaveRegistry {
    private struct Entry {
        let state: ReceiptAttachmentSaveState
        var access: UInt64
        var owners: Set<UUID> = []
    }
    private var entries: [UUID: Entry] = [:]
    private var clock: UInt64 = 0
    private let maximumIdleStates: Int
    var retainedStateCount: Int { entries.count }

    init(maximumIdleStates: Int = 12) { self.maximumIdleStates = max(1, maximumIdleStates) }

    func state(for transactionID: UUID) -> ReceiptAttachmentSaveState {
        clock &+= 1
        if entries[transactionID] == nil {
            let state = ReceiptAttachmentSaveState { [weak self] in self?.evictIdleStates() }
            entries[transactionID] = Entry(state: state, access: clock)
        } else { entries[transactionID]?.access = clock }
        let state = entries[transactionID]!.state
        evictIdleStates(keeping: transactionID)
        return state
    }

    func draftIncludingPendingAttachments(_ draft: TransactionDraft) -> TransactionDraft {
        guard let id = draft.id, let pending = entries[id]?.state.pendingAssets else { return draft }
        var editable = draft
        editable.attachments = pending
        return editable
    }

    func retainState(for transactionID: UUID, owner: UUID) {
        _ = state(for: transactionID)
        entries[transactionID]?.owners.insert(owner)
    }

    func releaseState(for transactionID: UUID, owner: UUID) {
        entries[transactionID]?.owners.remove(owner)
        evictIdleStates()
    }

    func invalidatePendingSaves(for transactionID: UUID) {
        entries[transactionID]?.state.invalidatePendingSaves()
    }

    func invalidatePendingSaves() {
        // Copy first: settlement can evict idle registry entries. Active viewers
        // keep the same observed state object, cleared for the replacement data.
        for state in entries.values.map(\.state) { state.invalidatePendingSaves() }
    }

    private func evictIdleStates(keeping transactionID: UUID? = nil) {
        let idle = entries.filter { _, entry in
            entry.owners.isEmpty && !entry.state.isSaving && entry.state.pendingAssets == nil && !entry.state.needsRetry
        }.sorted { $0.value.access < $1.value.access }
        var excess = max(0, idle.count - maximumIdleStates)
        for (id, _) in idle where excess > 0 && id != transactionID {
            entries.removeValue(forKey: id)
            excess -= 1
        }
    }
}

/// Validate before any provider/copy work and deliver on the same actor turn as
/// the final check. No late setter can append to a restored journal in between.
@MainActor
enum ReceiptImportGenerationGuard {
    static func run(expected: UUID, current: () -> UUID,
                    importFile: () async throws -> AttachmentAsset,
                    discard: (AttachmentAsset) async -> Void,
                    receive: (AttachmentAsset) -> Void) async throws -> AttachmentAsset {
        try Task.checkCancellation()
        guard expected == current() else { throw invalidatedError }
        let asset = try await importFile()
        guard expected == current(), !Task.isCancelled else {
            await discard(asset)
            if Task.isCancelled { throw CancellationError() }
            throw invalidatedError
        }
        receive(asset)
        return asset
    }

    private static var invalidatedError: ValidationError {
        ValidationError(message: "The journal was restored while adding attachments. Please choose the files again.")
    }
}

struct ReceiptTemporaryFile: Sendable {
    let url: URL
    fileprivate let directory: URL
}

/// Photo data can be tens of megabytes; stage and remove it away from UIKit's
/// event loop. Every import owns its temporary directory and filename.
actor ReceiptImportIO {
    static let shared = ReceiptImportIO()

    func stage(_ data: Data, filename: String) throws -> ReceiptTemporaryFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReceiptImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent((filename as NSString).lastPathComponent)
        do { try data.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return ReceiptTemporaryFile(url: url, directory: directory)
    }

    func remove(_ file: ReceiptTemporaryFile) { try? FileManager.default.removeItem(at: file.directory) }
}

/// UIKit supplies an immutable image on the main actor; JPEG encoding itself
/// runs off-main and never reads a view, scanner controller, or mutable store.
struct ReceiptScanImage: @unchecked Sendable {
    let image: UIImage

    func jpegData() async throws -> Data {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let data = autoreleasepool(invoking: { image.jpegData(compressionQuality: 0.85) }) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try Task.checkCancellation()
            return data
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }
}

/// Own the async scanner lifecycle independently of the presented controller.
/// Dismantling suppresses completion; the explicit Cancel button completes once.
@MainActor
final class ReceiptScanSession {
    private let completion: (Result<[Data], Error>) -> Void
    private var encodingTask: Task<Void, Never>?
    private var didComplete = false

    init(completion: @escaping (Result<[Data], Error>) -> Void) { self.completion = completion }

    func start(_ encode: @escaping @MainActor () async throws -> [Data]) {
        guard !didComplete, encodingTask == nil else { return }
        encodingTask = Task {
            defer { encodingTask = nil }
            do {
                let pages = try await encode()
                try Task.checkCancellation()
                finish(.success(pages))
            } catch is CancellationError { /* Cancel/dismantle already completed the session. */ }
            catch { finish(.failure(error)) }
        }
    }

    func cancel() { encodingTask?.cancel(); finish(.success([])) }
    func fail(_ error: Error) { encodingTask?.cancel(); finish(.failure(error)) }
    func invalidate() { didComplete = true; encodingTask?.cancel() }
    func waitForPendingEncoding() async { await encodingTask?.value }

    private func finish(_ result: Result<[Data], Error>) {
        guard !didComplete else { return }
        didComplete = true
        completion(result)
    }
}

struct ReceiptPicker: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Binding var assets: [AttachmentAsset]
    var textOnly = false
    var startWithScan = false
    @State private var didStartInitialScan = false
    @State private var files = false
    @State private var photos = false
    @State private var scan = false
    @State private var selections: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var importGeneration: UUID?

    var body: some View {
        Menu {
            Button("Choose Files", systemImage: "folder") { importGeneration = store.attachmentImportGeneration; files = true }
            Button("Photo Library", systemImage: "photo") { importGeneration = store.attachmentImportGeneration; photos = true }
            if VNDocumentCameraViewController.isSupported {
                Button("Scan Receipt", systemImage: "doc.viewfinder") { importGeneration = store.attachmentImportGeneration; scan = true }
            }
        } label: {
            if importing { ProgressView("Adding Receipt…") }
            else if textOnly { Text("Add Attachment") }
            else { Label("Add Attachment", systemImage: "paperclip") }
        }
        .disabled(importing)
        .task {
            guard startWithScan, !didStartInitialScan else { return }
            didStartInitialScan = true
            importGeneration = store.attachmentImportGeneration
            if VNDocumentCameraViewController.isSupported { scan = true }
            else { errorMessage = "Receipt scanning is unavailable on this device. Choose a file or photo instead." }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let generation = importGeneration ?? store.attachmentImportGeneration
                Task { await importURLs(urls, generation: generation) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $photos, selection: $selections, maxSelectionCount: 10, matching: .images)
        .onChange(of: selections) { _, items in
            guard !items.isEmpty else { return }
            let generation = importGeneration ?? store.attachmentImportGeneration
            Task {
                importing = true
                defer { importing = false; selections = [] }
                do {
                    for item in items {
                        guard let bytes = try await item.loadTransferable(type: Data.self) else { continue }
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        try await importBytes(bytes, filename: "Photo-\(UUID().uuidString.prefix(8)).\(ext)", generation: generation)
                    }
                } catch { errorMessage = error.localizedDescription }
            }
        }
        .sheet(isPresented: $scan) {
            let generation = importGeneration ?? store.attachmentImportGeneration
            ReceiptScanner { result in
                scan = false
                Task {
                    importing = true
                    defer { importing = false }
                    do {
                        for (index, bytes) in try result.get().enumerated() {
                            try await importBytes(bytes, filename: "Receipt-\(UUID().uuidString.prefix(8))-\(index + 1).jpg", generation: generation)
                        }
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .alert("Couldn’t Add Receipt", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func importURLs(_ urls: [URL], generation: UUID) async {
        importing = true
        defer { importing = false }
        do {
            for url in urls {
                _ = try await store.importAttachmentAsync(from: url, expectedGeneration: generation) { assets.append($0) }
            }
        }
        catch { errorMessage = error.localizedDescription }
    }
    private func importBytes(_ bytes: Data, filename: String, generation: UUID) async throws {
        let temporary = try await ReceiptImportIO.shared.stage(bytes, filename: filename)
        do {
            _ = try await store.importAttachmentAsync(from: temporary.url, expectedGeneration: generation) { assets.append($0) }
            await ReceiptImportIO.shared.remove(temporary)
        } catch {
            await ReceiptImportIO.shared.remove(temporary)
            throw error
        }
    }
}

struct ReceiptPreview: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let asset: AttachmentAsset
    var showsFilename = true
    var thumbnailHeight: CGFloat = 260
    @State private var thumbnail: UIImage?
    @State private var previewURL: URL?
    @State private var unavailable = false
    var body: some View {
        Button {
            let url = store.attachmentURL(for: asset)
            if FileManager.default.fileExists(atPath: url.path) { previewURL = url }
            else { unavailable = true }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if let thumbnail {
                    if showsFilename {
                        Image(uiImage: thumbnail).resizable().scaledToFit().frame(maxHeight: thumbnailHeight)
                    } else {
                        GeometryReader { geometry in
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: thumbnailHeight, alignment: .top).clipped()
                        }
                        .frame(height: thumbnailHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color(uiColor: .separator), lineWidth: 0.5) }
                    }
                }
                if showsFilename || thumbnail == nil { Label(asset.originalFilename, systemImage: "paperclip").font(.subheadline).lineLimit(2) }
            }.frame(maxWidth: .infinity, minHeight: showsFilename ? 0 : thumbnailHeight, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(asset.originalFilename)
        .accessibilityHint("Opens the full attachment.")
        .accessibilityIdentifier("receipt-preview")
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .quickLookPreview($previewURL)
        .task(id: asset.id) {
            let request = QLThumbnailGenerator.Request(fileAt: store.attachmentURL(for: asset), size: CGSize(width: 600, height: 400), scale: 1, representationTypes: .thumbnail)
            if let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail = result.uiImage }
        }
        .alert("Receipt Unavailable", isPresented: $unavailable) { Button("OK", role: .cancel) {} } message: { Text("This file hasn’t downloaded yet. Sync again to retrieve it from iCloud.") }
    }
}

struct ReceiptScanner: UIViewControllerRepresentable {
    let completion: (Result<[Data], Error>) -> Void
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: VNDocumentCameraViewController, coordinator: Coordinator) {
        coordinator.invalidate()
    }
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    @MainActor final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let completion: (Result<[Data], Error>) -> Void
        private lazy var session = ReceiptScanSession(completion: completion)
        init(completion: @escaping (Result<[Data], Error>) -> Void) { self.completion = completion }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            session.start {
                var pages: [Data] = []
                pages.reserveCapacity(scan.pageCount)
                for index in 0..<scan.pageCount {
                    try Task.checkCancellation()
                    let source = ReceiptScanImage(image: scan.imageOfPage(at: index))
                    pages.append(try await source.jpegData())
                }
                return pages
            }
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { session.cancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { session.fail(error) }
        func invalidate() { session.invalidate() }
    }
}
