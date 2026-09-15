import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let detail = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let done = UIButton(type: .system)
    private var preparation: Task<Void, Never>?
    private let progress = Progress(totalUnitCount: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 300)
        status.font = .preferredFont(forTextStyle: .title2)
        status.text = "Preparing Receipt"
        status.accessibilityIdentifier = "receipt-share-status"
        detail.font = .preferredFont(forTextStyle: .body)
        detail.text = "Keeping a copy for your new transaction…"
        for label in [status, detail] {
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        done.setTitle("Cancel", for: .normal)
        done.accessibilityIdentifier = "receipt-share-done"
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [spinner, status, detail, done])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
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
                let entry = try await SharedReceiptProviderLoader.stage(providers, in: inbox, progress: progress)
                if Task.isCancelled || progress.isCancelled {
                    try await inbox.discard(entry.id)
                    return
                }
                status.text = "Ready in Finances"
                detail.text = "Open Finances to review and save your transaction. Your \(entry.files.count == 1 ? "receipt is" : "receipts are") attached."
            } catch is CancellationError {
                return
            } catch {
                status.text = "Could Not Share Receipt"
                detail.text = error.localizedDescription
            }
            spinner.stopAnimating()
            done.setTitle("Done", for: .normal)
            isModalInPresentation = false
        }
    }

    @objc private func finish() {
        progress.cancel()
        preparation?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
