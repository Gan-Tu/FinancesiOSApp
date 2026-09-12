import SwiftUI

private struct RefundReadSnapshot: @unchecked Sendable {
    let data: JournalData
    let ledgerID: UUID
    let asOf: Date
}

struct RefundPaymentCandidate: Identifiable, @unchecked Sendable {
    let transaction: LedgerTransaction
    let incomingAmount: Decimal
    var id: UUID { transaction.id }
}

struct RefundPresentation: @unchecked Sendable {
    let id = UUID()
    let asOf: Date
    let overview: RefundTrackingOverview
    let recordsByPurchase: [UUID: RefundTrackingRecord]
    let summariesByPurchase: [UUID: RefundTrackingSummary]
    let currencies: [Commodity]
    let candidatesByCurrency: [UUID: [RefundPaymentCandidate]]
    let allocatedByCurrency: [UUID: [UUID: Decimal]]
    let nextFutureDate: Date?

    func isCurrent(at date: Date) -> Bool {
        date >= asOf && (nextFutureDate.map { date < $0 } ?? true)
    }

    func available(_ candidate: RefundPaymentCandidate, for record: RefundTrackingRecord) -> Decimal {
        let allocated = allocatedByCurrency[record.commodityID]?[candidate.id] ?? .zero
        let own = record.state == .active ? record.links.first(where: { $0.transactionID == candidate.id })?.amount ?? .zero : .zero
        let remaining = candidate.incomingAmount - allocated + own
        return remaining.isNaN ? .zero : max(.zero, remaining)
    }
}

private actor RefundPresentationWorker {
    static let shared = RefundPresentationWorker()

    func build(_ snapshot: RefundReadSnapshot) throws -> RefundPresentation {
        let data = snapshot.data, ledgerID = snapshot.ledgerID
        let currencies = data.commodities.filter { $0.ledgerID == ledgerID }
        let accountsByID = Dictionary(data.accounts.filter { $0.ledgerID == ledgerID }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ledgers = data.ledgers.filter { $0.id == ledgerID }
        var transactionsByID: [UUID: LedgerTransaction] = [:]
        var candidates: [UUID: [RefundPaymentCandidate]] = [:]
        var nextFuture: Date?
        for (offset, transaction) in data.transactions.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            guard transaction.ledgerID == ledgerID else { continue }
            transactionsByID[transaction.id] = transaction
            if transaction.date > snapshot.asOf {
                nextFuture = min(nextFuture ?? transaction.date, transaction.date)
                continue
            }
            let postingAccounts = Set(transaction.postings.map(\.accountID)).compactMap { accountsByID[$0] }
            let touched = Set(transaction.postings.compactMap { $0.commodityID ?? accountsByID[$0.accountID]?.commodityID ?? currencies.first?.id })
            // Domain validation sees one row and at most its own posting
            // accounts, so it cannot rescan the full journal for every row.
            let bounded = JournalData(ledgers: ledgers, commodities: currencies, accounts: postingAccounts, transactions: [transaction])
            for currencyID in touched {
                if let amount = try? RefundTracking.incomingAmount(transactionID: transaction.id, commodityID: currencyID, ledgerID: ledgerID, in: bounded, asOf: snapshot.asOf) {
                    candidates[currencyID, default: []].append(RefundPaymentCandidate(transaction: transaction, incomingAmount: amount))
                }
            }
        }
        for currencyID in Array(candidates.keys) {
            candidates[currencyID]?.sort {
                $0.transaction.date == $1.transaction.date ? $0.id.canonicallyPrecedes($1.id) : $0.transaction.date > $1.transaction.date
            }
        }

        var records: [RefundTrackingRecord] = [], sourcesByID: [UUID: TransactionSource] = [:], issues: [String] = []
        var unreadableSources: [RefundTrackingMetadataIssue] = []
        var peersByIncoming: [UUID: Set<UUID>] = [:]
        var allocatedByCurrency: [UUID: [UUID: Decimal]] = [:]
        for source in data.sources where source.ledgerID == ledgerID && source.type == RefundTracking.sourceType {
            try Task.checkCancellation()
            do {
                guard let record = try RefundTracking.decode(source) else { continue }
                records.append(record); sourcesByID[record.id] = source
                if record.state == .active {
                    for link in record.links {
                        peersByIncoming[link.transactionID, default: []].insert(record.id)
                        allocatedByCurrency[record.commodityID, default: [:]][link.transactionID, default: .zero] += link.amount
                    }
                }
            } catch {
                issues.append(error.localizedDescription)
                unreadableSources.append(RefundTrackingMetadataIssue(source: source, message: error.localizedDescription))
            }
        }
        var summaries: [RefundTrackingSummary] = []
        for record in records {
            try Task.checkCancellation()
            if !issues.isEmpty {
                summaries.append(RefundTrackingSummary(record: record, receivedAmount: nil, outstandingAmount: nil,
                    issues: ["Some tracking metadata is unreadable. Linked amounts cannot be verified."]))
                continue
            }
            let referencedIDs = Set([record.purchaseTransactionID] + record.links.map(\.transactionID))
            let referenced = referencedIDs.compactMap { transactionsByID[$0] }
            let postingAccounts = Set(referenced.flatMap(\.postings).map(\.accountID)).compactMap { accountsByID[$0] }
            var peers: Set<UUID> = [record.id]
            for link in record.links { peers.formUnion(peersByIncoming[link.transactionID] ?? []) }
            let bounded = JournalData(ledgers: ledgers, commodities: currencies, accounts: postingAccounts,
                transactions: referenced, sources: peers.compactMap { sourcesByID[$0] })
            if let summary = RefundTracking.overview(in: bounded, ledgerID: ledgerID, asOf: snapshot.asOf).summaries.first(where: { $0.id == record.id }) {
                summaries.append(summary)
            }
        }
        summaries.sort { $0.id.canonicallyPrecedes($1.id) }
        return RefundPresentation(asOf: snapshot.asOf, overview: RefundTrackingOverview(summaries: summaries, issues: issues, unreadableSources: unreadableSources),
            recordsByPurchase: Dictionary(records.map { ($0.purchaseTransactionID, $0) }, uniquingKeysWith: { first, _ in first }),
            summariesByPurchase: Dictionary(summaries.map { ($0.record.purchaseTransactionID, $0) }, uniquingKeysWith: { first, _ in first }),
            currencies: currencies, candidatesByCurrency: candidates, allocatedByCurrency: allocatedByCurrency, nextFutureDate: nextFuture)
    }

    func search(_ presentation: RefundPresentation, record: RefundTrackingRecord, query: String) throws -> [RefundPaymentCandidate] {
        var result: [RefundPaymentCandidate] = []
        for (offset, candidate) in (presentation.candidatesByCurrency[record.commodityID] ?? []).enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            guard candidate.id != record.purchaseTransactionID, presentation.available(candidate, for: record) > .zero else { continue }
            if query.isEmpty || candidate.transaction.payee.localizedStandardContains(query) || candidate.transaction.note.localizedStandardContains(query) {
                result.append(candidate)
            }
        }
        return result
    }
}

/// Store-owned, bounded read cache. UI tasks capture a cheap revision and an
/// immutable value snapshot; stale worker completions never replace newer data.
@MainActor
final class RefundPresentationCache {
    private struct Key: Hashable { let ledgerID: UUID; let revision: UInt64 }
    private struct BuildKey: Hashable { let key: Key; let asOf: Date }
    private struct SearchKey: Hashable { let presentationID: UUID; let recordID: UUID; let query: String }
    private var entries: [Key: RefundPresentation] = [:]
    private var pending: [BuildKey: Task<RefundPresentation, Error>] = [:]
    private var builds: [Key: BuildKey] = [:]
    private var latest: [UUID: UInt64] = [:]
    private var searches: [SearchKey: [RefundPaymentCandidate]] = [:]

    func presentation(data: JournalData, ledgerID: UUID, revision: UInt64, asOf: Date = Date()) async throws -> RefundPresentation {
        try Task.checkCancellation()
        let key = Key(ledgerID: ledgerID, revision: revision)
        if let previous = latest[ledgerID], previous != revision {
            entries = entries.filter { $0.key.ledgerID != ledgerID }
            for (oldKey, task) in pending where oldKey.key.ledgerID == ledgerID { task.cancel(); pending[oldKey] = nil }
            builds = builds.filter { $0.key.ledgerID != ledgerID }
            searches.removeAll()
        }
        latest[ledgerID] = revision
        if let entry = entries[key], entry.isCurrent(at: asOf) { return entry }
        let buildKey: BuildKey
        let work: Task<RefundPresentation, Error>
        if let existingKey = builds[key], let existing = pending[existingKey] {
            buildKey = existingKey; work = existing
        }
        else {
            buildKey = BuildKey(key: key, asOf: asOf)
            let snapshot = RefundReadSnapshot(data: data, ledgerID: ledgerID, asOf: asOf)
            work = Task { try await RefundPresentationWorker.shared.build(snapshot) }
            builds[key] = buildKey; pending[buildKey] = work
        }
        let result: RefundPresentation
        do { result = try await work.value }
        catch { pending[buildKey] = nil; throw error }
        guard latest[ledgerID] == revision else { throw CancellationError() }
        pending[buildKey] = nil
        // A shared build may have started before the payment deadline or a
        // backward clock change. Rebuild for this caller's captured instant.
        guard result.isCurrent(at: asOf) else {
            return try await presentation(data: data, ledgerID: ledgerID, revision: revision, asOf: asOf)
        }
        if builds[key] == buildKey {
            if entries.count >= 2, entries[key] == nil { entries.removeAll(); searches.removeAll() }
            entries[key] = result
        }
        try Task.checkCancellation()
        return result
    }

    func candidates(in presentation: RefundPresentation, record: RefundTrackingRecord, matching query: String) async throws -> [RefundPaymentCandidate] {
        let key = SearchKey(presentationID: presentation.id, recordID: record.id, query: query)
        if let cached = searches[key] { return cached }
        let result = try await RefundPresentationWorker.shared.search(presentation, record: record, query: query)
        try Task.checkCancellation()
        if searches.count >= 12 { searches.removeAll() }
        searches[key] = result
        return result
    }
}

private struct RefundPresentationClock: ViewModifier {
    @EnvironmentObject private var store: MobileLedgerStore
    let deadline: Date?

    func body(content: Content) -> some View {
        content.task(id: deadline) {
            guard let deadline else { return }
            do {
                while deadline > Date() {
                    // Recheck wall time periodically; app foreground and clock
                    // notifications also invalidate the store's read revision.
                    try await Task.sleep(for: .seconds(max(0, min(deadline.timeIntervalSinceNow, 3_600))))
                }
                try Task.checkCancellation()
                store.refreshRefundPresentationsForClockChange()
            } catch {}
        }
    }
}

private struct RefundMetadataRecoveryView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let issue: RefundTrackingMetadataIssue
    @State private var confirmRemoval = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(issue.message).foregroundStyle(.orange)
            Button("Remove Unreadable Tracking", role: .destructive) { confirmRemoval = true }
                .disabled(saving)
                .accessibilityIdentifier("refund-remove-unreadable-\(issue.id.uuidString)")
        }
        .confirmationDialog("Remove unreadable tracking?", isPresented: $confirmRemoval) {
            Button("Remove Tracking", role: .destructive) {
                saving = true
                Task {
                    _ = await store.removeUnreadableRefundTrackingAsync(issue.source)
                    saving = false
                }
            }
        } message: {
            Text("Only this journal's unreadable tracking metadata will be removed. Your transactions and payment amounts will be kept.")
        }
    }
}

struct RefundTrackingListView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let ledgerID: UUID
    @State private var summaries: [RefundTrackingSummary] = []
    @State private var issues: [String] = []
    @State private var unreadableSources: [RefundTrackingMetadataIssue] = []
    @State private var loading = true
    @State private var nextFutureDate: Date?
    var body: some View {
        List {
            if !unreadableSources.isEmpty {
                Section("Needs Attention") { ForEach(unreadableSources) { RefundMetadataRecoveryView(issue: $0) } }
            } else if !issues.isEmpty {
                Section("Needs Attention") { ForEach(issues, id: \.self) { Text($0).foregroundStyle(.orange) } }
            }
            ForEach(summaries) { summary in
                NavigationLink {
                    RefundTrackingDetailView(purchaseID: summary.record.purchaseTransactionID)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        let purchase = store.transaction(summary.record.purchaseTransactionID)
                        Text(purchase?.payee.isEmpty == false ? purchase!.payee : (purchase?.note ?? "Deleted Purchase"))
                        RefundStatusLabel(summary: summary)
                        if let due = summary.record.dueDate { Text("Expected \(due.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .overlay {
            if loading && summaries.isEmpty { ProgressView() }
            else if summaries.isEmpty && issues.isEmpty { ContentUnavailableView("No Tracked Refunds", systemImage: "arrow.uturn.backward.circle", description: Text("Open a purchase and choose Refund or Reimbursement to track money you expect back.")) }
        }
        .navigationTitle("Refunds & Reimbursements").navigationBarTitleDisplayMode(.inline)
        .modifier(RefundPresentationClock(deadline: nextFutureDate))
        .alert(item: $store.validationError) { error in Alert(title: Text("Refund Tracking"), message: Text(error.message)) }
        .task(id: store.refundPresentationRevision) {
            let revision = store.refundPresentationRevision
            do {
                let presentation = try await store.refundPresentations.presentation(data: store.data, ledgerID: ledgerID, revision: revision)
                try Task.checkCancellation()
                guard revision == store.refundPresentationRevision else { return }
                summaries = presentation.overview.summaries; issues = presentation.overview.issues
                unreadableSources = presentation.overview.unreadableSources
                nextFutureDate = presentation.nextFutureDate; loading = false
            } catch is CancellationError {} catch { issues = [error.localizedDescription]; loading = false }
        }
    }
}

private struct RefundStatusLabel: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let summary: RefundTrackingSummary
    var body: some View {
        Group {
            if !summary.issues.isEmpty { Text("Needs Attention").foregroundStyle(.orange) }
            else if summary.record.state == .cancelled { Text("Tracking Stopped").foregroundStyle(.secondary) }
            else if summary.isSettled { Text("Received in Full").foregroundStyle(.green) }
            else if let remaining = summary.outstandingAmount {
                Text("Waiting for \(moneyString(remaining, symbol: store.commodity(summary.record.commodityID)?.symbol ?? ""))")
                    .foregroundStyle(.secondary)
            }
        }.font(.subheadline)
    }
}

struct RefundTrackingDetailView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let purchaseID: UUID
    @State private var kind = RefundTrackingKind.refund
    @State private var amount = ""
    @State private var currencyID: UUID?
    @State private var person = ""
    @State private var note = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var loaded = false
    @State private var loadingError: String?
    @State private var recoveryIssue: RefundTrackingMetadataIssue?
    @State private var saving = false
    @State private var confirmRemove = false
    @State private var route: EditorRoute?
    @State private var record: RefundTrackingRecord?
    @State private var summary: RefundTrackingSummary?
    @State private var currencies: [Commodity] = []
    @State private var nextFutureDate: Date?
    private var purchase: LedgerTransaction? { store.transaction(purchaseID) }
    var body: some View {
        Form {
            if let summary {
                Section {
                    RefundStatusLabel(summary: summary)
                    ForEach(summary.issues, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
            Section("Expected Payment") {
                Picker("Type", selection: $kind) { ForEach(RefundTrackingKind.allCases) { Text($0.title).tag($0) } }
                TextField("Expected Amount", text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("refund-expected-amount")
                Picker("Currency", selection: $currencyID) {
                    Text("Choose Currency").tag(UUID?.none)
                    ForEach(currencies) { Text($0.symbol).tag(Optional($0.id)) }
                }
                TextField(kind == .refund ? "Merchant (optional)" : "Who owes you?", text: $person)
                TextField("Note", text: $note, axis: .vertical)
                Toggle("Expected Date", isOn: $hasDueDate)
                if hasDueDate { DatePicker("Date", selection: $dueDate, displayedComponents: .date) }
                Button(record == nil ? "Start Tracking" : "Save Changes") { save() }
                    .disabled(saving || currencyID == nil || (decimalFromInput(amount) ?? 0) <= 0 || purchase == nil)
                    .accessibilityIdentifier("refund-save-tracking")
            }
            if let record {
                Section("Received Payments") {
                    ForEach(record.links) { link in
                        HStack {
                            VStack(alignment: .leading) {
                                if let incoming = store.transaction(link.transactionID) {
                                    Button(incoming.payee.isEmpty ? incoming.note : incoming.payee) { route = .transaction(store.draft(for: incoming), "Edit Transaction") }
                                    Text(incoming.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                } else { Text("Deleted Payment").foregroundStyle(.orange) }
                                Text(moneyString(link.amount, symbol: store.commodity(record.commodityID)?.symbol ?? ""))
                            }
                            Spacer()
                            Button("Unlink", role: .destructive) {
                                run { await store.unlinkRefundAsync(purchaseID: purchaseID, incomingTransactionID: link.transactionID) }
                            }.disabled(saving)
                        }
                    }
                    if record.state == .active {
                        NavigationLink("Link Received Transaction") { RefundPaymentPicker(record: record) }
                            .accessibilityIdentifier("refund-link-payment")
                    }
                }
                Section {
                    if record.state == .active {
                        Button("Stop Waiting") { run { await store.cancelRefundTrackingAsync(purchaseID: purchaseID) } }.disabled(saving)
                    }
                    Button("Remove Tracking", role: .destructive) { confirmRemove = true }.disabled(saving)
                } footer: { Text("Tracking and linking never change transaction amounts, account balances, or cleared status.") }
            }
        }
        .disabled(!loaded || saving)
        .overlay {
            if !loaded {
                if let recoveryIssue {
                    VStack(spacing: 16) {
                        ContentUnavailableView("Tracking Unavailable", systemImage: "exclamationmark.triangle")
                        RefundMetadataRecoveryView(issue: recoveryIssue).padding()
                    }
                }
                else if let loadingError { ContentUnavailableView("Tracking Unavailable", systemImage: "exclamationmark.triangle", description: Text(loadingError)) }
                else { ProgressView("Loading Tracking…") }
            }
        }
        .navigationTitle("Refund / Reimbursement").navigationBarTitleDisplayMode(.inline)
        .modifier(RefundPresentationClock(deadline: nextFutureDate))
        .task(id: store.refundPresentationRevision) {
            let revision = store.refundPresentationRevision
            do {
                // A purchase may have moved journals since tracking began.
                // Keep the original tracking journal visible so its repair and
                // removal actions remain reachable from either entry point.
                let storedRecord = try store.refundTracking(for: purchaseID)
                guard let ledgerID = storedRecord?.ledgerID ?? purchase?.ledgerID else {
                    loadingError = "The purchase no longer exists."
                    return
                }
                let presentation = try await store.refundPresentations.presentation(data: store.data, ledgerID: ledgerID, revision: revision)
                try Task.checkCancellation()
                guard revision == store.refundPresentationRevision else { return }
                record = presentation.recordsByPurchase[purchaseID]
                summary = presentation.summariesByPurchase[purchaseID]
                currencies = presentation.currencies
                nextFutureDate = presentation.nextFutureDate
                recoveryIssue = nil; loadingError = nil
                guard !loaded else { return }; loaded = true
                if let record {
                    kind = record.kind; amount = decimalInputString(record.expectedAmount); currencyID = record.commodityID
                    person = record.person; note = record.note; hasDueDate = record.dueDate != nil; dueDate = record.dueDate ?? Date()
                } else if let purchase {
                    person = purchase.payee
                    let posting = purchase.postings.first { $0.amount < 0 } ?? purchase.postings.first
                    currencyID = posting?.commodityID ?? posting.flatMap { store.account($0.accountID)?.commodityID }
                    amount = posting.map { decimalInputString(abs($0.amount)) } ?? ""
                }
            } catch is CancellationError {} catch {
                recoveryIssue = store.data.sources.first { $0.id == RefundTracking.sourceID(for: purchaseID) }
                    .flatMap { RefundTracking.metadataIssue(for: $0) }
                if recoveryIssue != nil { loaded = false; loadingError = error.localizedDescription }
                else if !loaded { loadingError = error.localizedDescription }
                else { store.validationError = ValidationError(message: error.localizedDescription) }
            }
        }
        .confirmationDialog("Remove tracking?", isPresented: $confirmRemove) {
            Button("Remove Tracking", role: .destructive) { run { await store.removeRefundTrackingAsync(purchaseID: purchaseID) } }
        } message: { Text("Your purchase and linked payment transactions will be kept.") }
        .sheet(item: $route) { EditorSheet(route: $0) }
        .alert(item: $store.validationError) { error in Alert(title: Text("Refund Tracking"), message: Text(error.message)) }
    }
    private func save() {
        guard let currencyID, let value = decimalFromInput(amount) else { return }
        let draft = RefundTrackingDraft(purchaseTransactionID: purchaseID, kind: kind, expectedAmount: value,
            commodityID: currencyID, person: person, note: note, dueDate: hasDueDate ? dueDate : nil)
        run { await store.saveRefundTrackingAsync(draft) }
    }
    private func run(_ operation: @escaping @MainActor () async -> Bool) {
        guard !saving else { return }; saving = true
        Task { _ = await operation(); saving = false }
    }
}

private struct RefundPaymentPicker: View {
    @EnvironmentObject private var store: MobileLedgerStore
    let record: RefundTrackingRecord
    @State private var search = ""
    @State private var candidates: [RefundPaymentCandidate] = []
    @State private var loading = true
    @State private var nextFutureDate: Date?
    private struct Request: Hashable { let revision: UInt64; let query: String }
    var body: some View {
        List {
            ForEach(candidates) { candidate in
                let transaction = candidate.transaction
                NavigationLink {
                    RefundPaymentAllocationView(record: record, transaction: transaction)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transaction.payee.isEmpty ? transaction.note : transaction.payee)
                        Text(transaction.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Link Received Payment").searchable(text: $search)
            .modifier(RefundPresentationClock(deadline: nextFutureDate))
            .overlay { if loading && candidates.isEmpty { ProgressView() } }
            .task(id: Request(revision: store.refundPresentationRevision, query: search)) {
                let revision = store.refundPresentationRevision, query = search
                do {
                    if !query.isEmpty { try await Task.sleep(for: .milliseconds(140)) }
                    let presentation = try await store.refundPresentations.presentation(data: store.data, ledgerID: record.ledgerID, revision: revision)
                    let current = presentation.recordsByPurchase[record.purchaseTransactionID] ?? record
                    let results = try await store.refundPresentations.candidates(in: presentation, record: current, matching: query)
                    try Task.checkCancellation()
                    guard revision == store.refundPresentationRevision, query == search else { return }
                    candidates = results; nextFutureDate = presentation.nextFutureDate; loading = false
                } catch is CancellationError {} catch {
                    loading = false; store.validationError = ValidationError(message: error.localizedDescription)
                }
            }
    }
}

private struct RefundPaymentAllocationView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.dismiss) private var dismiss
    let record: RefundTrackingRecord
    let transaction: LedgerTransaction
    @State private var amount = ""
    @State private var saving = false
    @State private var initialized = false
    @State private var nextFutureDate: Date?
    var body: some View {
        Form {
            Section {
                Text(transaction.payee.isEmpty ? transaction.note : transaction.payee)
                Text(transaction.date, style: .date)
                TextField("Amount Received", text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("refund-link-amount")
                Text(store.commodity(record.commodityID)?.symbol ?? "")
            } footer: { Text("Enter how much of this payment belongs to the purchase. Use a partial amount when one payment covers multiple purchases.") }
            Button("Link Payment") {
                guard let value = decimalFromInput(amount) else { return }
                saving = true
                Task {
                    let saved = await store.linkRefundAsync(purchaseID: record.purchaseTransactionID, incomingTransactionID: transaction.id, amount: value)
                    saving = false
                    if saved { dismiss() }
                }
            }.disabled(saving || (decimalFromInput(amount) ?? 0) <= 0)
        }.navigationTitle("Received Amount")
            .modifier(RefundPresentationClock(deadline: nextFutureDate))
            .task(id: store.refundPresentationRevision) {
                let revision = store.refundPresentationRevision
                do {
                    let presentation = try await store.refundPresentations.presentation(data: store.data, ledgerID: record.ledgerID, revision: revision)
                    try Task.checkCancellation()
                    guard revision == store.refundPresentationRevision else { return }
                    nextFutureDate = presentation.nextFutureDate
                    guard !initialized else { return }
                    let current = presentation.recordsByPurchase[record.purchaseTransactionID] ?? record
                    let candidate = presentation.candidatesByCurrency[current.commodityID]?.first { $0.id == transaction.id }
                    let capacity = candidate.map { presentation.available($0, for: current) } ?? .zero
                    let own = current.links.first { $0.transactionID == transaction.id }?.amount ?? .zero
                    let outstanding = (presentation.summariesByPurchase[current.purchaseTransactionID]?.outstandingAmount ?? .zero) + own
                    amount = decimalInputString(min(capacity, outstanding)); initialized = true
                } catch is CancellationError {} catch { store.validationError = ValidationError(message: error.localizedDescription) }
            }
            .alert(item: $store.validationError) { error in Alert(title: Text("Couldn’t Link Payment"), message: Text(error.message)) }
    }
}
