import SwiftUI

struct AccountGroupPicker: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: MobileAccountDraft

    private var groups: [MobileAccountNode] {
        let accounts = store.data.accounts
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let source = draft.id.flatMap { byID[$0] }
        let hasChildren = source.map { row in accounts.contains { $0.parentID == row.id } } ?? false
        let hasEntries = draft.id.map { id in store.data.transactions.contains { $0.postings.contains { $0.accountID == id } } } ?? false
        return store.accountNodes(ledgerID: draft.ledgerID).filter { node in
            guard node.id != draft.id else { return false }
            if let source, source.parentID == nil { return false }
            if hasChildren || hasEntries, node.account.kind != draft.kind { return false }
            var parent: UUID? = node.id
            var visited = Set<UUID>()
            while let id = parent, visited.insert(id).inserted {
                if id == draft.id { return false }
                parent = byID[id]?.parentID
            }
            return true
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    draft.parentID = nil; draft.isGroup = true; dismiss()
                } label: {
                    HStack {
                        Text("No Group").foregroundColor(Color(uiColor: .label))
                        Spacer()
                        if draft.isGroup { Image(systemName: "checkmark").foregroundColor(.blue) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            ForEach(AccountKind.allCases) { kind in
                let rows = groups.filter { $0.account.kind == kind }
                if !rows.isEmpty {
                    Section(kind.title) {
                        ForEach(rows) { node in
                            Button {
                                if draft.kind != node.account.kind && draft.id == nil {
                                    draft.colorName = node.account.kind == .income ? "green" : (node.account.kind == .expense ? "red" : "gray")
                                }
                                draft.kind = node.account.kind
                                draft.parentID = node.id
                                draft.isGroup = false
                                dismiss()
                            } label: {
                                AccountSelectionLabel(account: node.account, depth: node.depth, selected: selectedGroupID == node.id, showCurrency: false)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("account-group-picker")
        .listStyle(.insetGrouped).compactGroupedForm(sectionSpacing: 0)
        .navigationTitle("Group In").navigationBarTitleDisplayMode(.inline)
    }

    private var selectedGroupID: UUID? {
        if draft.isGroup { return nil }
        return draft.parentID ?? groups.first { $0.depth == 0 && $0.account.kind == draft.kind }?.id
    }
}

struct AccountCurrencyPicker: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: MobileAccountDraft
    var body: some View {
        List {
            Section {
                Button {
                    draft.commodityID = nil; dismiss()
                } label: {
                    HStack {
                        Text("Default").foregroundColor(draft.commodityID == nil ? .blue : Color(uiColor: .label))
                        Spacer()
                        if draft.commodityID == nil { Image(systemName: "checkmark").foregroundColor(.blue) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Section {
                ForEach(draft.ledgerID.map { store.commodities(for: $0) } ?? []) { currency in
                    Button {
                        draft.commodityID = currency.id; dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(currency.name).foregroundColor(draft.commodityID == currency.id ? .blue : Color(uiColor: .label))
                                Text(currency.symbol).font(.caption).foregroundColor(Color(uiColor: .secondaryLabel))
                            }
                            Spacer()
                            if draft.commodityID == currency.id { Image(systemName: "checkmark").foregroundColor(.blue) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .accessibilityIdentifier("account-currency-picker")
        .listStyle(.insetGrouped).compactGroupedForm(sectionSpacing: 8)
        .navigationTitle("Currency").navigationBarTitleDisplayMode(.inline)
    }
}
