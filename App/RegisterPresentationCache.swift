import Foundation
import UIKit

/// Key only the inputs that affect a register, not the full journal arrays or
/// volatile timestamps/selection metadata. Each store owns a separate cache.
struct RegisterPresentationCacheKey: Hashable {
    let revision: UInt64
    let ledgerID: UUID?
    let scope: MobileTransactionScope
    let search: String
    let searchField: TransactionSearchField
    let dateInterval: DateInterval?
    let transactionIDs: Set<UUID>?
    let filtersScope: Bool
    let searchDatePolicy: TransactionSearchDatePolicy?
    let relativeScopeInterval: DateInterval?
    let calendar: Calendar

    init(revision: UInt64, ledgerID: UUID?, request: RegisterRenderRequest) {
        self.revision = revision
        self.ledgerID = ledgerID
        scope = request.scope
        search = request.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        searchField = request.searchField
        dateInterval = request.dateInterval
        transactionIDs = request.transactionIDs
        filtersScope = request.filtersScope
        searchDatePolicy = request.searchDatePolicy
        relativeScopeInterval = request.relativeScopeInterval
        calendar = request.calendar
    }
}

@MainActor
final class RegisterPresentationCache {
    typealias Renderer = @Sendable (RegisterRenderRequest) async throws -> RegisterRenderResult
    private struct Entry {
        let result: RegisterRenderResult
        let cost: Int
        var access: UInt64
    }
    private final class Pending {
        let id = UUID()
        let key: RegisterPresentationCacheKey
        let request: RegisterRenderRequest
        let order: UInt64
        let memoryEpoch: UInt64
        var waiters: [UUID: CheckedContinuation<RegisterRenderResult, Error>] = [:]
        var visibleWaiters: Set<UUID> = []
        var task: Task<Void, Never>?
        init(key: RegisterPresentationCacheKey, request: RegisterRenderRequest, order: UInt64, memoryEpoch: UInt64) {
            self.key = key; self.request = request; self.order = order; self.memoryEpoch = memoryEpoch
        }
    }
    private var entries: [RegisterPresentationCacheKey: Entry] = [:]
    private var pending: [RegisterPresentationCacheKey: Pending] = [:]
    private var clock: UInt64 = 0
    private var memoryEpoch: UInt64 = 0
    private var totalCost = 0
    private let maximumEntries: Int
    private let maximumRows: Int
    private let maximumConcurrentRenders: Int
    private let renderer: Renderer
    private var memoryWarning: RegisterCacheMemoryWarning?
    private(set) var revision: UInt64 = 0
    private(set) var renderCount = 0
    private(set) var hitCount = 0
    private(set) var joinedCount = 0
    private(set) var activeRenderCount = 0
    private(set) var maximumObservedActiveRenders = 0
    var entryCount: Int { entries.count }
    var retainedRows: Int { totalCost }
    var queuedCount: Int { pending.values.filter { $0.task == nil }.count }

    init(maximumEntries: Int = 6, maximumRows: Int = 100_000, maximumConcurrentRenders: Int = 2,
         renderer: @escaping Renderer = { try await RegisterRenderWorker.shared.render($0) }) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumRows = max(1, maximumRows)
        self.maximumConcurrentRenders = max(1, maximumConcurrentRenders)
        self.renderer = renderer
        memoryWarning = RegisterCacheMemoryWarning { [weak self] in self?.purge() }
    }

    func cached(for key: RegisterPresentationCacheKey) -> RegisterRenderResult? {
        guard key.revision == revision, var entry = entries[key] else { return nil }
        clock &+= 1; entry.access = clock; entries[key] = entry
        hitCount += 1
        return entry.result
    }

    func load(_ request: RegisterRenderRequest, key: RegisterPresentationCacheKey, speculative: Bool = false) async throws -> RegisterRenderResult {
        try Task.checkCancellation()
        guard key.revision == revision else { throw CancellationError() }
        if let cached = cached(for: key) { return cached }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let work: Pending
                if let existing = pending[key] {
                    joinedCount += 1
                    work = existing
                } else {
                    clock &+= 1
                    work = Pending(key: key, request: request, order: clock, memoryEpoch: memoryEpoch)
                    pending[key] = work
                }
                work.waiters[waiterID] = continuation
                if !speculative { work.visibleWaiters.insert(waiterID) }
                // A newly visible screen has priority over abandoned/prewarm
                // jobs. Active count stays occupied until cancellation finishes.
                if !speculative, activeRenderCount >= maximumConcurrentRenders {
                    let obsolete = pending.values.filter { $0.id != work.id && $0.task != nil && $0.visibleWaiters.isEmpty }
                    for item in obsolete { cancel(item) }
                }
                startNext()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID, for: key) }
        }
    }

    @discardableResult
    func invalidate() -> UInt64 {
        revision &+= 1
        for work in Array(pending.values) { cancel(work) }
        entries.removeAll(); totalCost = 0
        memoryEpoch &+= 1
        return revision
    }

    func purge() {
        entries.removeAll(); totalCost = 0
        memoryEpoch &+= 1
        // Keep visible waiters alive, but their pre-warning results won't refill
        // the cache. Speculative/abandoned work yields memory immediately.
        for work in pending.values.filter({ $0.visibleWaiters.isEmpty }) { cancel(work) }
        startNext()
    }

    private func cancelWaiter(_ id: UUID, for key: RegisterPresentationCacheKey) {
        guard let work = pending[key], let continuation = work.waiters.removeValue(forKey: id) else { return }
        work.visibleWaiters.remove(id)
        continuation.resume(throwing: CancellationError())
        if work.waiters.isEmpty && work.task == nil { pending.removeValue(forKey: key) }
        let visibleQueued = pending.values.contains { $0.task == nil && !$0.visibleWaiters.isEmpty }
        if work.visibleWaiters.isEmpty && visibleQueued { cancel(work) }
        startNext()
    }

    private func cancel(_ work: Pending) {
        guard pending[work.key]?.id == work.id else { return }
        pending.removeValue(forKey: work.key)
        let waiters = work.waiters.values
        work.waiters.removeAll(); work.visibleWaiters.removeAll()
        work.task?.cancel()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }

    private func startNext() {
        while activeRenderCount < maximumConcurrentRenders {
            guard let work = pending.values.filter({ $0.task == nil && !$0.waiters.isEmpty }).min(by: {
                if $0.visibleWaiters.isEmpty != $1.visibleWaiters.isEmpty { return !$0.visibleWaiters.isEmpty }
                return $0.order < $1.order
            }) else { return }
            activeRenderCount += 1
            maximumObservedActiveRenders = max(maximumObservedActiveRenders, activeRenderCount)
            renderCount += 1
            let renderer = renderer
            work.task = Task(priority: work.visibleWaiters.isEmpty ? .utility : .userInitiated) {
                let result: Result<RegisterRenderResult, Error>
                do { result = .success(try await renderer(work.request)) }
                catch { result = .failure(error) }
                self.finish(work, result: result)
            }
        }
    }

    private func finish(_ work: Pending, result: Result<RegisterRenderResult, Error>) {
        activeRenderCount -= 1
        work.task = nil
        guard pending[work.key]?.id == work.id else { startNext(); return }
        pending.removeValue(forKey: work.key)
        let delivered: Result<RegisterRenderResult, Error>
        if work.key.revision != revision { delivered = .failure(CancellationError()) }
        else { delivered = result }
        if case .success(let value) = delivered, work.memoryEpoch == memoryEpoch { insert(value, for: work.key) }
        let waiters = work.waiters.values
        work.waiters.removeAll(); work.visibleWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: delivered) }
        startNext()
    }

    private func insert(_ result: RegisterRenderResult, for key: RegisterPresentationCacheKey) {
        let cost = max(1, result.presentation.amounts.count)
        guard cost <= maximumRows else { return }
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
        while entries.count >= maximumEntries || totalCost + cost > maximumRows {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            totalCost -= removed.cost
        }
        clock &+= 1
        entries[key] = Entry(result: result, cost: cost, access: clock)
        totalCost += cost
    }
}

private final class RegisterCacheMemoryWarning: @unchecked Sendable {
    let token: NSObjectProtocol
    @MainActor init(onWarning: @escaping @MainActor @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in onWarning() }
        }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}
