import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

struct PaymentIdentityEditor: View {
    let accountID: UUID
    let ledgerID: UUID
    @ObservedObject private var store = PaymentMetadataStore.shared
    @State private var identities: [PaymentIdentity] = []
    @State private var original: PaymentAccountMetadata?
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cards").font(.headline)
                Spacer()
                Button("Add card", systemImage: "plus") { identities.append(PaymentIdentity()) }
            }
            ForEach($identities) { $identity in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Card label", text: $identity.label)
                    HStack {
                        Picker(
                            "Network",
                            selection: Binding(
                                get: { identity.network ?? "" },
                                set: { identity.network = $0.isEmpty ? nil : $0 })
                        ) {
                            Text("Unspecified / store card").tag("")
                            ForEach(PaymentIdentity.networks, id: \.self) {
                                Text($0 == "amex" ? "American Express" : $0.capitalized).tag($0)
                            }
                        }.labelsHidden()
                        TextField("Last four", text: $identity.last4).frame(width: 64)
                            .accessibilityLabel("Last four digits")
                        Button("Remove card", systemImage: "xmark") {
                            identities.removeAll { $0.id == identity.id }
                        }.labelStyle(.iconOnly)
                    }
                }
            }
            if store.conflicts.contains(accountID) {
                Text("Cards changed on another device.").foregroundStyle(.orange)
                HStack {
                    Button("Use iCloud cards") {
                        Task {
                            do {
                                try await store.resolve(accountID, keepLocal: false)
                                reload()
                            } catch { message = error.localizedDescription }
                        }
                    }
                    Button("Keep local cards") {
                        Task {
                            do {
                                try await store.resolve(accountID, keepLocal: true)
                                reload()
                            } catch { message = error.localizedDescription }
                        }
                    }
                }
            } else {
                HStack {
                    Button("Save cards") {
                        Task {
                            do {
                                try await store.save(
                                    PaymentAccountMetadata(
                                        id: accountID, ledgerID: ledgerID, identities: identities),
                                    expected: original)
                                reload()
                                message =
                                    store.pendingCount == 0
                                    ? "Saved" : "Saved on this device; waiting to sync."
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(store.busy || store.scope.isEmpty)
                    Button("Reload") {
                        Task {
                            await store.refresh()
                            reload()
                        }
                    }.disabled(store.busy)
                    if store.busy { ProgressView().controlSize(.small) }
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !store.error.isEmpty { Text(store.error).font(.caption).foregroundStyle(.red) }
        }
        .textFieldStyle(.roundedBorder)
        .task(id: accountID) {
            await store.refresh()
            reload()
        }
    }
    private func reload() {
        original = store.metadata[accountID]
        identities = original?.identities ?? []
    }
}
struct CardMetadataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
struct ReceiptAISettingsView: View {
    let accounts: [Account]
    @State private var settings = ReceiptAISettings.load()
    @ObservedObject private var client = ReceiptAnalysisClient.shared
    @ObservedObject private var metadata = PaymentMetadataStore.shared
    @State private var error = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var document = CardMetadataDocument()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(macOS)
                Text("Receipt Suggestions").font(.headline)
            #endif
            HStack {
                Text("Model")
                Spacer()
                Picker("Model", selection: $settings.model) {
                    ForEach(ReceiptAISettings.models, id: \.self) {
                        Text(
                            $0.replacingOccurrences(of: "gpt-", with: "GPT-").replacingOccurrences(
                                of: "-sol", with: " Sol"
                            ).replacingOccurrences(of: "-terra", with: " Terra").replacingOccurrences(
                                of: "-luna", with: " Luna"
                            ).replacingOccurrences(of: "-astra", with: " Astra")
                        ).tag($0)
                    }
                }
                .labelsHidden()
            }
            HStack {
                Text("Reasoning effort")
                Spacer()
                Picker("Reasoning effort", selection: $settings.effort) {
                    ForEach(settings.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }.labelsHidden()
            }
            Text("Additional instructions").font(.subheadline)
            TextEditor(text: $settings.instructions).frame(minHeight: 70, maxHeight: 100).overlay(
                RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            Text("API server").font(.subheadline)
            TextField("API server URL", text: $settings.endpoint).textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            if client.localDevelopment {
                Label("Local API connected", systemImage: "checkmark.circle")
            } else if client.authenticated {
                Label("Signed in for receipt suggestions", systemImage: "checkmark.circle")
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.nonce = client.nonce
                } onCompletion: { result in
                    Task {
                        do {
                            let authorization = try result.get()
                            guard
                                let credential = authorization.credential
                                    as? ASAuthorizationAppleIDCredential, let token = credential.identityToken
                            else { throw AssistError.message("Apple did not return an identity token.") }
                            try await client.signIn(identityToken: token, endpoint: settings.endpoint)
                            error = ""
                        } catch {
                            self.error = error.localizedDescription
                            await client.prepareSignIn(endpoint: settings.endpoint)
                        }
                    }
                }.frame(height: 32).disabled(client.nonce.isEmpty)
            }
            if !error.isEmpty || !client.error.isEmpty {
                Text(error.isEmpty ? client.error : error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button("Export cards") {
                    do {
                        document = CardMetadataDocument(data: try metadata.backup())
                        exporting = true
                    } catch { self.error = error.localizedDescription }
                }.disabled(metadata.scope.isEmpty)
                Button("Restore cards…") { importing = true }.disabled(
                    metadata.scope.isEmpty || metadata.busy)
            }
        }
        .onChange(of: settings) { _, value in
            if !value.efforts.contains(value.effort) { settings.effort = "medium" }
            settings.save()
        }
        .task(id: settings.endpoint) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { await client.prepareSignIn(endpoint: settings.endpoint) }
        }
        .task { await metadata.refresh() }
        .fileExporter(
            isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Finances Cards"
        ) { result in if case .failure(let failure) = result { error = failure.localizedDescription } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            Task {
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 2_000_000 else {
                        throw AssistError.message("Card backup is too large.")
                    }
                    try await metadata.restore(data, validAccounts: accounts)
                    error = ""
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
struct ReceiptAnalysisPanel: View {
    @Binding var draft: TransactionDraft
    let initialDraft: TransactionDraft
    let ledgerID: UUID
    let accounts: [Account]
    let commodities: [Commodity]
    let attachmentURL: (AttachmentAsset) -> URL
    var onContentChange: (() -> Void)? = nil
    @ObservedObject private var metadata = PaymentMetadataStore.shared
    @State private var task: Task<Void, Never>?
    @State private var analysisGeneration = UUID()
    @State private var busy = false
    @State private var error = ""
    @State private var warnings: [String] = []
    @State private var proposal: ReceiptDraftProposal?
    @State private var reviewed: TransactionDraft?
    @State private var replacements: [ReceiptProposalField] = []
    @State private var selected: Set<UUID> = []
    @State private var choosing = false
    @State private var protectedFields: Set<ReceiptProposalField> = []
    @State private var autoApplied: TransactionDraft?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !draft.attachments.isEmpty {
                HStack {
                    Button(busy ? "Analyzing…" : "Suggest from attachments", systemImage: "sparkles") {
                        analyze(useSelection: false)
                    }.disabled(busy)
                    if busy {
                        Button("Cancel") {
                            task?.cancel()
                            analysisGeneration = UUID()
                            busy = false
                        }
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if choosing {
                Text("Choose receipts within the attachment limits.").font(.caption)
                ForEach(draft.attachments) { asset in
                    Toggle(
                        asset.originalFilename,
                        isOn: Binding(
                            get: { selected.contains(asset.id) },
                            set: { if $0 { selected.insert(asset.id) } else { selected.remove(asset.id) } })
                    ).font(.caption)
                }
                Button("Analyze selected receipts") { analyze(useSelection: true) }.disabled(
                    busy || selected.isEmpty)
            }
            if let proposal {
                if !replacements.isEmpty { Text("Suggested replacements").font(.headline) }
                ForEach(replacements) { field in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(field.title).bold()
                            Spacer()
                            Button("Replace") { replace(field, proposal: proposal) }
                        }
                        if field == .postings {
                            postingTable("Current", draft.postings)
                            postingTable("Suggested", proposal.postings ?? [])
                        } else {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading) {
                                    Text("Current").foregroundStyle(.secondary)
                                    Text(text(field, draft: draft))
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .leading) {
                                    Text("Suggested").foregroundStyle(.secondary)
                                    Text(proposedText(field, proposal: proposal))
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.font(.caption)
                    Divider()
                }
                if replacements.isEmpty {
                    Text("Receipt fields filled. Save when ready.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(warnings.prefix(2).enumerated()), id: \.offset) { _, text in
                Text(text.split(separator: " ").prefix(12).joined(separator: " ")).font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: draft) { old, new in
            if new == autoApplied {
                autoApplied = nil
                return
            }
            for field in ReceiptProposalField.allCases where !ReceiptDraftProposal.equal(field, old, new) {
                protectedFields.insert(field)
            }
        }
        .onChange(of: busy) { _, _ in onContentChange?() }
        .onChange(of: replacements.count) { _, _ in onContentChange?() }
        .onDisappear { task?.cancel() }
    }
    private func analyze(useSelection: Bool) {
        let assets = draft.attachments.filter { !useSelection || selected.contains($0.id) }
        guard assets.count <= 10, assets.allSatisfy({ $0.sizeBytes <= 20_000_000 }),
            assets.reduce(Int64(0), { $0 + $1.sizeBytes }) <= 40_000_000
        else {
            choosing = true
            error = "Up to 10 files, 20 MB each, 40 MB combined."
            return
        }
        let baseline = draft
        let generation = UUID()
        analysisGeneration = generation
        busy = true
        error = ""
        proposal = nil
        warnings = []
        replacements = []
        task = Task { @MainActor in
            defer { if analysisGeneration == generation { busy = false } }
            do {
                await metadata.refresh()
                try Task.checkCancellation()
                guard !metadata.scope.isEmpty, !metadata.busy, metadata.error.isEmpty,
                    metadata.conflicts.isEmpty
                else { throw AssistError.message("Refresh or resolve card metadata before analysis.") }
                let result = try await ReceiptAnalysisClient.shared.analyze(
                    draft: baseline, ledgerID: ledgerID, accounts: accounts, commodities: commodities,
                    metadata: metadata.metadata,
                    assets: assets.map { ($0, attachmentURL($0)) }, settings: .load())
                try Task.checkCancellation()
                guard draft.ledgerID == baseline.ledgerID,
                    assets.allSatisfy({ asset in draft.attachments.contains(asset) })
                else { throw AssistError.message("The journal or receipts changed. Analyze again.") }
                let next = try ReceiptDraftProposal.make(result, accounts: accounts, commodities: commodities)
                var protected = protectedFields
                for field in [ReceiptProposalField.note, .payee, .number]
                where !text(field, draft: initialDraft).isEmpty { protected.insert(field) }
                var updated = draft
                replacements = next.autofill(&updated, initial: initialDraft, protected: protected)
                autoApplied = updated
                draft = updated
                reviewed = updated
                proposal = next
                warnings = Array(Set(result.suggestion.warnings))
                choosing = false
            } catch is CancellationError {} catch AssistError.attachmentLimit(let message) {
                choosing = true
                error = message
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func replace(_ field: ReceiptProposalField, proposal: ReceiptDraftProposal) {
        guard let reviewed, ReceiptDraftProposal.equal(field, draft, reviewed) else {
            error = "This field changed. Check the current value before replacing."
            self.reviewed = draft
            return
        }
        var updated = draft
        proposal.apply(field, to: &updated)
        autoApplied = updated
        draft = updated
        self.reviewed = updated
        replacements.removeAll { $0 == field }
        error = ""
    }
    private func text(_ field: ReceiptProposalField, draft: TransactionDraft) -> String {
        switch field {
        case .date: draft.date.formatted(date: .abbreviated, time: .omitted)
        case .note: draft.note
        case .payee: draft.payee
        case .number: draft.number
        case .postings: ""
        }
    }
    private func proposedText(_ field: ReceiptProposalField, proposal: ReceiptDraftProposal) -> String {
        var value = draft
        proposal.apply(field, to: &value)
        return text(field, draft: value)
    }
    private func postingTable(_ title: String, _ postings: [PostingDraft]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            ForEach(postings) { row in
                HStack(alignment: .top) {
                    Text(accounts.first { $0.id == row.accountID }?.name ?? "Not identified").frame(
                        maxWidth: .infinity, alignment: .leading)
                    Text(row.amount.isEmpty ? "Not identified" : row.amount).monospacedDigit()
                    Text(commodities.first { $0.id == row.commodityID }?.symbol ?? "—").foregroundStyle(
                        .secondary)
                }
            }
        }
    }
}
