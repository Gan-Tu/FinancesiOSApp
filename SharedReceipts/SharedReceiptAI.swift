import SwiftUI

typealias SharedReceiptAnalyzer = @MainActor (SharedTransaction, SharedTransactionCatalog, [URL]) async throws -> ReceiptAnalysisResponse

@MainActor
enum SharedReceiptAnalysis {
    #if DEBUG
    static let syntheticEndpoint = "https://synthetic-share-receipt.invalid"
    static func syntheticCredential() throws -> ReceiptSessionCredential {
        let payload = try JSONSerialization.data(withJSONObject: ["exp": Date().addingTimeInterval(3600).timeIntervalSince1970])
            .base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return try ReceiptSessionCredential(token: "synthetic.\(payload).fixture")
    }
    static func synthetic(_ draft: SharedTransaction, _ catalog: SharedTransactionCatalog, _ receipts: [URL]) async throws -> ReceiptAnalysisResponse {
        guard SharedReceiptStorage.usesDemoInbox, SharedReceiptStorage.demoAIBehavior != "disabled" else {
            throw AssistError.message("Receipt AI is disabled in this synthetic demo.")
        }
        guard let credential = try ReceiptKeychainStore().load(endpoint: syntheticEndpoint), credential.token.hasPrefix("synthetic.") else {
            throw AssistError.message("Synthetic shared sign-in was not available to the extension.")
        }
        try await Task.sleep(for: .milliseconds(500))
        if SharedReceiptStorage.demoAIBehavior == "failure" { throw AssistError.message("Synthetic receipt service is offline. Try again.") }
        let accounts = catalog.accounts.filter { $0.journalID == draft.journalID }
        let source = accounts.first { $0.kind == 0 }, counter = accounts.first { $0.kind == 3 }
        let currency = source?.currencyID ?? catalog.currencies.first { $0.journalID == draft.journalID }?.id
        return ReceiptAnalysisResponse(suggestion: .init(date: nil, payee: "QA Receipt Cafe", note: "Coffee and pastry", invoiceNumber: "QA-123", orderNumber: nil,
            postings: [.init(accountID: source?.id, commodityID: currency, amount: "-18.75", role: "source"),
                       .init(accountID: counter?.id, commodityID: currency, amount: "18.75", role: "counter")], warnings: []), postingsApplicable: true)
    }
    #endif
    static func analyze(_ draft: SharedTransaction, catalog: SharedTransactionCatalog, receipts: [URL]) async throws -> ReceiptAnalysisResponse {
        guard !catalog.locked, let journalID = draft.journalID,
              catalog.journals.contains(where: { $0.id == journalID }), let context = catalog.receiptAI else {
            throw AssistError.message("Open Finances once to load Receipt AI settings, then share again.")
        }
        if let reason = context.unavailableReason { throw AssistError.message(reason) }
        let client = ReceiptAnalysisClient()
        try await client.validateSharedAccountScope(context.accountScope)
        let assets = try receipts.map { url -> (AttachmentAsset, URL) in
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return (AttachmentAsset(originalFilename: url.lastPathComponent, storedPath: url.path,
                sizeBytes: Int64(bytes)), url)
        }
        return try await client.analyze(draft: draft.draft(operationID: UUID()), ledgerID: journalID,
            accounts: catalog.nativeAccounts(journalID: journalID), commodities: catalog.nativeCurrencies(journalID: journalID),
            metadata: context.metadata, assets: assets, settings: context.settings)
    }
}

/// Uses the same validation and edit-protection policy as the full app editor.
enum SharedReceiptAutofill {
    static func proposal(_ response: ReceiptAnalysisResponse, catalog: SharedTransactionCatalog, journalID: UUID) throws -> ReceiptDraftProposal {
        try ReceiptDraftProposal.make(response, accounts: catalog.nativeAccounts(journalID: journalID),
                                      commodities: catalog.nativeCurrencies(journalID: journalID))
    }
    static func apply(_ proposal: ReceiptDraftProposal, to draft: inout SharedTransaction,
                      initial: TransactionDraft, protected: Set<ReceiptProposalField>) -> [ReceiptProposalField] {
        var native = draft.draft(operationID: UUID())
        var guarded = protected
        if !initial.note.isEmpty { guarded.insert(.note) }
        if !initial.payee.isEmpty { guarded.insert(.payee) }
        if !initial.number.isEmpty { guarded.insert(.number) }
        let replacements = proposal.autofill(&native, initial: initial, protected: guarded)
        draft.apply(native)
        return replacements
    }
}

struct SharedReceiptAISection: View {
    @Binding var draft: SharedTransaction
    @Binding var busy: Bool
    let catalog: SharedTransactionCatalog
    let receipts: [URL]
    let analyzeReceipt: SharedReceiptAnalyzer
    @State private var initial: TransactionDraft
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var error = ""
    @State private var proposal: ReceiptDraftProposal?
    @State private var replacements: [ReceiptProposalField] = []
    @State private var protected: Set<ReceiptProposalField> = []
    @State private var automatic: SharedTransaction?
    @State private var reviewed: SharedTransaction?
    @State private var warnings: [String] = []

    init(draft: Binding<SharedTransaction>, busy: Binding<Bool>, catalog: SharedTransactionCatalog,
         receipts: [URL], analyzeReceipt: @escaping SharedReceiptAnalyzer) {
        _draft = draft; _busy = busy; self.catalog = catalog; self.receipts = receipts; self.analyzeReceipt = analyzeReceipt
        _initial = State(initialValue: draft.wrappedValue.draft(operationID: UUID()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(busy ? "Analyzing…" : "Auto-fill from receipt", systemImage: "sparkles", action: analyze)
                    .disabled(busy || receipts.isEmpty).accessibilityIdentifier("share-receipt-ai")
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: stop).accessibilityIdentifier("share-receipt-ai-cancel")
                }
            }
            if let settings = catalog.receiptAI?.settings {
                Text("\(settings.model) · \(settings.effort)").font(.caption).foregroundStyle(.secondary)
            }
            if let proposal {
                ForEach(replacements) { field in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(field.title).fontWeight(.semibold)
                            Spacer()
                            Button("Replace") { replace(field, proposal: proposal) }
                                .accessibilityIdentifier("share-receipt-replace-\(field.rawValue)")
                        }
                        Text("Current: \(text(field, draft))").foregroundStyle(.secondary)
                        Text("Suggested: \(suggested(field, proposal))")
                    }.font(.caption)
                }
                if replacements.isEmpty {
                    Text("Receipt fields filled. Save when ready.").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("share-receipt-ai-filled")
                }
            }
            ForEach(Array(warnings.prefix(3).enumerated()), id: \.offset) { _, warning in
                Text(warning).font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("share-receipt-ai-error") }
        }
        .onChange(of: draft) { old, new in
            if new == automatic { automatic = nil; return }
            let before = old.draft(operationID: UUID()), after = new.draft(operationID: UUID())
            for field in ReceiptProposalField.allCases where !ReceiptDraftProposal.equal(field, before, after) { protected.insert(field) }
        }
        .onDisappear(perform: stop)
    }

    private func analyze() {
        let baseline = draft
        let stamp = UUID(); generation = stamp
        busy = true; error = ""; proposal = nil; replacements = []; warnings = []
        task = Task { @MainActor in
            defer { if generation == stamp { busy = false } }
            do {
                let response = try await analyzeReceipt(baseline, catalog, receipts)
                try Task.checkCancellation()
                guard generation == stamp, draft.journalID == baseline.journalID, let id = baseline.journalID else { return }
                var next = try SharedReceiptAutofill.proposal(response, catalog: catalog, journalID: id)
                var updated = draft
                replacements = SharedReceiptAutofill.apply(next, to: &updated, initial: initial, protected: protected)
                if replacements.contains(.postings) {
                    next.keepCurrentAccountsForReview(response: response, current: updated.draft(operationID: UUID()),
                        accounts: catalog.nativeAccounts(journalID: id))
                }
                automatic = updated; draft = updated; reviewed = updated; proposal = next
                warnings = Array(Set(response.suggestion.warnings)).sorted()
            } catch is CancellationError { }
            catch { if generation == stamp && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func stop() { task?.cancel(); generation = UUID(); busy = false }
    private func replace(_ field: ReceiptProposalField, proposal: ReceiptDraftProposal) {
        guard let reviewed, ReceiptDraftProposal.equal(field, draft.draft(operationID: UUID()), reviewed.draft(operationID: UUID())) else {
            error = "This field changed. Review its current value before replacing."; self.reviewed = draft; return
        }
        var native = draft.draft(operationID: UUID())
        proposal.apply(field, to: &native)
        var updated = draft; updated.apply(native)
        automatic = updated; draft = updated; self.reviewed = updated
        replacements.removeAll { $0 == field }; error = ""
    }
    private func suggested(_ field: ReceiptProposalField, _ proposal: ReceiptDraftProposal) -> String {
        var native = draft.draft(operationID: UUID()); proposal.apply(field, to: &native)
        var value = draft; value.apply(native); return text(field, value)
    }
    private func text(_ field: ReceiptProposalField, _ value: SharedTransaction) -> String {
        switch field {
        case .date: value.date.formatted(date: .abbreviated, time: .shortened)
        case .note: value.note.isEmpty ? "Empty" : value.note
        case .payee: value.payee.isEmpty ? "Empty" : value.payee
        case .number: value.number.isEmpty ? "Empty" : value.number
        case .postings: value.postings.map { posting in
            let name = catalog.accounts.first { $0.id == posting.accountID }?.name ?? "Choose Account"
            let currency = catalog.currencies.first { $0.id == posting.currencyID }?.symbol ?? ""
            return "\(name): \(posting.amount) \(currency)"
        }.joined(separator: "\n")
        }
    }
}
