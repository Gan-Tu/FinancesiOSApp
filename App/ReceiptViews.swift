import SwiftUI
import PhotosUI
import QuickLook
import QuickLookThumbnailing
import VisionKit

struct ReceiptPicker: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Binding var assets: [AttachmentAsset]
    var textOnly = false
    @State private var files = false
    @State private var photos = false
    @State private var scan = false
    @State private var selections: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var errorMessage: String?

    var body: some View {
        Menu {
            Button("Choose Files", systemImage: "folder") { files = true }
            Button("Photo Library", systemImage: "photo") { photos = true }
            if VNDocumentCameraViewController.isSupported {
                Button("Scan Receipt", systemImage: "doc.viewfinder") { scan = true }
            }
        } label: {
            if importing { ProgressView("Adding Receipt…") }
            else if textOnly { Text("Add Attachment") }
            else { Label("Add Attachment", systemImage: "paperclip") }
        }
        .disabled(importing)
        .fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await importURLs(urls) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $photos, selection: $selections, maxSelectionCount: 10, matching: .images)
        .onChange(of: selections) { _, items in
            Task {
                importing = true
                defer { importing = false; selections = [] }
                do {
                    for item in items {
                        guard let bytes = try await item.loadTransferable(type: Data.self) else { continue }
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        try await importBytes(bytes, filename: "Photo-\(UUID().uuidString.prefix(8)).\(ext)")
                    }
                } catch { errorMessage = error.localizedDescription }
            }
        }
        .sheet(isPresented: $scan) {
            ReceiptScanner { result in
                scan = false
                Task {
                    importing = true
                    defer { importing = false }
                    do {
                        for (index, bytes) in try result.get().enumerated() {
                            try await importBytes(bytes, filename: "Receipt-\(UUID().uuidString.prefix(8))-\(index + 1).jpg")
                        }
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .alert("Couldn’t Add Receipt", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func importURLs(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        do { for url in urls { assets.append(try await store.importAttachmentAsync(from: url)) } }
        catch { errorMessage = error.localizedDescription }
    }
    private func importBytes(_ bytes: Data, filename: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try bytes.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        assets.append(try await store.importAttachmentAsync(from: url))
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
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<[Data], Error>) -> Void
        init(completion: @escaping (Result<[Data], Error>) -> Void) { self.completion = completion }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            completion(.success((0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.85) }))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(.success([])) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { completion(.failure(error)) }
    }
}
