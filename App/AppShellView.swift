import SwiftUI
import UIKit

enum EditorRoute: Identifiable {
    case transaction(TransactionDraft, String, scanInvoice: Bool = false)
    case account(MobileAccountDraft)
    case currency(CurrencyDraft)
    case journalNew
    case journalRename(Ledger)
    case template(TransactionTemplateDraft)

    var id: String {
        switch self {
        case .transaction(let draft, let title, let scanInvoice):
            "transaction-\(draft.id?.uuidString ?? "new")-\(title)-\(scanInvoice)"
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
    @State private var sceneID = UUID()
    @State private var route: EditorRoute?
    @State private var navigationPath: [MobileRoute] = []
    @State private var presentedSheet: ShellSheet?
    @State private var showingNewTransactionDialog = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            JournalsHomeScreen(navigationPath: $navigationPath, route: $route)
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
                    }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { globalBottomBar }
                }
        }
        .tint(.blue)
        .sheet(item: $route) { route in
            EditorSheet(route: route)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView(route: $route)
            case .cloudSync:
                MobileCloudSyncSheet()
            case .templates(let ledgerID):
                TemplateManagementSheet(ledgerID: ledgerID)
            case .quickSearch:
                QuickSearchSheet(navigationPath: $navigationPath, presentedSheet: $presentedSheet, route: $route, contextLedgerID: currentLedgerID)
            }
        }
        .overlay {
            ZStack {
                if store.requiresUnlock {
                    LockedAppView()
                        .transition(.opacity)
                        .zIndex(20)
                }
            }
        }
        .confirmationDialog("New Transaction", isPresented: $showingNewTransactionDialog, titleVisibility: .visible) {
            ForEach(MobileNewTransactionKind.allCases) { kind in
                Button(kind.rawValue) { route = .transaction(store.makeTransactionDraft(kind: kind, ledgerID: currentLedgerID, accountID: currentAccountID), "New Transaction") }
            }
            ForEach((currentLedgerID.map { store.transactionTemplates(for: $0) } ?? []).filter(\.enabled)) { template in
                Button(template.name) { route = .transaction(store.draft(for: template), "New Transaction", scanInvoice: template.scanInvoice) }
            }
            if let ledgerID = currentLedgerID {
                Button("Customize Templates…") { presentedSheet = .templates(ledgerID) }
            }
        }
        .onChange(of: scenePhase, initial: true) {
            store.setSceneActive(scenePhase == .active, sceneID: sceneID)
            if scenePhase != .active { store.lockApp() }
        }
        .onDisappear { store.setSceneActive(false, sceneID: sceneID) }
        .alert(item: Binding(
            get: { route == nil ? store.validationError : nil },
            set: { _ in store.validationError = nil }
        )) { error in
            Alert(title: Text("Finances"), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder private var globalBottomBar: some View {
        if showsGlobalBottomBar {
            FinanceBottomBar(
                isJournalActive: isJournalContext,
                openSettings: { presentedSheet = .settings },
                openSearch: { presentedSheet = .quickSearch },
                openCloudSync: { presentedSheet = .cloudSync },
                newTransaction: { showingNewTransactionDialog = true }
            )
        }
    }

    private var showsGlobalBottomBar: Bool {
        guard let lastRoute = navigationPath.last else { return true }
        switch lastRoute {
        case .transaction, .settings, .templates:
            return false
        case .journals, .journal, .transactions, .account, .currency:
            return true
        }
    }

    private var currentLedgerID: UUID? {
        navigationPath.reversed().compactMap { $0.resolvedLedgerID(in: store) }.first
    }

    private var currentAccountID: UUID? {
        if case .account(let id) = navigationPath.last { return id }
        return nil
    }

    private var isJournalContext: Bool {
        switch navigationPath.last {
        case .journal, .transactions, .templates, .account, .currency:
            return true
        case .journals, .settings, .transaction, .none:
            return false
        }
    }
}

private struct LockedAppView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @State private var password = ""

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
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
        }
    }
}


struct EditorSheet: View {
    let route: EditorRoute
    var body: some View {
        switch route {
        case .transaction(let draft, let title, let scanInvoice): TransactionEditorView(title: title, initialDraft: draft, scanInvoice: scanInvoice)
        case .account(let draft): AccountEditorView(initialDraft: draft)
        case .currency(let draft): CurrencyEditorView(initialDraft: draft)
        case .journalNew: JournalEditorView(mode: .create)
        case .journalRename(let ledger): JournalEditorView(mode: .rename(ledger))
        case .template(let draft): TemplateEditorView(initialDraft: draft)
        }
    }
}
