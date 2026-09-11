import SwiftUI
import Combine
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
                    receive: (AttachmentAsset) throws -> Void) async throws -> AttachmentAsset {
        try Task.checkCancellation()
        guard expected == current() else { throw invalidatedError }
        let asset = try await importFile()
        guard expected == current(), !Task.isCancelled else {
            await discard(asset)
            if Task.isCancelled { throw CancellationError() }
            throw invalidatedError
        }
        do { try receive(asset) }
        catch { await discard(asset); throw error }
        return asset
    }

    private static var invalidatedError: ValidationError {
        ValidationError(message: "The journal was restored while adding attachments. Please choose the files again.")
    }
}

/// One editor owns every accepted import until Save transfers ownership or
/// Cancel/teardown discards only its newly imported, still-unreferenced files.
@MainActor
final class ReceiptImportSession: ObservableObject {
    @Published private(set) var pendingCount = 0
    @Published private var lifecycleRevision: UInt64 = 0
    @Published private(set) var errorMessage: String?
    private(set) var isAccepting = true
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var ownedAssets: [UUID: AttachmentAsset] = [:]
    private var discard: (@MainActor ([AttachmentAsset]) -> Void)?
    var isImporting: Bool { pendingCount > 0 }
    var canSave: Bool { isAccepting && !isImporting }

    func configureDiscard(_ discard: @escaping @MainActor ([AttachmentAsset]) -> Void) { self.discard = discard }

    @discardableResult
    func start(_ operation: @escaping @MainActor (UUID) async throws -> Void) -> UUID? {
        guard isAccepting else { return nil }
        let id = UUID()
        pendingCount += 1 // Publish synchronously, before a Save tap can snapshot the draft.
        tasks[id] = Task {
            defer {
                if tasks.removeValue(forKey: id) != nil { pendingCount -= 1 }
            }
            do { try await operation(id) }
            catch is CancellationError { /* Cancel and teardown are deliberate. */ }
            catch { if isAccepting { errorMessage = error.localizedDescription } }
        }
        return id
    }

    func accept(_ asset: AttachmentAsset, for operationID: UUID) throws {
        guard isAccepting, tasks[operationID] != nil, !Task.isCancelled else { throw CancellationError() }
        if discard != nil { ownedAssets[asset.id] = asset }
    }

    func clearError() { errorMessage = nil }

    func cancel() {
        cancel(publishingChange: true)
    }

    /// SwiftUI is already destroying the observing graph. Close synchronously
    /// so late providers cannot deliver, without reentering that graph's update.
    func cancelForTeardown() {
        cancel(publishingChange: false)
    }

    private func cancel(publishingChange: Bool) {
        guard isAccepting else { return }
        if publishingChange { lifecycleRevision &+= 1 }
        isAccepting = false
        for task in Array(tasks.values) { task.cancel() }
        let assets = Array(ownedAssets.values)
        ownedAssets.removeAll()
        if !assets.isEmpty { discard?(assets) }
        discard = nil
    }

    func didCommit() {
        guard !isImporting else { return }
        // Reference-protected cleanup keeps files accepted by normal saves,
        // while removing a fresh source that a duplicate saved under a new copy.
        let assets = Array(ownedAssets.values)
        ownedAssets.removeAll()
        if !assets.isEmpty { discard?(assets) }
        discard = nil
        lifecycleRevision &+= 1
        isAccepting = false
    }

    func waitForPendingImports() async {
        for task in Array(tasks.values) { await task.value }
    }
}

private struct ReceiptImportSessionKey: EnvironmentKey {
    static let defaultValue: ReceiptImportSession? = nil
}

extension EnvironmentValues {
    var receiptImportSession: ReceiptImportSession? {
        get { self[ReceiptImportSessionKey.self] }
        set { self[ReceiptImportSessionKey.self] = newValue }
    }
}

/// Kept at the EditorSheet root so opening a child account/date/photo picker
/// does not end the import session. Removing the editor graph does.
struct ReceiptImportLifetimeAnchor: UIViewRepresentable {
    let session: ReceiptImportSession
    func makeCoordinator() -> ReceiptImportSession { session }
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: ReceiptImportSession) { coordinator.cancelForTeardown() }
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
    @Environment(\.receiptImportSession) private var editorSession
    @StateObject private var localSession = ReceiptImportSession()
    @Binding var assets: [AttachmentAsset]
    var textOnly = false
    var startWithScan = false

    var body: some View {
        ReceiptPickerContent(assets: $assets, textOnly: textOnly, startWithScan: startWithScan,
                             session: editorSession ?? localSession)
    }
}

#if DEBUG
@MainActor private enum ReceiptImportDemoDriver {
    private static var started = false
    static func shouldStart() -> Bool {
        guard !started, CommandLine.arguments.contains("--demo-delayed-receipt-import") else { return false }
        started = true
        return true
    }
}
#endif

private struct ReceiptPickerContent: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Binding var assets: [AttachmentAsset]
    let textOnly: Bool
    let startWithScan: Bool
    @ObservedObject var session: ReceiptImportSession
    @State private var didStartInitialScan = false
    @State private var files = false
    @State private var photos = false
    @State private var scan = false
    @State private var selections: [PhotosPickerItem] = []
    @State private var importGeneration: UUID?

    var body: some View {
        Menu {
            Button("Choose Files", systemImage: "folder") { importGeneration = store.attachmentImportGeneration; files = true }
            Button("Photo Library", systemImage: "photo") { importGeneration = store.attachmentImportGeneration; photos = true }
            if VNDocumentCameraViewController.isSupported {
                Button("Scan Receipt", systemImage: "doc.viewfinder") { importGeneration = store.attachmentImportGeneration; scan = true }
            }
        } label: {
            if session.isImporting { ProgressView("Adding Receipt…") }
            else if textOnly { Text("Add Attachment") }
            else { Label("Add Attachment", systemImage: "paperclip") }
        }
        .disabled(session.isImporting || !session.isAccepting)
        .accessibilityIdentifier("receipt-import-picker")
        .accessibilityValue(session.isImporting ? "Importing" : "Ready")
        .task {
            #if DEBUG
            if ReceiptImportDemoDriver.shouldStart() {
                let generation = store.attachmentImportGeneration
                session.start { operationID in
                    try await Task.sleep(for: .seconds(6))
                    try await importBytes(Data("Delayed synthetic receipt".utf8), filename: "Delayed Receipt.txt", generation: generation, operationID: operationID)
                }
            }
            #endif
            guard startWithScan, !didStartInitialScan else { return }
            didStartInitialScan = true
            importGeneration = store.attachmentImportGeneration
            if VNDocumentCameraViewController.isSupported { scan = true }
            else {
                session.start { _ in throw ValidationError(message: "Receipt scanning is unavailable on this device. Choose a file or photo instead.") }
            }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            let generation = importGeneration ?? store.attachmentImportGeneration
            session.start { operationID in
                for url in try result.get() {
                    try Task.checkCancellation()
                    _ = try await store.importAttachmentAsync(from: url, expectedGeneration: generation) { asset in
                        try session.accept(asset, for: operationID)
                        assets.append(asset)
                    }
                }
            }
        }
        .photosPicker(isPresented: $photos, selection: $selections, maxSelectionCount: 10, matching: .images)
        .onChange(of: selections) { _, items in
            guard !items.isEmpty else { return }
            let generation = importGeneration ?? store.attachmentImportGeneration
            session.start { operationID in
                defer { selections = [] }
                for item in items {
                    try Task.checkCancellation()
                    guard let bytes = try await item.loadTransferable(type: Data.self) else { continue }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    try await importBytes(bytes, filename: "Photo-\(UUID().uuidString.prefix(8)).\(ext)", generation: generation, operationID: operationID)
                }
            }
        }
        .sheet(isPresented: $scan) {
            let generation = importGeneration ?? store.attachmentImportGeneration
            ReceiptScanner { result in
                scan = false
                session.start { operationID in
                    for (index, bytes) in try result.get().enumerated() {
                        try await importBytes(bytes, filename: "Receipt-\(UUID().uuidString.prefix(8))-\(index + 1).jpg", generation: generation, operationID: operationID)
                    }
                }
            }
        }
        .alert("Couldn’t Add Receipt", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.clearError() } })) {
            Button("OK") { session.clearError() }
        } message: { Text(session.errorMessage ?? "") }
    }

    private func importBytes(_ bytes: Data, filename: String, generation: UUID, operationID: UUID) async throws {
        try Task.checkCancellation()
        let temporary = try await ReceiptImportIO.shared.stage(bytes, filename: filename)
        do {
            _ = try await store.importAttachmentAsync(from: temporary.url, expectedGeneration: generation) { asset in
                try session.accept(asset, for: operationID)
                assets.append(asset)
            }
            await ReceiptImportIO.shared.remove(temporary)
        } catch {
            await ReceiptImportIO.shared.remove(temporary)
            throw error
        }
    }
}

struct ReceiptContentVersion: Hashable {
    let epoch: UUID
    let revision: UInt64
}

/// File replacements are independent of attachment metadata. Publish only to
/// receipt observers, and change only the IDs whose verified bytes were replaced.
@MainActor
final class ReceiptContentRevisions: ObservableObject {
    @Published private var notificationRevision: UInt64 = 0
    private var epoch = UUID()
    private var revisions: [UUID: UInt64] = [:]

    func version(for assetID: UUID) -> ReceiptContentVersion {
        ReceiptContentVersion(epoch: epoch, revision: revisions[assetID] ?? 0)
    }

    func didReplaceContents(of assetIDs: Set<UUID>) {
        guard !assetIDs.isEmpty else { return }
        notificationRevision &+= 1
        for id in assetIDs { revisions[id, default: 0] &+= 1 }
    }

    func invalidateAll() {
        notificationRevision &+= 1
        epoch = UUID()
        revisions.removeAll()
    }
}

struct ReceiptThumbnailKey: Hashable {
    let asset: AttachmentAsset
    let fileURL: URL
    let contentVersion: ReceiptContentVersion
}

@MainActor
final class ReceiptThumbnailModel: ObservableObject {
    @Published private(set) var image: UIImage?
    private var requestID = UUID()

    func load(_ key: ReceiptThumbnailKey,
              isCurrent: @MainActor (ReceiptThumbnailKey) -> Bool = { _ in true },
              generate: @MainActor (ReceiptThumbnailKey) async throws -> UIImage?) async {
        let id = UUID()
        requestID = id
        if image != nil { image = nil }
        do {
            let rendered = try await generate(key)
            guard requestID == id, isCurrent(key), !Task.isCancelled else { return }
            image = rendered
        } catch {
            // A late/cancelled request may not overwrite a newer thumbnail.
            guard requestID == id, isCurrent(key), !Task.isCancelled else { return }
            image = nil
        }
    }
}

struct ReceiptPreview: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let asset: AttachmentAsset
    var showsFilename = true
    var thumbnailHeight: CGFloat = 260

    var body: some View {
        ReceiptPreviewContent(asset: asset, fileURL: store.attachmentURL(for: asset),
            showsFilename: showsFilename, thumbnailHeight: thumbnailHeight,
            contentRevisions: store.receiptContentRevisions)
    }
}

private struct ReceiptPreviewContent: View {
    let asset: AttachmentAsset
    let fileURL: URL
    let showsFilename: Bool
    let thumbnailHeight: CGFloat
    @ObservedObject var contentRevisions: ReceiptContentRevisions
    @StateObject private var thumbnail = ReceiptThumbnailModel()
    @State private var previewURL: URL?
    @State private var unavailable = false

    var body: some View {
        let key = ReceiptThumbnailKey(asset: asset, fileURL: fileURL, contentVersion: contentRevisions.version(for: asset.id))
        Button {
            if FileManager.default.fileExists(atPath: fileURL.path) { previewURL = fileURL }
            else { unavailable = true }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if let image = thumbnail.image {
                    if showsFilename {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: thumbnailHeight)
                    } else {
                        GeometryReader { geometry in
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: thumbnailHeight, alignment: .top).clipped()
                        }
                        .frame(height: thumbnailHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color(uiColor: .separator), lineWidth: 0.5) }
                    }
                }
                if showsFilename || thumbnail.image == nil { Label(asset.originalFilename, systemImage: "paperclip").font(.subheadline).lineLimit(2) }
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
        .task(id: key) {
            await thumbnail.load(key, isCurrent: { contentRevisions.version(for: $0.asset.id) == $0.contentVersion }) { key in
                let request = QLThumbnailGenerator.Request(fileAt: key.fileURL, size: CGSize(width: 600, height: 400), scale: 1, representationTypes: .thumbnail)
                return try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
            }
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
