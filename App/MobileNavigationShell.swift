import SwiftUI
import UIKit

enum MobileRoute: Hashable {
    case journals
    case journal(UUID)
    case transactions(scope: MobileTransactionScope, title: String, ledgerID: UUID)
    case searchTransactions(scope: MobileTransactionScope, ledgerID: UUID, query: TransactionSearchQuery)
    case transaction(UUID)
    case templates(UUID)
    case account(UUID)
    case currency(UUID)
    case settings
    @MainActor func resolvedLedgerID(in store: MobileLedgerStore) -> UUID? {
        switch self {
        case .journal(let id), .templates(let id): id
        case .transactions(_, _, let id), .searchTransactions(_, let id, _): id
        case .account(let id): store.account(id)?.ledgerID
        case .currency(let id): store.commodity(id)?.ledgerID
        case .transaction(let id): store.transaction(id)?.ledgerID
        case .journals, .settings: nil
        }
    }

}

enum ShellSheet: Identifiable {
    case settings
    case cloudSync
    case quickSearch
    case templates(UUID)

    var id: String {
        switch self {
        case .settings: "settings"
        case .cloudSync: "cloud-sync"
        case .quickSearch: "quick-search"
        case .templates(let id): "templates-\(id.uuidString)"
        }
    }
}

struct JournalsHomeScreen: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @State private var journalEditMode: EditMode = .inactive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var navigationPath: [MobileRoute]
    @Binding var route: EditorRoute?
    @State private var pendingDelete: Ledger?
    @State private var showingHiddenJournals = false
    @AppStorage(JournalVisibility.preferenceKey, store: MobileDisplayPreferences.defaults) private var hiddenJournalIDs = ""
    private var visibility: JournalVisibility { JournalVisibility(rawValue: hiddenJournalIDs) }
    private var visibleJournals: [Ledger] { visibility.visible(in: store.orderedLedgers) }

    private func hide(_ journal: Ledger) {
        var updated = visibility
        updated.setHidden(true, id: journal.id)
        withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) { hiddenJournalIDs = updated.rawValue }
    }

    var body: some View {
        List {
            Section {
                ForEach(visibleJournals) { ledger in
                    HStack(spacing: 8) {
                        if journalEditMode.isEditing {
                            Button { pendingDelete = ledger } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 22)).foregroundStyle(.red)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(ledger.name)")
                        }
                        NavigationLink(value: MobileRoute.journal(ledger.id)) {
                            HStack(spacing: 14) {
                                Image(systemName: "folder").font(.title2).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(ledger.name)
                                    Text("\(store.transactions(scope: .all, ledgerID: ledger.id).count.formatted()) Transactions")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                let count = store.unclearedTransactionCount(ledgerID: ledger.id)
                                if count > 0 { Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit() }
                            }
                            .padding(.vertical, 2)
                        }
                        .disabled(journalEditMode.isEditing)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .contextMenu {
                        Button("Hide Journal", systemImage: "archivebox") { hide(ledger) }
                        Button("Rename", systemImage: "pencil") { route = .journalRename(ledger) }
                        Button("Delete Journal", systemImage: "trash", role: .destructive) { pendingDelete = ledger }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button("Hide", systemImage: "archivebox") { hide(ledger) }.tint(.gray)
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Delete") { pendingDelete = ledger }.tint(.red)
                        Button("Rename") { route = .journalRename(ledger) }.tint(.blue)
                    }
                }
                .onMove { offsets, destination in
                    store.moveJournals(from: offsets, to: destination, excluding: visibility.hiddenIDs)
                }
            }
        }
        .listStyle(.insetGrouped)
        .compactGroupedForm()
        .environment(\.editMode, $journalEditMode)
        .animation(FinanceMotion.disclosure(reduceMotion: reduceMotion), value: hiddenJournalIDs)
        .contentMargins(.top, 16, for: .scrollContent)
        .overlay {
            if visibleJournals.isEmpty {
                ContentUnavailableView {
                    Label("Your Journals", systemImage: "folder")
                } description: {
                    Text(store.orderedLedgers.isEmpty
                         ? "Create a journal to get started, or turn on iCloud Sync to bring your journals from your Mac."
                         : "Your journals are hidden. Restore them from Hidden Journals in Settings.")
                } actions: {
                    if !store.orderedLedgers.isEmpty {
                        Button("Hidden Journals") { showingHiddenJournals = true }.buttonStyle(.borderedProminent)
                    } else {
                        Button("New Journal") { route = .journalNew }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .sheet(isPresented: $showingHiddenJournals) {
            NavigationStack {
                HiddenJournalsView()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingHiddenJournals = false } } }
            }
        }
        .navigationTitle("Journals")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("New Journal", systemImage: "plus") { route = .journalNew }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton().environment(\.editMode, $journalEditMode) }
        }
        .confirmationDialog("Delete Journal?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { ledger in
            Button("Delete \(ledger.name)", role: .destructive) { store.deleteJournal(ledger.id) }
        } message: { _ in Text("This deletes the journal, its accounts, transactions, and receipts on all synced devices.") }
    }
}

struct JournalOverviewScreen: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.editMode) private var editMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ledgerID: UUID
    @Binding var navigationPath: [MobileRoute]
    @Binding var route: EditorRoute?
    @AppStorage private var expandedKindIDs: String
    @AppStorage private var collapsedAccountIDs: String
    @State private var pendingAccountDelete: Account?

    init(ledgerID: UUID, navigationPath: Binding<[MobileRoute]>, route: Binding<EditorRoute?>) {
        self.ledgerID = ledgerID
        _navigationPath = navigationPath
        _route = route
        _expandedKindIDs = AppStorage(wrappedValue: "", "display.journal.\(ledgerID).expandedKinds", store: MobileDisplayPreferences.defaults)
        _collapsedAccountIDs = AppStorage(wrappedValue: "", "display.journal.\(ledgerID).collapsedAccounts", store: MobileDisplayPreferences.defaults)
    }

    private var expandedKinds: Set<AccountKind> {
        Set(expandedKindIDs.split(separator: ",").compactMap { Int($0).flatMap(AccountKind.init(rawValue:)) })
    }

    private var collapsedAccounts: Set<UUID> {
        Set(collapsedAccountIDs.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func toggleKind(_ kind: AccountKind) {
        var expanded = expandedKinds
        if !expanded.insert(kind).inserted { expanded.remove(kind) }
        expandedKindIDs = expanded.map { String($0.rawValue) }.sorted().joined(separator: ",")
    }

    private func toggleAccount(_ id: UUID) {
        var collapsed = collapsedAccounts
        if !collapsed.insert(id).inserted { collapsed.remove(id) }
        collapsedAccountIDs = collapsed.map(\.uuidString).sorted().joined(separator: ",")
    }

    var body: some View {
        List {
            TransactionLinksSection(ledgerID: ledgerID) { navigationPath.append(.templates(ledgerID)) }
            Section {
                ForEach(AccountKind.allCases) { kind in
                    Button { withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) { toggleKind(kind) } } label: {
                        HStack {
                            Text(groupTitle(kind)).fontWeight(.semibold)
                                .accessibilityIdentifier("account-kind-title-\(kind.rawValue)")
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing) {
                                ForEach((kind == .income || kind == .expense) ? [] : (store.ledgerTotalsByKind(ledgerID: ledgerID)[kind] ?? [])) { row in
                                    Text(moneyString(row.amount, symbol: row.symbol)).foregroundStyle(.secondary).monospacedDigit().font(.subheadline)
                                }
                            }
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(expandedKinds.contains(kind) ? 180 : 0))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.primary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .accessibilityValue(expandedKinds.contains(kind) ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows or hides accounts in this category")

                    // Category headings and first-level accounts share an inset.
                    // Only the account's actual hierarchy depth adds indentation.
                    if expandedKinds.contains(kind) {
                        ForEach(visibleNodes(kind)) { node in
                            HStack(spacing: 8) {
                                NavigationLink(value: MobileRoute.account(node.id)) {
                                    MobileAccountListRow(node: node, balances: store.balanceRows(for: node.id))
                                        .equatable()
                                }
                                if editMode?.wrappedValue.isEditing == true {
                                    Button("Edit \(node.account.name)", systemImage: "info.circle") { route = .account(store.draft(for: node.account)) }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                            }
                            .transition(.opacity)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .contextMenu {
                                if node.hasChildren {
                                    Button(collapsedAccounts.contains(node.id) ? "Expand Subaccounts" : "Collapse Subaccounts") {
                                        withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) { toggleAccount(node.id) }
                                    }
                                }

                                Button("Edit Account", systemImage: "pencil") { route = .account(store.draft(for: node.account)) }
                                Button("Delete Account", systemImage: "trash", role: .destructive) { pendingAccountDelete = node.account }
                            }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Delete") { pendingAccountDelete = node.account }.tint(.red)
                                Button("Edit") { route = .account(store.draft(for: node.account)) }.tint(.blue)
                            }
                        }
                        .onMove { offsets, destination in
                            let nodes = visibleNodes(kind)
                            guard let index = offsets.first, offsets.count == 1, destination != index, destination != index + 1 else { return }
                            let targetIndex = destination > index ? destination - 1 : destination
                            guard nodes.indices.contains(targetIndex) else { return }
                            store.moveAccount(nodes[index].id, relativeTo: nodes[targetIndex].id, placement: destination > index ? .after : .before)
                        }
                    }
                }
            } header: {
                SectionActionHeader(title: "Accounts") { route = .account(store.newAccountDraft(ledgerID: ledgerID)) }
            }
            Section {
                ForEach(store.commodities(for: ledgerID)) { currency in
                    NavigationLink(value: MobileRoute.currency(currency.id)) {
                        HStack {
                            Text(currency.name)
                            Spacer()
                            Text(currency.symbol).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Edit Currency", systemImage: "pencil") { route = .currency(store.draft(for: currency)) }
                        Button("Delete Currency", systemImage: "trash", role: .destructive) { store.deleteCurrency(currency.id) }
                    }
                }
            } header: {
                SectionActionHeader(title: "Currencies") { route = .currency(store.newCurrencyDraft(ledgerID: ledgerID)) }
            }
        }
        .listStyle(.insetGrouped)
        // AppStorage may publish outside the button's animation transaction.
        // Scope the list animation to the persisted disclosure values too.
        .animation(FinanceMotion.disclosure(reduceMotion: reduceMotion), value: expandedKindIDs)
        .animation(FinanceMotion.disclosure(reduceMotion: reduceMotion), value: collapsedAccountIDs)
        .compactGroupedForm()
        .safeAreaPadding(.top, 24)
        .navigationTitle(store.ledger(ledgerID)?.name ?? "Journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .onAppear { store.selectLedger(ledgerID) }
        .confirmationDialog("Delete Account?", isPresented: Binding(get: { pendingAccountDelete != nil }, set: { if !$0 { pendingAccountDelete = nil } }), presenting: pendingAccountDelete) { account in
            Button("Delete \(account.name)", role: .destructive) { store.deleteAccount(account.id) }
        } message: { _ in Text("Accounts that have transactions cannot be deleted.") }
    }

    private func groupTitle(_ kind: AccountKind) -> String {
        let roots = store.accounts(for: ledgerID).filter { $0.kind == kind && $0.parentID == nil }
        return roots.count == 1 ? roots[0].name : kind.title
    }

    private func visibleNodes(_ kind: AccountKind) -> [MobileAccountNode] {
        let nodes = store.accountNodes(kind: kind, ledgerID: ledgerID)
        let collapsed = collapsedAccounts
        let roots = nodes.filter { $0.account.parentID == nil }
        return nodes.filter { node in
            if roots.count == 1 && node.account.parentID == nil { return false }
            var parent = node.account.parentID
            var visited = Set<UUID>()
            while let id = parent, visited.insert(id).inserted {
                if collapsed.contains(id) { return false }
                parent = store.account(id)?.parentID
            }
            return true
        }.map { node in
            var adjusted = node
            adjusted.depth = max(0, node.depth - (roots.count == 1 ? 1 : 0))
            return adjusted
        }
    }
}

private struct TransactionLinksSection: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let ledgerID: UUID
    var showTemplates: () -> Void

    var body: some View {
        Section {
            NavigationLink(value: MobileRoute.transactions(scope: .all, title: "All", ledgerID: ledgerID)) {
                Label("All", systemImage: "arrow.right")
            }
            NavigationLink(value: MobileRoute.transactions(scope: .uncleared, title: "Uncleared", ledgerID: ledgerID)) {
                HStack {
                    Label("Uncleared", systemImage: "circle")
                    Spacer()
                    let count = store.unclearedTransactionCount(ledgerID: ledgerID)
                    if count > 0 {
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            NavigationLink(value: MobileRoute.transactions(scope: .repeating, title: "Repeating", ledgerID: ledgerID)) {
                Label("Repeating", systemImage: "arrow.2.squarepath")
            }
        } header: {
            SectionActionHeader(title: "Transactions", actionTitle: "Templates", addAction: showTemplates)
        }
    }
}

private struct SectionActionHeader: View {
    var title: String
    var actionTitle: String? = nil
    var addAction: () -> Void
    @State private var showingActions = false

    var body: some View {
        HStack {
            Text(title.uppercased())
            Spacer()
            Button { showingActions = true } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.tint)
            }
            .textCase(nil)
            .accessibilityLabel("\(title) actions")
            .accessibilityIdentifier("section-action-\(title)")
            .buttonStyle(.plain)
            .confirmationDialog(title, isPresented: $showingActions, titleVisibility: .hidden) {
                Button(actionTitle ?? (title == "Accounts" ? "New Account" : "New Currency"), action: addAction)
            }
        }.textCase(nil)
    }
}

struct TransactionListScreen: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: MobileTransactionScope
    let title: String
    @Binding var route: EditorRoute?
    var dateInterval: DateInterval? = nil
    var transactionIDs: Set<UUID>? = nil
    var ledgerID: UUID? = nil
    var searchFilter: TransactionSearchQuery? = nil
    let openTransaction: (UUID) -> Void
    @State private var pendingDeletion: LedgerTransaction?
    @AppStorage(TransactionSearchDatePolicy.preferenceKey, store: MobileDisplayPreferences.defaults) private var includeAllFutureEntries = false
    @State private var pendingDuplication: LedgerTransaction?
    @AppStorage("display.showsTransactionChart", store: MobileDisplayPreferences.defaults) private var showsChart = false
    @State private var selectedMonth: Date?
    @State private var presentation = RegisterPresentation(months: [], amounts: [:], balances: [:])
    @State private var renderRequest: RegisterRenderRequest?
    @State private var renderKey: RegisterPresentationCacheKey?
    @State private var appliedRenderKey: RegisterPresentationCacheKey?
    @State private var renderID = UUID()
    @State private var isActive = false
    @State private var hasLoaded = false
    @State private var contentReady = false
    @State private var initialDay: Date?
    @State private var initialScrollRequested = false
    @State private var loadingVisible = false
    @State private var loadError: String?

    private enum ScrollTarget: Hashable { case day(Date), transaction(UUID) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(presentation.months) { month in monthSection(month) }
            }
            .listStyle(.plain)
            .opacity(contentReady ? 1 : 0)
            .allowsHitTesting(contentReady)
            .accessibilityHidden(!contentReady)
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsChart && dateInterval == nil {
                    RegisterChart(months: presentation.months, ledgerID: ledgerID ?? store.selectedLedgerID, isLoading: !hasLoaded)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color(uiColor: .systemBackground))
                        .overlay(alignment: .bottom) { Divider() }
                        .transition(.opacity)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("register-chart-panel")
                }
            }
            .animation(FinanceMotion.disclosure(reduceMotion: reduceMotion), value: showsChart)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 0)
            .overlay {
                if let loadError {
                    ContentUnavailableView("Couldn’t Load Transactions", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else if !contentReady && loadingVisible && !(showsChart && dateInterval == nil) {
                    ProgressView("Loading Transactions").accessibilityIdentifier("register-loading")
                } else if hasLoaded && presentation.months.isEmpty {
                    ContentUnavailableView(searchFilter == nil ? "No Transactions" : "No Results", systemImage: searchFilter == nil ? "arrow.left.arrow.right" : "magnifyingglass", description: Text(searchFilter.map { $0.suggestion } ?? "Use the compose button to add your first transaction."))
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if searchFilter != nil {
                        Button {
                            includeAllFutureEntries.toggle()
                        } label: {
                            Image(systemName: includeAllFutureEntries ? "calendar.badge.checkmark" : "calendar.badge.clock")
                        }
                        .accessibilityLabel(includeAllFutureEntries ? "Limit Future Entries" : "Show All Future Entries")
                        .accessibilityIdentifier("search-future-toggle")
                        .accessibilityValue(includeAllFutureEntries ? "All dates" : "Recent entries")
                    }
                    if dateInterval == nil {
                        Button(showsChart ? "Hide Chart" : "Show Chart", systemImage: showsChart ? "chart.bar.fill" : "chart.bar") {
                            withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) { showsChart.toggle() }
                        }
                        .accessibilityIdentifier("toggle-transaction-chart")
                        .accessibilityValue(showsChart ? "Shown" : "Hidden")
                    }
                }
            }
            .sheet(isPresented: Binding(get: { selectedMonth != nil }, set: { if !$0 { selectedMonth = nil } })) {
                if let month = selectedMonth {
                    MonthSummaryView(month: month, scope: scope, ledgerID: ledgerID, transactionIDs: searchFilter == nil ? nil : Set(presentation.months.first { $0.date == month }?.days.flatMap(\.transactions).map(\.id) ?? []))
                }
            }
            .modifier(TransactionDeletionConfirmation(transaction: $pendingDeletion))
            .modifier(TransactionDuplicateConfirmation(transaction: $pendingDuplication))
            .onAppear { isActive = true; scheduleRefresh() }
            .onDisappear { isActive = false; renderRequest = nil }
            .onReceive(store.$registerContentRevision.debounce(for: .milliseconds(40), scheduler: RunLoop.main)) { _ in scheduleRefresh() }
            .task(id: renderID) { [renderID, renderRequest, renderKey] in await renderCurrentRequest(renderRequest, key: renderKey, id: renderID) }
            .onChange(of: includeAllFutureEntries) { if searchFilter != nil { scheduleRefresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in scheduleRefresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in scheduleRefresh() }
            .task(id: contentReady) {
                guard !contentReady else { loadingVisible = false; return }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                if !contentReady { loadingVisible = true }
            }
            .task(id: initialDay) {
                guard let day = initialDay, !contentReady, isActive else { return }
                let firstRow = presentation.months.lazy.flatMap(\.days).first { $0.date == day }?.transactions.first?.id
                // Retry after lazy row measurements settle. The alternate row
                // anchor handles headers whose estimated offset is inaccurate.
                for attempt in 0..<3 {
                    await Task.yield()
                    guard !Task.isCancelled, isActive, !contentReady else { return }
                    var update = Transaction(animation: nil); update.disablesAnimations = true
                    withTransaction(update) {
                        if attempt == 1, let firstRow {
                            proxy.scrollTo(ScrollTarget.transaction(firstRow), anchor: .center)
                        } else {
                            proxy.scrollTo(ScrollTarget.day(day), anchor: .top)
                        }
                        initialScrollRequested = true
                    }
                    do { try await Task.sleep(for: .milliseconds(attempt == 0 ? 120 : 220)) } catch { return }
                }
                // Navigation and scrolling must never remain disabled forever
                // if UIKit does not report the expected viewport callback.
                guard !Task.isCancelled, isActive, !contentReady else { return }
                contentReady = true
            }
        }
    }

    private func monthSection(_ month: RegisterMonth) -> some View {
        Section {
            monthHeading(month)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 10, trailing: 20))
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("month-heading")
            ForEach(month.days) { day in
                Text(registerDayTitle(day.date))
                    .id(ScrollTarget.day(day.date))
                    .font(.subheadline.weight(.bold)).foregroundColor(Color(uiColor: .label))
                    .padding(.top, 14).padding(.bottom, 10)
                    .background {
                        if initialDay == day.date && !contentReady {
                            RegisterInitialPositionProbe(armed: initialScrollRequested) {
                                guard initialDay == day.date, !contentReady else { return }
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { contentReady = true }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)
                ForEach(day.transactions) { transaction in
                    Button {
                        openTransaction(transaction.id)
                    } label: {
                        RegisterRow(transaction: transaction, amounts: presentation.amounts[transaction.id] ?? [], balances: presentation.balances[transaction.id] ?? [], flow: store.accountFlowDisplay(for: transaction), isFuture: RegisterPresentation.isFuture(transaction.date))
                            .equatable()
                            .padding(EdgeInsets(top: 8, leading: 28, bottom: 8, trailing: 20))
                    }
                    .buttonStyle(TransactionRowButtonStyle())
                    .id(ScrollTarget.transaction(transaction.id))
                    .accessibilityIdentifier("register-row-\(transaction.id.uuidString)")
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // Destructive swipe roles remove the cell optimistically.
                        // Confirmation and async register updates must own the deletion,
                        // or UIKit can abort with an invalid section item count.
                        Button("Delete") { requestDeletion(transaction) }.tint(.red)
                        Button("Duplicate") { pendingDuplication = transaction }.tint(.gray)
                    }
                    .swipeActions(edge: .leading) {
                        Button(transaction.cleared ? "Uncleared" : "Cleared") {
                            store.setTransactionCleared(transaction.id, cleared: !transaction.cleared)
                        }.tint(.blue)
                    }
                }
            }
        }.listSectionSeparator(.hidden)
    }

    private func monthHeading(_ month: RegisterMonth) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(month.date.formatted(.dateTime.month(.wide))).font(.title.bold()).foregroundStyle(Color(uiColor: .label))
                    .accessibilityIdentifier("month-title")
                Text(month.date.formatted(.dateTime.year())).font(.title3).foregroundStyle(.secondary)
                Spacer()
                Button("Monthly Summary", systemImage: "ellipsis") { selectedMonth = month.date }.labelStyle(.iconOnly)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(month.income) { value in summaryPill("INCOME", value: value, color: .green, month: month.date) }
                    ForEach(month.expenses) { value in summaryPill("EXPENSES", value: value, color: .red, month: month.date) }
                }
            }
        }
    }

    private func requestDeletion(_ row: LedgerTransaction) {
        if let rule = row.recurrenceRule, rule.frequency != .never { pendingDeletion = row }
        else { store.deleteTransaction(row.id, scope: .occurrence) }
    }

    private func registerDayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "TODAY" }
        if Calendar.current.isDateInYesterday(date) { return "YESTERDAY" }
        return (store.data.dateFormat == .iso ? dateString(date, format: .iso) : date.formatted(.dateTime.month(.wide).day().year())).uppercased()
    }

    private func scheduleRefresh() {
        guard isActive else { return }
        var request = RegisterRenderRequest(data: store.data, rows: store.registerSourceRows(ledgerID: ledgerID), scope: scope, search: searchFilter?.text ?? "", dateInterval: dateInterval, transactionIDs: transactionIDs, searchField: searchFilter?.field ?? .anywhere, filtersScope: true)
        if searchFilter != nil {
            request.searchDatePolicy = TransactionSearchDatePolicy(includeAllFuture: includeAllFutureEntries, now: request.referenceDate, calendar: request.calendar)
        }
        let key = RegisterPresentationCacheKey(revision: store.registerContentRevision, ledgerID: ledgerID ?? store.selectedLedgerID, request: request)
        if appliedRenderKey == key, hasLoaded {
            // Returning to the already displayed query must also detach a
            // different pending query, so a late result cannot replace it.
            if renderKey != key {
                renderKey = key
                renderRequest = nil
                renderID = UUID()
            }
            loadError = nil
            return
        }
        if renderKey == key, renderRequest != nil { return }
        renderKey = key
        renderID = UUID()
        if let cached = store.registerPresentations.cached(for: key) {
            renderRequest = nil
            applyRenderResult(cached, key: key)
        } else {
            renderRequest = request
        }
    }

    private func renderCurrentRequest(_ snapshot: RegisterRenderRequest?, key: RegisterPresentationCacheKey?, id: UUID) async {
        guard let request = snapshot, let key, isActive, id == renderID, !Task.isCancelled else { return }
        do {
            let result = try await store.registerPresentations.load(request, key: key)
            guard !Task.isCancelled, isActive, id == renderID,
                  key.revision == store.registerContentRevision else { return }
            applyRenderResult(result, key: key)
        } catch is CancellationError { return }
        catch {
            guard id == renderID else { return }
            loadError = error.localizedDescription
            hasLoaded = true; contentReady = true
        }
    }

    private func applyRenderResult(_ result: RegisterRenderResult, key: RegisterPresentationCacheKey) {
        var update = Transaction(animation: nil); update.disablesAnimations = true
        withTransaction(update) {
            presentation = result.presentation
            appliedRenderKey = key
            hasLoaded = true
            loadError = nil
            if !contentReady {
                initialScrollRequested = false
                initialDay = dateInterval == nil ? presentation.initialDay() : nil
                if initialDay == nil { contentReady = true }
            }
        }
    }

    private func summaryPill(_ label: String, value: RegisterMoney, color: Color, month: Date) -> some View {
        Button { selectedMonth = month } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2.weight(.semibold))
                Text(moneyString(value.amount, symbol: value.symbol)).font(.headline).monospacedDigit()
            }.foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9).background(color.gradient, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}

struct RegisterRow: View, Equatable {
    let transaction: LedgerTransaction
    let amounts: [RegisterMoney]
    let balances: [RegisterMoney]
    let flow: MobileAccountFlowDisplay
    let isFuture: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                (Text(transaction.note.isEmpty ? (transaction.payee.isEmpty ? "Transaction" : transaction.payee) : transaction.note) + Text(!transaction.note.isEmpty && !transaction.payee.isEmpty ? " @\(transaction.payee)" : "").foregroundColor(.secondary))
                    .lineLimit(1)
                    .accessibilityIdentifier("transaction-title")
                HStack(spacing: 4) {
                    AccountFlowText(display: flow)
                    if transaction.recurrenceRule != nil { Image(systemName: "arrow.2.squarepath").font(.caption2) }
                }.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(amounts) { value in Text(moneyString(value.amount, symbol: value.symbol)).foregroundStyle(value.amount < 0 ? .red : .primary).monospacedDigit() }
                ForEach(balances) { value in Text(moneyString(value.amount, symbol: value.symbol)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
            }.lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            TransactionGutter(cleared: transaction.cleared, hasAttachment: transaction.attachment?.assets.isEmpty == false)
        }
        .accessibilityValue(transaction.cleared ? "Cleared" : "Uncleared")
        .opacity(isFuture ? 0.48 : 1)
        .accessibilityElement(children: .combine)
    }
}

struct TemplateListScreen: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ledgerID: UUID
    @Binding var route: EditorRoute?

    private var templates: [TransactionTemplate] { store.transactionTemplates(for: ledgerID) }
    private var included: [TransactionTemplate] { templates.filter(\.enabled) }
    private var excluded: [TransactionTemplate] { templates.filter { !$0.enabled } }

    var body: some View {
        List {
            if templates.isEmpty {
                ContentUnavailableView("No Templates", systemImage: "doc.text", description: Text("Create reusable transaction templates for this journal."))
            }
            if !included.isEmpty {
                Section("Include") {
                    ForEach(included) { template in
                        templateRow(template, included: true)
                    }
                    .onMove { offsets, destination in
                        let sourceIDs = Set(offsets.map { included[$0].id })
                        let all = templates
                        let source = IndexSet(all.indices.filter { sourceIDs.contains(all[$0].id) })
                        let target = destination < included.count ? all.firstIndex { $0.id == included[destination].id } ?? all.count : all.count
                        store.moveTransactionTemplates(ledgerID: ledgerID, from: source, to: target)
                    }
                }
            }
            if !excluded.isEmpty {
                Section("More Templates") {
                    ForEach(excluded) { template in
                        templateRow(template, included: false)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .compactGroupedForm()
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.selectLedger(ledgerID)
                    route = .template(store.templateDraft(for: nil))
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("New Template")
            }
        }
    }

    private func templateRow(_ template: TransactionTemplate, included: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) { store.setTransactionTemplateIncluded(template.id, included: !included) }
            } label: {
                Image(systemName: included ? "minus.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(included ? Color.red : Color.green)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(included ? "Exclude" : "Include") \(template.name)")
            Button { route = .template(store.templateDraft(for: template)) } label: {
                Text(template.name).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Edit template \(template.name)")
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}

struct TemplateManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    let ledgerID: UUID
    @State private var route: EditorRoute?
    var body: some View {
        NavigationStack {
            TemplateListScreen(ledgerID: ledgerID, route: $route)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(item: $route) { EditorSheet(route: $0) }
    }
}

struct TransactionDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MobileLedgerStore
    let transactionID: UUID
    @Binding var route: EditorRoute?
    @State private var pendingDeletion: LedgerTransaction?
    @State private var pendingDuplication: LedgerTransaction?

    private var transaction: LedgerTransaction? { store.transaction(transactionID) }
    private var attachments: Binding<[AttachmentAsset]> {
        Binding(get: { transaction?.attachment?.assets ?? [] }, set: { assets in
            guard let transaction else { return }
            var draft = store.draft(for: transaction)
            draft.attachments = assets
            store.saveTransactionAndFlush(draft)
        })
    }

    var body: some View {
        List {
            if let transaction {
                ForEach(transaction.postings.sortedForDisplay()) { posting in
                    PostingDetailRow(presentation: postingDetailPresentation(for: posting, store: store))
                        .padding(.vertical, 4)
                }
                DetailValueRow(label: "Date", value: detailDate(transaction.date))
                if let frequency = transaction.recurrenceRule?.frequency, frequency != .never {
                    DetailValueRow(label: "Repeat", value: frequency.title)
                }
                if !transaction.note.isEmpty { DetailValueRow(label: "Notes", value: transaction.note) }
                if !transaction.payee.isEmpty { DetailValueRow(label: "Payee", value: transaction.payee) }
                if !transaction.number.isEmpty { DetailValueRow(label: "Number", value: transaction.number) }
                if let assets = transaction.attachment?.assets, !assets.isEmpty {
                    ForEach(assets) { asset in
                        ReceiptPreview(asset: asset, showsFilename: false, thumbnailHeight: 210)
                            .padding(.vertical, 4)
                    }
                } else {
                    ReceiptPicker(assets: attachments, textOnly: true)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        .contentMargins(.bottom, 16, for: .scrollContent)
        .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    if let transaction { route = .transaction(store.draft(for: transaction), "Edit Transaction") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ZStack {
                HStack {
                    Menu {
                        Button("Duplicate") { pendingDuplication = transaction }
                        Button("Save as Template") {
                            if let transaction { route = .template(store.templateDraft(from: transaction)) }
                        }
                        ReceiptPicker(assets: attachments)
                    } label: {
                        Image(systemName: "plus.square").font(.title3).frame(width: 44, height: 44)
                    }.accessibilityLabel("Transaction Actions")
                    Spacer()
                }
                Button("Delete Transaction") { requestDeletion() }
                    .frame(minHeight: 44).foregroundStyle(.blue)
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
        .modifier(TransactionDeletionConfirmation(transaction: $pendingDeletion, onDeleted: { dismiss() }))
        .modifier(TransactionDuplicateConfirmation(transaction: $pendingDuplication))
    }

    private func requestDeletion() {
        guard let transaction else { return }
        if let rule = transaction.recurrenceRule, rule.frequency != .never { pendingDeletion = transaction }
        else {
            store.deleteTransaction(transaction.id, scope: .occurrence)
            if store.validationError == nil { dismiss() }
        }
    }

    private func detailDate(_ date: Date) -> String {
        let time = Self.detailTimeFormatter.string(from: date)
        if store.data.dateFormat == .iso { return dateString(date, format: .iso) + " " + time }
        return Self.detailDateFormatter.string(from: date) + " at " + time
    }

    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.timeStyle = .none
        return formatter
    }()
    private static let detailTimeFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct PostingDetailPresentation {
    var accountName: String
    var accountPath: String
    var accountColor: Color
    var directionSystemImage: String
    var amountText: String
}

@MainActor
private func postingDetailPresentation(
    for posting: Posting,
    store: MobileLedgerStore
) -> PostingDetailPresentation {
    let account = store.account(posting.accountID)
    let accountColor: Color
    if let account, account.kind == .income || account.kind == .expense {
        accountColor = AppColors.color(account.colorName)
    } else {
        accountColor = .gray
    }

    var path = "Account"
    if let account {
        var names: [String] = []
        var parent = store.account(account.parentID)
        var visited = Set<UUID>()
        while let current = parent, visited.insert(current.id).inserted {
            names.append(current.name)
            parent = store.account(current.parentID)
        }
        path = names.isEmpty ? account.kind.title : names.reversed().joined(separator: ":")
    }

    return PostingDetailPresentation(
        accountName: account?.name ?? "Unassigned",
        accountPath: path,
        accountColor: accountColor,
        directionSystemImage: posting.amount < .zero ? "arrow.left" : "arrow.right",
        amountText: moneyString(posting.amount, symbol: store.symbol(for: posting.commodityID ?? account?.commodityID, ledgerID: account?.ledgerID))
    )
}

private struct PostingDetailRow: View {
    let presentation: PostingDetailPresentation

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(presentation.accountColor)
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: presentation.directionSystemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                }
            (Text(presentation.accountPath + ":").foregroundColor(.secondary) + Text(presentation.accountName).foregroundColor(.primary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(presentation.amountText).foregroundStyle(.secondary).fixedSize()
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}

private struct DetailValueRow: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}

private struct MobileTransactionPreviewPresentation: Equatable {
    var cleared: Bool
    var title: String
    var payeeLabel: String?
    var amountText: String
    var isNegativeAmount: Bool
    var flowDisplay: MobileAccountFlowDisplay
    var hasActiveRecurrence: Bool
    var hasAttachment: Bool
    var dateLabel: String
}

@MainActor
private func mobileTransactionPreviewPresentation(
    for transaction: LedgerTransaction,
    store: MobileLedgerStore
) -> MobileTransactionPreviewPresentation {
    let amount = store.registerAmountInfo(for: transaction)
    let title = transactionTitle(for: transaction)
    return MobileTransactionPreviewPresentation(
        cleared: transaction.cleared,
        title: title,
        payeeLabel: !transaction.payee.isEmpty && transaction.payee != title ? "@\(transaction.payee)" : nil,
        amountText: moneyString(amount.amount, symbol: amount.symbol),
        isNegativeAmount: amount.amount < .zero,
        flowDisplay: store.accountFlowDisplay(for: transaction),
        hasActiveRecurrence: transaction.recurrenceRule?.frequency != nil && transaction.recurrenceRule?.frequency != .never,
        hasAttachment: transaction.attachment?.assets.isEmpty == false,
        dateLabel: Calendar.current.isDateInToday(transaction.date) ? "Today"
            : Calendar.current.isDateInYesterday(transaction.date) ? "Yesterday"
            : store.data.dateFormat == .iso ? dateString(transaction.date, format: .iso)
            : transaction.date.formatted(.dateTime.month(.wide).day().year())
    )
}

private func transactionTitle(for transaction: LedgerTransaction) -> String {
    if !transaction.note.isEmpty { return transaction.note }
    if !transaction.payee.isEmpty { return transaction.payee }
    return "Transaction"
}

private struct MobileTransactionPreviewRow: View {
    let presentation: MobileTransactionPreviewPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(presentation.title)
                        .lineLimit(1)
                    if let payeeLabel = presentation.payeeLabel {
                        Text(payeeLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(presentation.amountText)
                        .foregroundStyle(presentation.isNegativeAmount ? .red : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                HStack(spacing: 4) {
                    AccountFlowText(display: presentation.flowDisplay)
                    if presentation.hasActiveRecurrence {
                        Image(systemName: "arrow.2.squarepath")
                    }
                    Spacer(minLength: 8)
                    Text(presentation.dateLabel)
                        .layoutPriority(1)
                        .accessibilityIdentifier("search-result-date")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .topLeading) { TransactionGutter(cleared: presentation.cleared, hasAttachment: presentation.hasAttachment) }
    }
}
struct AccountFlowText: View {
    let display: MobileAccountFlowDisplay

    var body: some View {
        HStack(spacing: 3) {
            flowSide(accounts: display.negative)
            Image(systemName: "arrow.right")
                .font(.caption2)
            flowSide(accounts: display.positive)
        }
    }

    @ViewBuilder
    private func flowSide(accounts: [MobileAccountFlowAccount]) -> some View {
        if accounts.isEmpty {
            Text("Unassigned")
        } else {
            ForEach(Array(accounts.prefix(2).enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Text(",")
                }
                Text(account.name)
                    .foregroundStyle(accountFlowColor(account))
            }
        }
    }

    private func accountFlowColor(_ account: MobileAccountFlowAccount) -> Color {
        switch account.kind {
        case .income, .expense:
            AppColors.color(account.colorName)
        case .asset, .liability, .equity:
            .secondary
        }
    }
}

private struct MobileAccountListRow: View, Equatable {
    let node: MobileAccountNode
    let balances: [MobileBalanceRow]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
            if node.account.kind == .income || node.account.kind == .expense {
                Circle()
                    .fill(AppColors.color(node.account.colorName))
                    .frame(width: 12, height: 12)
            }
            Text(node.account.name)
                .lineLimit(1)
                .accessibilityIdentifier("overview-account-name-\(node.id)")
            }
            .padding(.leading, CGFloat(node.depth) * 22)
            Spacer()
            if node.account.kind != .income && node.account.kind != .expense {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(balances) { row in
                        Text(moneyString(row.amount, symbol: row.symbol))
                            .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.72)
                    }
                }
            }
        }
    }
}

struct AccountTransactionsScreen: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let accountID: UUID
    @Binding var route: EditorRoute?
    let openTransaction: (UUID) -> Void

    var body: some View {
        TransactionListScreen(
            scope: .account(accountID),
            title: store.account(accountID)?.name ?? "Account",
            route: $route,
            ledgerID: store.account(accountID)?.ledgerID,
            openTransaction: openTransaction
        )
    }
}

struct CurrencyTransactionsScreen: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let currencyID: UUID
    @Binding var route: EditorRoute?
    let openTransaction: (UUID) -> Void

    var body: some View {
        TransactionListScreen(
            scope: .currency(currencyID),
            title: store.commodity(currencyID)?.name ?? "Currency",
            route: $route,
            ledgerID: store.commodity(currencyID)?.ledgerID,
            openTransaction: openTransaction
        )
    }
}

struct FinanceBottomBar: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @EnvironmentObject private var syncState: MobileCloudSyncState
    var isJournalActive: Bool
    var openSettings: () -> Void
    var openSearch: () -> Void
    var openCloudSync: () -> Void
    var newTransaction: () -> Void

    var body: some View {
        HStack {
            Button(action: isJournalActive ? openSearch : openSettings) {
                Image(systemName: isJournalActive ? "magnifyingglass" : "gear")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isJournalActive ? "Quick Search" : "Settings")

            Spacer()

            Button(action: openCloudSync) {
                VStack(spacing: 5) {
                    Text(syncTitle)
                        .font(.body)
                        .lineLimit(1)
                    if syncState.progress.isRunning {
                        CloudSyncProgressBar(progress: syncState.progress)
                            .frame(maxWidth: 160)
                    }
                }
                .frame(maxWidth: 220, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("iCloud Sync")
            .accessibilityValue(syncState.progress.detail.map { "\(syncTitle) \($0)" } ?? syncTitle)

            Spacer()

            if isJournalActive {
                Button(action: newTransaction) {
                    Image(systemName: "square.and.pencil")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("New Transaction")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var syncTitle: String {
        switch syncState.progress.state {
        case .idle:
            store.data.syncEnabled ? "Ready to Sync" : "Sync Disabled"
        case .running:
            syncState.progress.phase.title
        case .succeeded:
            "Up to date"
        case .failed:
            "Sync failed"
        }
    }
}

struct QuickSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var navigationPath: [MobileRoute]
    @Binding var presentedSheet: ShellSheet?
    @Binding var route: EditorRoute?
    @State private var searchText = ""
    @State private var searchResults = MobileQuickSearchResults.empty
    @State private var isSearchPresented = false
    @State private var isSearching = false
    @State private var showsAllAccounts = false
    @State private var searchRevision = UUID()
    @AppStorage(TransactionSearchDatePolicy.preferenceKey, store: MobileDisplayPreferences.defaults) private var includeAllFutureEntries = false

    var contextLedgerID: UUID? = nil
    var contextScope: MobileTransactionScope? = nil
    var initialQuery: TransactionSearchQuery? = nil
    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    QuickSearchSection("Suggestions") {
                        suggestion("All Transactions", "arrow.right") {
                            open(.all, title: "All")
                        }
                        suggestion("Uncleared Transactions", "circle") {
                            open(.uncleared, title: "Uncleared")
                        }
                        suggestion("Repeating Transactions", "arrow.2.squarepath") {
                            open(.repeating, title: "Repeating")
                        }
                    }
                    QuickSearchSection("Date") {
                        suggestion("Today", "calendar") {
                            open(.today, title: "Today")
                        }
                        suggestion("Last Month", "calendar") {
                            open(.lastMonth, title: "Last Month")
                        }
                    }
                } else {
                    if !searchResults.accounts.isEmpty {
                        QuickSearchSection("Accounts") {
                            ForEach(searchResults.accounts.prefix(showsAllAccounts ? searchResults.accounts.count : 3)) { account in
                                Button { openAccount(account) } label: {
                                    accountResultRow(account)
                                }
                                .buttonStyle(TransactionRowButtonStyle())
                                .accessibilityIdentifier("search-account-\(account.id.uuidString)")
                            }
                            if searchResults.accounts.count > 3 {
                                Button(showsAllAccounts ? "Show Fewer Accounts" : "Show All \(searchResults.accounts.count) Accounts") {
                                    withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) {
                                        showsAllAccounts.toggle()
                                    }
                                }
                                .foregroundStyle(.blue)
                                .accessibilityIdentifier("search-accounts-toggle")
                                .accessibilityValue(showsAllAccounts ? "Expanded" : "Collapsed")
                            }
                        }
                    }
                    QuickSearchSection("Suggestions") {
                        ForEach(TransactionSearchField.allCases) { field in
                            let query = TransactionSearchQuery(text: trimmedQuery, field: field)
                            suggestion(query.suggestion, "magnifyingglass") { openFiltered(query) }
                                .accessibilityIdentifier("search-filter-\(field.rawValue)")
                        }
                    }
                    if isSearching {
                        ProgressView("Searching")
                    } else if searchResults.isEmpty {
                        Section {
                            Text("No Results")
                                .foregroundStyle(.secondary)
                        }
                    }

                    QuickSearchSection("Transactions") {
                        Button {
                            includeAllFutureEntries.toggle()
                        } label: {
                            Label(includeAllFutureEntries ? "Limit Future Entries" : "Show All Future Entries", systemImage: "calendar.badge.clock")
                                .foregroundStyle(.blue).font(.subheadline)
                        }
                        .accessibilityIdentifier("search-future-toggle")
                        .accessibilityValue(includeAllFutureEntries ? "All dates" : "Recent entries")
                        if !searchResults.transactions.isEmpty {
                            ForEach(searchResults.transactions) { transaction in
                                Button {
                                    openTransaction(transaction)
                                } label: {
                                    MobileTransactionPreviewRow(
                                        presentation: mobileTransactionPreviewPresentation(for: transaction, store: store)
                                    )
                                    .padding(EdgeInsets(top: 8, leading: 28, bottom: 8, trailing: 20))
                                }
                                .buttonStyle(TransactionRowButtonStyle())
                                .listRowInsets(EdgeInsets())
                                .accessibilityIdentifier("search-transaction-\(transaction.id.uuidString)")
                            }
                        }
                    }

                    if !searchResults.ledgers.isEmpty {
                        QuickSearchSection("Journals") {
                            ForEach(searchResults.ledgers) { ledger in
                                Button {
                                    openJournal(ledger)
                                } label: {
                                    resultRow(
                                        title: ledger.name,
                                        subtitle: "\(searchResults.ledgerTransactionCounts[ledger.id] ?? 0) Transactions",
                                        systemImage: "folder",
                                        tint: .blue
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }


                    if !searchResults.currencies.isEmpty {
                        QuickSearchSection("Currencies") {
                            ForEach(searchResults.currencies) { currency in
                                Button {
                                    openCurrency(currency)
                                } label: {
                                    resultRow(
                                        title: currency.symbol,
                                        subtitle: "\(currency.name) · \(store.ledger(currency.ledgerID)?.name ?? "Journal")",
                                        systemImage: "coloncurrencysign.circle",
                                        tint: .orange
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !searchResults.templates.isEmpty {
                        QuickSearchSection("Templates") {
                            ForEach(searchResults.templates) { template in
                                Button {
                                    useTemplate(template)
                                } label: {
                                    resultRow(
                                        title: template.name,
                                        subtitle: templateSubtitle(template),
                                        systemImage: "doc.text",
                                        tint: template.enabled ? .green : .secondary
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(.custom(0))
            .contentMargins(.top, 0, for: .scrollContent)
            .environment(\.defaultMinListHeaderHeight, 0)
            .searchable(text: $searchText, isPresented: $isSearchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .modifier(QuickSearchToolbarVisibility())
            .scrollDismissesKeyboard(.interactively)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit(of: .search) {
                // Keep the query, suggestions, results, and sheet in place.
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .navigationTitle("Quick Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismissSheet()
                    }
                }
            }
        }
        .onAppear {
            if let initialQuery { searchText = initialQuery.text }
            isSearchPresented = true
        }
        .onChange(of: searchText) {
            showsAllAccounts = false
            searchRevision = UUID()
        }
        .onChange(of: includeAllFutureEntries) { searchRevision = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in searchRevision = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in searchRevision = UUID() }
        .onReceive(store.$searchContentRevision) { _ in searchRevision = UUID() }
        .task(id: searchRevision) { await refreshSearchResults() }
    }

    private func refreshSearchResults() async {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            searchResults = .empty
            isSearching = false
            return
        }
        isSearching = true
        searchResults = .empty
        let scope = contextScope ?? .all
        let matchingRows: [LedgerTransaction]
        do {
            try await Task.sleep(for: .milliseconds(150))
            var request = RegisterRenderRequest(data: store.data, rows: store.registerSourceRows(ledgerID: contextLedgerID), scope: scope, search: trimmedSearch, dateInterval: nil, transactionIDs: nil, filtersScope: true)
            request.searchDatePolicy = TransactionSearchDatePolicy(includeAllFuture: includeAllFutureEntries, now: request.referenceDate, calendar: request.calendar)
            matchingRows = try await RegisterRenderWorker.shared.search(request, limit: 40).rows
            try Task.checkCancellation()
        } catch { return }
        let ledgers = contextScope == nil ? store.searchLedgers(trimmedSearch) : []
        searchResults = MobileQuickSearchResults(
            transactions: matchingRows,
            ledgers: ledgers,
            accounts: store.searchAccounts(trimmedSearch, ledgerID: contextLedgerID ?? store.selectedLedgerID, limit: .max),
            currencies: contextScope == nil ? store.searchCommodities(trimmedSearch) : [],
            templates: contextScope == nil ? store.searchTransactionTemplates(trimmedSearch) : [],
            ledgerTransactionCounts: Dictionary(uniqueKeysWithValues: ledgers.map { ledger in
                (ledger.id, store.transactions(scope: .all, ledgerID: ledger.id).count)
            })
        )
        isSearching = false
    }

    private func suggestion(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .foregroundStyle(.primary)
                .padding(.vertical, 4)
        }
    }

    private func accountResultRow(_ account: Account) -> some View {
        let path = store.accountParentPath(for: account)
        return HStack(spacing: 12) {
            Circle()
                .fill(account.kind == .income || account.kind == .expense ? AppColors.color(account.colorName) : .gray)
                .frame(width: 12, height: 12)
            (Text(path.isEmpty ? "" : path + ":").foregroundColor(.secondary)
                + Text(account.name).foregroundColor(.primary))
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func resultRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private func openFiltered(_ query: TransactionSearchQuery) {
        guard let ledgerID = contextLedgerID ?? store.selectedLedgerID else { return }
        navigationPath.append(.searchTransactions(scope: contextScope ?? .all, ledgerID: ledgerID, query: query))
        dismissSheet()
    }

    private func open(_ scope: MobileTransactionScope, title: String) {
        if navigationPath.isEmpty, let ledgerID = store.selectedLedgerID {
            navigationPath.append(.journal(ledgerID))
        }
        if let ledgerID = contextLedgerID ?? store.selectedLedgerID {
            navigationPath.append(.transactions(scope: scope, title: title, ledgerID: ledgerID))
        }
        dismissSheet()
    }

    private func openTransaction(_ transaction: LedgerTransaction) {
        store.selectLedger(transaction.ledgerID)
        if contextScope != nil { navigationPath.append(.transaction(transaction.id)) }
        else { navigationPath = [.journal(transaction.ledgerID), .transaction(transaction.id)] }
        dismissSheet()
    }

    private func openJournal(_ ledger: Ledger) {
        store.selectLedger(ledger.id)
        navigationPath = [.journal(ledger.id)]
        dismissSheet()
    }

    private func openAccount(_ account: Account) {
        store.selectLedger(account.ledgerID)
        navigationPath = [.journal(account.ledgerID), .account(account.id)]
        dismissSheet()
    }

    private func openCurrency(_ currency: Commodity) {
        store.selectLedger(currency.ledgerID)
        navigationPath = [.journal(currency.ledgerID), .currency(currency.id)]
        dismissSheet()
    }

    private func useTemplate(_ template: TransactionTemplate) {
        store.selectLedger(template.ledgerID)
        route = .newFromTemplate(template, "New From Template")
        dismissSheet()
    }

    private func templateSubtitle(_ template: TransactionTemplate) -> String {
        let ledgerName = store.ledger(template.ledgerID)?.name ?? "Journal"
        if !template.payee.isEmpty {
            return "\(template.payee) · \(ledgerName)"
        }
        if !template.note.isEmpty {
            return "\(template.note) · \(ledgerName)"
        }
        return ledgerName
    }

    private func dismissSheet() {
        presentedSheet = nil
        dismiss()
    }
}

private struct QuickSearchSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        Section { content } header: {
            Text(title)
                .font(.headline)
                .foregroundColor(Color(uiColor: .label))
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 5)
                .background(Color(uiColor: .systemGray5))
                .listRowInsets(EdgeInsets())
        }
        .listSectionSeparator(.hidden)
    }
}

private struct QuickSearchToolbarVisibility: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.1, *) {
            content.searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            content
        }
    }
}

private struct MobileQuickSearchResults {
    static let empty = MobileQuickSearchResults(
        transactions: [],
        ledgers: [],
        accounts: [],
        currencies: [],
        templates: [],
        ledgerTransactionCounts: [:]
    )

    var transactions: [LedgerTransaction]
    var ledgers: [Ledger]
    var accounts: [Account]
    var currencies: [Commodity]
    var templates: [TransactionTemplate]
    var ledgerTransactionCounts: [UUID: Int]

    var isEmpty: Bool {
        transactions.isEmpty &&
            ledgers.isEmpty &&
            accounts.isEmpty &&
            currencies.isEmpty &&
            templates.isEmpty
    }
}

struct MobileCloudSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MobileLedgerStore

    // Sync belongs to MobileLedgerStore, not this presentation. Dismissing
    // the sheet must never cancel its task; the Cloud Sync toggle owns that.
    var body: some View {
        NavigationStack {
            CloudSyncManagementView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    }
                }
        }
        .environmentObject(store.cloudSyncState)
    }
}

struct MobileCloudSyncConflictsSection: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @EnvironmentObject private var syncState: MobileCloudSyncState

    var body: some View {
        if !store.cloudSyncConflicts.isEmpty {
            Section("Needs Review") {
                ForEach(store.cloudSyncConflicts, id: \.id) { conflict in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title(for: conflict.local))
                            .font(.headline)
                        Text("This item changed on this device and in iCloud. Choose the version to keep.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        LabeledContent("This Device", value: summary(for: conflict.local))
                        LabeledContent("iCloud", value: summary(for: conflict.remote))
                        HStack {
                            Button("Keep This Device") {
                                store.resolveCloudKitSyncConflict(id: conflict.id, keepLocal: true)
                            }
                            Button("Use iCloud") {
                                store.resolveCloudKitSyncConflict(id: conflict.id, keepLocal: false)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(syncState.progress.isRunning)
                    }
                    .padding(.vertical, 4)
                }
            }
            .onAppear { store.refreshCloudSyncConflicts() }
        }
    }

    private func title(for record: CloudKitSyncRecord) -> String {
        values(for: record).first ?? record.recordType.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func summary(for record: CloudKitSyncRecord) -> String {
        if record.operation == "delete" { return "Deleted" }
        var fields = values(for: record)
        if record.recordType == "transaction",
           let json = record.payloadJSON?.data(using: .utf8),
           let transaction = try? JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: json) {
            fields += transaction.postings.map { posting in
                let account = store.account(posting.accountID)
                let symbol = store.symbol(for: posting.commodityID ?? account?.commodityID)
                return "\(account?.name ?? "Account"): \(moneyString(posting.amount, symbol: symbol))"
            }
        }
        return fields.isEmpty ? "Updated" : fields.joined(separator: " · ")
    }

    private func values(for record: CloudKitSyncRecord) -> [String] {
        guard let json = record.payloadJSON?.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        return ["name", "symbol", "payee", "note", "date"].compactMap { key in
            guard let value = fields[key] as? String, !value.isEmpty else { return nil }
            return value
        }
    }
}
