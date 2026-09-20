import SwiftUI
import QuickLook

struct SharedTransactionEditor: View {
    let catalog: SharedTransactionCatalog
    let receipts: [URL]
    let analyzeReceipt: SharedReceiptAnalyzer
    let save: (SharedTransaction) async throws -> Void
    let cancel: () -> Void
    @State private var draft: SharedTransaction
    @State private var saving = false
    @State private var analyzing = false
    @State private var failure: String?
    @State private var preview: ReceiptPreview?
    @State private var focusedAmount: UUID?
    @State private var accountPostingID: UUID?
    @State private var showingDate = false
    @FocusState private var textFocus: TextFieldKind?
    @ScaledMetric(relativeTo: .body) private var amountWidth: CGFloat = 82
    @ScaledMetric(relativeTo: .body) private var currencyWidth: CGFloat = 38
    private enum TextFieldKind { case note, payee, number }

    init(catalog: SharedTransactionCatalog, receipts: [URL],
         analyzeReceipt: @escaping SharedReceiptAnalyzer = { try await SharedReceiptAnalysis.analyze($0, catalog: $1, receipts: $2) },
         save: @escaping (SharedTransaction) async throws -> Void, cancel: @escaping () -> Void) {
        self.catalog = catalog; self.receipts = receipts; self.analyzeReceipt = analyzeReceipt
        self.save = save; self.cancel = cancel
        _draft = State(initialValue: SharedTransaction(catalog: catalog))
    }
    private var validationMessage: String? {
        do { try draft.validate(in: catalog); return nil }
        catch { return error.localizedDescription }
    }
    private var scheduleDraft: Binding<TransactionDraft> {
        Binding(get: { draft.draft(operationID: UUID()) }, set: { value in
            draft.recurrence = value.repeatFrequency == .never ? nil : RecurrenceRule(frequency: value.repeatFrequency,
                intervalValue: value.repeatIntervalValue, occurrenceCount: value.repeatOccurrenceCount,
                endDate: value.repeatEndDate, onWorkdays: value.repeatOnWorkdays)
        })
    }

    var body: some View {
        NavigationStack {
            FinanceForm(spacing: 0) {
                FinanceFormCard {
                    FinanceFormRow(last: true) {
                        Menu {
                            ForEach(catalog.journals) { journal in
                                Button(journal.name) { finishTyping(); draft.selectJournal(journal.id, catalog: catalog) }
                            }
                        } label: {
                            FinanceFormLabel(title: "Journal", value: catalog.journals.first { $0.id == draft.journalID }?.name ?? "Choose Journal")
                        }.buttonStyle(.plain).accessibilityLabel("Journal")
                            .accessibilityValue(catalog.journals.first { $0.id == draft.journalID }?.name ?? "Choose Journal")
                            .accessibilityIdentifier("incoming-journal-picker")
                    }
                }.padding(.bottom, 24)
                VStack(spacing: 7) {
                    FinanceFormCard {
                        ForEach(draft.postings) { posting in
                            FinanceDeletableFormRow(last: posting.id == draft.postings.last?.id,
                                canDelete: draft.postings.count > 2,
                                deleteIdentifier: "shared-transaction-delete-\(draft.postings.firstIndex { $0.id == posting.id } ?? 0)",
                                delete: { removePosting(posting.id) }) {
                                postingRow(posting)
                            }
                        }
                    }
                    HStack {
                        Button {
                            draft.postings.append(.init(currencyID: draft.postings.first?.currencyID))
                        } label: { Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(.green) }
                            .accessibilityLabel("Posting").disabled(draft.postings.count >= 64)
                        Spacer()
                        Button("Balance", action: balance).font(.footnote).foregroundStyle(.tint)
                    }.buttonStyle(.plain).padding(.horizontal, 8).frame(height: 28)
                }.padding(.bottom, 32)
                FinanceFormCard {
                    FinanceFormRow {
                        Button { finishTyping(); showingDate.toggle() } label: {
                            FinanceFormLabel(title: "Date", value: compactTransactionDate(draft.date), chevron: false)
                        }.buttonStyle(.plain).accessibilityIdentifier("transaction-date-toggle")
                    }
                    if showingDate {
                        DatePicker("Date", selection: $draft.date, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                    }
                    FinanceFormRow {
                        VStack(alignment: .leading, spacing: 2) {
                            if !draft.note.isEmpty { Text("Notes").font(.caption).foregroundStyle(.secondary) }
                            TextField("Notes", text: $draft.note, axis: .vertical).focused($textFocus, equals: .note)
                                .accessibilityLabel("Notes").accessibilityIdentifier("shared-transaction-note")
                        }.frame(minHeight: draft.note.isEmpty ? 0 : 44, alignment: .leading)
                    }
                    FinanceFormRow { TextField("Payee", text: $draft.payee).focused($textFocus, equals: .payee) }
                    FinanceFormRow(last: true) { TextField("Number", text: $draft.number).focused($textFocus, equals: .number) }
                }.padding(.bottom, 40)
                FinanceFormCard {
                    FinanceFormRow {
                        NavigationLink { RepeatFrequencyEditor(draft: scheduleDraft) } label: {
                            FinanceFormLabel(title: "Repeat", value: repeatDescription(scheduleDraft.wrappedValue))
                        }.buttonStyle(.plain)
                    }
                    if draft.recurrence != nil {
                        FinanceFormRow {
                            NavigationLink { RepeatEndEditor(draft: scheduleDraft) } label: {
                                FinanceFormLabel(title: "End Repeat", value: repeatEndDescription(scheduleDraft.wrappedValue))
                            }.buttonStyle(.plain)
                        }
                    }
                    FinanceFormRow(last: true) { Toggle("Cleared", isOn: $draft.cleared) }
                }.padding(.bottom, 40)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Receipts").font(.footnote).foregroundStyle(.secondary).padding(.leading, 16)
                    FinanceFormCard {
                        ForEach(receipts, id: \.self) { url in
                            FinanceFormRow {
                                Button { finishTyping(); preview = ReceiptPreview(url: url) } label: {
                                    Label(url.lastPathComponent, systemImage: "doc.richtext").lineLimit(2)
                                }.accessibilityIdentifier("shared-transaction-receipt")
                            }
                        }
                        FinanceFormRow(last: true) {
                            SharedReceiptAISection(draft: $draft, busy: $analyzing, catalog: catalog,
                                receipts: receipts, analyzeReceipt: analyzeReceipt).id(draft.journalID)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let validationMessage { Text(validationMessage) }
                    Text("Saved here securely. Added to your journal and synced when Finances next opens.")
                }.font(.footnote).foregroundStyle(.secondary).padding(.top, 16)
            }
            .navigationTitle("New Transaction").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel).accessibilityIdentifier("receipt-share-cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        finishTyping(); saving = true
                        Task { @MainActor in
                            do { try await save(draft) }
                            catch { failure = error.localizedDescription; saving = false }
                        }
                    } label: { if saving { ProgressView() } else { Text("Save") } }
                        .disabled(validationMessage != nil || saving || analyzing).accessibilityIdentifier("receipt-share-save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if let id = focusedAmount, let index = draft.postings.firstIndex(where: { $0.id == id }) {
                        Button("±") {
                            if let value = AmountExpressionEvaluator.evaluate(draft.postings[index].amount) {
                                draft.setAmount(NSDecimalNumber(decimal: -value).stringValue, at: index, catalog: catalog)
                            } else { draft.postings[index].amount = draft.postings[index].amount == "-" ? "" : "-" }
                        }.accessibilityLabel("Change amount sign")
                        ForEach(["÷", "×", "−", "+"], id: \.self) { symbol in
                            Button(symbol) { ShareAmountKeyboard.insert(symbol) }
                        }
                        Button("=") {
                            if let value = AmountExpressionEvaluator.evaluate(draft.postings[index].amount) {
                                draft.setAmount(NSDecimalNumber(decimal: value).stringValue, at: index, catalog: catalog)
                            }
                        }.accessibilityLabel("Calculate")
                    }
                    Spacer()
                    Button("Done", action: finishTyping)
                }
            }
            .disabled(saving).interactiveDismissDisabled()
            .navigationDestination(item: $accountPostingID) { id in
                ShareAccountPicker(catalog: catalog, journalID: draft.journalID,
                    selected: draft.postings.first { $0.id == id }?.accountID) { choice in
                    if let index = draft.postings.firstIndex(where: { $0.id == id }) { draft.postings[index].accountID = choice }
                }
            }
            .alert("Couldn’t Save Transaction", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") { failure = nil }
            } message: { Text(failure ?? "") }
            .sheet(item: $preview) { item in
                NavigationStack {
                    SharedReceiptPreview(url: item.url).navigationTitle("Receipt").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview = nil }.accessibilityIdentifier("editor-receipt-preview-done") } }
                }
            }
        }
    }
    private func finishTyping() { focusedAmount = nil; textFocus = nil; ShareAmountKeyboard.field?.resignFirstResponder() }
    private func removePosting(_ id: UUID) {
        guard draft.postings.count > 2 else { return }
        finishTyping()
        if accountPostingID == id { accountPostingID = nil }
        draft.postings.removeAll { $0.id == id }
    }
    private func postingRow(_ posting: SharedTransaction.Posting) -> some View {
        let account = catalog.accounts.first { $0.id == posting.accountID }
        let amount = AmountExpressionEvaluator.evaluate(posting.amount) ?? 0
        let symbol = amount == 0 ? "circle.fill" : (amount < 0 ? "arrow.left.circle.fill" : "arrow.right.circle.fill")
        let index = draft.postings.firstIndex { $0.id == posting.id } ?? 0
        return HStack(spacing: 8) {
            Button { finishTyping(); accountPostingID = posting.id } label: {
                HStack(spacing: 9) {
                    Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(AppColors.color(account?.colorName ?? "gray"))
                    Text(account?.name ?? "Choose Account").foregroundStyle(.primary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).layoutPriority(1).accessibilityIdentifier("shared-transaction-account-\(index)")
            ShareAmountField(text: Binding(get: { draft.postings.first { $0.id == posting.id }?.amount ?? "" }, set: { value in
                if let index = draft.postings.firstIndex(where: { $0.id == posting.id }) { draft.setAmount(value, at: index, catalog: catalog) }
            }), focused: Binding(get: { focusedAmount == posting.id }, set: { active in
                if active { focusedAmount = posting.id; textFocus = nil }
                else if focusedAmount == posting.id { focusedAmount = nil }
            }), identifier: "shared-transaction-amount-\(index)")
                .frame(width: amountWidth).frame(minHeight: 32)
            Menu {
                Button("Account Currency") {
                    if let index = draft.postings.firstIndex(where: { $0.id == posting.id }) { draft.postings[index].currencyID = nil }
                }
                ForEach(catalog.currencies.filter { $0.journalID == draft.journalID }) { currency in
                    Button(currency.symbol) {
                        if let index = draft.postings.firstIndex(where: { $0.id == posting.id }) { draft.postings[index].currencyID = currency.id }
                    }
                }
            } label: {
                Text(catalog.currencies.first { $0.id == catalog.currencyID(for: posting, journalID: draft.journalID) }?.symbol ?? "Currency")
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75).frame(width: currencyWidth, alignment: .trailing)
            }.buttonStyle(.plain).tint(.secondary).accessibilityLabel("Currency")
                .accessibilityValue(catalog.currencies.first { $0.id == catalog.currencyID(for: posting, journalID: draft.journalID) }?.symbol ?? "Not selected")
                .accessibilityIdentifier("shared-transaction-currency-\(index)")
        }
    }
    private func balance() {
        guard let last = draft.postings.indices.last, let currency = catalog.currencyID(for: draft.postings[last], journalID: draft.journalID) else { return }
        var total: Decimal = 0
        for posting in draft.postings.dropLast() where catalog.currencyID(for: posting, journalID: draft.journalID) == currency {
            guard let amount = AmountExpressionEvaluator.evaluate(posting.amount) else { return }
            total += amount
        }
        draft.postings[last].amount = NSDecimalNumber(decimal: -total).stringValue
    }
    private struct ReceiptPreview: Identifiable { var url: URL; var id: URL { url } }
}

private struct ShareAccountPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    let catalog: SharedTransactionCatalog
    let journalID: UUID?
    let selected: UUID?
    let select: (UUID) -> Void
    @State private var search = ""
    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(AccountKind.allCases) { kind in
                    let rows = catalog.accountPickerNodes(journalID: journalID, kind: kind, search: search)
                    if !rows.isEmpty {
                        Section(kind.title) {
                            ForEach(rows) { node in
                                Button { dismissSearch(); select(node.id); dismiss() } label: {
                                    AccountSelectionLabel(account: node.account, depth: node.depth,
                                        currency: catalog.currencies.first { $0.id == node.account.commodityID }?.symbol ?? "",
                                        selected: selected == node.id)
                                }
                                .buttonStyle(.plain)
                                .id(node.id)
                                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .compactGroupedForm(sectionSpacing: 0)
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            .navigationTitle("Choose Account").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Find an account")
        }
    }
}

@MainActor
private enum ShareAmountKeyboard {
    static weak var field: UITextField?
    static func insert(_ symbol: String) {
        let value = ["÷": "/", "×": "*", "−": "-"][symbol] ?? symbol
        field?.insertText(value)
        field?.sendActions(for: .editingChanged)
    }
}
/// Keep the caret after the initial minus sign without using UIApplication
/// (which is unavailable inside a share extension).
private struct ShareAmountField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let identifier: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "0.00"
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .regular))
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = .right
        field.keyboardType = .decimalPad
        field.accessibilityLabel = "Amount"
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.accessibilityIdentifier = identifier
        if field.text != text { field.text = text }
        if !focused && field.isFirstResponder { field.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ShareAmountField
        init(_ parent: ShareAmountField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            // UIKit may finish positioning the caret after its focus callbacks.
            // Treat typing digits before the untouched seed as negative entry;
            // explicit selection/replacement or deletion still belongs to the user.
            if field.text == "-", range.location == 0, range.length == 0, !string.isEmpty,
               string.allSatisfy({ "0123456789.,".contains($0) }) {
                let value = "-" + string
                field.text = value; parent.text = value
                field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
                return false
            }
            return true
        }
        func textFieldDidBeginEditing(_ field: UITextField) {
            ShareAmountKeyboard.field = field
            parent.focused = true
            DispatchQueue.main.async { [weak field] in
                guard let field, field.isFirstResponder, field.text == "-" else { return }
                field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
            }
        }
        func textFieldDidEndEditing(_ field: UITextField) {
            if ShareAmountKeyboard.field === field { ShareAmountKeyboard.field = nil }
            parent.focused = false
        }
    }
}

private struct SharedReceiptPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
