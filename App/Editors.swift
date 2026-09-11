import SwiftUI
import UIKit

enum TransactionEditorField: Hashable {
    case amount(UUID), notes, payee, number
}

extension TransactionDraft {
    /// Seed a sign once when opening a new, empty amount. Subsequent edits,
    /// including deleting the sign, belong entirely to the user.
    var preparedForAmountEntry: TransactionDraft {
        guard id == nil, !isDuplicate else { return self }
        var editable = self
        for index in editable.postings.indices {
            let text = editable.postings[index].amount
            if text.isEmpty || decimalFromInput(text) == 0 {
                editable.postings[index].amount = index == 0 ? "-" : ""
            }
        }
        return editable
    }
}

@MainActor
enum AmountKeyboardInput {
    static func insertOperator(_ symbol: String) {
        // Use the active field's native selection/caret and editing events so
        // SwiftUI updates the draft and its balancing posting just as typing does.
        UIApplication.shared.sendAction(#selector(UIKeyInput.insertText(_:)), to: nil,
            from: symbol == "−" ? "-" : symbol, for: nil)
    }

    static func moveAfterLoneSign() {
        UIApplication.shared.sendAction(#selector(UIResponder.moveAfterLoneAmountSign), to: nil, from: nil, for: nil)
    }

    static func togglingSign(of text: String) -> String? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "": return "-"
        case "-", "−": return ""
        default: return decimalFromInput(text).map { decimalInputString(-$0) }
        }
    }
}

extension UIResponder {
    @objc fileprivate func moveAfterLoneAmountSign() {
        guard let field = self as? UITextField, field.text == "-", field.selectedTextRange?.isEmpty == true else { return }
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
    }
}

/// Keep account selection in the original transaction sheet, without briefly
/// presenting the detailed editor or its amount keyboard underneath the picker.
struct TemplateTransactionEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let scanInvoice: Bool
    @State private var draft: TransactionDraft
    @State private var accountPostingIDs: [UUID]

    init(title: String, initialDraft: TransactionDraft, accountPostingIDs: [UUID], scanInvoice: Bool) {
        self.title = title
        self.scanInvoice = scanInvoice
        _draft = State(initialValue: initialDraft)
        _accountPostingIDs = State(initialValue: accountPostingIDs)
    }

    var body: some View {
        NavigationStack {
            if let postingID = accountPostingIDs.first,
               let index = draft.postings.firstIndex(where: { $0.id == postingID }) {
                AccountPickerScreen(ledgerID: draft.ledgerID, selected: $draft.postings[index].accountID,
                    onSelection: { accountID in
                        guard accountPostingIDs.first == postingID,
                              let index = draft.postings.firstIndex(where: { $0.id == postingID }) else { return }
                        withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) {
                            draft.postings[index].accountID = accountID
                            _ = accountPostingIDs.removeFirst()
                        }
                    })
                    .id(postingID)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    }
                    .transition(.opacity)
            } else {
                TransactionEditorView(title: title, initialDraft: draft, scanInvoice: scanInvoice)
                    .transition(.opacity)
            }
        }
    }
}

struct TransactionEditorView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    var title: String
    private let initialDraft: TransactionDraft
    private let scanInvoice: Bool
    @State private var draft: TransactionDraft
    @FocusState private var focusedField: TransactionEditorField?
    @State private var accountPostingID: UUID?
    @State private var showingRecurringSaveScope = false
    @State private var hasAppliedInitialFocus = false
    @State private var showingDatePicker = false

    init(title: String, initialDraft: TransactionDraft, scanInvoice: Bool = false) {
        self.title = title
        self.initialDraft = initialDraft
        self.scanInvoice = scanInvoice
        _draft = State(initialValue: initialDraft.preparedForAmountEntry)
    }

    private var focusedAmountID: UUID? {
        if case .amount(let id) = focusedField { return id }
        return nil
    }

    private var recurrencePolicy: RecurringTransactionEditPolicy {
        RecurringTransactionEditPolicy(
            initialDraft: initialDraft, editedDraft: draft,
            anchorID: initialDraft.recurrenceRuleID.flatMap { store.recurrenceAnchorID(ruleID: $0) }
        )
    }

    var body: some View {
        FinanceForm(spacing: 0) {
            VStack(spacing: 7) {
                FinanceFormCard {
                    ForEach($draft.postings) { $posting in
                        FinanceFormRow(last: posting.id == draft.postings.last?.id) {
                            PostingEditorRow(posting: $posting, ledgerID: draft.ledgerID, focusedField: $focusedField, canRemove: draft.postings.count > 2,
                                changeAmount: { text in
                                    if let index = draft.postings.firstIndex(where: { $0.id == posting.id }) { updateAmount(text, at: index) }
                                }, chooseAccount: { focusedField = nil; accountPostingID = posting.id }) {
                                    withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) {
                                        draft.postings.removeAll { $0.id == posting.id }
                                    }
                                }
                        }
                        .transition(.opacity)
                    }
                }
                HStack {
                    Button {
                        withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) {
                            draft.postings.append(PostingDraft(accountID: store.leafAccountNodes(ledgerID: draft.ledgerID).first?.account.id, amount: ""))
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
                    }
                    .accessibilityLabel("Posting")
                    Spacer()
                    Button("Balance") { balanceLastPosting() }.font(.footnote).foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .frame(height: 28)
            }
            .padding(.bottom, 32)

            FinanceFormCard {
                FinanceFormRow {
                    Button {
                        hasAppliedInitialFocus = true
                        focusedField = nil
                        withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) {
                            showingDatePicker.toggle()
                        }
                    } label: {
                        FinanceFormLabel(title: "Date", value: compactTransactionDate(draft.date), chevron: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("transaction-date-toggle")
                    .accessibilityLabel("Date")
                    .accessibilityValue(compactTransactionDate(draft.date))
                    .accessibilityHint(showingDatePicker ? "Collapse date picker" : "Expand date picker")
                }
                if showingDatePicker {
                    DatePicker("Date", selection: $draft.date, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Divider().padding(.leading, 20) }
                        .accessibilityIdentifier("transaction-date-picker")
                        .transition(.opacity)
                }
                FinanceFormRow {
                    VStack(alignment: .leading, spacing: 2) {
                        if !draft.note.isEmpty { Text("Notes").font(.caption).foregroundStyle(.secondary) }
                        TextField("Notes", text: $draft.note, axis: .vertical).accessibilityLabel("Notes").focused($focusedField, equals: .notes)
                    }
                    .frame(minHeight: draft.note.isEmpty ? 0 : 44, alignment: .leading)
                }
                FinanceFormRow { TextField("Payee", text: $draft.payee).textInputAutocapitalization(.words).focused($focusedField, equals: .payee) }
                FinanceFormRow(last: true) { TextField("Number", text: $draft.number).focused($focusedField, equals: .number) }
            }
            .padding(.bottom, 40)

            FinanceFormCard {
                FinanceFormRow {
                    NavigationLink {
                        RepeatFrequencyEditor(draft: $draft)
                    } label: { FinanceFormLabel(title: "Repeat", value: repeatDescription(draft)) }
                    .buttonStyle(.plain)
                    .disabled(!recurrencePolicy.canEditRepeatSettings)
                }
                if draft.repeatFrequency != .never {
                    FinanceFormRow {
                        NavigationLink {
                            RepeatEndEditor(draft: $draft)
                        } label: { FinanceFormLabel(title: "End Repeat", value: repeatEndDescription(draft)) }
                        .buttonStyle(.plain)
                        .disabled(!recurrencePolicy.canEditRepeatSettings)
                    }
                }
                FinanceFormRow(last: true) { Toggle("Cleared", isOn: $draft.cleared) }
            }
            .padding(.bottom, 40)
            if !recurrencePolicy.canEditRepeatSettings {
                Text("Repeat settings belong to the first entry in this series.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            FinanceFormCard {
                ForEach(draft.attachments) { asset in
                    FinanceFormRow {
                        HStack {
                            Text(asset.originalFilename).lineLimit(1)
                            Spacer()
                            Button("Remove Attachment", systemImage: "minus.circle", role: .destructive) {
                                draft.attachments.removeAll { $0.id == asset.id }
                            }.labelStyle(.iconOnly)
                        }
                    }
                }
                FinanceFormRow(last: true) { ReceiptPicker(assets: $draft.attachments, textOnly: true, startWithScan: scanInvoice) }
            }
        }
        .navigationDestination(item: $accountPostingID) { id in
            if let index = draft.postings.firstIndex(where: { $0.id == id }) {
                AccountPickerScreen(ledgerID: draft.ledgerID, selected: $draft.postings[index].accountID)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if initialDraft.recurrenceRuleID != nil {
                        showingRecurringSaveScope = true
                    } else {
                        save(scope: .occurrence)
                    }
                }
                .disabled(draft.postings.count < 2 || draft.postings.contains { $0.accountID == nil || decimalFromInput($0.amount) == nil } || !draft.postings.contains { (decimalFromInput($0.amount) ?? 0) != 0 })
            }
            ToolbarItem(placement: .keyboard) {
                AmountKeyboardToolbar(showOperators: focusedAmountID != nil,
                    negate: { calculate(negate: true) }, insertOperator: insertOperator,
                    calculate: { calculate() }, done: { focusedField = nil })
            }

        }
        .task {
            guard initialDraft.id == nil, !scanInvoice, !hasAppliedInitialFocus else { return }
            hasAppliedInitialFocus = true
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard focusedField == nil, accountPostingID == nil, !showingDatePicker else { return }
            focusedField = draft.postings.first.map { .amount($0.id) }
        }
        .onChange(of: focusedField) { _, field in
            if field != nil && showingDatePicker {
                withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) {
                    showingDatePicker = false
                }
            }
        }
        .confirmationDialog(
            recurrencePolicy.requiresScheduleConfirmation ? "Update repeating schedule" : "Save recurring transaction changes",
            isPresented: $showingRecurringSaveScope,
            titleVisibility: .visible
        ) {
            if recurrencePolicy.requiresScheduleConfirmation {
                Button("Update Repeating Schedule") { save(scope: .future) }
            } else {
                Button("This Occurrence Only") { save(scope: .occurrence) }
                Button("This and Future Occurrences") { save(scope: .future) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(recurrencePolicy.requiresScheduleConfirmation
                ? "Changing the first entry's date or Repeat settings updates the repeating series and regenerates later occurrences."
                : "Choose whether to update only this entry or this entry and later entries in the same series. Other occurrence dates, receipts, and cleared status remain unchanged.")
        }
        .alert("Couldn’t Save Transaction", isPresented: Binding(get: { store.validationError != nil }, set: { if !$0 { store.validationError = nil } })) {
            Button("OK") { store.validationError = nil }
        } message: { Text(store.validationError?.message ?? "") }

    }

    private func updateAmount(_ value: String, at index: Int) {
        draft = PostingBalance.settingAmount(value, at: index, in: draft, accounts: store.data.accounts, commodities: store.data.commodities)
    }

    private func insertOperator(_ symbol: String) {
        guard focusedAmountID != nil else { return }
        AmountKeyboardInput.insertOperator(symbol)
    }

    private func calculate(negate: Bool = false) {
        guard let index = draft.postings.firstIndex(where: { $0.id == focusedAmountID }) else { return }
        let text = draft.postings[index].amount
        let result = negate ? AmountKeyboardInput.togglingSign(of: text)
            : decimalFromInput(text).map(decimalInputString)
        guard let result else { return }
        updateAmount(result, at: index)
    }

    private func save(scope: RecurringJournalEditor.Scope) {
        store.saveTransactionAndFlush(draft, scope: scope)
        guard store.validationError == nil else { return }
        dismiss()
    }

    private func balanceLastPosting() {
        do {
            let amount = try PostingBalance.amount(forLastPostingIn: draft, accounts: store.data.accounts, commodities: store.data.commodities)
            draft.postings[draft.postings.count - 1].amount = decimalInputString(amount)
        } catch { store.validationError = ValidationError(message: error.localizedDescription) }
    }

}

private struct AmountKeyboardToolbar: View {
    let showOperators: Bool
    let negate: () -> Void
    let insertOperator: (String) -> Void
    let calculate: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            if showOperators {
                key("±", highlighted: true, action: negate)
                ForEach(["÷", "×", "−", "+"], id: \.self) { symbol in
                    key(symbol) { insertOperator(symbol) }
                }
                key("=", highlighted: true, action: calculate)
            } else { Spacer() }
            Button(action: done) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 20)).frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Done")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func key(_ symbol: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol).font(.system(size: 26, weight: .medium))
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .background(highlighted ? Color.blue : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("amount-key-\(symbol)")
    }
}

struct PostingEditorRow: View {
    @ScaledMetric(relativeTo: .body) private var amountWidth: CGFloat = 82
    @ScaledMetric(relativeTo: .body) private var currencyWidth: CGFloat = 38
    @EnvironmentObject private var store: MobileLedgerStore
    @Binding var posting: PostingDraft
    let ledgerID: UUID?
    var focusedField: FocusState<TransactionEditorField?>.Binding
    let canRemove: Bool
    let changeAmount: (String) -> Void
    let chooseAccount: () -> Void
    let remove: () -> Void

    private var postingSymbol: String {
        let amount = decimalFromInput(posting.amount) ?? 0
        return amount == 0 ? "circle.fill" : (amount < 0 ? "arrow.left.circle.fill" : "arrow.right.circle.fill")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: chooseAccount) {
                HStack(spacing: 9) {
                    Image(systemName: postingSymbol)
                        .font(.system(size: 22))
                        .foregroundStyle(AppColors.color(store.account(posting.accountID)?.colorName ?? "gray"))
                    Text(store.account(posting.accountID)?.name ?? "Choose Account")
                        .foregroundStyle(.primary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            TextField("0.00", text: Binding(get: { posting.amount }, set: { value in changeAmount(value) }))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .focused(focusedField, equals: .amount(posting.id))
                .frame(width: amountWidth).monospacedDigit()
                .accessibilityLabel("Amount for \(store.account(posting.accountID)?.name ?? "account")")
                .simultaneousGesture(TapGesture().onEnded {
                    guard posting.amount == "-" else { return }
                    // Let UITextField finish placing its caret before correcting
                    // a tap on an otherwise empty amount's default sign.
                    DispatchQueue.main.async { AmountKeyboardInput.moveAfterLoneSign() }
                })
            Menu {
                Button("Account Currency") { posting.commodityID = nil }
                ForEach(ledgerID.map { store.commodities(for: $0) } ?? []) { currency in
                    Button(currency.symbol) { posting.commodityID = currency.id }
                }
            } label: {
                Text(store.symbol(for: posting.commodityID ?? store.account(posting.accountID)?.commodityID, ledgerID: ledgerID))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: currencyWidth, alignment: .trailing)
            }
            .tint(.secondary)
            .accessibilityLabel("Currency")
        }
        .contextMenu {
            if canRemove { Button("Remove Posting", role: .destructive, action: remove) }
        }
    }

}

struct AccountPickerScreen: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let ledgerID: UUID?
    @Binding var selected: UUID?
    var onSelection: ((UUID) -> Void)? = nil
    @State private var search = ""
    @State private var creating = false
    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(AccountKind.allCases) { kind in
                    let rows = options(for: kind)
                    if !rows.isEmpty {
                        Section(kind.title) {
                            ForEach(rows) { node in
                                AccountPickerChoice(node: node, selected: $selected, onSelection: onSelection)
                                    .id(node.id)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .compactGroupedForm(sectionSpacing: 0)
            .onAppear {
                guard let account = store.account(selected), account.ledgerID == ledgerID else { return }
                let target = account.isGroup ? options(for: account.kind).first?.id : account.id
                if let target { proxy.scrollTo(target, anchor: .center) }
            }
            .searchable(text: $search, prompt: "Find an account")
            .navigationTitle("Choose Account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("New Account", systemImage: "plus") { creating = true } } }
            .sheet(isPresented: $creating) { AccountEditorView(initialDraft: ledgerID.map { store.newAccountDraft(ledgerID: $0) } ?? store.draft(for: nil)) }
        }
    }
    private func options(for kind: AccountKind) -> [MobileAccountNode] {
        store.accountNodes(kind: kind, ledgerID: ledgerID).filter { node in
            node.account.parentID != nil && (search.isEmpty || node.account.name.localizedCaseInsensitiveContains(search) || node.account.note.localizedCaseInsensitiveContains(search))
        }
    }

}

struct AccountEditorView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MobileAccountDraft

    init(initialDraft: MobileAccountDraft) {
        var editable = initialDraft
        if initialDraft.id == nil { editable.name = "" }
        _draft = State(initialValue: editable)
    }

    private var groupName: String {
        if draft.isGroup { return "No Group" }
        if let parent = store.account(draft.parentID) { return parent.name }
        return draft.ledgerID.flatMap { id in store.accounts(for: id).first { $0.parentID == nil && $0.kind == draft.kind }?.name } ?? draft.kind.title
    }

    var body: some View {
        NavigationStack {
            FinanceForm(spacing: 36) {
                FinanceFormCard {
                    FinanceFormRow { TextField("Name", text: $draft.name) }
                    FinanceFormRow(last: true) { TextField("Description", text: $draft.note, axis: .vertical) }
                }
                FinanceFormCard {
                    FinanceFormRow {
                        NavigationLink {
                            AccountGroupPicker(draft: $draft)
                        } label: { FinanceFormLabel(title: "Group In", value: groupName) }
                        .buttonStyle(.plain)
                    }
                    FinanceFormRow(last: true) {
                        NavigationLink {
                            AccountCurrencyPicker(draft: $draft)
                        } label: { FinanceFormLabel(title: "Currency", value: draft.commodityID.flatMap { store.commodity($0)?.name } ?? "") }
                        .buttonStyle(.plain)
                    }
                }
                FinanceFormCard {
                    ForEach(AppColors.names, id: \.self) { name in
                        FinanceFormRow(last: name == AppColors.names.last, separatorLeading: 58) {
                            Button { draft.colorName = name } label: {
                                HStack(spacing: 16) {
                                    Circle().fill(AppColors.color(name)).frame(width: 22, height: 22)
                                    Text(AppColors.displayName(name)).foregroundColor(Color(uiColor: .label))
                                    Spacer()
                                    if draft.colorName == name { Image(systemName: "checkmark").fontWeight(.semibold).foregroundColor(.blue) }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(draft.id == nil ? "New Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .journalEditorValidation()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveAccount(draft)
                        if store.validationError == nil {
                            do { try store.flushLocalChanges(); dismiss() }
                            catch { store.validationError = ValidationError(message: error.localizedDescription) }
                        }
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

        }
    }
}

struct CurrencyEditorView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CurrencyDraft

    init(initialDraft: CurrencyDraft) {
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            FinanceForm {
                FinanceFormCard {
                    FinanceFormRow {
                        NavigationLink {
                            CurrencyCatalogPicker(selectedName: Binding(get: { draft.name }, set: { draft.name = $0; draft.syncFromCatalogName() }))
                        } label: { FinanceFormLabel(title: "Currency", value: draft.name) }
                        .buttonStyle(.plain)
                    }
                    FinanceFormRow { TextField("Symbol", text: $draft.symbol).textInputAutocapitalization(.characters) }
                    FinanceFormRow(last: true) { TextField("Name", text: $draft.name) }
                }
            }
            .navigationTitle(draft.id == nil ? "New Currency" : "Edit Currency")
            .navigationBarTitleDisplayMode(.inline)
            .journalEditorValidation()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveCurrency(draft)
                        if store.validationError == nil {
                            do { try store.flushLocalChanges(); dismiss() }
                            catch { store.validationError = ValidationError(message: error.localizedDescription) }
                        }
                    }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

enum JournalEditorMode {
    case create
    case rename(Ledger)
}

struct JournalEditorView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.dismiss) private var dismiss
    var mode: JournalEditorMode
    @State private var name: String
    @State private var currencyName = "US Dollar"
    @State private var template = "Personal"

    init(mode: JournalEditorMode) {
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "")
        case .rename(let ledger):
            _name = State(initialValue: ledger.name)
        }
    }

    var body: some View {
        NavigationStack {
            FinanceForm(spacing: 0, topInset: 4) {
                FinanceFormCard {
                    FinanceFormRow(last: true) { TextField("Name", text: $name) }
                }
                .padding(.bottom, 40)
                if case .create = mode {
                    FinanceFormCard {
                        FinanceFormRow(last: true) {
                            NavigationLink {
                                CurrencyCatalogPicker(selectedName: $currencyName)
                            } label: { FinanceFormLabel(title: "Currency", value: currencyName) }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 36)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TEMPLATES").font(.footnote).foregroundStyle(.secondary).padding(.leading, 16)
                        FinanceFormCard {
                            ForEach(["Personal", "Business"], id: \.self) { option in
                                FinanceFormRow(last: option == "Business") {
                                    Button { template = option } label: {
                                        HStack {
                                            Text(option).foregroundStyle(.primary)
                                            Spacer()
                                            if template == option { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .journalEditorValidation()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        switch mode {
                        case .create:
                            store.addJournal(name: name, currencyName: currencyName, template: template)
                        case .rename(let ledger):
                            store.renameJournal(ledger.id, name: name)
                        }
                        if store.validationError == nil {
                            do { try store.flushLocalChanges(); dismiss() }
                            catch { store.validationError = ValidationError(message: error.localizedDescription) }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var title: String {
        switch mode {
        case .create: "New Journal"
        case .rename: "Rename Journal"
        }
    }
}

struct TemplateEditorView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TransactionTemplateDraft
    @State private var showingDeleteConfirmation = false

    init(initialDraft: TransactionTemplateDraft) {
        var editable = initialDraft
        if initialDraft.id == nil { editable.name = "" }
        _draft = State(initialValue: editable)
    }

    var body: some View {
        NavigationStack {
            FinanceForm {
                FinanceFormCard {
                    FinanceFormRow(last: true) { TextField("Name", text: $draft.name) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("POSTINGS").font(.footnote).foregroundStyle(.secondary).padding(.leading, 16)
                    FinanceFormCard {
                        ForEach($draft.postings) { $posting in
                            FinanceFormRow(last: posting.id == draft.postings.last?.id) {
                                HStack {
                                    NavigationLink {
                                        AccountPickerScreen(ledgerID: draft.ledgerID, selected: $posting.accountID)
                                    } label: { FinanceFormLabel(title: "Account", value: store.account(posting.accountID)?.name ?? "Choose Account") }
                                    .buttonStyle(.plain)
                                    if draft.postings.count > 2 {
                                        Button("Remove Posting", systemImage: "minus.circle", role: .destructive) {
                                            withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) {
                                                draft.postings.removeAll { $0.id == posting.id }
                                            }
                                        }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.red)
                                    }
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    Button {
                        withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) {
                            draft.postings.append(PostingTemplateDraft(accountID: store.leafAccountNodes(ledgerID: draft.ledgerID).first?.id))
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Posting").padding(.leading, 8)
                }
                FinanceFormCard {
                    FinanceFormRow { TextField("Payee", text: $draft.payee) }
                    FinanceFormRow { TextField("Note", text: $draft.note, axis: .vertical) }
                    FinanceFormRow { Toggle("Cleared", isOn: $draft.cleared) }
                    FinanceFormRow(last: true) { Toggle("Scan Invoice", isOn: $draft.scanInvoice) }
                }
                if draft.id != nil {
                    FinanceFormCard {
                        FinanceFormRow(last: true) {
                            Button("Delete", role: .destructive) { showingDeleteConfirmation = true }
                                .foregroundStyle(.red).accessibilityLabel("Delete Template")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .confirmationDialog("Delete this template permanently?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Template", role: .destructive) {
                    guard let id = draft.id else { return }
                    store.deleteTransactionTemplate(id)
                    guard store.validationError == nil else { return }
                    do { try store.flushLocalChanges(); dismiss() }
                    catch { store.validationError = ValidationError(message: error.localizedDescription) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .navigationTitle(draft.id == nil ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .journalEditorValidation()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveTransactionTemplate(draft)
                        if store.validationError == nil {
                            do { try store.flushLocalChanges(); dismiss() }
                            catch { store.validationError = ValidationError(message: error.localizedDescription) }
                        }
                    }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}


private struct JournalEditorValidation: ViewModifier {
    @EnvironmentObject private var store: MobileLedgerStore
    func body(content: Content) -> some View {
        content.alert("Couldn’t Save", isPresented: Binding(get: { store.validationError != nil }, set: { if !$0 { store.validationError = nil } })) {
            Button("OK") { store.validationError = nil }
        } message: { Text(store.validationError?.message ?? "") }
    }
}

private extension View {
    func journalEditorValidation() -> some View { modifier(JournalEditorValidation()) }
}

private struct AccountPickerChoice: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    let node: MobileAccountNode
    @Binding var selected: UUID?
    var onSelection: ((UUID) -> Void)? = nil
    var body: some View {
        Button {
            dismissSearch()
            if let onSelection {
                onSelection(node.id)
            } else {
                selected = node.id
                dismiss()
            }
        } label: {
            AccountSelectionLabel(account: node.account, depth: max(node.depth - 1, 0), currency: currencySymbol, selected: selected == node.id)
        }.buttonStyle(.plain)
    }

    private var currencySymbol: String {
        node.account.commodityID.flatMap { store.commodity($0)?.symbol } ?? store.commodities(for: node.account.ledgerID).first?.symbol ?? ""
    }
}
