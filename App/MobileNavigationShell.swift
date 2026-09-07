import SwiftUI

enum MobileRoute: Hashable {
    case journals
    case journal(UUID)
    case transactions(scope: MobileTransactionScope, title: String, ledgerID: UUID)
    case transaction(UUID)
    case templates(UUID)
    case account(UUID)
    case currency(UUID)
    case settings
    @MainActor func resolvedLedgerID(in store: MobileLedgerStore) -> UUID? {
        switch self {
        case .journal(let id), .templates(let id): id
        case .transactions(_, _, let id): id
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
    @Environment(\.editMode) private var editMode
    @Binding var navigationPath: [MobileRoute]
    @Binding var route: EditorRoute?
    @State private var pendingDelete: Ledger?

    var body: some View {
        List {
            Section {
                ForEach(store.orderedLedgers) { ledger in
                    NavigationLink(value: MobileRoute.journal(ledger.id)) {
                        HStack(spacing: 14) {
                            Image(systemName: "folder").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ledger.name)
                                Text("\(store.transactions(scope: .all, ledgerID: ledger.id).count.formatted()) Transactions")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            let count = store.transactions(scope: .uncleared, ledgerID: ledger.id).count
                            if count > 0 { Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit() }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { route = .journalRename(ledger) }
                        Button("Delete Journal", systemImage: "trash", role: .destructive) { pendingDelete = ledger }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { pendingDelete = ledger }.tint(.red)
                        Button("Rename") { route = .journalRename(ledger) }.tint(.blue)
                    }
                }
                .onDelete { offsets in
                    if let index = offsets.first { pendingDelete = store.orderedLedgers[index] }
                }
                .onMove(perform: store.moveJournals)
            }
        }
        .listStyle(.insetGrouped)
        .compactGroupedForm()
        .overlay {
            if store.orderedLedgers.isEmpty {
                ContentUnavailableView {
                    Label("Your Journals", systemImage: "folder")
                } description: {
                    Text("Create a journal to get started, or turn on iCloud Sync to bring your journals from your Mac.")
                } actions: {
                    Button("New Journal") { route = .journalNew }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Journals")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("New Journal", systemImage: "plus") { route = .journalNew }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .confirmationDialog("Delete Journal?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { ledger in
            Button("Delete \(ledger.name)", role: .destructive) { store.deleteJournal(ledger.id) }
        } message: { _ in Text("This deletes the journal, its accounts, transactions, and receipts on all synced devices.") }
    }
}

struct JournalOverviewScreen: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.editMode) private var editMode
    let ledgerID: UUID
    @Binding var navigationPath: [MobileRoute]
    @Binding var route: EditorRoute?
    @State private var expandedKinds = Set<AccountKind>()
    @State private var collapsedAccounts = Set<UUID>()
    @State private var pendingAccountDelete: Account?

    var body: some View {
        List {
            TransactionLinksSection(ledgerID: ledgerID) { navigationPath.append(.templates(ledgerID)) }
            Section {
                ForEach(AccountKind.allCases) { kind in
                    DisclosureGroup(isExpanded: Binding(get: { expandedKinds.contains(kind) }, set: { if $0 { expandedKinds.insert(kind) } else { expandedKinds.remove(kind) } })) {
                        ForEach(visibleNodes(kind)) { node in
                            HStack(spacing: 8) {
                                NavigationLink(value: MobileRoute.account(node.id)) {
                                    MobileAccountListRow(node: node, balances: store.balanceRows(for: node.id))
                                }
                                if editMode?.wrappedValue.isEditing == true {
                                    Button("Edit \(node.account.name)", systemImage: "info.circle") { route = .account(store.draft(for: node.account)) }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .contextMenu {
                                if node.hasChildren {
                                    Button(collapsedAccounts.contains(node.id) ? "Expand Subaccounts" : "Collapse Subaccounts") {
                                        if !collapsedAccounts.insert(node.id).inserted { collapsedAccounts.remove(node.id) }
                                    }
                                }

                                Button("Edit Account", systemImage: "pencil") { route = .account(store.draft(for: node.account)) }
                                Button("Delete Account", systemImage: "trash", role: .destructive) { pendingAccountDelete = node.account }
                            }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) { pendingAccountDelete = node.account }.tint(.red)
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
                    } label: {
                        HStack {
                            Text(groupTitle(kind)).fontWeight(.semibold)
                            Spacer()
                            VStack(alignment: .trailing) {
                                ForEach((kind == .income || kind == .expense) ? [] : (store.ledgerTotalsByKind(ledgerID: ledgerID)[kind] ?? [])) { row in
                                    Text(moneyString(row.amount, symbol: row.symbol)).foregroundStyle(.secondary).monospacedDigit().font(.subheadline)
                                }
                            }
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
        let roots = nodes.filter { $0.account.parentID == nil }
        return nodes.filter { node in
            if roots.count == 1 && node.account.parentID == nil { return false }
            var parent = node.account.parentID
            var visited = Set<UUID>()
            while let id = parent, visited.insert(id).inserted {
                if collapsedAccounts.contains(id) { return false }
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
                    Text("\(store.unclearedTransactionCount(ledgerID: ledgerID))")
                        .foregroundStyle(.secondary)
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
    let scope: MobileTransactionScope
    let title: String
    @Binding var route: EditorRoute?
    var dateInterval: DateInterval? = nil
    var transactionIDs: Set<UUID>? = nil
    var ledgerID: UUID? = nil
    let openTransaction: (UUID) -> Void
    @State private var searchText = ""
    @State private var pendingDeletion: LedgerTransaction?
    @State private var pendingDuplication: LedgerTransaction?
    @State private var showsChart = false
    @State private var selectedMonth: Date?
    @State private var presentation = RegisterPresentation(months: [], amounts: [:], balances: [:])
    @State private var positionedInitialRows = false

    private enum ScrollTarget: Hashable { case day(Date), chart }

    private var rows: [LedgerTransaction] {
        store.transactions(scope: scope, ledgerID: ledgerID, search: searchText).filter { row in
            (dateInterval.map { row.date >= $0.start && row.date < $0.end } ?? true) && (transactionIDs?.contains(row.id) ?? true)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if showsChart && dateInterval == nil {
                    RegisterChart(months: presentation.months)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                        .id(ScrollTarget.chart)
                }
                ForEach(presentation.months) { month in monthSection(month) }
            }
            .listStyle(.plain)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 0)
            .searchable(text: $searchText, prompt: "Notes, payee, account or amount")
            .overlay { if presentation.months.isEmpty { ContentUnavailableView(searchText.isEmpty ? "No Transactions" : "No Results", systemImage: searchText.isEmpty ? "arrow.left.arrow.right" : "magnifyingglass", description: Text(searchText.isEmpty ? "Use the compose button to add your first transaction." : "Try a different search.")) } }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if dateInterval == nil { Button("Show Chart", systemImage: showsChart ? "chart.bar.fill" : "chart.bar") { withAnimation { showsChart.toggle() } } }
                }
            }
            .sheet(isPresented: Binding(get: { selectedMonth != nil }, set: { if !$0 { selectedMonth = nil } })) {
                if let month = selectedMonth {
                    MonthSummaryView(month: month, scope: scope, ledgerID: ledgerID)
                }
            }
            .modifier(TransactionDeletionConfirmation(transaction: $pendingDeletion))
            .modifier(TransactionDuplicateConfirmation(transaction: $pendingDuplication))
            .task { refresh() }
            .onReceive(store.$data.debounce(for: .milliseconds(40), scheduler: RunLoop.main)) { _ in refresh() }
            .onChange(of: searchText) { refresh() }
            .task(id: presentation.months.isEmpty) {
                guard !presentation.months.isEmpty, !positionedInitialRows else { return }
                positionedInitialRows = true
                guard dateInterval == nil, searchText.isEmpty,
                      let day = presentation.initialDay() else { return }
                await Task.yield()
                proxy.scrollTo(ScrollTarget.day(day), anchor: .top)
            }
            .onChange(of: showsChart) {
                if showsChart {
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(ScrollTarget.chart, anchor: .top)
                    }
                }
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
                    .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)
                ForEach(day.transactions) { transaction in
                    Button {
                        openTransaction(transaction.id)
                    } label: {
                        RegisterRow(transaction: transaction, amounts: presentation.amounts[transaction.id] ?? [], balances: presentation.balances[transaction.id] ?? [])
                            .padding(.leading, 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("register-row-\(transaction.id.uuidString)")
                    .listRowInsets(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { requestDeletion(transaction) }.tint(.red)
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

    private func refresh() { presentation = RegisterPresentation.build(data: store.data, rows: rows, scope: scope) }

    private func summaryPill(_ label: String, value: RegisterMoney, color: Color, month: Date) -> some View {
        Button { selectedMonth = month } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2.weight(.semibold))
                Text(moneyString(value.amount, symbol: value.symbol)).font(.headline).monospacedDigit()
            }.foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9).background(color.gradient, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}

struct RegisterRow: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let transaction: LedgerTransaction
    let amounts: [RegisterMoney]
    let balances: [RegisterMoney]

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                (Text(transaction.note.isEmpty ? (transaction.payee.isEmpty ? "Transaction" : transaction.payee) : transaction.note) + Text(!transaction.note.isEmpty && !transaction.payee.isEmpty ? " @\(transaction.payee)" : "").foregroundColor(.secondary))
                    .lineLimit(1)
                    .accessibilityIdentifier("transaction-title")
                HStack(spacing: 4) {
                    AccountFlowText(display: store.accountFlowDisplay(for: transaction))
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
        .opacity(RegisterPresentation.isFuture(transaction.date) ? 0.48 : 1)
        .accessibilityElement(children: .combine)
    }
}

struct TemplateListScreen: View {
    @EnvironmentObject private var store: MobileLedgerStore
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
                        Button { route = .template(store.templateDraft(for: template)) } label: {
                            Text(template.name).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { included[$0].id }
                        for id in ids { store.deleteTransactionTemplate(id) }
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
                        Button {
                            var draft = store.templateDraft(for: template)
                            draft.enabled = true
                            store.saveTransactionTemplate(draft)
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(.green).font(.title3)
                                Text(template.name).foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit Template") { route = .template(store.templateDraft(for: template)) }
                            Button("Delete Template", role: .destructive) { store.deleteTransactionTemplate(template.id) }
                        }
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
        hasAttachment: transaction.attachment?.assets.isEmpty == false
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
                    Spacer(minLength: 8)
                    if presentation.hasActiveRecurrence {
                        Image(systemName: "arrow.2.squarepath")
                    }
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

private struct MobileAccountListRow: View {
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
                .fontWeight(node.hasChildren ? .semibold : .regular)
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
                    if store.cloudSyncProgress.isRunning {
                        CloudSyncProgressBar(progress: store.cloudSyncProgress)
                            .frame(maxWidth: 160)
                    }
                }
                .frame(maxWidth: 220, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("iCloud Sync")
            .accessibilityValue(store.cloudSyncProgress.detail.map { "\(syncTitle) \($0)" } ?? syncTitle)

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
        switch store.cloudSyncProgress.state {
        case .idle:
            store.data.syncEnabled ? "Ready to Sync" : "Sync Disabled"
        case .running:
            store.cloudSyncProgress.phase.title
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
    @Binding var navigationPath: [MobileRoute]
    @Binding var presentedSheet: ShellSheet?
    @Binding var route: EditorRoute?
    @State private var searchText = ""
    @State private var searchResults = MobileQuickSearchResults.empty

    var contextLedgerID: UUID? = nil

    var body: some View {
        NavigationStack {
            List {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Suggestions") {
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
                    Section("Date") {
                        suggestion("Today", "calendar") {
                            open(.today, title: "Today")
                        }
                        suggestion("Last Month", "calendar") {
                            open(.lastMonth, title: "Last Month")
                        }
                    }
                } else {
                    if searchResults.isEmpty {
                        Section {
                            Text("No Results")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !searchResults.transactions.isEmpty {
                        Section("Transactions") {
                            ForEach(searchResults.transactions) { transaction in
                                Button {
                                    openTransaction(transaction)
                                } label: {
                                    MobileTransactionPreviewRow(
                                        presentation: mobileTransactionPreviewPresentation(for: transaction, store: store)
                                    )
                                    .padding(.leading, 8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !searchResults.ledgers.isEmpty {
                        Section("Journals") {
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

                    if !searchResults.accounts.isEmpty {
                        Section("Accounts") {
                            ForEach(searchResults.accounts) { account in
                                Button {
                                    openAccount(account)
                                } label: {
                                    resultRow(
                                        title: account.name,
                                        subtitle: "\(store.ledger(account.ledgerID)?.name ?? "Journal") · \(account.kind.title)",
                                        systemImage: account.isGroup ? "folder" : "list.bullet.rectangle",
                                        tint: account.kind == .income || account.kind == .expense ? AppColors.color(account.colorName) : .gray
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !searchResults.currencies.isEmpty {
                        Section("Currencies") {
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
                        Section("Templates") {
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
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
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
        .onAppear(perform: refreshSearchResults)
        .onChange(of: searchText) { _, _ in
            refreshSearchResults()
        }
    }

    private func refreshSearchResults() {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            searchResults = .empty
            return
        }
        let ledgers = store.searchLedgers(trimmedSearch)
        searchResults = MobileQuickSearchResults(
            transactions: store.searchTransactions(trimmedSearch),
            ledgers: ledgers,
            accounts: store.searchAccounts(trimmedSearch),
            currencies: store.searchCommodities(trimmedSearch),
            templates: store.searchTransactionTemplates(trimmedSearch),
            ledgerTransactionCounts: Dictionary(uniqueKeysWithValues: ledgers.map { ledger in
                (ledger.id, store.transactions(scope: .all, ledgerID: ledger.id).count)
            })
        )
    }

    private func suggestion(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
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
        navigationPath = [.journal(transaction.ledgerID), .transaction(transaction.id)]
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
        route = .transaction(store.draft(for: template), "New From Template", scanInvoice: template.scanInvoice)
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
    }
}

struct MobileCloudSyncConflictsSection: View {
    @EnvironmentObject private var store: MobileLedgerStore

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
                        .disabled(store.cloudSyncProgress.isRunning)
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
