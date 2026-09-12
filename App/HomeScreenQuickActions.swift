import SwiftUI
import UIKit
import Combine

struct HomeScreenQuickActionTemplate: Identifiable, Equatable {
    let id: UUID
    let ledgerID: UUID
    let title: String
    let journalTitle: String
    let scansReceipt: Bool
    var includedRowID: String { "included-\(id)" }
    var availableRowID: String { "available-\(id)" }
}

/// Device-local selection and UIKit publication. Only small template/journal
/// metadata is retained; updating shortcuts never scans transaction history.
@MainActor
final class HomeScreenQuickActions: ObservableObject {
    static let maximumCount = 4
    static let preferenceKey = "entry.homeScreenTemplates"
    static let shortcutPrefix = "dev.gan.FinancesApp.iOS.template."
    static let shared = HomeScreenQuickActions(
        publish: { UIApplication.shared.shortcutItems = $0 },
        openTemplate: { SystemEntryRouter.shared.openTemplate($0) }
    )

    private struct DisplayState: Equatable {
        var selected: [HomeScreenQuickActionTemplate] = []
        var available: [HomeScreenQuickActionTemplate] = []
    }
    @Published private var displayState = DisplayState()
    var selectedTemplates: [HomeScreenQuickActionTemplate] { displayState.selected }
    var availableTemplates: [HomeScreenQuickActionTemplate] { displayState.available }
    private let preferences: UserDefaults
    private let publish: ([UIApplicationShortcutItem]) -> Void
    private let openTemplate: (UUID) -> Void
    private var preferenceObservation: AnyCancellable?
    private var configuredIDs: [UUID]
    private var observedHiddenIDs: Set<UUID>
    private var hiddenIDs: Set<UUID>
    private var ledgers: [Ledger] = []
    private var templates: [TransactionTemplate] = []
    private var preferredLedgerID: UUID?
    private var eligibleTemplates: [HomeScreenQuickActionTemplate] = []
    private var eligibleByID: [UUID: HomeScreenQuickActionTemplate] = [:]
    private var lastPublished: [HomeScreenQuickActionTemplate]?
    private var hasLoadedMetadata = false
    private var pendingTemplateID: UUID?

    init(preferences: UserDefaults = MobileDisplayPreferences.defaults,
         publish: @escaping ([UIApplicationShortcutItem]) -> Void,
         openTemplate: @escaping (UUID) -> Void) {
        self.preferences = preferences
        self.publish = publish
        self.openTemplate = openTemplate
        configuredIDs = Self.decodeSelection(preferences.string(forKey: Self.preferenceKey) ?? "")
        let hidden = JournalVisibility(rawValue: preferences.string(forKey: JournalVisibility.preferenceKey) ?? "").hiddenIDs
        observedHiddenIDs = hidden
        hiddenIDs = hidden
        preferenceObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in self?.preferencesChanged() }
            }
    }

    var canAddTemplate: Bool { selectedTemplates.count < Self.maximumCount }

    func update(data: JournalData, hiddenLedgerIDs: Set<UUID>) {
        guard !hasLoadedMetadata || ledgers != data.ledgers || templates != data.transactionTemplates || hiddenIDs != hiddenLedgerIDs else { return }
        ledgers = data.ledgers
        templates = data.transactionTemplates
        preferredLedgerID = data.selectedLedgerID
        hiddenIDs = hiddenLedgerIDs
        hasLoadedMetadata = true
        rebuildEligibleTemplates()
        if let pendingTemplateID {
            self.pendingTemplateID = nil
            _ = openIfEligible(pendingTemplateID)
        }
    }

    @discardableResult
    func addTemplate(_ id: UUID) -> Bool {
        guard hasLoadedMetadata, canAddTemplate, eligibleByID[id] != nil,
              !selectedTemplates.contains(where: { $0.id == id }) else { return false }
        // Dormant hidden/disabled shortcuts do not consume an invisible slot
        // when the user explicitly fills the menu with other templates.
        setSelection(selectedTemplates.map(\.id) + [id])
        return true
    }

    func removeTemplates(at offsets: IndexSet) {
        let removed = Set(offsets.compactMap { selectedTemplates.indices.contains($0) ? selectedTemplates[$0].id : nil })
        setSelection(configuredIDs.filter { !removed.contains($0) })
    }

    func moveTemplates(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ selectedTemplates.indices.contains($0) }),
              (0...selectedTemplates.count).contains(destination) else { return }
        var visible = selectedTemplates.map(\.id)
        visible.move(fromOffsets: offsets, toOffset: destination)
        let visibleIDs = Set(visible)
        setSelection(visible + configuredIDs.filter { !visibleIDs.contains($0) })
    }

    /// A stale menu item can arrive after a journal/template was hidden or
    /// removed. Identity comes from the type, never its editable display name.
    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let id = Self.templateID(from: item) else { return false }
        preferencesChanged()
        guard configuredIDs.contains(id) else { return false }
        guard hasLoadedMetadata else {
            pendingTemplateID = id
            return true
        }
        return openIfEligible(id)
    }

    static func templateID(from item: UIApplicationShortcutItem) -> UUID? {
        guard item.type.hasPrefix(shortcutPrefix) else { return nil }
        return UUID(uuidString: String(item.type.dropFirst(shortcutPrefix.count)))
    }

    private func openIfEligible(_ id: UUID) -> Bool {
        guard configuredIDs.contains(id), eligibleByID[id] != nil else { return false }
        openTemplate(id)
        return true
    }

    private func preferencesChanged() {
        let selected = Self.decodeSelection(preferences.string(forKey: Self.preferenceKey) ?? "")
        let hidden = JournalVisibility(rawValue: preferences.string(forKey: JournalVisibility.preferenceKey) ?? "").hiddenIDs
        let visibilityChanged = hidden != observedHiddenIDs
        observedHiddenIDs = hidden
        guard selected != configuredIDs || visibilityChanged else { return }
        configuredIDs = selected
        if visibilityChanged { hiddenIDs = hidden }
        guard hasLoadedMetadata else { return }
        if visibilityChanged { rebuildEligibleTemplates() }
        else { rebuildSelection() }
    }

    private func setSelection(_ ids: [UUID]) {
        let selected = Self.decodeSelection(ids.map(\.uuidString).joined(separator: ","))
        guard selected != configuredIDs else { return }
        configuredIDs = selected
        preferences.set(selected.map(\.uuidString).joined(separator: ","), forKey: Self.preferenceKey)
        rebuildSelection()
    }

    private static func decodeSelection(_ raw: String) -> [UUID] {
        var seen = Set<UUID>()
        return Array(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            .filter { seen.insert($0).inserted }.prefix(maximumCount))
    }

    private func rebuildEligibleTemplates() {
        let orderedLedgers = ledgers.filter { !hiddenIDs.contains($0.id) }.sorted {
            if $0.listIndex != $1.listIndex { return $0.listIndex < $1.listIndex }
            return $0.id.uuidString < $1.id.uuidString
        }
        let byLedger = Dictionary(grouping: templates.filter(\.enabled), by: \.ledgerID)
        eligibleTemplates = orderedLedgers.flatMap { ledger in
            (byLedger[ledger.id] ?? []).sorted {
                if $0.listIndex != $1.listIndex { return $0.listIndex < $1.listIndex }
                return $0.id.uuidString < $1.id.uuidString
            }.map { HomeScreenQuickActionTemplate(id: $0.id, ledgerID: ledger.id, title: $0.name, journalTitle: ledger.name, scansReceipt: $0.scanInvoice) }
        }
        eligibleByID = Dictionary(eligibleTemplates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if preferences.object(forKey: Self.preferenceKey) == nil, !eligibleTemplates.isEmpty {
            let preferred = eligibleTemplates.filter { $0.ledgerID == preferredLedgerID }
            let remaining = eligibleTemplates.filter { $0.ledgerID != preferredLedgerID }
            configuredIDs = Array((preferred + remaining).prefix(Self.maximumCount).map(\.id))
            preferences.set(configuredIDs.map(\.uuidString).joined(separator: ","), forKey: Self.preferenceKey)
        }
        rebuildSelection()
    }

    private func rebuildSelection() {
        let selected = configuredIDs.compactMap { eligibleByID[$0] }
        let ids = Set(selected.map(\.id))
        let available = eligibleTemplates.filter { !ids.contains($0.id) }
        let next = DisplayState(selected: selected, available: available)
        if displayState != next { displayState = next }
        guard hasLoadedMetadata, lastPublished != selected else { return }
        lastPublished = selected
        publish(selected.map { template in
            UIApplicationShortcutItem(type: Self.shortcutPrefix + template.id.uuidString,
                localizedTitle: template.title, localizedSubtitle: template.journalTitle,
                icon: UIApplicationShortcutIcon(systemImageName: template.scansReceipt ? "doc.viewfinder" : "square.and.pencil"))
        })
    }
}

/// Root installs this class on the scene configuration; SwiftUI continues to
/// own its window/content. Cold and warm actions converge on the same validator.
@MainActor
final class HomeScreenQuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    private let coordinator: HomeScreenQuickActions

    override init() { coordinator = .shared; super.init() }
    init(coordinator: HomeScreenQuickActions) { self.coordinator = coordinator; super.init() }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        receiveColdLaunchShortcut(connectionOptions.shortcutItem)
        receiveFiles(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        receiveFiles(URLContexts)
    }

    private func receiveFiles(_ contexts: Set<UIOpenURLContext>) {
        let urls = contexts.map(\.url).filter(\.isFileURL).sorted { $0.absoluteString < $1.absoluteString }
        if !urls.isEmpty { SystemEntryRouter.shared.openReceipts(urls) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        performShortcut(shortcutItem, completionHandler: completionHandler)
    }

    func receiveColdLaunchShortcut(_ item: UIApplicationShortcutItem?) {
        if let item { _ = coordinator.handle(item) }
    }

    func performShortcut(_ item: UIApplicationShortcutItem, completionHandler: (Bool) -> Void) {
        completionHandler(coordinator.handle(item))
    }
}

struct HomeScreenQuickActionSettingsView: View {
    @ObservedObject private var coordinator: HomeScreenQuickActions

    init(coordinator: HomeScreenQuickActions = .shared) { self.coordinator = coordinator }

    var body: some View {
        List {
            Section {
                ForEach(coordinator.selectedTemplates, id: \.includedRowID) { template in
                    templateLabel(template)
                }
                .onDelete(perform: coordinator.removeTemplates)
                .onMove(perform: coordinator.moveTemplates)
                if coordinator.selectedTemplates.isEmpty {
                    Text("Choose up to four templates below.").foregroundStyle(.secondary)
                }
            } header: { Text("Included") } footer: {
                Text("Touch and hold Finances v2 on the Home Screen to start a transaction from one of these templates.")
            }
            Section("More Templates") {
                ForEach(coordinator.availableTemplates, id: \.availableRowID) { template in
                    Button {
                        _ = coordinator.addTemplate(template.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                            templateLabel(template)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!coordinator.canAddTemplate)
                    .accessibilityLabel("Add \(template.title), \(template.journalTitle)")
                }
                if coordinator.availableTemplates.isEmpty {
                    Text("Create or enable a template in a visible journal to add it here.")
                        .foregroundStyle(.secondary)
                }
            }
            .environment(\.editMode, .constant(.inactive))
        }
        .listStyle(.insetGrouped)
        .compactGroupedForm()
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Home Screen Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func templateLabel(_ template: HomeScreenQuickActionTemplate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(template.title).foregroundStyle(.primary)
            Text(template.journalTitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
