import SwiftUI
import PhotosUI
import AVFoundation
import VisionKit

struct AssistantAttachmentContext: Equatable {
    let conversationID: UUID
    let identity: String
}

enum AssistantAttachmentInput {
    case file(URL)
    case bytes(Data, filename: String)
}

@MainActor
enum AssistantPhotoLoader {
    static func load<Selection>(_ selections: [Selection], maximumBytes: Int,
                                read: @MainActor (Selection) async throws -> (data: Data, filename: String)) async throws -> [AssistantAttachmentInput] {
        var inputs: [AssistantAttachmentInput] = [], total = 0
        for selection in selections {
            try Task.checkCancellation()
            let photo = try await read(selection)
            try Task.checkCancellation()
            guard !photo.data.isEmpty, photo.data.count <= 15 * 1024 * 1024 else {
                throw AssistantFailure("attachment_limit", "Each chat attachment must be at most 15 MiB.")
            }
            total += photo.data.count
            guard total <= maximumBytes else { throw AssistantFailure("attachment_limit", "One message can include at most 40 MB of attachments.") }
            inputs.append(.bytes(photo.data, filename: photo.filename))
        }
        return inputs
    }
}

/// Uses the receipt flow's scanner, encoder and temporary-file staging. Chat
/// uploads remain separate from durable transaction receipt storage.
struct AssistantAttachmentMenu: View {
    @ObservedObject var assistant: AssistantCoordinator
    @State private var files = false
    @State private var fileContext: AssistantAttachmentContext?
    @State private var photos = false
    @State private var selections: [PhotosPickerItem] = []
    @State private var photoContext: AssistantAttachmentContext?
    @State private var capture: CaptureRequest?

    private enum CaptureKind { case photo, receipt, pdf }
    private struct CaptureRequest: Identifiable {
        let id = UUID()
        let kind: CaptureKind
        let context: AssistantAttachmentContext
    }

    var body: some View {
        Menu {
            Button("Choose Files", systemImage: "folder") {
                guard let context = assistant.beginAttachmentSelection() else { return }
                fileContext = context; files = true
            }
            Button("Photo Library", systemImage: "photo") {
                guard let context = assistant.beginAttachmentSelection() else { return }
                photoContext = context; photos = true
            }
            Button("Take Photo", systemImage: "camera") { requestCamera(.photo) }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button("Scan Receipt", systemImage: "doc.viewfinder") { requestCamera(.receipt) }
                .disabled(!VNDocumentCameraViewController.isSupported)
            Button("Scan to PDF", systemImage: "doc") { requestCamera(.pdf) }
                .disabled(!VNDocumentCameraViewController.isSupported)
        } label: {
            Image(systemName: "plus").font(.system(size: 21, weight: .regular)).frame(width: 44, height: 44).contentShape(Circle())
        }
        .foregroundStyle(Color(uiColor: .secondaryLabel))
        .accessibilityLabel("Add Attachment")
        .accessibilityIdentifier("assistant.attach")
        .disabled(!assistant.canAttachFiles)
        .fileImporter(isPresented: $files, allowedContentTypes: [.image, .pdf, .plainText, .commaSeparatedText, .data], allowsMultipleSelection: true) { [context = fileContext] result in
            if fileContext == context { fileContext = nil }
            guard let context, assistant.isCurrentAttachmentContext(context) else { return }
            do { assistant.attach(try result.get(), context: context) }
            catch { if (error as NSError).code != NSUserCancelledError { assistant.error = error.localizedDescription } }
        }
        .photosPicker(isPresented: $photos, selection: $selections, maxSelectionCount: max(1, 10 - assistant.uploadedFiles.count), matching: .images)
        .onChange(of: selections) { _, items in
            guard !items.isEmpty, let context = photoContext else { return }
            selections = []; photoContext = nil
            assistant.attach(context: context) {
                try await AssistantPhotoLoader.load(items, maximumBytes: remainingBytes) { item in
                    guard let bytes = try await item.loadTransferable(type: Data.self) else {
                        throw AssistantFailure("photo_unavailable", "The selected photo could not be loaded. Please choose it again.")
                    }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    return (bytes, "Photo-\(UUID().uuidString.prefix(8)).\(ext)")
                }
            }
        }
        .sheet(item: $capture) { request in
            if request.kind == .photo {
                AssistantCameraPicker { result in receive(result, request: request) }
            } else {
                ReceiptScanner(maximumPages: request.kind == .pdf ? 30 : max(1, 10 - assistant.uploadedFiles.count), maximumBytes: remainingBytes) { result in receive(result, request: request) }
            }
        }
        .onChange(of: assistant.identity) { _, _ in clearSelection() }
        .onChange(of: assistant.conversation.id) { _, _ in clearSelection() }
    }

    private var remainingBytes: Int { max(0, 40_000_000 - assistant.uploadedFiles.reduce(0) { $0 + ($1["size_bytes"].int ?? 0) }) }

    private func requestCamera(_ kind: CaptureKind) {
        guard let context = assistant.beginAttachmentSelection() else { return }
        Task { @MainActor in
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard assistant.isCurrentAttachmentContext(context) else { return }
            if allowed { capture = CaptureRequest(kind: kind, context: context) }
            else { assistant.error = "Enable camera access for Finances in Settings, or choose Photo Library or Files." }
        }
    }

    private func receive(_ result: Result<[Data], Error>, request: CaptureRequest) {
        guard capture?.id == request.id else { return }
        capture = nil
        guard assistant.isCurrentAttachmentContext(request.context) else { return }
        do {
            let pages = try result.get()
            guard !pages.isEmpty else { return } // Explicit scanner/camera cancellation.
            assistant.attach(context: request.context) {
                if request.kind == .pdf {
                    return [.bytes(try await ReceiptScanPDF.shared.makeDocument(pages: pages), filename: "Scan-\(UUID().uuidString.prefix(8)).pdf")]
                }
                let prefix = request.kind == .photo ? "Photo" : "Receipt"
                return pages.enumerated().map { .bytes($0.element, filename: "\(prefix)-\(UUID().uuidString.prefix(8))-\($0.offset + 1).jpg") }
            }
        } catch { assistant.error = error.localizedDescription }
    }

    private func clearSelection() {
        capture = nil; photos = false; files = false; selections = []; photoContext = nil; fileContext = nil
    }
}

private struct AssistantCameraPicker: UIViewControllerRepresentable {
    let completion: (Result<[Data], Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIImagePickerController, coordinator: Coordinator) { coordinator.session.invalidate() }

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let session: ReceiptScanSession
        init(completion: @escaping (Result<[Data], Error>) -> Void) { session = ReceiptScanSession(completion: completion) }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { session.cancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { session.fail(AssistantFailure("photo_unavailable", "The photo could not be captured.")); return }
            session.start { [try await ReceiptScanImage(image: image).jpegData()] }
        }
    }
}
