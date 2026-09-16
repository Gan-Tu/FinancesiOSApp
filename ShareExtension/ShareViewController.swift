import UIKit
import SwiftUI

@MainActor
final class ShareViewController: UIViewController {
    private var preparation: Task<Void, Never>?
    private let progress = Progress(totalUnitCount: 1)
    private var inbox: SharedReceiptInbox?
    private var entry: SharedReceiptEntry?
    private var finished = false
    private var saving = false
    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 440, height: 720)
        isModalInPresentation = true
        status.text = "Preparing Transaction…"
        status.numberOfLines = 0
        status.textAlignment = .center
        status.accessibilityIdentifier = "receipt-share-status"
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
        let loading = UIStackView(arrangedSubviews: [status, cancel])
        loading.axis = .vertical; loading.spacing = 20
        loading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loading)
        NSLayoutConstraint.activate([
            loading.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            loading.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            loading.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        preparation = Task {
            do {
                #if DEBUG
                let inbox = try SharedReceiptStorage.inbox(demo: SharedReceiptStorage.usesDemoInbox)
                #else
                let inbox = try SharedReceiptStorage.inbox()
                #endif
                self.inbox = inbox
                let catalog = try await inbox.catalog()
                let entry = try await SharedReceiptProviderLoader.stage(providers, in: inbox, progress: progress, awaitsHandoff: true)
                self.entry = entry
                guard !finished, !Task.isCancelled else { try await inbox.discard(entry.id); return }
                let urls = try await inbox.fileURLs(for: entry)
                guard !finished, !Task.isCancelled else { try await inbox.discard(entry.id); return }
                let editor = SharedTransactionEditor(catalog: catalog, receipts: urls, save: { [weak self] transaction in
                    guard let self, !self.finished, !self.saving else { throw CancellationError() }
                    self.saving = true
                    do { try await inbox.saveTransaction(transaction, for: entry) }
                    catch { self.saving = false; throw error }
                    self.finished = true
                    self.extensionContext?.completeRequest(returningItems: nil)
                }, cancel: { [weak self] in self?.cancelShare() })
                let host = UIHostingController(rootView: editor)
                addChild(host)
                host.view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(host.view)
                NSLayoutConstraint.activate([
                    host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    host.view.topAnchor.constraint(equalTo: view.topAnchor),
                    host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
                ])
                host.didMove(toParent: self)
                loading.removeFromSuperview()
            } catch is CancellationError { }
            catch { if !finished { status.text = error.localizedDescription } }
        }
    }

    @objc private func cancelShare() {
        guard !finished, !saving else { return }
        finished = true; progress.cancel(); preparation?.cancel()
        Task {
            do {
                if let entry, let inbox { try await inbox.discard(entry.id) }
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                finished = false
                let alert = UIAlertController(title: "Could Not Cancel", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}
