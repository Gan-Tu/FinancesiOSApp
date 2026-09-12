import SwiftUI
import AppIntents

struct IncomingTransactionRequest: Identifiable {
    var id = UUID()
    var suggestion: CaptureSuggestion?
    var receiptURLs: [URL] = []
    var sharedReceiptID: UUID?
}

@MainActor
final class SystemEntryRouter: ObservableObject {
    static let shared = SystemEntryRouter()
    enum Destination {
        case template(UUID), incoming(IncomingTransactionRequest), suggestions
    }
    struct Request: Identifiable { var id = UUID(); var destination: Destination }
    @Published private(set) var requests: [Request] = []
    @Published private(set) var suggestions: [CaptureSuggestion] = []
    @Published private(set) var editorRevision: UInt64 = 0
    @Published var error: ValidationError?
    private var catalog: SystemIntegrationCatalog?
    private var catalogWrite: Task<Void, Never>?
    private var queuedReceiptIDs: Set<UUID> = []
    private var restoredReceipts = false
    private var editorIDs: Set<UUID> = []
    private var suggestionsRevision: UInt64 = 0
    private let receiptInbox: SharedReceiptInbox
    private let suggestionRepository: CaptureSuggestionRepository
    private let catalogRepository: SystemIntegrationCatalogRepository
    private let publishShortcutParameters: () -> Void

    init(receiptInbox: SharedReceiptInbox = .shared,
         suggestionRepository: CaptureSuggestionRepository = .shared,
         catalogRepository: SystemIntegrationCatalogRepository = .shared,
         publishShortcutParameters: @escaping () -> Void = { FinancesAppShortcuts.updateAppShortcutParameters() }) {
        self.receiptInbox = receiptInbox
        self.suggestionRepository = suggestionRepository
        self.catalogRepository = catalogRepository
        self.publishShortcutParameters = publishShortcutParameters
    }
    var activeEditorCount: Int { editorIDs.count }
    func beginEditor(_ id: UUID) {
        editorIDs.insert(id)
        Task { @MainActor [weak self] in self?.editorRevision &+= 1 }
    }
    func endEditor(_ id: UUID) {
        editorIDs.remove(id)
        Task { @MainActor [weak self] in self?.editorRevision &+= 1 }
    }

    func openTemplate(_ templateID: UUID) { requests.append(.init(destination: .template(templateID))) }
    func openNewTransaction(_ suggestion: CaptureSuggestion? = nil) {
        requests.append(.init(destination: .incoming(.init(suggestion: suggestion))))
    }
    func openReceipts(_ urls: [URL]) {
        Task {
            do { try await openSharedReceipt(receiptInbox.stage(urls)) }
            catch { self.error = ValidationError(message: "Could not open receipt: \(error.localizedDescription)") }
        }
    }
    func openSharedReceipt(_ entry: SharedReceiptEntry) async throws {
        guard queuedReceiptIDs.insert(entry.id).inserted else { return }
        do {
            let urls = try await receiptInbox.fileURLs(for: entry)
            requests.append(.init(destination: .incoming(.init(id: entry.id, receiptURLs: urls, sharedReceiptID: entry.id))))
        } catch { queuedReceiptIDs.remove(entry.id); throw error }
    }
    func restoreSharedReceipts(store: MobileLedgerStore) async {
        guard !restoredReceipts else { return }
        restoredReceipts = true
        do {
            let entries = try await receiptInbox.pendingEntries()
            let committed = await store.durablyStoredTransactionIDs(Set(entries.map(\.id)))
            for entry in entries {
                if committed.contains(entry.id) { try await receiptInbox.discard(entry.id) }
                else { try await openSharedReceipt(entry) }
            }
        } catch { self.error = ValidationError(message: "Could not restore pending receipts: \(error.localizedDescription)") }
    }
    func finishSharedReceipt(_ id: UUID) {
        // Retain the delivered identity for this session so late duplicate
        // callbacks cannot reopen a batch while its cleanup is suspended.
        Task {
            do { try await receiptInbox.discard(id) }
            catch { self.error = ValidationError(message: "Could not remove the pending receipt: \(error.localizedDescription)") }
        }
    }
    func openSuggestions() { requests.append(.init(destination: .suggestions)) }
    func takeNext() -> Request? { requests.isEmpty || !editorIDs.isEmpty ? nil : requests.removeFirst() }

    func updateCatalog(data: JournalData, hiddenLedgerIDs: Set<UUID>) {
        let journals = data.ledgers.filter { !hiddenLedgerIDs.contains($0.id) }.sorted { $0.listIndex < $1.listIndex }
        let names = Dictionary(uniqueKeysWithValues: journals.map { ($0.id, $0.name) })
        let next = SystemIntegrationCatalog(journals: journals.map { .init(id: $0.id, name: $0.name) },
            templates: data.transactionTemplates.filter { $0.enabled && names[$0.ledgerID] != nil }
                .sorted { $0.listIndex < $1.listIndex }.map { .init(id: $0.id, journalID: $0.ledgerID, name: $0.name, journalName: names[$0.ledgerID]!) })
        guard next != catalog else { return }
        catalog = next
        let previous = catalogWrite
        catalogWrite = Task {
            await previous?.value
            do {
                try await catalogRepository.save(next)
                publishShortcutParameters()
            } catch { /* The editor still resolves against the live store. */ }
        }
    }

    func reloadSuggestions(store: MobileLedgerStore) async {
        suggestionsRevision &+= 1
        let revision = suggestionsRevision
        do {
            let loaded = try await suggestionRepository.all()
            // A crash after Save but before inbox removal cannot create a duplicate.
            let committed = await store.durablyStoredTransactionIDs(Set(loaded.map(\.id)))
            let completed = loaded.filter { committed.contains($0.id) }
            for item in completed { try await suggestionRepository.remove(item.id) }
            guard revision == suggestionsRevision else { return }
            suggestions = loaded.filter { !committed.contains($0.id) }
        } catch { if revision == suggestionsRevision { self.error = ValidationError(message: "Could not load Suggestions: \(error.localizedDescription)") } }
    }

    func dismissSuggestion(_ id: UUID, store: MobileLedgerStore) async {
        suggestionsRevision &+= 1
        do {
            try await suggestionRepository.remove(id)
            suggestions.removeAll { $0.id == id }
            await reloadSuggestions(store: store)
        } catch { self.error = ValidationError(message: "Could not remove the suggestion: \(error.localizedDescription)") }
    }
}

/// Every editor, including editors presented by nested search/settings screens,
/// holds a lease until UIKit tears down its presentation subtree.
struct SystemEntryEditorLifetimeAnchor: UIViewRepresentable {
    let id: UUID
    func makeUIView(context: Context) -> UIView {
        SystemEntryRouter.shared.beginEditor(id)
        return UIView(frame: .zero)
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func makeCoordinator() -> UUID { id }
    static func dismantleUIView(_ uiView: UIView, coordinator: UUID) {
        Task { @MainActor in SystemEntryRouter.shared.endEditor(coordinator) }
    }
}
