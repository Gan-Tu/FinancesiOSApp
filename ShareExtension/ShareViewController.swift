import UIKit
import QuickLook

@MainActor
final class ShareViewController: UIViewController, @preconcurrency UIDocumentInteractionControllerDelegate {
    private enum Phase: Equatable { case preparing, preview, sending, cancelling, finished, failed }
    private var phase = Phase.preparing
    private let status = UILabel()
    private let detail = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let cancel = UIButton(type: .system)
    private var preparation: Task<Void, Never>?
    private let progress = Progress(totalUnitCount: 1)
    private var receiptInbox: SharedReceiptInbox?
    private var receiptEntry: SharedReceiptEntry?
    private var documentController: UIDocumentInteractionController?
    private var preview: ShareReceiptPreviewController?
    private var loadingStack: UIStackView?
    private var shouldOfferOpenIn = false
    private var hasAppeared = false
    private var handoffDirectory: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 440, height: 600)
        status.font = .preferredFont(forTextStyle: .title2)
        status.text = "Preparing Receipt"
        status.accessibilityIdentifier = "receipt-share-status"
        detail.font = .preferredFont(forTextStyle: .body)
        detail.text = "Preparing your screenshot for Finances…"
        for label in [status, detail] {
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        cancel.setTitle("Cancel", for: .normal)
        cancel.accessibilityIdentifier = "receipt-share-cancel"
        cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [spinner, status, detail, cancel])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        loadingStack = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        isModalInPresentation = true
        spinner.startAnimating()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                #if DEBUG
                let inbox = try SharedReceiptStorage.inbox(demo: SharedReceiptStorage.usesDemoInbox)
                #else
                let inbox = try SharedReceiptStorage.inbox()
                #endif
                receiptInbox = inbox
                let entry = try await SharedReceiptProviderLoader.stage(providers, in: inbox, progress: progress, awaitsHandoff: true)
                receiptEntry = entry
                if Task.isCancelled || progress.isCancelled {
                    try await inbox.discard(entry.id)
                    return
                }
                let urls = try await inbox.fileURLs(for: entry)
                try Task.checkCancellation()
                guard phase == .preparing else { return }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReceiptOpenIn-\(entry.id.uuidString)", isDirectory: true)
                handoffDirectory = directory
                let document = try SharedReceiptHandoff(receiptID: entry.id).write(in: directory)
                let controller = UIDocumentInteractionController(url: document)
                controller.uti = SharedReceiptHandoff.typeIdentifier
                controller.name = "New Transaction"
                controller.delegate = self
                documentController = controller
                showPreview(urls)
                phase = .preview
                shouldOfferOpenIn = true
                offerOpenInIfVisible()
            } catch is CancellationError {
                return
            } catch {
                guard phase != .cancelling, phase != .finished else { return }
                phase = .failed
                status.text = "Could Not Share Receipt"
                detail.text = error.localizedDescription
                spinner.stopAnimating()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        offerOpenInIfVisible()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hasAppeared = false
    }

    private func showPreview(_ urls: [URL]) {
        spinner.stopAnimating()
        loadingStack?.removeFromSuperview()
        loadingStack = nil
        let preview = ShareReceiptPreviewController(urls: urls)
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelShare))
        preview.navigationItem.leftBarButtonItem?.accessibilityIdentifier = "receipt-share-cancel"
        preview.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Open Finances", style: .done, target: self, action: #selector(openFinances))
        preview.navigationItem.rightBarButtonItem?.accessibilityIdentifier = "receipt-share-open-finances"
        self.preview = preview
        let navigation = UINavigationController(rootViewController: preview)
        addChild(navigation)
        navigation.view.frame = view.bounds
        navigation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigation.view)
        navigation.didMove(toParent: self)
        view.layoutIfNeeded()
    }

    private func offerOpenInIfVisible() {
        guard shouldOfferOpenIn, hasAppeared, view.window != nil, preview != nil, phase == .preview else { return }
        shouldOfferOpenIn = false
        openFinances()
    }

    @objc private func openFinances() {
        guard phase == .preview, let documentController, let button = preview?.navigationItem.rightBarButtonItem else { return }
        // The system's document-opening UI delivers this private document type
        // to Finances. The share extension itself never launches UIApplication.
        if !documentController.presentOpenInMenu(from: button, animated: true) {
            let alert = UIAlertController(title: "Could Not Open Finances", message: "You can preview your receipt here. Try Open Finances again, or cancel this share.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            preview?.present(alert, animated: true)
        }
    }

    func documentInteractionController(_ controller: UIDocumentInteractionController, willBeginSendingToApplication application: String?) {
        guard application == "dev.gan.FinancesApp.iOS", phase == .preview else { return }
        phase = .sending
        preview?.navigationItem.leftBarButtonItem?.isEnabled = false
        preview?.navigationItem.rightBarButtonItem?.isEnabled = false
    }

    func documentInteractionController(_ controller: UIDocumentInteractionController, didEndSendingToApplication application: String?) {
        guard phase == .sending, application == nil || application == "dev.gan.FinancesApp.iOS" else { return }
        phase = .finished
        cleanupHandoffDocument()
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func cancelShare() {
        guard phase != .sending, phase != .finished, phase != .cancelling else { return }
        phase = .cancelling
        cancel.isEnabled = false
        preview?.navigationItem.leftBarButtonItem?.isEnabled = false
        preview?.navigationItem.rightBarButtonItem?.isEnabled = false
        progress.cancel()
        preparation?.cancel()
        documentController?.dismissMenu(animated: false)
        Task {
            do {
                if let receiptEntry, let receiptInbox { try await receiptInbox.discard(receiptEntry.id) }
                cleanupHandoffDocument()
                phase = .finished
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                phase = .failed
                cancel.isEnabled = true
                preview?.navigationItem.leftBarButtonItem?.isEnabled = true
                let alert = UIAlertController(title: "Could Not Cancel Share", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                (preview as UIViewController? ?? self).present(alert, animated: true)
            }
        }
    }

    private func cleanupHandoffDocument() {
        guard let handoffDirectory else { return }
        try? FileManager.default.removeItem(at: handoffDirectory)
        self.handoffDirectory = nil
    }
}

@MainActor
private final class ShareReceiptPreviewController: UIViewController, QLPreviewControllerDataSource {
    private let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
        super.init(nibName: nil, bundle: nil)
        title = urls.count == 1 ? "Receipt" : "Receipts"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let preview = QLPreviewController()
        preview.dataSource = self
        addChild(preview)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            preview.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        preview.didMove(toParent: self)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { urls[index] as NSURL }
}
