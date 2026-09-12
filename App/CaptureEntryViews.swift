import SwiftUI

@MainActor
enum IncomingTransactionDraftFactory {
    static func make(request: IncomingTransactionRequest, store: MobileLedgerStore, visibility: JournalVisibility? = nil) -> TransactionDraft {
        let hidden = visibility ?? JournalVisibility(rawValue: MobileDisplayPreferences.defaults.string(forKey: JournalVisibility.preferenceKey) ?? "")
        let journals = hidden.visible(in: store.orderedLedgers)
        let requestedID = request.suggestion?.journalID ?? store.selectedLedgerID
        let journalID = journals.first { $0.id == requestedID }?.id ?? journals.first?.id
        let accounts = journalID.map { store.leafAccountNodes(ledgerID: $0).map(\.account) } ?? []
        let currencyCode = request.suggestion?.currencyCode ?? ""
        let funding = accounts.filter { $0.kind == .asset || $0.kind == .liability }
        let card = request.suggestion?.card ?? ""
        let matches = funding.filter { $0.name.caseInsensitiveCompare(card) == .orderedSame }
        let account = card.isEmpty ? funding.first : (matches.count == 1 ? matches.first : nil)
        let currency = currencyCode.isEmpty
            ? account?.commodityID.flatMap { store.commodity($0) }
            : store.data.commodities.first { $0.ledgerID == journalID && $0.symbol.caseInsensitiveCompare(currencyCode) == .orderedSame }
        let expense = accounts.first { $0.kind == .expense }
        let amount = request.suggestion?.amount
        var draft = TransactionDraft(ledgerID: journalID)
        draft.saveOperationID = request.suggestion?.id ?? request.id
        draft.date = request.suggestion?.date ?? Date()
        draft.payee = request.suggestion?.merchant ?? ""
        draft.note = request.suggestion?.note ?? ""
        draft.cleared = false
        draft.postings = [PostingDraft(accountID: account?.id, amount: amount.map { decimalInputString(-$0) } ?? "-", commodityID: currency?.id),
            PostingDraft(accountID: expense?.id, amount: amount.map(decimalInputString) ?? "", commodityID: currency?.id)]
        return draft
    }
}

struct IncomingTransactionView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let request: IncomingTransactionRequest
    var body: some View {
        NavigationStack {
            TransactionEditorView(title: "New Transaction", initialDraft: IncomingTransactionDraftFactory.make(request: request, store: store),
                allowsJournalSelection: true, captureCurrencyCode: request.suggestion?.currencyCode ?? "",
                initialReceiptURLs: request.receiptURLs, onSaved: {
                    if let id = request.suggestion?.id { Task { await SystemEntryRouter.shared.dismissSuggestion(id, store: store) } }
                })
        }
    }
}

struct CaptureSuggestionsView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @ObservedObject private var inbox = SystemEntryRouter.shared
    @State private var route: EditorRoute?
    var body: some View {
        List {
            Section {
                ForEach(inbox.suggestions) { suggestion in
                    Button {
                        route = .incoming(.init(suggestion: suggestion))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(suggestion.merchant.isEmpty ? "Purchase" : suggestion.merchant).foregroundStyle(.primary)
                                Text(suggestion.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                if !suggestion.card.isEmpty { Text(suggestion.card).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let amount = suggestion.amount { Text(moneyString(amount, symbol: suggestion.currencyCode)).foregroundStyle(.primary) }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .swipeActions {
                        Button("Dismiss", role: .destructive) { Task { await inbox.dismissSuggestion(suggestion.id, store: store) } }
                    }
                }
            } footer: {
                Text("Suggestions are pending drafts on this iPhone. Review a suggestion and tap Save to add it to a journal.")
            }
            Section {
                NavigationLink("Set Up Apple Pay Capture") { ApplePayCaptureSetupView() }
            }
        }
        .overlay {
            if inbox.suggestions.isEmpty {
                ContentUnavailableView("No Suggestions", systemImage: "tray", description: Text("Wallet captures will appear here for review."))
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Suggestions")
        .sheet(item: $route, onDismiss: { Task { await inbox.reloadSuggestions(store: store) } }) { EditorSheet(route: $0) }
        .task { await inbox.reloadSuggestions(store: store) }
        .alert(item: $inbox.error) { error in Alert(title: Text("Suggestions"), message: Text(error.message)) }
    }
}

struct ApplePayCaptureSetupView: View {
    var body: some View {
        List {
            Section("One-Time Setup") {
                Text("1. Open Shortcuts → Automation → + → Transaction (or Wallet).")
                Text("2. Choose the card you tap with Apple Pay and select Run Immediately.")
                Text("3. Add the Finances action ‘Add Apple Pay to Suggestions’.")
                Text("4. Connect Amount to the transaction’s amount and currency, Merchant to its merchant, and optionally Card Name and Date. Choose a journal, or leave it open for review.")
                Text("5. Check the currency on your first capture. If Wallet supplies a number without currency, set Currency Code explicitly in the action.")
            }
            Section {
                Text("The automation captures supported Wallet transactions. It does not import your card’s full history or record purchases automatically in the ledger.")
                Text("Open Suggestions in Finances to check the amount, currency, journal and accounts before saving.")
            }
        }.navigationTitle("Apple Pay Capture").navigationBarTitleDisplayMode(.inline)
    }
}

struct SystemIntegrationsSettingsView: View {
    var body: some View {
        List {
            NavigationLink("Home Screen Quick Actions") { HomeScreenQuickActionSettingsView() }
            NavigationLink("Apple Pay Suggestions") { ApplePayCaptureSetupView() }
            Section("Siri & Shortcuts") {
                Text("Use New Transaction, Use Transaction Template, Open Suggestions, or New Transaction with Receipts in Shortcuts. You can assign a shortcut to your Action button or Control Center.")
                Text("Try saying ‘Log an expense in Finances v2’. Transactions open as drafts for you to review and save.")
            }
            Section("Share a Receipt") {
                Text("Share or open an image or PDF in Finances to start a transaction with the receipt attached. Choose the journal and edit the transaction before saving.")
            }
        }.navigationTitle("Quick Entry & Shortcuts").navigationBarTitleDisplayMode(.inline)
    }
}
