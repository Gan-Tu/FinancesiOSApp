import SwiftUI
import UIKit

enum EditorRoute: Identifiable {
    case transaction(TransactionDraft, String, scanInvoice: Bool = false)
    case newFromTemplate(TransactionTemplate, String, accountID: UUID? = nil)
    case incoming(IncomingTransactionRequest)
    case account(MobileAccountDraft)
    case currency(CurrencyDraft)
    case journalNew
    case journalRename(Ledger)
    case template(TransactionTemplateDraft)

    var id: String {
        switch self {
        case .transaction(let draft, let title, let scanInvoice):
            "transaction-\(draft.id?.uuidString ?? "new")-\(title)-\(scanInvoice)"
        case .newFromTemplate(let template, let title, let accountID):
            "template-transaction-\(template.id)-\(title)-\(accountID?.uuidString ?? "")"
        case .incoming(let request): "incoming-\(request.id)"
        case .account(let draft):
            "account-\(draft.id?.uuidString ?? "new")"
        case .currency(let draft):
            "currency-\(draft.id?.uuidString ?? "new")"
        case .journalNew:
            "journal-new"
        case .journalRename(let ledger):
            "journal-\(ledger.id.uuidString)"
        case .template(let draft):
            "template-\(draft.id?.uuidString ?? "new")"
        }
    }
}

struct AppShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: MobileLedgerStore
    @EnvironmentObject private var assistant: AssistantCoordinator
    @State private var sceneID = UUID()
    @State private var route: EditorRoute?
    @State private var navigationPath: [MobileRoute] = []
    @State private var presentedSheet: ShellSheet?
    @State private var templateSelection: TemplatePickerSelection?
    @ObservedObject private var systemEntries = SystemEntryRouter.shared
    @State private var activeSharedReceiptID: UUID?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            JournalsHomeScreen(navigationPath: $navigationPath, route: $route)
                .toolbar {
                    ToolbarItem(placement: .principal) { syncTitle("Journals") }
                }
                .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { globalBottomBar }
                .navigationDestination(for: MobileRoute.self) { destination in
                    Group {
                    switch destination {
                    case .journals:
                        JournalsHomeScreen(navigationPath: $navigationPath, route: $route)
                    case .journal(let ledgerID):
                        JournalOverviewScreen(ledgerID: ledgerID, navigationPath: $navigationPath, route: $route)
                    case .transactions(let scope, let title, let ledgerID):
                        TransactionListScreen(scope: scope, title: title, route: $route, ledgerID: ledgerID, openTransaction: { navigationPath.append(.transaction($0)) })
                    case .searchTransactions(let scope, let ledgerID, let query):
                        TransactionListScreen(scope: scope, title: query.title, route: $route, ledgerID: ledgerID, searchFilter: query, openTransaction: { navigationPath.append(.transaction($0)) })
                    case .assistantRegister(let scope, let ledgerID, let query, let interval):
                        TransactionListScreen(scope: scope, title: query.isEmpty ? "Transactions" : query, route: $route, dateInterval: interval, ledgerID: ledgerID, searchFilter: query.isEmpty ? nil : TransactionSearchQuery(text: query), openTransaction: { navigationPath.append(.transaction($0)) })
                    case .transaction(let transactionID):
                        TransactionDetailScreen(transactionID: transactionID, route: $route)
                    case .templates(let ledgerID):
                        TemplateListScreen(ledgerID: ledgerID, route: $route)
                    case .account(let accountID):
                        AccountTransactionsScreen(accountID: accountID, route: $route, openTransaction: { navigationPath.append(.transaction($0)) })
                    case .currency(let currencyID):
                        CurrencyTransactionsScreen(currencyID: currencyID, route: $route, openTransaction: { navigationPath.append(.transaction($0)) })
                    case .settings:
                        SettingsView(route: $route)
                    case .suggestions:
                        CaptureSuggestionsView()
                    }
                    }
                    // Keep both ends of a push/pop opaque while a register
                    // moves to today's rows and the navigation title changes.
                    .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbar {
                        if let title = syncNavigationTitle(for: destination) {
                            ToolbarItem(placement: .principal) { syncTitle(title) }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { globalBottomBar }
                }
        }
        .onChange(of: navigationPath) { old, new in
            if new.count > old.count {
                if case .journal? = new.last { FinancePerformanceTrace.begin("journal-navigation") }
                if case .transactions? = new.last { FinancePerformanceTrace.begin("register-navigation") }
            } else if old.count > new.count, case .transactions? = old.last, case .journal? = new.last {
                FinancePerformanceTrace.begin("register-back-navigation")
            }
        }
        .tint(.blue)
        #if DEBUG
        .overlay(alignment: .bottom) {
            if CommandLine.arguments.contains("--demo"), CommandLine.arguments.contains("--demo-share-sheet") {
                SharedReceiptShareQA()
            }
        }
        #endif
        .sheet(item: $route, onDismiss: {
            if let id = activeSharedReceiptID { systemEntries.finishSharedReceipt(id); activeSharedReceiptID = nil }
            handleSystemEntry()
        }) { route in
            EditorSheet(route: route)
        }
        .sheet(item: $presentedSheet, onDismiss: finishShellSheet) { sheet in
            switch sheet {
            case .assistant:
                AssistantView()
            case .settings:
                SettingsView(route: $route)
            case .cloudSync:
                MobileCloudSyncSheet()
            case .templates(let ledgerID):
                TemplateManagementSheet(ledgerID: ledgerID)
            case .newTransaction(let ledgerID, let accountID):
                TransactionTemplatePicker(ledgerID: ledgerID, accountID: accountID, selection: $templateSelection)
            case .quickSearch:
                QuickSearchSheet(navigationPath: $navigationPath, presentedSheet: $presentedSheet, route: $route, contextLedgerID: currentLedgerID, contextScope: currentRegisterScope, initialQuery: currentSearchQuery)
            }
        }
        .background {
            LockPresentationShield(store: store, isLocked: store.requiresUnlock)
                .frame(width: 0, height: 0)
        }
        .onChange(of: scenePhase, initial: true) {
            assistant.setForeground(scenePhase == .active, isBackground: scenePhase == .background)
            store.setSceneActive(scenePhase == .active, sceneID: sceneID)
            if scenePhase != .active { store.lockApp() }
            else {
                handleSystemEntry()
                Task {
                    await systemEntries.restoreSharedReceipts(store: store)
                    await systemEntries.reloadSuggestions(store: store)
                }
            }
        }
        .onChange(of: systemEntries.requests.map(\.id)) { handleSystemEntry() }
        .onChange(of: systemEntries.editorRevision) { handleSystemEntry() }
        .onChange(of: store.validationError?.id) { _, id in if id == nil { handleSystemEntry() } }
        .onChange(of: systemEntries.error?.id) { _, id in if id == nil { handleSystemEntry() } }
        .onChange(of: store.isUnlocked) { _, unlocked in
            assistant.lockChanged()
            handleSystemEntry()
            if unlocked { Task { await systemEntries.restoreSharedReceipts(store: store) } }
        }
        .onChange(of: assistant.navigationRequest) { _, request in
            guard let request else { return }
            assistant.navigationRequest = nil
            assistant.dismiss(); presentedSheet = nil
            if let value = request["transaction"].string, let id = UUID(uuidString: value), store.transaction(id) != nil {
                navigationPath.append(.transaction(id))
            } else if let value = request["journal"].string, let id = UUID(uuidString: value), store.ledger(id) != nil {
                if request["view"].string == "overview" { navigationPath.append(.journal(id)) }
                else {
                    let account = request["account"].string.flatMap(UUID.init(uuidString:))
                    let from = request["from_timestamp"].string.flatMap { ISO8601DateFormatter().date(from: $0) }
                    let to = request["to_timestamp"].string.flatMap { ISO8601DateFormatter().date(from: $0) }
                    let interval = (from != nil || to != nil) ? DateInterval(start: from ?? .distantPast, end: to ?? .distantFuture) : nil
                    navigationPath.append(.assistantRegister(scope: account.map(MobileTransactionScope.account) ?? .all, ledgerID: id, query: request["query"].string ?? "", interval: interval))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .financesSuggestionsChanged)) { _ in
            Task { await systemEntries.reloadSuggestions(store: store) }
        }
        .onDisappear { store.setSceneActive(false, sceneID: sceneID) }
        .alert(item: shellValidationError) { error in
            Alert(title: Text("Finances"), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
    }

    private func handleSystemEntry() {
        guard scenePhase == .active, !store.requiresUnlock, !store.requiresJournalRecovery,
              systemEntries.activeEditorCount == 0,
              route == nil, store.validationError == nil, systemEntries.error == nil,
              !systemEntries.requests.isEmpty else { return }
        // Close browsing/settings sheets for an explicit external entry action;
        // actual editors keep their global lease and are never replaced.
        if presentedSheet != nil { presentedSheet = nil; return }
        guard let request = systemEntries.takeNext() else { return }
        switch request.destination {
        case .template(let id):
            let hidden = JournalVisibility(rawValue: MobileDisplayPreferences.defaults.string(forKey: JournalVisibility.preferenceKey) ?? "").hiddenIDs
            guard let template = store.data.transactionTemplates.first(where: { $0.id == id && $0.enabled && !hidden.contains($0.ledgerID) }) else {
                store.validationError = ValidationError(message: "This template is no longer available. Choose another template in Settings.")
                return
            }
            route = .newFromTemplate(template, "New Transaction")
        case .incoming(let incoming):
            activeSharedReceiptID = incoming.sharedReceiptID
            route = .incoming(incoming)
        case .suggestions: navigationPath.append(.suggestions)
        }
    }

    private func finishShellSheet() {
        let selection = templateSelection
        templateSelection = nil
        guard systemEntries.requests.isEmpty else { handleSystemEntry(); return }
        switch selection {
        case .template(let template, let accountID):
            route = .newFromTemplate(template, "New Transaction", accountID: accountID)
        case .customize(let ledgerID):
            presentedSheet = .templates(ledgerID)
        case nil:
            handleSystemEntry()
        }
    }

    @ViewBuilder private var globalBottomBar: some View {
        if showsGlobalBottomBar {
            FinanceBottomBar(
                isJournalActive: isJournalContext,
                openSettings: { presentedSheet = .settings },
                openSearch: { presentedSheet = .quickSearch },
                newTransaction: {
                    guard let ledgerID = currentLedgerID else { return }
                    FinancePerformanceTrace.begin("template-menu")
                    presentedSheet = .newTransaction(ledgerID, accountID: currentAccountID)
                },
                openAssistant: {
                    let context = AssistantContext(journalID: currentLedgerID, accountID: currentAccountID, transactionID: currentTransactionID)
                    do {
                        try assistant.openConversation(context: context)
                        presentedSheet = .assistant
                    } catch {
                        store.validationError = ValidationError(message: "Could not save the previous conversation: \(error.localizedDescription). Its progress has been kept; please try again.")
                    }
                }
            )
        }
    }

    private func syncTitle(_ title: String) -> some View {
        FinanceSyncTitle(title: title) { presentedSheet = .cloudSync }
    }

    private func syncNavigationTitle(for destination: MobileRoute) -> String? {
        switch destination {
        case .journals: "Journals"
        case .journal(let id): store.ledger(id)?.name ?? "Journal"
        case .transactions(_, let title, _): title
        case .searchTransactions(_, _, let query): query.title
        case .assistantRegister(_, _, let query, _): query.isEmpty ? "Transactions" : query
        case .account(let id): store.account(id)?.name ?? "Account"
        case .currency(let id): store.commodity(id)?.name ?? "Currency"
        case .transaction, .templates, .settings, .suggestions: nil
        }
    }

    private var shellValidationError: Binding<ValidationError?> {
        Binding(get: {
            if case .quickSearch? = presentedSheet { return nil }
            return route == nil ? (store.validationError ?? systemEntries.error) : nil
        }, set: { _ in
            store.validationError = nil; systemEntries.error = nil
            Task { @MainActor in handleSystemEntry() }
        })
    }

    private var showsGlobalBottomBar: Bool {
        guard let lastRoute = navigationPath.last else { return true }
        switch lastRoute {
        case .transaction, .settings, .templates, .suggestions:
            return false
        case .journals, .journal, .transactions, .searchTransactions, .assistantRegister, .account, .currency:
            return true
        }
    }

    private var currentLedgerID: UUID? {
        navigationPath.reversed().compactMap { $0.resolvedLedgerID(in: store) }.first
    }

    private var currentAccountID: UUID? {
        if case .account(let id) = currentRegisterScope { return id }
        return nil
    }
    private var currentTransactionID: UUID? {
        if case .transaction(let id) = navigationPath.last { return id }
        return nil
    }

    private var currentRegisterScope: MobileTransactionScope? {
        switch navigationPath.last {
        case .transactions(let scope, _, _), .searchTransactions(let scope, _, _), .assistantRegister(let scope, _, _, _): scope
        case .account(let id): .account(id)
        case .currency(let id): .currency(id)
        default: nil
        }
    }

    private var currentSearchQuery: TransactionSearchQuery? {
        if case .searchTransactions(_, _, let query) = navigationPath.last { return query }
        return nil
    }

    private var isJournalContext: Bool {
        switch navigationPath.last {
        case .journal, .transactions, .searchTransactions, .assistantRegister, .templates, .account, .currency:
            return true
        case .journals, .settings, .transaction, .suggestions, .none:
            return false
        }
    }
}

private enum TemplatePickerSelection {
    case template(TransactionTemplate, accountID: UUID?)
    case customize(UUID)
}

private struct TransactionTemplatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MobileLedgerStore
    @ScaledMetric(relativeTo: .title3) private var rowHeight = 56.0
    @State private var actionsHeight = 0.0
    let ledgerID: UUID
    let accountID: UUID?
    @Binding var selection: TemplatePickerSelection?

    private var templates: [TransactionTemplate] {
        store.transactionTemplates(for: ledgerID).filter(\.enabled)
    }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 0) {
                    Text("You are creating a new transaction.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                    ForEach(templates) { template in
                        Divider()
                        action(template.name) {
                            FinancePerformanceTrace.begin("template-editor")
                            selection = .template(template, accountID: accountID)
                            dismiss()
                        }
                    }
                    Divider()
                    action("Customize Templates…") { selection = .customize(ledgerID); dismiss() }
                }
                .onGeometryChange(for: Double.self) { $0.size.height } action: { actionsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: actionsHeight > 0 ? actionsHeight : nil)

            action("Cancel", role: .cancel) { dismiss() }
                .fontWeight(.semibold)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transaction-template-picker")
        .presentationDetents([.height((actionsHeight > 0 ? actionsHeight : Double(templates.count + 1) * rowHeight + 50) + rowHeight + 16)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(24)
        .presentationBackground(Color(.sRGB, red: 240 / 255, green: 240 / 255, blue: 241 / 255, opacity: 1))
        .performanceDestination("template-menu")
    }

    private func action(_ title: String, role: ButtonRole? = nil, perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            Text(title)
                .font(.title3)
                .foregroundStyle(.blue)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransactionRowButtonStyle())
    }
}

/// A scene-local window covers UIKit presentations too, without destroying editor state.
private struct LockPresentationShield: UIViewRepresentable {
    let store: MobileLedgerStore
    let isLocked: Bool

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }
    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.attach(to: view.window)
        context.coordinator.update(isLocked: isLocked)
    }
    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.hide()
    }

    final class AnchorView: UIView {
        var windowChanged: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged?(window)
        }
    }

    @MainActor final class Coordinator {
        let store: MobileLedgerStore
        weak var originalWindow: UIWindow?
        private var shieldWindow: UIWindow?
        private var previousInteractionEnabled = true
        private var previousAccessibilityHidden = false

        init(store: MobileLedgerStore) { self.store = store }
        func attach(to window: UIWindow?) {
            guard let window, window !== shieldWindow else { return }
            if originalWindow !== window {
                hide()
                originalWindow = window
            }
            update(isLocked: store.requiresUnlock)
        }
        func update(isLocked: Bool) {
            guard isLocked else { hide(); return }
            guard shieldWindow == nil, let originalWindow, let scene = originalWindow.windowScene else { return }
            originalWindow.endEditing(true)
            previousInteractionEnabled = originalWindow.isUserInteractionEnabled
            previousAccessibilityHidden = originalWindow.accessibilityElementsHidden
            originalWindow.isUserInteractionEnabled = false
            originalWindow.accessibilityElementsHidden = true
            let window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            window.overrideUserInterfaceStyle = originalWindow.traitCollection.userInterfaceStyle
            let controller = UIHostingController(rootView: LockedAppView().environmentObject(store))
            controller.view.accessibilityViewIsModal = true
            window.rootViewController = controller
            shieldWindow = window
            window.makeKeyAndVisible()
        }
        func hide() {
            guard let window = shieldWindow else { return }
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            shieldWindow = nil
            originalWindow?.isUserInteractionEnabled = previousInteractionEnabled
            originalWindow?.accessibilityElementsHidden = previousAccessibilityHidden
            originalWindow?.makeKey()
        }
    }
}

private struct LockedAppView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @State private var password = ""
    @State private var passwordError: String?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .systemGroupedBackground))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(spacing: 6) {
                    Text("Finances")
                        .font(.title.weight(.bold))
                    Text("Password Required")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(unlock)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: 260)

                if let passwordError {
                    Text(passwordError).font(.footnote).foregroundStyle(.red)
                }
                Button("Unlock") {
                    unlock()
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
            }
            .padding(24)
            .frame(maxWidth: 320)
        }
    }

    private func unlock() {
        store.unlock(password: password)
        if !store.requiresUnlock {
            password = ""
            passwordError = nil
        } else { passwordError = "Password is incorrect." }
    }
}


struct EditorSheet: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let route: EditorRoute
    @StateObject private var receiptImports = ReceiptImportSession()
    @State private var editorPresentationID = UUID()
    var body: some View {
        Group {
        switch route {
        case .transaction(let draft, let title, let scanInvoice):
            NavigationStack { TransactionEditorView(title: title, initialDraft: draft, scanInvoice: scanInvoice) }
        case .newFromTemplate(let template, let title, let accountID):
            let draft = store.draft(for: template, accountID: accountID)
            TemplateTransactionEntryView(title: title, initialDraft: draft,
                accountPostingIDs: store.templateAccountSelectionPostingIDs(in: draft).filter { id in
                    // An explicitly viewed category is already chosen, even when it has children.
                    accountID == nil || draft.postings.first(where: { $0.id == id })?.accountID != accountID
                }, scanInvoice: template.scanInvoice)
        case .incoming(let request): IncomingTransactionView(request: request)
        case .account(let draft): AccountEditorView(initialDraft: draft)
        case .currency(let draft): CurrencyEditorView(initialDraft: draft)
        case .journalNew: JournalEditorView(mode: .create)
        case .journalRename(let ledger): JournalEditorView(mode: .rename(ledger))
        case .template(let draft): TemplateEditorView(initialDraft: draft)
        }
        }
        .environmentObject(receiptImports)
        .environment(\.receiptImportSession, receiptImports)
        .background { ReceiptImportLifetimeAnchor(session: receiptImports).frame(width: 0, height: 0) }
        .background { SystemEntryEditorLifetimeAnchor(id: editorPresentationID).frame(width: 0, height: 0) }
        .onAppear {
            receiptImports.configureDiscard { [weak store] assets in store?.discardUnreferencedImportedAttachments(assets) }
        }
    }
}
