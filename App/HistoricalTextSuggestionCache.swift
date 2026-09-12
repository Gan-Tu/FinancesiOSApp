import Combine
import Foundation
import UIKit

/// Immutable value data crosses to the worker; no store or view is accessed there.
struct HistoricalSuggestionSnapshot: @unchecked Sendable {
    let data: JournalData
    let ledgerID: UUID
    let asOf: Date
}

private actor HistoricalSuggestionIndexWorker {
    static let shared = HistoricalSuggestionIndexWorker()

    nonisolated static func makeIndex(_ snapshot: HistoricalSuggestionSnapshot) async throws -> HistoricalTextSuggestionIndex {
        try await shared.build(snapshot)
    }

    func build(_ snapshot: HistoricalSuggestionSnapshot) throws -> HistoricalTextSuggestionIndex {
        try Task.checkCancellation()
        var transactions: [LedgerTransaction] = []
        for (offset, transaction) in snapshot.data.transactions.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            if transaction.ledgerID == snapshot.ledgerID { transactions.append(transaction) }
        }
        return try HistoricalTextSuggestionIndex(transactions: transactions, asOf: snapshot.asOf,
                                                  checkCancellation: { try Task.checkCancellation() })
    }
}

/// Builds once per journal/source generation, never by scanning on a keystroke.
/// A shared worker serializes CPU work; cancelled speculative builds yield at
/// explicit checkpoints. Only the small indexed lookup runs on the UI actor.
@MainActor
final class HistoricalTextSuggestionCache: ObservableObject {
    typealias Builder = @Sendable (HistoricalSuggestionSnapshot) async throws -> HistoricalTextSuggestionIndex

    private struct Generation: Equatable, Sendable {
        let epoch: UInt64
        let journal: UInt64
    }
    private struct Entry {
        let index: HistoricalTextSuggestionIndex
        let generation: Generation
        var access: UInt64
    }
    private struct Pending: Sendable {
        let id: UUID
        let generation: Generation
        let asOf: Date
        let task: Task<HistoricalTextSuggestionIndex, Error>
        var visibleWaiters: Set<UUID>
        let memoryEpoch: UInt64
        var isVisible: Bool { !visibleWaiters.isEmpty }
    }

    @Published private(set) var revision: UInt64 = 0
    private(set) var buildCount = 0
    private(set) var hitCount = 0
    var cachedJournalCount: Int { entries.count }
    private var epoch: UInt64 = 0
    private var journalGenerations: [UUID: UInt64] = [:]
    private var entries: [UUID: Entry] = [:]
    private var pending: [UUID: Pending] = [:]
    private var access: UInt64 = 0
    private var memoryEpoch: UInt64 = 0
    private var memoryWarning: HistoricalSuggestionMemoryWarning?
    private let maximumCachedJournals: Int
    private let builder: Builder
    private var prewarmTask: Task<Void, Never>?
    private var prewarmID: UUID?
    private var prewarmLedgerID: UUID?
    private var latestRequestedLedgerID: UUID?

    init(maximumCachedJournals: Int = 4,
         builder: @escaping Builder = { try await HistoricalSuggestionIndexWorker.makeIndex($0) }) {
        self.maximumCachedJournals = max(1, maximumCachedJournals)
        self.builder = builder
        memoryWarning = HistoricalSuggestionMemoryWarning { [weak self] in self?.purgeForMemoryPressure() }
    }

    deinit {
        prewarmTask?.cancel()
        for work in pending.values { work.task.cancel() }
    }

    func suggestions(data: JournalData, ledgerID: UUID, field: HistoricalTextSuggestionField,
                     query: String, revision expectedRevision: UInt64, limit: Int = 5,
                     now: Date = Date()) async throws -> [HistoricalTextSuggestion] {
        try Task.checkCancellation()
        // The caller captures this with its data snapshot, not when a delayed
        // task finally starts. Otherwise old data could acquire a new revision.
        guard expectedRevision == revision else { throw CancellationError() }
        guard data.ledgers.contains(where: { $0.id == ledgerID }), limit > 0 else { return [] }
        latestRequestedLedgerID = ledgerID
        if prewarmLedgerID != ledgerID { cancelPrewarm() }
        let snapshot = HistoricalSuggestionSnapshot(data: data, ledgerID: ledgerID, asOf: now)
        let token = generation(for: ledgerID)
        let waiterID = UUID()
        let index = try await withTaskCancellationHandler {
            defer { releaseVisibleWaiter(waiterID, for: ledgerID) }
            return try await loadIndex(snapshot, generation: token, visibleWaiter: waiterID)
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseVisibleWaiter(waiterID, for: ledgerID) }
        }
        try Task.checkCancellation()
        guard expectedRevision == revision else { throw CancellationError() }
        return index.suggestions(for: field, in: ledgerID, matching: query, limit: limit)
    }

    func hasCachedIndex(for ledgerID: UUID, now: Date = Date()) -> Bool {
        guard let entry = entries[ledgerID], entry.generation == generation(for: ledgerID) else { return false }
        return usable(entry.index, at: now)
    }

    /// Returns affected warm/in-flight journals so callers may prewarm only
    /// relevant indexes after publishing the new data snapshot.
    @discardableResult
    func invalidate(ledgerIDs: Set<UUID>) -> Set<UUID> {
        guard !ledgerIDs.isEmpty else { return [] }
        let interested = Set(entries.keys).union(pending.keys).union(prewarmLedgerID.map { [$0] } ?? [])
        for id in ledgerIDs {
            journalGenerations[id, default: 0] &+= 1
            entries.removeValue(forKey: id)
            pending.removeValue(forKey: id)?.task.cancel()
        }
        if let id = prewarmLedgerID, ledgerIDs.contains(id) { cancelPrewarm() }
        revision &+= 1
        return interested.intersection(ledgerIDs)
    }

    @discardableResult
    func invalidateAll() -> Set<UUID> {
        let interested = Set(entries.keys).union(pending.keys).union(prewarmLedgerID.map { [$0] } ?? [])
        epoch &+= 1
        journalGenerations.removeAll()
        entries.removeAll()
        for work in pending.values { work.task.cancel() }
        pending.removeAll()
        cancelPrewarm()
        revision &+= 1
        return interested
    }

    func prewarm(data: JournalData, ledgerID: UUID, now: Date = Date()) {
        guard data.ledgers.contains(where: { $0.id == ledgerID }) else { return }
        latestRequestedLedgerID = ledgerID
        if prewarmLedgerID != ledgerID { cancelPrewarm() }
        guard !hasCachedIndex(for: ledgerID, now: now) else { return }
        if entries[ledgerID] != nil { invalidate(ledgerIDs: [ledgerID]) }
        if pending[ledgerID]?.generation == generation(for: ledgerID) { return }
        // Keep only the latest speculative navigation request. Visible requests
        // share its pending build and are never cancelled by a keystroke.
        cancelPrewarm()
        let id = UUID()
        let token = generation(for: ledgerID)
        let snapshot = HistoricalSuggestionSnapshot(data: data, ledgerID: ledgerID, asOf: now)
        prewarmID = id
        prewarmLedgerID = ledgerID
        prewarmTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                defer { if self.prewarmID == id { self.prewarmTask = nil; self.prewarmID = nil; self.prewarmLedgerID = nil } }
                _ = try await self.loadIndex(snapshot, generation: token, visibleWaiter: nil)
            } catch { /* Speculative indexing does not affect the editor. */ }
        }
    }

    private func cancelPrewarm() {
        prewarmTask?.cancel()
        if let ledgerID = prewarmLedgerID, let work = pending[ledgerID], !work.isVisible {
            pending.removeValue(forKey: ledgerID)?.task.cancel()
        }
        prewarmTask = nil
        prewarmID = nil
        prewarmLedgerID = nil
    }

    func purgeForMemoryPressure() {
        entries.removeAll()
        memoryEpoch &+= 1
        cancelPrewarm()
        for (id, work) in pending where !work.isVisible {
            pending.removeValue(forKey: id)?.task.cancel()
        }
        // Visible callers can finish, but their pre-warning indexes will not
        // refill memory. Existing chips retain only their five small strings.
    }

    private func generation(for ledgerID: UUID) -> Generation {
        Generation(epoch: epoch, journal: journalGenerations[ledgerID, default: 0])
    }

    private func usable(_ index: HistoricalTextSuggestionIndex, at date: Date) -> Bool {
        index.asOf <= date && (index.nextFutureTransactionDate.map { date < $0 } ?? true)
    }

    private func releaseVisibleWaiter(_ waiterID: UUID, for ledgerID: UUID) {
        guard var work = pending[ledgerID], work.visibleWaiters.remove(waiterID) != nil else { return }
        pending[ledgerID] = work
        let competing = latestRequestedLedgerID != ledgerID || pending.contains { id, other in
            id != ledgerID && (other.isVisible || prewarmLedgerID == id)
        }
        // Keep an abandoned same-journal build between keystrokes, but yield to
        // another screen once nobody is waiting for this journal anymore.
        if !work.isVisible && competing {
            if prewarmLedgerID == ledgerID { cancelPrewarm() }
            else { pending.removeValue(forKey: ledgerID)?.task.cancel() }
        }
    }

    private func loadIndex(_ snapshot: HistoricalSuggestionSnapshot, generation token: Generation,
                           visibleWaiter: UUID?) async throws -> HistoricalTextSuggestionIndex {
        let ledgerID = snapshot.ledgerID
        while true {
            try Task.checkCancellation()
            guard token == generation(for: ledgerID) else { throw CancellationError() }
            for (id, old) in pending where id != ledgerID && !old.isVisible {
                if prewarmLedgerID == id { cancelPrewarm() }
                else { pending.removeValue(forKey: id)?.task.cancel() }
            }
            if var entry = entries[ledgerID], entry.generation == token, usable(entry.index, at: snapshot.asOf) {
                access &+= 1; entry.access = access; entries[ledgerID] = entry
                hitCount += 1
                return entry.index
            }
            let work: Pending
            if var existing = pending[ledgerID], existing.generation == token, existing.asOf <= snapshot.asOf {
                if let visibleWaiter {
                    existing.visibleWaiters.insert(visibleWaiter)
                    pending[ledgerID] = existing
                }
                work = existing
            } else {
                pending.removeValue(forKey: ledgerID)?.task.cancel()
                let build = builder
                work = Pending(id: UUID(), generation: token, asOf: snapshot.asOf,
                    task: Task.detached(priority: visibleWaiter == nil ? .utility : .userInitiated) { try await build(snapshot) },
                    visibleWaiters: visibleWaiter.map { [$0] } ?? [], memoryEpoch: memoryEpoch)
                pending[ledgerID] = work
                buildCount += 1
            }
            let index: HistoricalTextSuggestionIndex
            do { index = try await work.task.value }
            catch {
                if pending[ledgerID]?.id == work.id { pending.removeValue(forKey: ledgerID) }
                throw error
            }
            guard token == generation(for: ledgerID) else { throw CancellationError() }
            if pending[ledgerID]?.id == work.id {
                pending.removeValue(forKey: ledgerID)
                access &+= 1
                if work.memoryEpoch == memoryEpoch {
                    entries[ledgerID] = Entry(index: index, generation: token, access: access)
                }
                while entries.count > maximumCachedJournals,
                      let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
                    entries.removeValue(forKey: oldest)
                }
            }
            try Task.checkCancellation()
            if usable(index, at: snapshot.asOf) { return index }
            // A future transaction became eligible while an older prewarm was
            // queued. Rebuild against this request's time before returning it.
        }
    }
}

private final class HistoricalSuggestionMemoryWarning: @unchecked Sendable {
    private let token: NSObjectProtocol
    @MainActor init(onWarning: @escaping @MainActor @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                       object: nil, queue: .main) { _ in
            Task { @MainActor in onWarning() }
        }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}
