import CryptoKit
import Foundation

extension Notification.Name {
    static let financesCloudKitRemoteChange = Notification.Name("FinancesCloudKitRemoteChange")
    static let financesCloudKitPushRegistrationSucceeded = Notification.Name("FinancesCloudKitPushRegistrationSucceeded")
    static let financesCloudKitPushRegistrationFailed = Notification.Name("FinancesCloudKitPushRegistrationFailed")
}

struct CloudKitSyncDependencies: Sendable {
    var configuration: @Sendable () -> CloudKitSyncConfiguration?
    var makeClient: @Sendable (CloudKitSyncConfiguration) throws -> any CloudKitSyncTransport
    var automaticTriggersEnabled = true
    var now: @Sendable () -> Date = { Date() }
    /// Shorter than iOS's background execution allowance; injectable for deterministic tests.
    var backgroundRefreshDeadline: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(20)) }

    /// Optional instrumentation runs after a database operation is admitted.
    var beforeDatabaseOperation: (@Sendable () -> Void)? = nil

    static let live = Self(
        configuration: { CloudKitSyncConfiguration.availableConfiguration() },
        makeClient: { try CloudKitSyncClient(configuration: $0) }
    )
}

enum CloudKitBackgroundRefreshOutcome: Equatable, Sendable {
    case newData, noData, failed
}

/// Registration success is acknowledged by the platform delegate, not by the request call.
struct CloudKitPushRegistrationState: Equatable {
    enum Phase: Equatable { case idle, requesting, registered, retryAfter(Date) }
    private(set) var phase: Phase = .idle
    private var failures = 0
    mutating func beginIfNeeded(at now: Date) -> Bool {
        switch phase {
        case .requesting, .registered: return false
        case .retryAfter(let deadline) where now < deadline: return false
        case .idle, .retryAfter: phase = .requesting; return true
        }
    }
    mutating func succeeded() {
        // APNs callbacks have no attempt ID. A success while the current
        // registration intent is enabled also supersedes a stale failure.
        guard phase != .idle else { return }
        phase = .registered; failures = 0
    }
    mutating func failed(at now: Date) {
        guard phase == .requesting else { return }
        failures = min(failures + 1, 5)
        phase = .retryAfter(now.addingTimeInterval(min(30 * pow(2, Double(failures - 1)), 300)))
    }
    @discardableResult mutating func stop() -> Bool {
        let requested = phase != .idle
        phase = .idle; failures = 0
        return requested
    }
}

/// Closing admission never waits for SQLite. An already admitted atomic operation
/// finishes, while queued operations are rejected. Explicit Off additionally drains
/// admitted work before the host persists its disabled setting.
final class CloudKitPersistenceGate: @unchecked Sendable {
    private let stateLock = NSLock()
    private let workLock = NSRecursiveLock()
    private var closed = false

    func closeAdmission() { stateLock.lock(); closed = true; stateLock.unlock() }
    func waitForAdmittedWork() { workLock.lock(); workLock.unlock() }
    func checkCancellation() throws {
        try Task.checkCancellation()
        stateLock.lock(); let canceled = closed; stateLock.unlock()
        if canceled { throw CancellationError() }
    }
    func whileActive<T>(_ body: () throws -> T) throws -> T {
        workLock.lock(); defer { workLock.unlock() }
        // This check is the admission point; cancellation after it permits only
        // this atomic operation to finish, without admitting its queued successor.
        try checkCancellation()
        return try body()
    }
}

@MainActor
private final class CloudKitBackgroundRefreshRequest {
    let id = UUID()
    var passID: UUID
    var waitsForFollowUp: Bool
    let initialRemoteChangeGeneration: UInt64
    var deadlineTask: Task<Void, Never>?
    private var outcome: CloudKitBackgroundRefreshOutcome?
    private var continuation: CheckedContinuation<CloudKitBackgroundRefreshOutcome, Never>?
    init(passID: UUID, waitsForFollowUp: Bool, generation: UInt64) {
        self.passID = passID; self.waitsForFollowUp = waitsForFollowUp; initialRemoteChangeGeneration = generation
    }
    func value() async -> CloudKitBackgroundRefreshOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: CloudKitBackgroundRefreshOutcome) {
        guard outcome == nil else { return }
        outcome = value; deadlineTask?.cancel(); deadlineTask = nil
        continuation?.resume(returning: value); continuation = nil
    }
}

/// Both app targets commit through their own local-save queue. No suspension is
/// permitted between reading the current journal, validation, and this commit.
@MainActor
protocol CloudKitJournalSyncHost: AnyObject {
    var cloudKitJournalData: JournalData { get }
    var cloudKitSQLiteStore: SQLiteJournalStore { get }
    func cloudKitFlushLocalChanges() throws
    func cloudKitValidate(_ candidate: JournalData) throws
    func cloudKitCommitRemote(_ records: [CloudKitSyncRecord], data: JournalData, contextKey: String, changeToken: Data?) throws
    func cloudKitCommitConflictResolution(id: String, keepLocal: Bool, data: JournalData, contextKey: String) throws
    func cloudKitAttachmentURL(for asset: AttachmentAsset) throws -> URL
    func cloudKitSyncDidUpdate(_ progress: CloudSyncProgress)
    func cloudKitSyncDidFail(_ message: String)
    func cloudKitSyncDidFinish(at date: Date) throws
}

/// Value-only journal snapshots cross the database queue without sharing mutable
/// model references. The models contain Foundation value types and arrays.
private struct CloudKitJournalSnapshot: @unchecked Sendable {
    let data: JournalData
}

@MainActor
final class CloudKitJournalSyncCoordinator {
    private weak var host: (any CloudKitJournalSyncHost)?
    private let dependencies: CloudKitSyncDependencies
    private var activeID: UUID?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var client: (any CloudKitSyncTransport)?
    private var gate: CloudKitPersistenceGate?
    private var persistenceGates: [UUID: CloudKitPersistenceGate] = [:]
    private var reportsProgress = false
    private var needsFollowUp = false
    private var activePassIsBackgroundOwned = false
    private var backgroundRequests: [UUID: CloudKitBackgroundRefreshRequest] = [:]
    private var remoteChangeGeneration: UInt64 = 0
    private var retryNotBefore: Date?
    private var failureCount = 0
    private nonisolated static let databaseQueue = DispatchQueue(label: "Finances.CloudKit.database", qos: .utility)

    init(host: any CloudKitJournalSyncHost, dependencies: CloudKitSyncDependencies = .live) {
        self.host = host
        self.dependencies = dependencies
    }

    var isSyncing: Bool { activeID != nil }

    func synchronize(reportProgress: Bool = true, requireFollowUpIfBusy: Bool = true) {
        guard let host, host.cloudKitJournalData.syncEnabled else { return }
        if activeID != nil {
            // Manual, local-edit, and foreground work must survive a push deadline.
            activePassIsBackgroundOwned = false
            reportsProgress = reportsProgress || reportProgress
            needsFollowUp = needsFollowUp || requireFollowUpIfBusy
            return
        }
        _ = startPass(reportProgress: reportProgress, backgroundOwned: false)
    }

    @discardableResult
    private func startPass(reportProgress: Bool, backgroundOwned: Bool) -> UUID? {
        guard activeID == nil, let host, host.cloudKitJournalData.syncEnabled else { return nil }
        if let retryNotBefore, retryNotBefore > dependencies.now() {
            if reportProgress {
                host.cloudKitSyncDidUpdate(.failed(message: "Waiting for iCloud", detail: "iCloud requested a pause. Your changes remain saved on this device."))
            }
            return nil
        }
        guard let configuration = dependencies.configuration() else {
            if reportProgress {
                let message = CloudKitSyncConfiguration().validationErrorForCurrentApplication()
                    ?? "CloudKit is not configured for this build."
                host.cloudKitSyncDidUpdate(.failed(message: "iCloud unavailable", detail: message))
                host.cloudKitSyncDidFail(message)
            }
            return nil
        }
        let id = UUID()
        let gate = CloudKitPersistenceGate()
        activeID = id
        activePassIsBackgroundOwned = backgroundOwned
        self.gate = gate
        persistenceGates[id] = gate
        reportsProgress = reportProgress
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id, gate: gate, configuration: configuration)
        }
        return id
    }

    /// Returns on its own deadline even if a joined manual transport ignores cancellation.
    /// Only a still-owned exact pass with no remaining push watchers may be canceled.
    func backgroundRefresh(isForeground: Bool = false) async -> CloudKitBackgroundRefreshOutcome {
        guard !Task.isCancelled, let host, host.cloudKitJournalData.syncEnabled else { return .noData }
        let passID: UUID
        let waitsForFollowUp: Bool
        if let current = activeID {
            if isForeground {
                activePassIsBackgroundOwned = false
                // The foreground still needs the post-checkpoint fetch even if
                // the APNs completion budget expires before this pass ends.
                needsFollowUp = true
            }
            passID = current; waitsForFollowUp = true
        } else if let started = startPass(reportProgress: false, backgroundOwned: !isForeground) {
            passID = started; waitsForFollowUp = false
        } else { return .failed }
        let request = CloudKitBackgroundRefreshRequest(passID: passID, waitsForFollowUp: waitsForFollowUp, generation: remoteChangeGeneration)
        backgroundRequests[request.id] = request
        let waitForDeadline = dependencies.backgroundRefreshDeadline
        request.deadlineTask = Task { [weak self, weak request] in
            do { try await waitForDeadline() } catch { return }
            guard !Task.isCancelled, let self, let request else { return }
            self.finishBackgroundRequest(request.id, outcome: .failed, mayCancelOwnedPass: true)
        }
        let id = request.id
        return await withTaskCancellationHandler {
            await request.value()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishBackgroundRequest(id, outcome: .noData, mayCancelOwnedPass: true)
            }
        }
    }

    /// A scene leaving the foreground has no open-ended execution allowance.
    /// Preserve only work covered by a still-live APNs completion lease.
    func suspendForegroundWork() {
        guard let id = activeID, !activePassIsBackgroundOwned else { return }
        needsFollowUp = false; reportsProgress = false
        if backgroundRequests.values.contains(where: { $0.passID == id }) {
            activePassIsBackgroundOwned = true
        } else {
            retireActivePass(waitForDatabase: false)
            host?.cloudKitSyncDidUpdate(.idle)
        }
    }

    private func finishBackgroundRequest(_ id: UUID, outcome: CloudKitBackgroundRefreshOutcome, mayCancelOwnedPass: Bool = false) {
        guard let request = backgroundRequests.removeValue(forKey: id) else { return }
        let disabled = host?.cloudKitJournalData.syncEnabled != true
        let result: CloudKitBackgroundRefreshOutcome
        if disabled || outcome == .noData { result = .noData }
        else if remoteChangeGeneration != request.initialRemoteChangeGeneration { result = .newData }
        else { result = outcome }
        request.finish(result)
        guard mayCancelOwnedPass, activeID == request.passID, activePassIsBackgroundOwned,
              !backgroundRequests.values.contains(where: { $0.passID == request.passID }) else { return }
        retireActivePass(waitForDatabase: false)
        if !disabled, outcome == .failed {
            host?.cloudKitSyncDidUpdate(.failed(message: "Background sync paused", detail: "The background time allowance ended. Local changes remain saved for the next sync."))
        } else { host?.cloudKitSyncDidUpdate(.idle) }
    }

    private func finishPass(_ id: UUID, succeeded: Bool, canceled: Bool) {
        tasks.removeValue(forKey: id)
        persistenceGates.removeValue(forKey: id)
        guard activeID == id else { return }
        let watching = backgroundRequests.values.filter { $0.passID == id }
        let followUpWatchers = watching.filter(\.waitsForFollowUp)
        let ordinaryFollowUp = needsFollowUp
        let continueSync = succeeded && !Task.isCancelled && host?.cloudKitJournalData.syncEnabled == true
        activeID = nil; client = nil; gate = nil
        activePassIsBackgroundOwned = false; reportsProgress = false; needsFollowUp = false
        let nextID = continueSync && (ordinaryFollowUp || !followUpWatchers.isEmpty)
            ? startPass(reportProgress: false, backgroundOwned: !ordinaryFollowUp) : nil
        for request in watching {
            if request.waitsForFollowUp, let nextID {
                request.passID = nextID; request.waitsForFollowUp = false
            } else {
                let outcome: CloudKitBackgroundRefreshOutcome
                if canceled || host?.cloudKitJournalData.syncEnabled != true { outcome = .noData }
                else if remoteChangeGeneration != request.initialRemoteChangeGeneration { outcome = .newData }
                else { outcome = succeeded && (!request.waitsForFollowUp || nextID != nil) ? .noData : .failed }
                finishBackgroundRequest(request.id, outcome: outcome)
            }
        }
    }

    /// Retire ownership first. Late callbacks cannot finish, report errors, or
    /// erase the state of a replacement pass started by a rapid Off/On toggle.
    func cancel() {
        retireActivePass()
        let requests = Array(backgroundRequests.keys)
        for id in requests { finishBackgroundRequest(id, outcome: .noData) }
        host?.cloudKitSyncDidUpdate(.idle)
    }

    private func retireActivePass(waitForDatabase: Bool = true) {
        let task = activeID.flatMap { tasks[$0] }
        let oldClient = client, oldGate = gate
        activeID = nil; client = nil; gate = nil
        activePassIsBackgroundOwned = false
        needsFollowUp = false; reportsProgress = false
        if waitForDatabase {
            // Include a pass retired by a deadline: Off must still wait for any
            // admitted write from that pass before changing local persistence.
            let ownedGates = Array(persistenceGates.values)
            for gate in ownedGates { gate.closeAdmission() }
            for gate in ownedGates { gate.waitForAdmittedWork() }
        } else { oldGate?.closeAdmission() }
        oldClient?.cancel(); task?.cancel()
    }

    func waitUntilIdle() async {
        while !tasks.isEmpty {
            for task in Array(tasks.values) { await task.value }
        }
    }

    func waitForRetiredPasses() async {
        let current = activeID
        for (id, task) in Array(tasks) where id != current { await task.value }
    }

    func conflicts() throws -> [CloudKitSyncConflict] {
        guard let host, let context = try host.cloudKitSQLiteStore.cloudKitBoundContextKey() else { return [] }
        return try host.cloudKitSQLiteStore.unresolvedCloudKitConflicts(contextKey: context)
    }

    func resolveConflict(id: String, keepLocal: Bool) throws {
        cancel()
        guard let host, let context = try host.cloudKitSQLiteStore.cloudKitBoundContextKey(),
              let conflict = try host.cloudKitSQLiteStore.unresolvedCloudKitConflicts(contextKey: context).first(where: { $0.id == id }) else { return }
        try host.cloudKitFlushLocalChanges()
        if !keepLocal, conflict.remote.recordType == "attachment_asset", conflict.remote.operation != "delete" {
            guard host.cloudKitJournalData.syncEnabled else {
                throw CloudKitSyncError.unavailable("Turn on iCloud Sync to download the selected receipt version.")
            }
            guard let configuration = dependencies.configuration() else {
                throw CloudKitSyncError.unavailable("A signed iCloud-enabled build is required to download this receipt.")
            }
            guard [configuration.containerIdentifier, configuration.environment, configuration.zoneName].joined(separator: "|") == context else {
                throw CloudKitSyncError.unavailable("This build uses a different iCloud environment. The original journal binding was preserved.")
            }
            let passID = UUID()
            let gate = CloudKitPersistenceGate()
            activeID = passID
            self.gate = gate
            persistenceGates[passID] = gate
            reportsProgress = true
            tasks[passID] = Task { [weak self] in
                guard let self else { return }
                await self.resolveRemoteReceipt(conflict, context: context, configuration: configuration, id: passID, gate: gate)
            }
            return
        }
        // Keep Local means the latest on-device value, including any edit made
        // after the conflict was first presented. Remote choice is revalidated
        // against the exact pending version inside the SQLite transaction.
        let candidate = keepLocal ? host.cloudKitJournalData
            : try CloudKitJournalMerger.applying([conflict.remote], to: host.cloudKitJournalData)
        try host.cloudKitValidate(candidate)
        try host.cloudKitCommitConflictResolution(id: id, keepLocal: keepLocal, data: candidate, contextKey: context)
        if host.cloudKitJournalData.syncEnabled { synchronize() }
    }

    private func resolveRemoteReceipt(_ conflict: CloudKitSyncConflict, context: String, configuration: CloudKitSyncConfiguration, id: UUID, gate: CloudKitPersistenceGate) async {
        var remoteClient: (any CloudKitSyncTransport)?
        var resolved = false
        defer {
            remoteClient?.cancel()
            if activeID == id, resolved { needsFollowUp = true }
            finishPass(id, succeeded: resolved, canceled: Task.isCancelled)
        }
        do {
            try check(id, gate: gate)
            guard let host else { throw CancellationError() }
            let client = try dependencies.makeClient(configuration)
            remoteClient = client
            self.client = client
            let account = try await client.accountIdentifier()
            try check(id, gate: gate)
            _ = try await database(gate: gate) { try $0.bindCloudKitAccount(contextKey: context, accountID: account) }
            try check(id, gate: gate)
            progress(id, "Downloading the selected iCloud receipt")
            let remote = try await client.fetchRecord(recordType: conflict.remote.recordType, recordID: conflict.remote.recordID)
            try check(id, gate: gate)
            guard CloudKitJournalMerger.sameValue(remote, conflict.remote) else {
                if try Self.persistConflict(local: conflict.local, remote: remote, context: context, store: host.cloudKitSQLiteStore, trackChange: !backgroundRequests.isEmpty) {
                    remoteChangeGeneration &+= 1
                }
                throw CloudKitSyncError.service("The iCloud receipt changed again. Review its latest version before choosing.")
            }
            try host.cloudKitFlushLocalChanges()
            let candidate = try CloudKitJournalMerger.applying([remote], to: host.cloudKitJournalData)
            try host.cloudKitValidate(candidate)
            let retained = Set(candidate.transactions.flatMap { $0.attachment?.assets.map(\.id) ?? [] })
            try withInstalledReceipts([remote], retainedAssetIDs: retained, knownRecords: [:], gate: gate) {
                try check(id, gate: gate)
                try host.cloudKitCommitConflictResolution(id: conflict.id, keepLocal: false, data: candidate, contextKey: context)
            }
            if !backgroundRequests.isEmpty { remoteChangeGeneration &+= 1 }
            host.cloudKitSyncDidUpdate(.succeeded(message: "iCloud version restored"))
            resolved = true
        } catch {
            guard activeID == id else { return }
            if error is CancellationError || host?.cloudKitJournalData.syncEnabled != true {
                host?.cloudKitSyncDidUpdate(.idle)
            } else {
                host?.cloudKitSyncDidUpdate(.failed(message: "Receipt could not be restored", detail: error.localizedDescription))
                host?.cloudKitSyncDidFail(error.localizedDescription)
            }
        }
    }

    private func check(_ id: UUID, gate: CloudKitPersistenceGate) throws {
        try gate.checkCancellation()
        guard activeID == id, host?.cloudKitJournalData.syncEnabled == true else { throw CancellationError() }
    }

    private func progress(_ id: UUID, _ message: String, fraction: Double? = nil) {
        guard activeID == id, reportsProgress else { return }
        host?.cloudKitSyncDidUpdate(.running(message: message, fractionCompleted: fraction))
    }

    private func database<T: Sendable>(gate: CloudKitPersistenceGate, _ operation: @escaping @Sendable (SQLiteJournalStore) throws -> T) async throws -> T {
        guard let host else { throw CancellationError() }
        let url = host.cloudKitSQLiteStore.databaseURL
        let beforeOperation = dependencies.beforeDatabaseOperation
        try gate.checkCancellation()
        let result: T = try await withCheckedThrowingContinuation { continuation in
            Self.databaseQueue.async {
                do {
                    let value = try gate.whileActive {
                        beforeOperation?()
                        return try operation(SQLiteJournalStore(databaseURL: url))
                    }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
        try gate.checkCancellation()
        return result
    }

    private func run(id: UUID, gate: CloudKitPersistenceGate, configuration: CloudKitSyncConfiguration) async {
        var succeeded = false
        var canceled = false
        var passClient: (any CloudKitSyncTransport)?
        defer {
            passClient?.cancel() // Release owned temporary receipt files.
            finishPass(id, succeeded: succeeded, canceled: canceled)
        }
        do {
            try check(id, gate: gate)
            guard let host else { throw CancellationError() }
            try host.cloudKitFlushLocalChanges()
            let client = try dependencies.makeClient(configuration)
            self.client = client
            passClient = client
            progress(id, "Checking iCloud account", fraction: 0.02)
            let account = try await client.accountIdentifier()
            try check(id, gate: gate)
            let context = [configuration.containerIdentifier, configuration.environment, configuration.zoneName].joined(separator: "|")
            _ = try await database(gate: gate) { try $0.bindCloudKitAccount(contextKey: context, accountID: account) }
            try check(id, gate: gate)
            let startingToken = try await database(gate: gate) { try $0.cloudKitChangeToken(contextKey: context) }
            let known = try await database(gate: gate) { try $0.knownCloudKitRecords(contextKey: context) }
            try check(id, gate: gate)
            if startingToken == nil && known.isEmpty {
                try await client.prepareZone()
                try check(id, gate: gate)
            }
            // Protect a populated Cloudflare-era journal before merging its
            // first iCloud download. A fresh empty device downloads first.
            if !host.cloudKitJournalData.ledgers.isEmpty {
                let snapshot = CloudKitJournalSnapshot(data: host.cloudKitJournalData)
                _ = try await database(gate: gate) { try $0.prepareInitialCloudKitSnapshot(snapshot.data, contextKey: context) }
                try check(id, gate: gate)
            }
            progress(id, "Downloading iCloud changes", fraction: 0.12)
            var token = startingToken
            var fetched: [String: CloudKitSyncRecord] = [:]
            var retriedExpiredToken = false
            while true {
                let page: CloudKitSyncPage
                do { page = try await client.fetchChanges(since: token) }
                catch CloudKitSyncError.changeTokenExpired where !retriedExpiredToken {
                    try check(id, gate: gate)
                    // Do not erase the durable checkpoint until the complete
                    // replacement fetch has been validated and committed.
                    token = nil
                    fetched.removeAll()
                    retriedExpiredToken = true
                    continue
                }
                try check(id, gate: gate)
                for record in page.records { fetched[record.key] = record }
                if page.moreComing && (page.changeToken == nil || page.changeToken == token) {
                    throw CloudKitSyncError.invalidData("iCloud returned a non-advancing page. No journal checkpoint was changed.")
                }
                token = page.changeToken
                if !page.moreComing { break }
            }
            try check(id, gate: gate)
            try commitFetched(Array(fetched.values), token: token, context: context, id: id, gate: gate)
            let snapshot = CloudKitJournalSnapshot(data: host.cloudKitJournalData)
            _ = try await database(gate: gate) { try $0.prepareInitialCloudKitSnapshot(snapshot.data, contextKey: context) }
            try check(id, gate: gate)

            var uploaded = 0
            while true {
                try check(id, gate: gate)
                try host.cloudKitFlushLocalChanges()
                var pending = try await database(gate: gate) { try $0.claimCloudKitChanges(contextKey: context, limit: 50) }
                try check(id, gate: gate)
                if pending.isEmpty { break }
                for index in pending.indices where pending[index].recordType == "attachment_asset" && pending[index].operation != "delete" {
                    guard let bytes = pending[index].payloadJSON?.data(using: .utf8) else { throw CloudKitSyncError.invalidData("A queued receipt is missing its metadata.") }
                    let asset = try JSONDecoder.appDecoder.decode(AttachmentAsset.self, from: bytes)
                    let url = try host.cloudKitAttachmentURL(for: asset)
                    guard FileManager.default.fileExists(atPath: url.path) else { throw CloudKitSyncError.invalidData("A receipt is missing on this device. Restore it before syncing: \(asset.originalFilename)") }
                    pending[index].assetFileURL = url
                    pending[index].assetFilename = asset.originalFilename
                    pending[index].assetMIMEType = asset.mimeType
                    // The transport freezes/checks the bytes before handing the
                    // CKAsset to CloudKit; JSON hash and blob hash stay distinct.
                }
                progress(id, "Uploading changes to iCloud", fraction: 0.55)
                let submitted = pending
                let response = try await client.modifyRecords(submitted)
                try check(id, gate: gate)
                let submittedByKey = Dictionary(uniqueKeysWithValues: submitted.map { ($0.key, $0) })
                let accepted = response.saved
                var equivalent: [CloudKitSyncRecord] = []
                var conflicts: [(CloudKitSyncRecord, CloudKitSyncRecord)] = []
                for remote in response.conflicts {
                    guard let local = submittedByKey[remote.key] else { throw CloudKitSyncError.invalidData("iCloud returned an unrelated conflict.") }
                    if CloudKitJournalMerger.sameValue(local, remote) { equivalent.append(remote) }
                    else { conflicts.append((local, remote)) }
                }
                if !accepted.isEmpty {
                    let values = accepted
                    _ = try await database(gate: gate) { try $0.acknowledgeCloudKitRecords(values, submitted: submitted, contextKey: context) }
                    try check(id, gate: gate)
                    uploaded += accepted.count
                }
                if !equivalent.isEmpty {
                    let values = equivalent
                    _ = try await database(gate: gate) { try $0.acknowledgeCloudKitEquivalentRecords(values, submitted: submitted, contextKey: context) }
                    try check(id, gate: gate)
                    uploaded += equivalent.count
                }
                for (local, remote) in conflicts {
                    // A background watcher may join while this write is suspended.
                    let changed = try await database(gate: gate) {
                        try Self.persistConflict(local: local, remote: remote, context: context, store: $0, trackChange: true)
                    }
                    try check(id, gate: gate)
                    if changed { remoteChangeGeneration &+= 1 }
                }
                if !conflicts.isEmpty { throw CloudKitSyncError.service("Both this device and iCloud changed the same item. Review sync conflicts to choose which version to keep.") }
                if let message = response.failureMessage {
                    throw CloudKitSyncError.retryable(message, response.retryAfter)
                }
                if let delay = response.retryAfter { throw CloudKitSyncError.retryable("iCloud requested a pause. Local changes remain queued.", delay) }
                guard !accepted.isEmpty || !equivalent.isEmpty else { throw CloudKitSyncError.invalidData("iCloud did not acknowledge the upload. Its original retry IDs remain queued.") }
            }
            try check(id, gate: gate)
            let unresolved = try await database(gate: gate) { try $0.unresolvedCloudKitConflicts(contextKey: context) }
            try check(id, gate: gate)
            guard unresolved.isEmpty else {
                throw CloudKitSyncError.service("Some iCloud changes need review. Choose which version to keep in Sync settings.")
            }
            try host.cloudKitSyncDidFinish(at: dependencies.now())
            try check(id, gate: gate)
            failureCount = 0
            retryNotBefore = nil
            succeeded = true
            host.cloudKitSyncDidUpdate(.succeeded(message: "Synced with iCloud", detail: fetched.isEmpty && uploaded == 0 ? "Everything is up to date." : "Downloaded \(fetched.count) changes and uploaded \(uploaded) changes."))
        } catch {
            guard activeID == id else { return }
            if error is CancellationError || host?.cloudKitJournalData.syncEnabled != true {
                canceled = true
                host?.cloudKitSyncDidUpdate(.idle)
                return
            }
            if case CloudKitSyncError.retryable(_, let delay) = error {
                failureCount = min(failureCount + 1, 6)
                retryNotBefore = dependencies.now().addingTimeInterval(max(delay ?? 0, min(30 * pow(2, Double(failureCount - 1)), 900)))
            }
            host?.cloudKitSyncDidUpdate(.failed(message: "iCloud sync paused", detail: error.localizedDescription))
            if reportsProgress { host?.cloudKitSyncDidFail(error.localizedDescription) }
        }
    }

    private func commitFetched(_ records: [CloudKitSyncRecord], token: Data?, context: String, id: UUID, gate: CloudKitPersistenceGate) throws {
        try check(id, gate: gate)
        guard let host else { throw CancellationError() }
        try host.cloudKitFlushLocalChanges()
        let store = host.cloudKitSQLiteStore
        let pending = try store.pendingCloudKitRecords(contextKey: context)
        let known = try store.knownCloudKitRecords(contextKey: context)
        let versions = try store.pendingSyncRecordsByKey()
        var applicable: [CloudKitSyncRecord] = []
        var containsNewContent = false
        var changedReceiptIDs: Set<UUID> = []
        for remote in records {
            // Earlier, already-accepted mutations can be replayed by a pull.
            // They must not replace a newer accepted value, even when no local
            // edit is pending. A reset can rebuild absent CAS metadata safely.
            let hasKnownOrPending = known[remote.key] != nil || pending[remote.key] != nil
            let acknowledgedEcho = try hasKnownOrPending && store.hasAcknowledgedCloudKitMutation(remote, contextKey: context)
            if let current = known[remote.key], acknowledgedEcho,
               !CloudKitJournalMerger.sameValue(current, remote) { continue }
            if let local = pending[remote.key], !CloudKitJournalMerger.sameValue(local, remote) {
                let isBaseReplay = known[remote.key].map { CloudKitJournalMerger.sameValue($0, remote) } ?? false
                let isEarlierEcho = remote.recordType != "attachment_asset" && (versions[remote.key]?.inFlightVersions.contains {
                    $0.operation == remote.operation && ($0.operation == "delete" || $0.contentHash == remote.contentHash)
                } ?? false)
                let receiptEcho = try remote.recordType == "attachment_asset"
                    && store.isCloudKitReceiptUploadEcho(remote, contextKey: context)
                if isBaseReplay || isEarlierEcho || receiptEcho || acknowledgedEcho { continue }
                if try Self.persistConflict(local: local, remote: remote, context: context, store: store, trackChange: !backgroundRequests.isEmpty) {
                    remoteChangeGeneration &+= 1
                }
                throw CloudKitSyncError.service("Both this device and iCloud changed the same item. Review sync conflicts to choose which version to keep.")
            }
            if remote.recordType == "ledger", remote.operation == "delete",
               try store.hasPendingDescendantChanges(of: remote.recordID) {
                throw CloudKitSyncError.service("iCloud deleted a journal that still contains unsynced local edits. Your local journal has been preserved.")
            }
            let equivalentLocal = pending[remote.key].map { CloudKitJournalMerger.sameValue($0, remote) } ?? false
            let equivalentKnown = known[remote.key].map { CloudKitJournalMerger.sameValue($0, remote) } ?? false
            let newContent = !acknowledgedEcho && !equivalentLocal && !equivalentKnown
            containsNewContent = containsNewContent || newContent
            if newContent, remote.recordType == "attachment_asset", remote.operation == "upsert", let id = UUID(uuidString: remote.recordID) {
                changedReceiptIDs.insert(id)
            }
            applicable.append(remote)
        }
        let previous = host.cloudKitJournalData
        let candidate = try CloudKitJournalMerger.applying(applicable, to: previous)
        try host.cloudKitValidate(candidate)
        let retained = Set(candidate.transactions.flatMap { $0.attachment?.assets.map(\.id) ?? [] })
        try withInstalledReceipts(applicable, retainedAssetIDs: retained, knownRecords: known, gate: gate) {
            try check(id, gate: gate)
            try host.cloudKitCommitRemote(records, data: candidate, contextKey: context, changeToken: token)
        }
        if !backgroundRequests.isEmpty, containsNewContent,
           !changedReceiptIDs.isDisjoint(with: retained) || Self.domainContentDiffers(previous, candidate) { remoteChangeGeneration &+= 1 }
    }

    private nonisolated static func persistConflict(local: CloudKitSyncRecord, remote: CloudKitSyncRecord, context: String,
                                                     store: SQLiteJournalStore, trackChange: Bool) throws -> Bool {
        let unchanged = try !trackChange || store.unresolvedCloudKitConflicts(contextKey: context).contains {
            CloudKitJournalMerger.sameValue($0.local, local) && CloudKitJournalMerger.sameValue($0.remote, remote)
        }
        try store.saveCloudKitConflict(local: local, remote: remote, contextKey: context)
        return !unchanged
    }

    private static func domainContentDiffers(_ lhs: JournalData, _ rhs: JournalData) -> Bool {
        lhs.ledgers != rhs.ledgers || lhs.commodities != rhs.commodities || lhs.accounts != rhs.accounts
            || lhs.transactions != rhs.transactions || lhs.sources != rhs.sources || lhs.transactionTemplates != rhs.transactionTemplates
            || SQLiteSyncedJournalMetadata(data: lhs) != SQLiteSyncedJournalMetadata(data: rhs)
    }

    private func withInstalledReceipts(_ records: [CloudKitSyncRecord], retainedAssetIDs: Set<UUID>, knownRecords: [String: CloudKitSyncRecord], gate: CloudKitPersistenceGate, commit: () throws -> Void) throws {
        guard let host else { throw CancellationError() }
        // Receipt replacements are reversible until SQLite commits. Network
        // staging is client-owned; moving it avoids copying an entire receipt
        // library on the UI actor during the first sync.
        var installations: [(destination: URL, backup: URL?)] = []
        let localAssets = host.cloudKitJournalData.transactions.flatMap { $0.attachment?.assets ?? [] }
            .reduce(into: [UUID: AttachmentAsset]()) { $0[$1.id] = $1 }
        do {
            for record in records where record.recordType == "attachment_asset" && record.operation == "delete" {
                guard let id = UUID(uuidString: record.recordID), !retainedAssetIDs.contains(id) else { continue }
                let knownAsset = knownRecords[record.key]?.payloadJSON?.data(using: .utf8)
                    .flatMap { try? JSONDecoder.appDecoder.decode(AttachmentAsset.self, from: $0) }
                guard let asset = localAssets[id] ?? knownAsset else { continue }
                let destination = try host.cloudKitAttachmentURL(for: asset)
                guard FileManager.default.fileExists(atPath: destination.path) else { continue }
                let backup = destination.deletingLastPathComponent().appendingPathComponent(".icloud-deleted-\(UUID().uuidString)")
                try gate.whileActive { try FileManager.default.moveItem(at: destination, to: backup) }
                installations.append((destination, backup))
            }
            for record in records where record.recordType == "attachment_asset" && record.operation != "delete" {
                guard let payload = record.payloadJSON?.data(using: .utf8) else { throw CloudKitSyncError.invalidData("An iCloud receipt is missing metadata.") }
                let asset = try JSONDecoder.appDecoder.decode(AttachmentAsset.self, from: payload)
                let destination = try host.cloudKitAttachmentURL(for: asset)
                if let source = record.assetFileURL {
                    try gate.whileActive {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let stage = destination.deletingLastPathComponent().appendingPathComponent(".icloud-\(UUID().uuidString)")
                        defer { try? FileManager.default.removeItem(at: stage) }
                        try FileManager.default.moveItem(at: source, to: stage)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            let backup = destination.deletingLastPathComponent().appendingPathComponent(".icloud-previous-\(UUID().uuidString)")
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage, backupItemName: backup.lastPathComponent, options: .withoutDeletingBackupItem)
                            installations.append((destination, backup))
                        } else {
                            try FileManager.default.moveItem(at: stage, to: destination)
                            installations.append((destination, nil))
                        }
                    }
                } else if !FileManager.default.fileExists(atPath: destination.path) {
                    throw CloudKitSyncError.invalidData("An iCloud receipt has not downloaded yet. The journal checkpoint was preserved.")
                }
            }
            try gate.checkCancellation()
            try gate.whileActive { try commit() }
        } catch {
            for installation in installations.reversed() {
                if let backup = installation.backup {
                    if FileManager.default.fileExists(atPath: installation.destination.path) {
                        _ = try FileManager.default.replaceItemAt(installation.destination, withItemAt: backup)
                    } else { try FileManager.default.moveItem(at: backup, to: installation.destination) }
                } else { try FileManager.default.removeItem(at: installation.destination) }
            }
            throw error
        }
        for installation in installations {
            if let backup = installation.backup { try? FileManager.default.removeItem(at: backup) }
        }

    }
}

enum CloudKitJournalMerger {
    static func sameValue(_ lhs: CloudKitSyncRecord, _ rhs: CloudKitSyncRecord) -> Bool {
        guard lhs.key == rhs.key, lhs.operation == rhs.operation else { return false }
        if lhs.operation == "delete" { return true }
        guard let hash = lhs.contentHash, hash == rhs.contentHash,
              lhs.payloadJSON == rhs.payloadJSON, lhs.parentRecordID == rhs.parentRecordID else { return false }
        if lhs.recordType == "attachment_asset" {
            guard let left = lhs.assetSHA256?.lowercased(), let right = rhs.assetSHA256?.lowercased(),
                  left.count == 64, right.count == 64 else { return false }
            return left == right && lhs.assetFilename == rhs.assetFilename
                && (lhs.assetMIMEType ?? "application/octet-stream") == (rhs.assetMIMEType ?? "application/octet-stream")
        }
        return true
    }

    static func applying(_ records: [CloudKitSyncRecord], to current: JournalData) throws -> JournalData {
        var candidate = current
        func decode<T: Decodable>(_ record: CloudKitSyncRecord, as type: T.Type) throws -> T {
            guard let payload = record.payloadJSON?.data(using: .utf8) else { throw CloudKitSyncError.invalidData("An iCloud \(record.recordType) record has no payload.") }
            return try JSONDecoder.appDecoder.decode(type, from: payload)
        }
        func identified<T: Decodable & Identifiable>(_ record: CloudKitSyncRecord, as type: T.Type) throws -> T where T.ID == UUID {
            let value: T = try decode(record, as: type)
            guard value.id == UUID(uuidString: record.recordID) else {
                throw CloudKitSyncError.invalidData("An iCloud payload does not match its record identity.")
            }
            return value
        }
        func requireParent(_ record: CloudKitSyncRecord, _ expected: UUID?) throws {
            guard record.parentRecordID.flatMap(UUID.init(uuidString:)) == expected else {
                throw CloudKitSyncError.invalidData("An iCloud record does not match its journal or parent.")
            }
        }
        func replace<T: Identifiable>(_ value: T, in values: inout [T]) where T.ID == UUID {
            if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
            else { values.append(value) }
        }
        for record in records where record.operation != "delete" {
            switch record.recordType {
            case "journal_metadata":
                guard UUID(uuidString: record.recordID) == SQLiteSyncedJournalMetadata.recordID else { throw CloudKitSyncError.invalidData("The iCloud preferences identity is invalid.") }
                try decode(record, as: SQLiteSyncedJournalMetadata.self).apply(to: &candidate)
            case "ledger":
                let value = try identified(record, as: Ledger.self)
                try requireParent(record, nil)
                replace(value, in: &candidate.ledgers)
            case "commodity":
                let value = try identified(record, as: Commodity.self)
                try requireParent(record, value.ledgerID)
                replace(value, in: &candidate.commodities)
            case "account":
                let value = try identified(record, as: Account.self)
                try requireParent(record, value.parentID ?? value.ledgerID)
                replace(value, in: &candidate.accounts)
            case "source":
                let value = try identified(record, as: TransactionSource.self)
                try requireParent(record, value.ledgerID)
                replace(value, in: &candidate.sources)
            case "transaction":
                let value = try identified(record, as: LedgerTransaction.self)
                try requireParent(record, value.ledgerID)
                replace(value, in: &candidate.transactions)
            case "transaction_template":
                let value = try identified(record, as: TransactionTemplate.self)
                try requireParent(record, value.ledgerID)
                replace(value, in: &candidate.transactionTemplates)
            case "attachment_asset":
                let _: AttachmentAsset = try identified(record, as: AttachmentAsset.self)
            default: throw CloudKitSyncError.invalidData("An iCloud record uses an unsupported schema. Update the app before syncing.")
            }
        }
        for record in records where record.recordType == "attachment_asset" && record.operation != "delete" {
            let asset = try identified(record, as: AttachmentAsset.self)
            for index in candidate.transactions.indices {
                guard var container = candidate.transactions[index].attachment,
                      let assetIndex = container.assets.firstIndex(where: { $0.id == asset.id }) else { continue }
                try requireParent(record, container.id)
                container.assets[assetIndex] = asset
                candidate.transactions[index].attachment = container
            }
        }
        for record in records where record.operation == "delete" {
            guard let id = UUID(uuidString: record.recordID) else { throw CloudKitSyncError.invalidData("An iCloud deletion has an invalid identity.") }
            switch record.recordType {
            case "ledger":
                candidate.ledgers.removeAll { $0.id == id }
                candidate.commodities.removeAll { $0.ledgerID == id }
                candidate.accounts.removeAll { $0.ledgerID == id }
                candidate.sources.removeAll { $0.ledgerID == id }
                candidate.transactions.removeAll { $0.ledgerID == id }
                candidate.transactionTemplates.removeAll { $0.ledgerID == id }
            case "commodity": candidate.commodities.removeAll { $0.id == id }
            case "account": candidate.accounts.removeAll { $0.id == id }
            case "source":
                candidate.sources.removeAll { $0.id == id }
                for index in candidate.transactions.indices where candidate.transactions[index].sourceID == id { candidate.transactions[index].sourceID = nil }
            case "transaction": candidate.transactions.removeAll { $0.id == id }
            case "transaction_template": candidate.transactionTemplates.removeAll { $0.id == id }
            case "attachment_asset":
                for index in candidate.transactions.indices { candidate.transactions[index].attachment?.assets.removeAll { $0.id == id } }
            case "journal_metadata": break
            default: throw CloudKitSyncError.invalidData("An iCloud deletion uses an unsupported schema.")
            }
        }
        if candidate.selectedLedgerID == nil || !candidate.ledgers.contains(where: { $0.id == candidate.selectedLedgerID }) {
            candidate.selectedLedgerID = candidate.ledgers.first?.id
        }
        return candidate
    }
}
