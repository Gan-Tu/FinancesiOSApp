import CloudKit
import CryptoKit
import Foundation


@MainActor
protocol CloudKitLiveVerificationStore: AnyObject, Sendable {
    var data: JournalData { get }
    var validationError: ValidationError? { get set }
    var requiresJournalRecovery: Bool { get }
    var cloudSyncProgress: CloudSyncProgress { get }
    var cloudKitSQLiteStore: SQLiteJournalStore { get }
    func setSyncEnabled(_ enabled: Bool)
    func requestCloudKitSync(reportProgress: Bool, requireFollowUpIfBusy: Bool)
    func waitForCloudKitSyncIdle() async
    func cloudKitSyncConflicts() -> [CloudKitSyncConflict]
    func resolveCloudKitSyncConflict(id: String, keepLocal: Bool)
    func balance(for accountID: UUID) -> Decimal
    func draft(for transaction: LedgerTransaction) -> TransactionDraft
    func saveTransaction(_ draft: TransactionDraft)
    func saveTransactionForFutureOccurrences(_ draft: TransactionDraft)
    func deleteTransaction(_ id: UUID)
    func importAttachment(from url: URL) throws -> AttachmentAsset
    func cloudKitAttachmentURL(for asset: AttachmentAsset) throws -> URL
    func liveIntegrityIsValid() -> Bool
    var automaticPushExecutionContext: CloudKitPeerPushExecutionContext { get }
    func startAutomaticPushVerification() throws
    func handleAutomaticPushNotification() async -> CloudKitBackgroundRefreshOutcome
    func stopAutomaticPushVerification()
}

extension CloudKitLiveVerificationStore {
    var automaticPushExecutionContext: CloudKitPeerPushExecutionContext { .unknown }
    func startAutomaticPushVerification() throws {
        throw CloudKitSyncError.unavailable("This QA adapter does not expose automatic notification handling.")
    }
    func handleAutomaticPushNotification() async -> CloudKitBackgroundRefreshOutcome { .failed }
    func stopAutomaticPushVerification() {}
}

/// Explicit live integration check. This entry point never opens the normal journal.
@MainActor
enum CloudKitLiveVerification {
    nonisolated static let flag = "--verify-cloudkit-live"
    nonisolated static var isRequested: Bool { isVerificationRequested(arguments: CommandLine.arguments) }
    nonisolated static func isVerificationRequested(arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.lowercased().hasPrefix("--verify-cloudkit") }
    }
    typealias StoreFactory = @MainActor @Sendable (URL, JournalData, CloudKitSyncDependencies) -> any CloudKitLiveVerificationStore

    nonisolated static func launchArgumentsError(arguments allArguments: [String] = CommandLine.arguments) -> String? {
        if allArguments.contains("--verify-cloudkit-peer") { return CloudKitPeerVerification.launchArgumentsError(arguments: allArguments) }
        let arguments = Array(allArguments.dropFirst())
        #if targetEnvironment(simulator)
        let allowed = [flag, "--allow-cloudkit-live-simulator"]
        guard arguments == [flag] || (arguments.count == 2 && Set(arguments) == Set(allowed)) else {
            return "Use only --verify-cloudkit-live and the optional simulator QA authorization flag."
        }
        #else
        guard arguments == [flag] else { return "Use only --verify-cloudkit-live; other launch arguments are rejected." }
        #endif
        return nil
    }
    private static let containerIdentifier = "iCloud.dev.gan.FinanceApp"

    struct Report: Codable {
        var status = "FAIL"
        var runID: String
        var container = "iCloud.dev.gan.FinanceApp"
        var environment = "Development"
        var zone: String
        var scope = "Three isolated SQLite stores using real CloudKit"
        var pushDeliveryVerified = false
        var physicalMultiDeviceVerified = false
        var passedScenarios: [String] = []
        var failure: String?
        var cleanup = "not-needed"
        var requestCounts: [String: Int] = [:]
        var durationSeconds: Double = 0
    }

    static func run(platform: String, makeStore: StoreFactory, onScenario: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async -> Report {
        let started = Date()
        let runID = UUID()
        let zoneName = "FinancesQA_\(runID.uuidString)"
        var report = Report(runID: runID.uuidString, zone: zoneName)
        report.scope = "Three isolated \(platform) SQLite stores using real CloudKit"
        let configuration = CloudKitSyncConfiguration(containerIdentifier: containerIdentifier, environment: "Development", zoneName: zoneName)
        var stores: [any CloudKitLiveVerificationStore] = []
        var mayOwnQAZone = false
        var factory: LiveClientFactory?
        var temporaryRoot: URL?
        var currentScenario = "signed-development-configuration"

        do {
            try require(configuration.containerIdentifier == containerIdentifier && configuration.environment == "Development"
                        && configuration.zoneName == zoneName && zoneName != "FinancesJournal_v1", "QA configuration is outside the permitted scope")
            if let argumentError = launchArgumentsError() { throw LiveFailure.check(argumentError) }
            try LiveQAAuthorization.validate(configuration)
            onScenario(currentScenario)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinancesLiveQA-\(runID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            temporaryRoot = root
            let clients = LiveClientFactory(configuration: configuration)
            factory = clients
            let accountProbe = try clients.makeClient()
            try await bounded("iCloud account preflight", seconds: 60, cancel: { accountProbe.cancel() }) {
                _ = try await accountProbe.accountIdentifier() // Retained privately for same-account cleanup checks.
            }
            accountProbe.cancel()
            let preflight = try LiveZoneOperations(configuration: configuration, runID: runID)
            try await bounded("QA zone preflight", seconds: 60, cancel: { preflight.cancel() }) {
                try await preflight.requireResourcesAbsent()
            }
            mayOwnQAZone = true
            report.passedScenarios.append(currentScenario)

            let seed = Fixture.make()
            let aURL = root.appendingPathComponent("A/journal.json")
            let bURL = root.appendingPathComponent("B/journal.json")
            let dependencies = CloudKitSyncDependencies(configuration: { configuration }, makeClient: { _ in try clients.makeClient() }, automaticTriggersEnabled: false)
            let a = makeStore(aURL, seed.data, dependencies)
            var b = makeStore(bURL, JournalData(), dependencies)
            stores = [a, b]
            try require(!a.requiresJournalRecovery && !b.requiresJournalRecovery, "An isolated QA journal failed to initialize")
            let context = [configuration.containerIdentifier, configuration.environment, configuration.zoneName].joined(separator: "|")

            currentScenario = "initial-A-to-empty-B"
            onScenario(currentScenario)
            try await sync(a, label: "Initial A upload")
            try await sync(b, label: "Initial B download")
            try requireInitialDomains(a.data, expected: seed.data)
            try requireInitialDomains(b.data, expected: seed.data)
            try require(a.balance(for: seed.checkingID) == -100 && b.balance(for: seed.checkingID) == -100, "Initial balances differ")
            try integrity(a); try integrity(b)
            report.passedScenarios.append(currentScenario)

            currentScenario = "offline-edit-and-reenable"
            onScenario(currentScenario)
            a.setSyncEnabled(false)
            let requestsBeforeOfflineEdit = clients.counts
            try editNote(a, id: seed.transactionID, note: "Synthetic offline edit")
            try require(clients.counts == requestsBeforeOfflineEdit, "An offline edit started a CloudKit request")
            try require(!a.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context).isEmpty, "Offline edit was not queued")
            try require(transaction(b, id: seed.transactionID)?.note != "Synthetic offline edit", "Offline edit changed the other local replica")
            try await sync(a, label: "Resume A")
            try await sync(b, label: "Receive offline edit")
            try require(transaction(b, id: seed.transactionID)?.note == "Synthetic offline edit", "Offline edit did not reach B")
            report.passedScenarios.append(currentScenario)

            currentScenario = "backdated-balances"
            onScenario(currentScenario)
            a.setSyncEnabled(false)
            var backdated = TransactionDraft(ledgerID: seed.ledgerID)
            backdated.date = Date(timeIntervalSince1970: 1_104_537_600)
            backdated.payee = "Synthetic Live QA"
            backdated.note = "Synthetic backdated expense"
            backdated.postings = [PostingDraft(accountID: seed.checkingID, amount: "-37.25", commodityID: seed.currencyID), PostingDraft(accountID: seed.foodID, amount: "37.25", commodityID: seed.currencyID)]
            a.saveTransaction(backdated)
            try require(a.validationError == nil, "Backdated transaction was rejected")
            guard let historical = a.data.transactions.first(where: { $0.note == backdated.note }) else { throw LiveFailure.check("Backdated transaction was not saved") }
            try await sync(a, label: "Backdated upload")
            try await sync(b, label: "Backdated download")
            let combinedBalance = Decimal(string: "-137.25")!
            try require(a.balance(for: seed.checkingID) == combinedBalance && b.balance(for: seed.checkingID) == combinedBalance, "Backdated balances did not reconcile")
            try require(transaction(b, id: historical.id)?.date == backdated.date, "Backdated date changed during sync")
            report.passedScenarios.append(currentScenario)

            currentScenario = "receipt-transfer"
            onScenario(currentScenario)
            a.setSyncEnabled(false)
            let receiptBytes = Data("Finances synthetic live CloudKit receipt. No personal data.\n".utf8)
            let source = root.appendingPathComponent("synthetic-receipt.txt")
            try receiptBytes.write(to: source, options: .atomic)
            let receipt = try a.importAttachment(from: source)
            guard let existing = transaction(a, id: seed.transactionID) else { throw LiveFailure.check("Receipt transaction disappeared") }
            var receiptDraft = a.draft(for: existing)
            receiptDraft.attachments = [receipt]
            a.saveTransaction(receiptDraft)
            try require(a.validationError == nil, "Receipt edit was rejected")
            try await sync(a, label: "Receipt upload")
            try await sync(b, label: "Receipt download")
            guard let downloaded = transaction(b, id: seed.transactionID)?.attachment?.assets.first else { throw LiveFailure.check("Receipt metadata did not reach B") }
            let bReceipt = try b.cloudKitAttachmentURL(for: downloaded)
            try require(hash(try Data(contentsOf: bReceipt)) == hash(receiptBytes), "Receipt bytes differ between replicas")
            try integrity(a); try integrity(b)
            report.passedScenarios.append(currentScenario)

            currentScenario = "conflict-and-explicit-cloud-resolution"
            onScenario(currentScenario)
            a.setSyncEnabled(false); b.setSyncEnabled(false)
            try editNote(a, id: seed.transactionID, note: "Synthetic conflict winner A")
            try editNote(b, id: seed.transactionID, note: "Synthetic conflicting B edit")
            try await sync(a, label: "Conflict A upload")
            b.setSyncEnabled(true)
            b.requestCloudKitSync(reportProgress: true, requireFollowUpIfBusy: false)
            try await waitForIdle(b, label: "Conflict B detection")
            let conflicts = b.cloudKitSyncConflicts()
            guard let conflict = conflicts.first(where: { $0.remote.recordID == seed.transactionID.uuidString }) else { throw LiveFailure.check("Concurrent edits did not produce a reviewable conflict") }
            try require(transaction(b, id: seed.transactionID)?.note == "Synthetic conflicting B edit", "Conflict silently overwrote B")
            b.validationError = nil
            b.resolveCloudKitSyncConflict(id: conflict.id, keepLocal: false)
            try await waitForIdle(b, label: "Explicit conflict resolution")
            try require(b.cloudKitSyncConflicts().isEmpty, "Explicit resolution left a conflict pending")
            try require(transaction(b, id: seed.transactionID)?.note == "Synthetic conflict winner A", "Explicit cloud choice was not applied")
            try require(b.cloudSyncProgress.state == .succeeded, "Conflict resolution did not finish syncing")
            report.passedScenarios.append(currentScenario)

            currentScenario = "transaction-and-receipt-deletion"
            onScenario(currentScenario)
            b.deleteTransaction(seed.transactionID)
            try require(b.validationError == nil, "Synthetic deletion was rejected")
            try await sync(b, label: "Deletion upload")
            try await sync(a, label: "Deletion download")
            try require(transaction(a, id: seed.transactionID) == nil && transaction(b, id: seed.transactionID) == nil, "Deleted transaction returned")
            try require(!FileManager.default.fileExists(atPath: bReceipt.path), "Deleted receipt remains in B's attachment store")
            let aReceipt = try a.cloudKitAttachmentURL(for: receipt)
            try require(!FileManager.default.fileExists(atPath: aReceipt.path), "Deleted receipt remains in A's attachment store")
            let remainingBalance = Decimal(string: "-37.25")!
            try require(a.balance(for: seed.checkingID) == remainingBalance && b.balance(for: seed.checkingID) == remainingBalance, "Balances did not update after deletion")
            report.passedScenarios.append(currentScenario)

            currentScenario = "local-store-restart"
            onScenario(currentScenario)
            b.setSyncEnabled(false)
            try await waitForIdle(b, label: "Stop B before reopening")
            // A nonnil fallback prevents original-app hint/autoload paths even on reopen.
            b = makeStore(bURL, JournalData(), dependencies)
            stores.append(b)
            try require(!b.requiresJournalRecovery, "Reopened QA SQLite journal needs recovery")
            try require(transaction(b, id: historical.id) != nil && b.balance(for: seed.checkingID) == remainingBalance, "Restart lost journal data or derived balances")
            let submissionsBeforeRestart = clients.counts["modifyRequests", default: 0]
            try await sync(b, label: "Sync reopened B")
            try require(clients.counts["modifyRequests", default: 0] == submissionsBeforeRestart, "Restart resent already acknowledged records")
            report.passedScenarios.append(currentScenario)

            currentScenario = "post-server-acceptance-cancellation"
            onScenario(currentScenario)
            a.setSyncEnabled(false)
            try editNote(a, id: historical.id, note: "Synthetic accepted-then-canceled edit")
            clients.armAcceptanceHold()
            a.setSyncEnabled(true)
            a.requestCloudKitSync(reportProgress: true, requireFollowUpIfBusy: false)
            try await bounded("Observe server acceptance", seconds: 90, cancel: { a.setSyncEnabled(false); clients.releaseHolds() }) {
                while !clients.acceptanceObserved {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            let submissionsAfterAcceptance = clients.counts["modifyRequests", default: 0]
            let frozen = try a.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context)
            guard let frozenID = frozen["transaction:\(historical.id.uuidString)"]?.clientChangeID else { throw LiveFailure.check("Accepted mutation was not durably claimed") }
            a.setSyncEnabled(false) // Releases only this wrapper's held, real accepted response.
            try await waitForIdle(a, label: "Canceled accepted pass")
            try require(a.data.syncEnabled == false, "Cancellation re-enabled sync")
            let afterCancel = try a.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context)
            try require(frozenID == afterCancel["transaction:\(historical.id.uuidString)"]?.clientChangeID, "Late acceptance erased the durable retry intent")
            try await sync(a, label: "Recover accepted upload by echo")
            try require(clients.counts["modifyRequests", default: 0] == submissionsAfterAcceptance, "Accepted upload was sent again instead of acknowledging its echo")
            try await sync(b, label: "Read cancellation recovery from B")
            try require(transaction(b, id: historical.id)?.note == "Synthetic accepted-then-canceled edit", "Accepted edit did not converge after cancellation")
            report.passedScenarios.append(currentScenario)

            currentScenario = "recurring-one-off-future-edit-and-deletion"
            onScenario(currentScenario)
            a.setSyncEnabled(false)
            let recurring = try createRecurringProof(a, fixture: seed)
            try await sync(a, label: "Recurring edits upload")
            try await sync(b, label: "Recurring edits download")
            try requireRecurringProof(a, proof: recurring)
            try requireRecurringProof(b, proof: recurring)
            report.passedScenarios.append(currentScenario)

            currentScenario = "fresh-replica-recurring-tombstone-and-reopen"
            onScenario(currentScenario)
            let cURL = root.appendingPathComponent("C/journal.json")
            var c = makeStore(cURL, JournalData(), dependencies)
            stores.append(c)
            try await sync(c, label: "Fresh C recurring download")
            try requireRecurringProof(c, proof: recurring)
            c.setSyncEnabled(false)
            try await waitForIdle(c, label: "Stop C before recurring reopen")
            c = makeStore(cURL, JournalData(), dependencies)
            stores.append(c)
            try require(!c.requiresJournalRecovery, "Reopened recurring QA journal needs recovery")
            try requireRecurringProof(c, proof: recurring)
            let requestsBeforeProjection = clients.counts
            try exerciseRecurringProjection(c, proof: recurring, oneOffID: historical.id)
            try require(clients.counts == requestsBeforeProjection, "Offline recurrence projection contacted CloudKit")
            try await sync(c, label: "Reopened C recurring reconciliation")
            try requireRecurringProof(c, proof: recurring)
            try require(c.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context).isEmpty, "Fresh recurring replica has pending changes")
            try integrity(c)
            report.passedScenarios.append(currentScenario)

            try integrity(a); try integrity(b)
            try require(a.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context).isEmpty && b.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context).isEmpty, "Final outbox is not empty")
            report.status = "PASS"
        } catch {
            report.failure = "\(currentScenario): \(safeDescription(error))"
        }

        // A disappearing iOS QA scene cancels its task. Cleanup uses a fresh
        // owned task so that cancellation cannot skip removal of the QA zone.
        let shutdownStores = stores, cleanupFactory = factory, cleanupNeeded = mayOwnQAZone
        let cleanup = await Task { @MainActor in
            await cleanupResources(stores: shutdownStores, factory: cleanupFactory, configuration: configuration,
                                   runID: runID, mayOwnQAZone: cleanupNeeded)
        }.value
        report.cleanup = cleanup.remoteStatus
        if let failure = cleanup.failure { report.status = "FAIL"; report.failure = report.failure ?? failure }
        report.requestCounts = factory?.counts ?? [:]
        report.durationSeconds = Date().timeIntervalSince(started)
        if let temporaryRoot {
            // Contains synthetic records only. Keep compact result evidence, remove databases/assets.
            if cleanup.localStoresStopped {
                for name in ["A", "B", "C", "synthetic-receipt.txt"] { try? FileManager.default.removeItem(at: temporaryRoot.appendingPathComponent(name)) }
            }
            if let data = try? JSONEncoder().encode(report) { try? data.write(to: temporaryRoot.appendingPathComponent("result.json"), options: .atomic) }
        }
        return report
    }

    private struct CleanupOutcome: Sendable {
        var remoteStatus = "not-needed"
        var failure: String?
        var localStoresStopped = true
    }
    private static func cleanupResources(stores: [any CloudKitLiveVerificationStore], factory: LiveClientFactory?,
                                         configuration: CloudKitSyncConfiguration, runID: UUID, mayOwnQAZone: Bool) async -> CleanupOutcome {
        var outcome = CleanupOutcome()
        factory?.releaseHolds()
        for store in stores { store.setSyncEnabled(false) }
        for store in stores {
            do { try await waitForIdle(store, label: "QA shutdown", seconds: 30) }
            catch { outcome.failure = "QA sync shutdown timed out"; outcome.localStoresStopped = false }
        }
        if mayOwnQAZone, let factory {
            do {
                let probe = try factory.makeClient()
                try await bounded("Cleanup account check", seconds: 60, cancel: { probe.cancel() }) { _ = try await probe.accountIdentifier() }
                probe.cancel()
                let cleanup = try LiveZoneOperations(configuration: configuration, runID: runID)
                try await bounded("QA zone cleanup", seconds: 60, cancel: { cleanup.cancel() }) { try await cleanup.removeOnlyQAResources() }
                outcome.remoteStatus = "verified-absent"
            } catch {
                outcome.remoteStatus = "failed-qa-zone-may-remain"
                outcome.failure = outcome.failure ?? "Cleanup: \(safeDescription(error))"
            }
        }
        return outcome
    }

    nonisolated static func makeNativeQAClient(configuration: CloudKitSyncConfiguration, qualityOfService: QualityOfService = .userInitiated) throws -> CloudKitSyncClient {
        try LiveQAAuthorization.validate(configuration)
        #if targetEnvironment(simulator)
        return CloudKitSyncClient(configuration: configuration, executor: LiveQAOperationExecutor(configuration: configuration), qualityOfService: qualityOfService)
        #else
        return try CloudKitSyncClient(configuration: configuration, qualityOfService: qualityOfService)
        #endif
    }
    static func requireEmptyQAResources(configuration: CloudKitSyncConfiguration, runID: UUID) async throws {
        let operations = try LiveZoneOperations(configuration: configuration, runID: runID)
        try await bounded("QA resource preflight", seconds: 60, cancel: { operations.cancel() }) { try await operations.requireResourcesAbsent() }
    }
    /// Consumer registration prepares only this app's subscription context. It
    /// never creates a missing zone or deletes another device's resources.
    static func ensureExistingQAZoneSubscription(configuration: CloudKitSyncConfiguration, runID: UUID) async throws {
        let operations = try LiveZoneOperations(configuration: configuration, runID: runID)
        defer { operations.cancel() }
        try await bounded("Consumer QA subscription", seconds: 60, cancel: { operations.cancel() }) {
            try await operations.ensureSubscriptionForExistingZone()
        }
    }

    static func requireExistingQAZone(configuration: CloudKitSyncConfiguration, runID: UUID) async throws {
        let operations = try LiveZoneOperations(configuration: configuration, runID: runID)
        try await bounded("Existing peer QA zone", seconds: 60, cancel: { operations.cancel() }) { try await operations.requireZonePresent() }
    }
    static func removeOwnedQAResources(configuration: CloudKitSyncConfiguration, runID: UUID) async throws {
        let operations = try LiveZoneOperations(configuration: configuration, runID: runID)
        try await bounded("Owned QA cleanup", seconds: 60, cancel: { operations.cancel() }) { try await operations.removeOnlyQAResources() }
    }

    private static func sync(_ store: any CloudKitLiveVerificationStore, label: String) async throws {
        store.validationError = nil
        if !store.data.syncEnabled { store.setSyncEnabled(true) }
        store.requestCloudKitSync(reportProgress: true, requireFollowUpIfBusy: false)
        try await waitForIdle(store, label: label)
        try require(store.cloudSyncProgress.state == .succeeded, "\(label) did not succeed (\(store.cloudSyncProgress.message))")
    }
    private static func waitForIdle(_ store: any CloudKitLiveVerificationStore, label: String, seconds: Double = 90) async throws {
        try await bounded(label, seconds: seconds, cancel: { store.setSyncEnabled(false) }) { await store.waitForCloudKitSyncIdle() }
    }
    static func bounded(_ label: String, seconds: Double, cancel: @escaping @MainActor @Sendable () -> Void,
                                operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    await cancel()
                    throw LiveFailure.check("\(label) timed out")
                }
                defer { group.cancelAll() }
                _ = try await group.next()
                try Task.checkCancellation()
            }
        } onCancel: {
            // A QA window close must stop the operation before waiting for its
            // child task to settle; canceling the waiter alone is insufficient.
            Task { @MainActor in cancel() }
        }
    }
    private static func editNote(_ store: any CloudKitLiveVerificationStore, id: UUID, note: String) throws {
        guard let value = transaction(store, id: id) else { throw LiveFailure.check("Synthetic transaction is missing") }
        var draft = store.draft(for: value); draft.note = note
        store.saveTransaction(draft)
        try require(store.validationError == nil, "Synthetic transaction edit was rejected")
    }
    private static func transaction(_ store: any CloudKitLiveVerificationStore, id: UUID) -> LedgerTransaction? { store.data.transactions.first { $0.id == id } }
    private static func accountOrder(_ a: Account, _ b: Account) -> Bool { a.id.uuidString < b.id.uuidString }
    private static func integrity(_ store: any CloudKitLiveVerificationStore) throws { try require(store.liveIntegrityIsValid(), "Synthetic journal integrity check failed") }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw LiveFailure.check(message) }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func safeDescription(_ error: Error) -> String {
        if case LiveFailure.check(let message) = error { return message }
        if let validation = error as? ValidationError { return "Synthetic journal validation: \(validation.message)" }
        if let cloud = error as? CKError { return "CloudKit error code \(cloud.code.rawValue)" }
        if error is CancellationError { return "Operation canceled" }
        if error is CloudKitSyncError { return "CloudKit request or configuration failed" }
        return "Local QA operation failed (\(String(describing: type(of: error))))"
    }

    static func requireInitialDomains(_ actual: JournalData, expected: JournalData) throws {
        try require(SQLiteSyncedJournalMetadata(data: actual) == SQLiteSyncedJournalMetadata(data: expected), "Synced journal preferences differ")
        try require(actual.ledgers.sorted { $0.id.uuidString < $1.id.uuidString } == expected.ledgers.sorted { $0.id.uuidString < $1.id.uuidString }, "Initial journal values differ")
        try require(actual.commodities.sorted { $0.id.uuidString < $1.id.uuidString } == expected.commodities.sorted { $0.id.uuidString < $1.id.uuidString }, "Initial currency values differ")
        try require(actual.accounts.sorted(by: accountOrder) == expected.accounts.sorted(by: accountOrder), "Initial account values differ")
        try require(actual.sources.sorted { $0.id.uuidString < $1.id.uuidString } == expected.sources.sorted { $0.id.uuidString < $1.id.uuidString }, "Initial source values differ")
        try require(actual.transactionTemplates.sorted { $0.id.uuidString < $1.id.uuidString } == expected.transactionTemplates.sorted { $0.id.uuidString < $1.id.uuidString }, "Initial template values differ")
        try require(actual.transactions.sorted { $0.id.uuidString < $1.id.uuidString } == expected.transactions.sorted { $0.id.uuidString < $1.id.uuidString }, "Initial transaction values differ")
    }

    struct RecurrenceProof {
        var ruleID: UUID
        var originalIDs: [UUID]
        var deletedID: UUID
        var expectedRows: [LedgerTransaction]
        var checkingID: UUID
        var expectedBalance: Decimal
    }

    /// Uses the same occurrence/future edit and delete entrypoints as the UI.
    /// Four historical occurrences bound projection work independently of today.
    static func createRecurringProof(_ store: any CloudKitLiveVerificationStore, fixture: Fixture) throws -> RecurrenceProof {
        let startingBalance = store.balance(for: fixture.checkingID)
        let ruleID = UUID()
        var draft = TransactionDraft(ledgerID: fixture.ledgerID)
        draft.date = Date(timeIntervalSince1970: 1_610_452_800) // Four daily rows in January 2021.
        draft.payee = "Synthetic recurring QA"
        draft.note = "Recurring base details"
        draft.number = "R-BASE"
        draft.recurrenceRuleID = ruleID
        draft.repeatFrequency = .daily
        draft.repeatOccurrenceCount = 4
        draft.postings = [PostingDraft(accountID: fixture.checkingID, amount: "-10", commodityID: fixture.currencyID), PostingDraft(accountID: fixture.foodID, amount: "10", commodityID: fixture.currencyID)]
        store.saveTransaction(draft)
        try require(store.validationError == nil, "Recurring series creation failed")
        let original = recurringRows(store.data, ruleID: ruleID)
        try require(original.count == 4, "Recurring creation did not produce exactly four occurrences")
        try require(store.balance(for: fixture.checkingID) == startingBalance - 40, "Initial recurring balance differs")
        let originalIDs = original.map(\.id)

        var oneOff = store.draft(for: original[1])
        oneOff.note = "Synthetic single-occurrence edit"
        oneOff.number = "R-ONCE"
        setAmount(&oneOff, checkingID: fixture.checkingID, debit: "17.50")
        store.saveTransaction(oneOff)
        try require(store.validationError == nil, "Recurring one-off edit failed")
        let afterOneOff = recurringRows(store.data, ruleID: ruleID)
        try require(afterOneOff.map(\.id) == originalIDs, "A one-off edit changed occurrence identities")
        try require(afterOneOff[0] == original[0] && afterOneOff[2] == original[2] && afterOneOff[3] == original[3], "A one-off edit changed another occurrence")
        try require(afterOneOff[1].note == oneOff.note && afterOneOff[1].postings.first { $0.accountID == fixture.checkingID }?.amount == Decimal(string: "-17.50"), "One-off values were not saved")

        var future = store.draft(for: afterOneOff[2])
        future.note = "Synthetic future-series details"
        future.number = "R-FUTURE"
        setAmount(&future, checkingID: fixture.checkingID, debit: "12")
        store.saveTransactionForFutureOccurrences(future)
        try require(store.validationError == nil, "Future-series edit failed")
        let afterFuture = recurringRows(store.data, ruleID: ruleID)
        try require(afterFuture.map(\.id) == originalIDs && afterFuture.map(\.date) == original.map(\.date), "Future edit changed scheduled identities or dates")
        try require(afterFuture[0].note == original[0].note && afterFuture[1].note == oneOff.note, "Future edit overwrote earlier or one-off details")
        for row in afterFuture.suffix(2) {
            try require(row.note == future.note && row.postings.first { $0.accountID == fixture.checkingID }?.amount == -12, "Future details did not reach later occurrences")
        }
        guard let history = afterFuture[0].recurrenceRule?.templateHistory else { throw LiveFailure.check("Recurring template history is missing") }
        try require(history.baseTemplate.note == draft.note && history.changes.count == 1 && history.changes[0].template.note == future.note, "Recurring history lost its base or future edit")
        try require(afterFuture.allSatisfy { $0.recurrenceRule?.templateHistory == history }, "Occurrences disagree about recurring history")
        try require(store.balance(for: fixture.checkingID) == startingBalance - Decimal(string: "51.50")!, "Edited recurring balance differs")

        let deletedID = originalIDs[3]
        store.deleteTransaction(deletedID)
        try require(store.validationError == nil, "Recurring occurrence deletion failed")
        let proof = RecurrenceProof(ruleID: ruleID, originalIDs: originalIDs, deletedID: deletedID,
                                    expectedRows: Array(afterFuture.prefix(3)), checkingID: fixture.checkingID,
                                    expectedBalance: startingBalance - Decimal(string: "39.50")!)
        try requireRecurringProof(store, proof: proof)
        return proof
    }

    static func requireRecurringProof(_ store: any CloudKitLiveVerificationStore, proof: RecurrenceProof) throws {
        try requireRecurringRecords(store, proof: proof)
        try require(store.balance(for: proof.checkingID) == proof.expectedBalance, "Recurring balance differs after deletion or reopen")
    }
    private static func requireRecurringRecords(_ store: any CloudKitLiveVerificationStore, proof: RecurrenceProof) throws {
        try require(recurringRows(store.data, ruleID: proof.ruleID) == proof.expectedRows, "Recurring values, IDs or template history differ")
        try require(!store.data.transactions.contains { $0.id == proof.deletedID }, "Deleted recurring occurrence returned")
        try require(store.cloudKitSQLiteStore.deletedTransactionIDs().contains(proof.deletedID), "Recurring deletion tombstone was not persisted")
    }

    /// Moving and restoring an existing one-off while offline invokes each
    /// platform's real projection path without retaining a synthetic probe row.
    static func exerciseRecurringProjection(_ store: any CloudKitLiveVerificationStore, proof: RecurrenceProof, oneOffID: UUID) throws {
        try require(!store.data.syncEnabled, "Projection probe must remain offline")
        guard let row = transaction(store, id: oneOffID), row.recurrenceRule == nil,
              let futureDate = Calendar.current.date(byAdding: .year, value: 8, to: Date()) else {
            throw LiveFailure.check("Projection probe needs its existing one-off transaction")
        }
        let original = store.draft(for: row)
        var moved = original; moved.date = futureDate
        store.saveTransaction(moved)
        try require(store.validationError == nil, "Projection probe edit failed")
        try requireRecurringRecords(store, proof: proof)
        // Current balances exclude the temporarily future-dated one-off.
        let movedAmount = row.postings.filter { $0.accountID == proof.checkingID }.reduce(Decimal.zero) { $0 + $1.amount }
        try require(store.balance(for: proof.checkingID) == proof.expectedBalance - movedAmount, "Projection probe current balance did not respect the future cutoff")
        store.saveTransaction(original)
        try require(store.validationError == nil && transaction(store, id: oneOffID) == row, "Projection probe did not restore the original transaction")
        try requireRecurringProof(store, proof: proof)
    }

    private static func recurringRows(_ data: JournalData, ruleID: UUID) -> [LedgerTransaction] {
        data.transactions.filter { $0.recurrenceRule?.id == ruleID }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
    }
    private static func setAmount(_ draft: inout TransactionDraft, checkingID: UUID, debit: String) {
        for index in draft.postings.indices { draft.postings[index].amount = draft.postings[index].accountID == checkingID ? "-" + debit : debit }
    }

    struct Fixture {
        let data: JournalData
        let ledgerID: UUID
        let currencyID: UUID
        let checkingID: UUID
        let foodID: UUID
        let transactionID: UUID
        static func make() -> Self {
            let ledger = Ledger(name: "Synthetic Live QA")
            let currency = Commodity(ledgerID: ledger.id, symbol: "USD", name: "US Dollar")
            let assets = Account(ledgerID: ledger.id, name: "Assets", kind: .asset)
            let expenses = Account(ledgerID: ledger.id, name: "Expenses", kind: .expense)
            let checking = Account(ledgerID: ledger.id, parentID: assets.id, commodityID: currency.id, name: "QA Checking", kind: .asset)
            let food = Account(ledgerID: ledger.id, parentID: expenses.id, commodityID: currency.id, name: "QA Food", kind: .expense)
            let source = TransactionSource(ledgerID: ledger.id, type: 2, date: Date(timeIntervalSince1970: 1_577_836_800), externalID: "synthetic-live-source")
            let transaction = LedgerTransaction(ledgerID: ledger.id, sourceID: source.id, date: Date(timeIntervalSince1970: 1_577_836_800), payee: "Synthetic QA", note: "Synthetic initial expense", number: "QA-001", cleared: true, postings: [Posting(accountID: checking.id, commodityID: currency.id, amount: -100), Posting(accountID: food.id, commodityID: currency.id, amount: 100, listIndex: 1)], externalTransactionID: "synthetic-live-transaction")
            let template = TransactionTemplate(ledgerID: ledger.id, name: "Synthetic shared template", note: "Template details", payee: "Synthetic template payee", cleared: false, enabled: true, scanInvoice: false, listIndex: 1, postings: [PostingTemplate(accountID: checking.id), PostingTemplate(accountID: food.id, listIndex: 1)])
            return Self(data: JournalData(ledgers: [ledger], commodities: [currency], accounts: [assets, expenses, checking, food], transactions: [transaction], sources: [source], transactionTemplates: [template], selectedLedgerID: ledger.id, dateFormat: .iso, appearance: .dark), ledgerID: ledger.id, currencyID: currency.id, checkingID: checking.id, foodID: food.id, transactionID: transaction.id)
        }
    }
}

private enum LiveFailure: Error { case check(String) }
private final class LiveLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func access<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result { lock.lock(); defer { lock.unlock() }; return try body(&value) }
}

private final class LiveClientFactory: @unchecked Sendable {
    private struct State {
        var counts: [String: Int] = [:]
        var account: String?
        var armed = false
        var accepted = false
        var holdingOwner: UUID?
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = LiveLocked(State())
    private let configuration: CloudKitSyncConfiguration
    init(configuration: CloudKitSyncConfiguration) { self.configuration = configuration }
    var counts: [String: Int] { state.access { $0.counts } }
    var acceptanceObserved: Bool { state.access { $0.accepted } }
    func makeClient() throws -> any CloudKitSyncTransport {
        let native = try CloudKitLiveVerification.makeNativeQAClient(configuration: configuration)
        record("clients")
        return LiveObservedTransport(native: native, factory: self)
    }
    func record(_ name: String) { state.access { $0.counts[name, default: 0] += 1 } }
    func validateAccount(_ account: String) throws {
        try state.access {
            if let expected = $0.account, expected != account { throw LiveFailure.check("The iCloud account changed during QA; cleanup was not redirected") }
            $0.account = account
        }
    }
    func armAcceptanceHold() { state.access { $0.armed = true; $0.accepted = false } }
    func afterAcceptance(owner: UUID) async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.access { state -> Bool in
                guard state.armed else { return true }
                state.armed = false; state.accepted = true
                state.holdingOwner = owner; state.continuation = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }
    func cancel(owner: UUID) {
        let continuation = state.access { state -> CheckedContinuation<Void, Never>? in
            guard state.holdingOwner == owner else { return nil }
            let continuation = state.continuation; state.continuation = nil; state.holdingOwner = nil
            return continuation
        }
        continuation?.resume()
    }
    func releaseHolds() {
        let continuation = state.access { state in
            let continuation = state.continuation
            state.continuation = nil; state.holdingOwner = nil; state.armed = false
            return continuation
        }
        continuation?.resume()
    }
}

private final class LiveObservedTransport: CloudKitSyncTransport, @unchecked Sendable {
    private let native: CloudKitSyncClient
    private let factory: LiveClientFactory
    private let owner = UUID()
    init(native: CloudKitSyncClient, factory: LiveClientFactory) { self.native = native; self.factory = factory }
    func accountIdentifier() async throws -> String {
        factory.record("accountRequests")
        let value = try await native.accountIdentifier(); try factory.validateAccount(value); return value
    }
    func prepareZone() async throws { factory.record("prepareRequests"); try await native.prepareZone() }
    func fetchChanges(since: Data?) async throws -> CloudKitSyncPage { factory.record("fetchRequests"); return try await native.fetchChanges(since: since) }
    func fetchRecord(recordType: String, recordID: String) async throws -> CloudKitSyncRecord { factory.record("singleRecordRequests"); return try await native.fetchRecord(recordType: recordType, recordID: recordID) }
    func modifyRecords(_ records: [CloudKitSyncRecord]) async throws -> CloudKitSyncModifyResult {
        factory.record("modifyRequests")
        let result = try await native.modifyRecords(records)
        if !result.saved.isEmpty { await factory.afterAcceptance(owner: owner) }
        return result
    }
    func cancel() { native.cancel(); factory.cancel(owner: owner) }
}

/// The only hard-deletion path in this harness. Exact newly minted QA identifiers
/// are validated again in the initializer; no caller supplies an arbitrary zone.
private final class LiveZoneOperations: @unchecked Sendable {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let subscriptionID: String
    private let gate = CloudKitSyncOperationGate()
    init(configuration: CloudKitSyncConfiguration, runID: UUID) throws {
        guard configuration.containerIdentifier == "iCloud.dev.gan.FinanceApp", configuration.environment == "Development",
              configuration.zoneName == "FinancesQA_\(runID.uuidString)" else {
            throw LiveFailure.check("QA cleanup scope validation failed")
        }
        try LiveQAAuthorization.validate(configuration)
        database = CKContainer(identifier: configuration.containerIdentifier).privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: configuration.zoneName, ownerName: CKCurrentUserDefaultName)
        subscriptionID = "Finances-\(configuration.zoneName)-changes-v1"
    }
    func cancel() { gate.cancel() }
    private func run(_ operation: CKDatabaseOperation, configure: (@escaping @Sendable (Result<Void, Error>) -> Void) -> Void) async throws {
        try await withTaskCancellationHandler {
            try gate.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let pending = LiveLocked<CheckedContinuation<Void, Error>?>(continuation)
                let id = UUID(), gate = gate
                let complete: @Sendable (Result<Void, Error>) -> Void = { result in
                    let active = gate.finish(id)
                    let continuation = pending.access { value in let previous = value; value = nil; return previous }
                    continuation?.resume(with: active ? result : .failure(CancellationError()))
                }
                configure(complete)
                // CLI QA has no foreground finance window; make its explicit
                // preflight/cleanup requests non-discretionary as well.
                operation.qualityOfService = .userInitiated
                let options = operation.configuration ?? CKOperation.Configuration()
                options.qualityOfService = .userInitiated
                options.timeoutIntervalForRequest = 30
                options.timeoutIntervalForResource = 60
                operation.configuration = options
                gate.registerAndStart(operation, id: id, start: { database.add(operation) }, onCancel: {
                    let continuation = pending.access { value in let previous = value; value = nil; return previous }
                    continuation?.resume(throwing: CancellationError())
                })
            }
        } onCancel: { self.cancel() }
    }
    func requireZonePresent() async throws {
        let found = LiveLocked<Result<Void, Error>?>(nil)
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [zoneID])
        try await run(operation) { complete in
            operation.perRecordZoneResultBlock = { _, result in found.access { $0 = result.map { _ in () } } }
            operation.fetchRecordZonesResultBlock = { result in
                complete(result.flatMap { found.access { $0 } ?? .failure(LiveFailure.check("The producer QA zone was not found")) })
            }
        }
    }
    func ensureSubscriptionForExistingZone() async throws {
        try await requireZonePresent()
        let fetched = LiveLocked<Result<CKSubscription?, Error>?>(nil)
        let fetch = CKFetchSubscriptionsOperation(subscriptionIDs: [subscriptionID])
        try await run(fetch) { complete in
            fetch.perSubscriptionResultBlock = { _, value in
                fetched.access { state in
                    switch value {
                    case .success(let subscription): state = .success(subscription)
                    case .failure(let error): state = Self.isMissing(error) ? .success(nil) : .failure(error)
                    }
                }
            }
            fetch.fetchSubscriptionsResultBlock = { outcome in
                do {
                    guard let value = fetched.access({ $0 }) else { try outcome.get(); throw LiveFailure.check("QA subscription lookup returned no result") }
                    _ = try value.get(); complete(.success(()))
                } catch { complete(.failure(error)) }
            }
        }
        let existing = try fetched.access { $0 }?.get()
        if let existing {
            guard let zone = existing as? CKRecordZoneSubscription, zone.zoneID == zoneID,
                  zone.notificationInfo?.shouldSendContentAvailable == true else {
                throw LiveFailure.check("The existing QA subscription does not match this private zone")
            }
            return
        }
        try gate.checkCancellation()
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true; subscription.notificationInfo = info
        let save = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
        try await run(save) { complete in save.modifySubscriptionsResultBlock = { complete($0.map { _ in () }) } }
        // A zone deleted during setup fails this check; no zone-creation request
        // exists on this path, and READY will not be emitted.
        try await requireZonePresent()
    }

    func requireResourcesAbsent() async throws {
        try await requireZoneAbsent()
        let result = LiveLocked<Result<Bool, Error>?>(nil)
        let operation = CKFetchSubscriptionsOperation(subscriptionIDs: [subscriptionID])
        try await run(operation) { complete in
            operation.perSubscriptionResultBlock = { _, value in
                result.access { state in
                    switch value {
                    case .success: state = .success(false)
                    case .failure(let error): state = Self.isMissing(error) ? .success(true) : .failure(error)
                    }
                }
            }
            operation.fetchSubscriptionsResultBlock = { outcome in
                do {
                    guard let absent = try result.access({ $0 })?.get() else { try outcome.get(); throw LiveFailure.check("QA subscription preflight returned no result") }
                    guard absent else { throw LiveFailure.check("Generated QA subscription already exists; refusing to use or delete it") }
                    complete(.success(()))
                } catch { complete(.failure(error)) }
            }
        }
    }
    func requireZoneAbsent() async throws {
        let result = LiveLocked<Result<Bool, Error>?>(nil)
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [zoneID])
        try await run(operation) { complete in
            operation.perRecordZoneResultBlock = { _, value in
                result.access { state in
                    switch value {
                    case .success: state = .success(false)
                    case .failure(let error):
                        if let error = error as? CKError, [.zoneNotFound, .unknownItem, .userDeletedZone].contains(error.code) { state = .success(true) }
                        else { state = .failure(error) }
                    }
                }
            }
            operation.fetchRecordZonesResultBlock = { outcome in
                do {
                    guard let absent = try result.access({ $0 })?.get() else { try outcome.get(); throw LiveFailure.check("QA zone preflight returned no result") }
                    guard absent else { throw LiveFailure.check("Generated QA zone already exists; refusing to use or delete it") }
                    complete(.success(()))
                } catch { complete(.failure(error)) }
            }
        }
    }
    func removeOnlyQAResources() async throws {
        let subscriptions = CKModifySubscriptionsOperation(subscriptionsToSave: nil, subscriptionIDsToDelete: [subscriptionID])
        let subscriptionError = LiveLocked<Error?>(nil)
        try await run(subscriptions) { complete in
            subscriptions.perSubscriptionDeleteBlock = { _, result in
                if case .failure(let error) = result, !Self.isMissing(error) { subscriptionError.access { $0 = error } }
            }
            subscriptions.modifySubscriptionsResultBlock = { result in
                if let error = subscriptionError.access({ $0 }) { complete(.failure(error)) }
                else if case .failure(let error) = result, !Self.isOnlyMissing(error) { complete(.failure(error)) }
                else { complete(.success(())) }
            }
        }
        let zones = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: [zoneID])
        let zoneError = LiveLocked<Error?>(nil)
        try await run(zones) { complete in
            zones.perRecordZoneDeleteBlock = { _, result in
                if case .failure(let error) = result, !Self.isMissing(error) { zoneError.access { $0 = error } }
            }
            zones.modifyRecordZonesResultBlock = { result in
                if let error = zoneError.access({ $0 }) { complete(.failure(error)) }
                else if case .failure(let error) = result, !Self.isOnlyMissing(error) { complete(.failure(error)) }
                else { complete(.success(())) }
            }
        }
        try await requireResourcesAbsent()
    }
    private static func isMissing(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        return [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code)
    }
    private static func isOnlyMissing(_ error: Error) -> Bool {
        if isMissing(error) { return true }
        guard let error = error as? CKError, error.code == .partialFailure, let nested = error.partialErrorsByItemID, !nested.isEmpty else { return false }
        return nested.values.allSatisfy(isMissing)
    }
}


/// Value-only validation shared with offline launch/proof regression tests.
struct CloudKitLiveQAProof: Codable, Sendable {
    var allowedAction: String
    var executableSHA256: String
    var bundleIdentifier: String
    var containerIdentifier: String
    var environment: String
    var teamIdentifier: String
    var codesignAndEntitlementsVerified: Bool
    var expiresAt: TimeInterval
    var runID: String? = nil
    var phase: String? = nil

    func matches(configuration: CloudKitSyncConfiguration, executableSHA256 expectedHash: String, bundleIdentifier expectedBundle: String,
                 teamIdentifier expectedTeam: String, action: String, peerRunID: String?, peerPhase: String?, now: TimeInterval) -> Bool {
        guard ["verify-cloudkit-live", "verify-cloudkit-peer"].contains(action), allowedAction == action,
              codesignAndEntitlementsVerified, bundleIdentifier == expectedBundle, !expectedBundle.isEmpty,
              containerIdentifier == "iCloud.dev.gan.FinanceApp", configuration.containerIdentifier == containerIdentifier,
              environment == "Development", configuration.environment == environment,
              teamIdentifier == expectedTeam, expectedTeam.count == 10,
              expectedTeam.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              executableSHA256.lowercased() == expectedHash.lowercased(), expectedHash.count == 64,
              expectedHash.lowercased().utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              expiresAt > now, expiresAt <= now + 3_600,
              configuration.zoneName.hasPrefix("FinancesQA_"),
              let zoneUUID = UUID(uuidString: String(configuration.zoneName.dropFirst("FinancesQA_".count))),
              configuration.zoneName == "FinancesQA_\(zoneUUID.uuidString)" else { return false }
        if action == "verify-cloudkit-peer" {
            return runID == peerRunID && phase == peerPhase && peerRunID == zoneUUID.uuidString
                && peerPhase.flatMap(CloudKitPeerVerification.Phase.init(rawValue:)) != nil
        }
        return runID == nil && phase == nil && peerRunID == nil && peerPhase == nil
    }
}

/// Simulator authorization is a QA-only exception to the product's offline policy.
/// The proof must be generated after external codesign/entitlement verification.
/// It binds that verification to this exact binary and expires within one hour.
private enum LiveQAAuthorization {
    static func validate(_ configuration: CloudKitSyncConfiguration) throws {
        let peer = CloudKitPeerVerification.isRequested ? try CloudKitPeerVerification.Request.parse() : nil
        guard CommandLine.arguments.contains("--verify-cloudkit-live") || peer != nil else {
            throw LiveFailure.check("An explicit live QA command is required")
        }
        guard configuration.containerIdentifier == "iCloud.dev.gan.FinanceApp",
              configuration.environment == "Development",
              configuration.zoneName.hasPrefix("FinancesQA_"),
              let runID = UUID(uuidString: String(configuration.zoneName.dropFirst("FinancesQA_".count))),
              configuration.zoneName == "FinancesQA_\(runID.uuidString)" else {
            throw LiveFailure.check("Live QA requires its explicit flag and an isolated Development QA zone")
        }
        if let peer, configuration.zoneName != peer.zoneName { throw LiveFailure.check("Peer command and QA zone differ") }
        #if targetEnvironment(simulator)
        guard CommandLine.arguments.contains("--allow-cloudkit-live-simulator") else {
            throw LiveFailure.check("Simulator live QA requires explicit authorization after signed-entitlement preflight")
        }
        let info = Bundle.main.infoDictionary ?? [:]
        guard let proofPath = ProcessInfo.processInfo.environment["FINANCES_CLOUDKIT_QA_PROOF"],
              let executable = Bundle.main.executableURL,
              let bundleID = Bundle.main.bundleIdentifier,
              let team = info["FinancesCloudKitTeamIdentifier"] as? String,
              team.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              info["FinancesCloudKitEnabled"] as? Bool == true,
              info["FinancesCloudKitContainerIdentifier"] as? String == configuration.containerIdentifier,
              info["FinancesCloudKitEnvironment"] as? String == "Development" else {
            throw LiveFailure.check("Simulator QA requires its explicit build markers and verification proof")
        }
        let proofURL = URL(fileURLWithPath: proofPath).resolvingSymlinksInPath().standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard proofURL.path.hasPrefix(temporaryRoot.hasSuffix("/") ? temporaryRoot : temporaryRoot + "/"),
              proofURL.lastPathComponent.hasPrefix("FinancesCloudKitQAProof-"), proofURL.pathExtension == "json" else {
            throw LiveFailure.check("Simulator QA proof must be a dedicated JSON file in this app's temporary directory")
        }
        let proofData = try Data(contentsOf: proofURL)
        guard proofData.count <= 16_384 else { throw LiveFailure.check("Simulator QA proof is invalid") }
        let proof = try JSONDecoder().decode(CloudKitLiveQAProof.self, from: proofData)
        let actual = SHA256.hash(data: try Data(contentsOf: executable, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard proof.matches(configuration: configuration, executableSHA256: actual, bundleIdentifier: bundleID, teamIdentifier: team,
                            action: peer == nil ? "verify-cloudkit-live" : "verify-cloudkit-peer", peerRunID: peer?.runID.uuidString,
                            peerPhase: peer?.phase.rawValue, now: Date().timeIntervalSince1970) else {
            throw LiveFailure.check("Simulator QA proof is expired or does not match this binary, scope, and phase")
        }
        #else
        guard configuration.validationErrorForCurrentApplication() == nil else {
            throw LiveFailure.check("This executable lacks the required signed Development CloudKit entitlements")
        }
        #endif
    }
}

#if targetEnvironment(simulator)
/// Constructed only by the live-QA factory after the proof and exact QA scope pass.
/// Normal CloudKitSyncConfiguration.availableConfiguration() remains simulator-off.
private final class LiveQAOperationExecutor: CloudKitSyncOperationExecutor, @unchecked Sendable {
    private let container: CKContainer
    init(configuration: CloudKitSyncConfiguration) { container = CKContainer(identifier: configuration.containerIdentifier) }
    func add(_ operation: CKDatabaseOperation, to scope: CKDatabase.Scope) { container.database(with: scope).add(operation) }
}
#endif
