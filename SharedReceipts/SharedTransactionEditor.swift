import SwiftUI
import QuickLook

struct SharedTransactionEditor: View {
    let catalog: SharedTransactionCatalog
    let receipts: [URL]
    let save: (SharedTransaction) async throws -> Void
    let cancel: () -> Void
    @State private var draft: SharedTransaction
    @State private var saving = false
    @State private var failure: String?
    @State private var preview: ReceiptPreview?
    @State private var focusedAmount: UUID?

    init(catalog: SharedTransactionCatalog, receipts: [URL],
         save: @escaping (SharedTransaction) async throws -> Void, cancel: @escaping () -> Void) {
        self.catalog = catalog; self.receipts = receipts; self.save = save; self.cancel = cancel
        _draft = State(initialValue: SharedTransaction(catalog: catalog))
    }

    private var validationMessage: String? {
        do { try draft.validate(in: catalog); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Journal", selection: Binding(get: { draft.journalID }, set: { draft.selectJournal($0, catalog: catalog) })) {
                        Text("Choose Journal").tag(UUID?.none)
                        ForEach(catalog.journals) { Text($0.name).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("incoming-journal-picker")
                }
                Section {
                    ForEach(Array(draft.postings.indices), id: \.self) { index in postingRow(index) }
                    HStack {
                        Button("Posting", systemImage: "plus.circle") {
                            draft.postings.append(.init(currencyID: draft.postings.first?.currencyID))
                        }.disabled(draft.postings.count >= 64)
                        Spacer()
                        Button("Balance") { balance() }
                    }
                }
                Section {
                    DatePicker("Date", selection: $draft.date, displayedComponents: [.date, .hourAndMinute])
                    TextField("Notes", text: $draft.note, axis: .vertical)
                    TextField("Payee", text: $draft.payee)
                    TextField("Number", text: $draft.number)
                    Toggle("Cleared", isOn: $draft.cleared)
                }
                Section("Receipts") {
                    ForEach(receipts, id: \.self) { url in
                        Button { preview = ReceiptPreview(url: url) } label: {
                            Label(url.lastPathComponent, systemImage: "doc.richtext").lineLimit(2)
                        }.accessibilityIdentifier("shared-transaction-receipt")
                    }
                }
                Section {
                    if let validationMessage { Text(validationMessage).foregroundStyle(.secondary) }
                } footer: {
                    Text("Save keeps this transaction and its receipts in Finances. It will be added to your journal and synced the next time Finances opens.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).accessibilityIdentifier("receipt-share-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        focusedAmount = nil; saving = true
                        Task { @MainActor in
                            do { try await save(draft) }
                            catch { failure = error.localizedDescription; saving = false }
                        }
                    } label: {
                        if saving { ProgressView() } else { Text("Save") }
                    }.disabled(validationMessage != nil || saving).accessibilityIdentifier("receipt-share-save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if let id = focusedAmount, let index = draft.postings.firstIndex(where: { $0.id == id }) {
                        Button("−/+") {
                            if let value = AmountExpressionEvaluator.evaluate(draft.postings[index].amount) {
                                draft.setAmount(NSDecimalNumber(decimal: -value).stringValue, at: index)
                            } else { draft.postings[index].amount = draft.postings[index].amount == "-" ? "" : "-" }
                        }.accessibilityLabel("Change amount sign")
                    }
                    Spacer()
                    Button("Done") { focusedAmount = nil }
                }
            }
            .disabled(saving).interactiveDismissDisabled()
            .alert("Couldn’t Save Transaction", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") { failure = nil }
            } message: { Text(failure ?? "") }
            .sheet(item: $preview) { item in
                NavigationStack {
                    SharedReceiptPreview(url: item.url)
                        .navigationTitle("Receipt").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview = nil }.accessibilityIdentifier("editor-receipt-preview-done") } }
                }
            }
        }
    }

    @ViewBuilder private func postingRow(_ index: Int) -> some View {
        VStack(spacing: 8) {
            Picker(index == 0 ? "From Account" : "To Account", selection: $draft.postings[index].accountID) {
                Text("Choose Account").tag(UUID?.none)
                ForEach(catalog.accounts.filter { $0.journalID == draft.journalID }) { Text($0.name).tag(Optional($0.id)) }
            }
            HStack {
                Picker("Currency", selection: $draft.postings[index].currencyID) {
                    ForEach(catalog.currencies.filter { $0.journalID == draft.journalID }) { Text($0.symbol).tag(Optional($0.id)) }
                }.labelsHidden().fixedSize()
                ShareAmountField(text: Binding(get: { draft.postings[index].amount }, set: { draft.setAmount($0, at: index) }),
                    focused: Binding(get: { focusedAmount == draft.postings[index].id }, set: { focusedAmount = $0 ? draft.postings[index].id : nil }),
                    identifier: "shared-transaction-amount-\(index)")
                    .frame(minHeight: 32)
                if draft.postings.count > 2 {
                    Button("Remove Posting", systemImage: "minus.circle", role: .destructive) { draft.postings.remove(at: index) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        }
    }

    private func balance() {
        guard let last = draft.postings.indices.last, let currency = draft.postings[last].currencyID else { return }
        var total: Decimal = 0
        for posting in draft.postings.dropLast() where posting.currencyID == currency {
            guard let amount = AmountExpressionEvaluator.evaluate(posting.amount) else { return }
            total += amount
        }
        draft.postings[last].amount = NSDecimalNumber(decimal: -total).stringValue
    }
    private struct ReceiptPreview: Identifiable { var url: URL; var id: URL { url } }
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
        field.placeholder = "Amount"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = .right
        field.keyboardType = .numbersAndPunctuation
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
        func textFieldDidBeginEditing(_ field: UITextField) {
            parent.focused = true
            DispatchQueue.main.async { [weak field] in
                guard let field, field.isFirstResponder, field.text == "-" else { return }
                field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
            }
        }
        func textFieldDidEndEditing(_ field: UITextField) { parent.focused = false }
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
