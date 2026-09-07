import CryptoKit
import Darwin
import Foundation

/// A staged live round trip across separately launched app instances. Reports
/// must also be matched with independently verified device origins by the caller.
@MainActor
enum CloudKitPeerVerification {
    nonisolated static var isRequested: Bool { CommandLine.arguments.contains("--verify-cloudkit-peer") }
    enum Phase: String, Codable, Sendable {
        case prepare = "producer-prepare"
        case exchange = "consumer-exchange"
        case awaitPush = "consumer-await-push"
        case sendPush = "producer-send-push"
        case verify = "producer-verify"
        case cleanup = "producer-cleanup"
        case abort = "producer-abort"
        var role: String { self == .exchange || self == .awaitPush ? "consumer" : "producer" }
    }
    struct Request: Sendable {
        let runID: UUID
        let phase: Phase
        var zoneName: String { "FinancesQA_\(runID.uuidString)" }
        nonisolated static func parse(arguments: [String] = CommandLine.arguments) throws -> Self {
            var args = Array(arguments.dropFirst())
            #if targetEnvironment(simulator)
            if let index = args.firstIndex(of: "--allow-cloudkit-live-simulator") { args.remove(at: index) }
            #endif
            guard args.count == 5, args.first == "--verify-cloudkit-peer" else { throw PeerFailure.check("Expected --verify-cloudkit-peer --run-id UUID --phase PHASE") }
            var options: [String: String] = [:]
            for index in stride(from: 1, to: args.count, by: 2) {
                let key = args[index]
                guard ["--run-id", "--phase"].contains(key), options[key] == nil else { throw PeerFailure.check("Unknown or repeated peer QA argument") }
                options[key] = args[index + 1]
            }
            guard let id = options["--run-id"].flatMap(UUID.init(uuidString:)), let phase = options["--phase"].flatMap(Phase.init(rawValue:)) else { throw PeerFailure.check("Peer QA requires a UUID and a supported phase") }
            return Self(runID: id, phase: phase)
        }
    }
    nonisolated static func launchArgumentsError(arguments: [String] = CommandLine.arguments) -> String? {
        do { _ = try Request.parse(arguments: arguments); return nil }
        catch { return "Use --verify-cloudkit-peer --run-id UUID --phase producer-prepare|consumer-exchange|consumer-await-push|producer-send-push|producer-verify|producer-cleanup|producer-abort." }
    }
    struct Report: Codable, Sendable {
        var status = "FAIL"
        var phase: String
        var role: String
        var runID: String
        var zone: String
        var platform: String
        var container = "iCloud.dev.gan.FinanceApp"
        var environment = "Development"
        var producerInstanceID: String?
        var consumerInstanceID: String?
        var challengeDigest: String?
        var roundTripDigest: String?
        var receiptSHA256: String?
        var transactionAmount: String?
        var matchingPushDeliveryVerified = false
        var automaticConvergenceVerified = false
        var automaticUploadVerified = false
        var resumedPushAttempt = false
        var passQualityOfService = "userInitiated"
        var matchingPushNotificationCount = 0
        var pushRegistrationSucceeded = false
        var pushRegistrationFailed = false
        var pushDeliveryExecutionContexts: [CloudKitPeerPushExecutionContext] = []
        var backgroundPushDeliveryVerified = false
        var convergenceObservedExecutionContext: CloudKitPeerPushExecutionContext?
        var pushNonceDigest: String?
        var peerRoundTripVerified = false
        // A random installation marker is not hardware attestation. The caller
        // must match these reports and their actual remote device provenance.
        var physicalMultiDeviceVerified = false
        var requiresIndependentDeviceOriginMatch = true
        var cleanup = "not-requested"
        var failure: String?
    }
    struct Manifest: Codable, Sendable {
        var version = 1
        var role: String
        var runID: String
        var zone: String
        var container = "iCloud.dev.gan.FinanceApp"
        var environment = "Development"
        var localInstanceID: String
        var producerInstanceID: String
        var accountDigest: String
        var challenge: String
        var stage: String
        var consumerInstanceID: String?
        var roundTripDigest: String?
        var pushNonce: String? = nil
    }
    struct Marker: Codable, Equatable, Sendable {
        var version = 1
        var runID: String
        var producerInstanceID: String
        var consumerInstanceID: String?
        var challenge: String
        var role: String
        var receiptID: String
        var receiptSHA256: String
        var roundTripDigest: String?
        var pushNonce: String? = nil
    }
    private struct DeviceMarker: Codable { let instanceID: String }

    static func run(platform: String, makeStore: CloudKitLiveVerification.StoreFactory,
                    onScenario: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async -> Report {
        let request: Request
        do { request = try Request.parse() }
        catch { return Report(phase: "invalid", role: "none", runID: "", zone: "", platform: platform, failure: "Invalid peer QA arguments") }
        var report = Report(phase: request.phase.rawValue, role: request.phase.role, runID: request.runID.uuidString, zone: request.zoneName, platform: platform)
        report.passQualityOfService = request.phase == .awaitPush || request.phase == .sendPush ? "utility" : "userInitiated"
        let configuration = CloudKitSyncConfiguration(containerIdentifier: "iCloud.dev.gan.FinanceApp", environment: "Development", zoneName: request.zoneName)
        var store: (any CloudKitLiveVerificationStore)?
        var phaseDirectory: URL?
        var pushSessionID: UUID?
        let pushEvidence = PeerValue<CloudKitPeerPushEvidence?>(nil)
        var descriptor: Int32 = -1
        defer { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor) } }
        do {
            onScenario(request.phase.rawValue)
            // Native construction validates the exact signed Development scope
            // (or an explicitly authorized, binary-bound simulator QA proof).
            let accountProbe = try CloudKitLiveVerification.makeNativeQAClient(configuration: configuration)
            let account = PeerValue<String?>(nil)
            try await CloudKitLiveVerification.bounded("Peer account", seconds: 60, cancel: { accountProbe.cancel() }) {
                account.set(try await accountProbe.accountIdentifier())
            }
            accountProbe.cancel()
            guard let accountID = account.get() else { throw PeerFailure.check("Peer account could not be identified") }
            let accountDigest = digest(Data(accountID.utf8))

            let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            let base = temp.appendingPathComponent("FinancesPeerQA_\(request.runID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard base.resolvingSymlinksInPath().standardizedFileURL == base.standardizedFileURL else { throw PeerFailure.check("Peer QA storage must not be redirected") }
            let lockURL = base.appendingPathComponent("phase.lock")
            descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw PeerFailure.check("Another peer QA phase is active in this app") }
            let instanceURL = base.appendingPathComponent("instance.json")
            let instance: DeviceMarker
            if FileManager.default.fileExists(atPath: instanceURL.path) { instance = try read(DeviceMarker.self, at: instanceURL) }
            else { instance = DeviceMarker(instanceID: UUID().uuidString); try write(instance, to: instanceURL) }
            guard UUID(uuidString: instance.instanceID) != nil else { throw PeerFailure.check("Peer instance manifest is invalid") }
            let directory = base.appendingPathComponent(request.phase.role, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else { throw PeerFailure.check("Peer role storage must not be redirected") }
            phaseDirectory = directory
            let manifestURL = directory.appendingPathComponent("ownership.json")
            var manifest = FileManager.default.fileExists(atPath: manifestURL.path) ? try read(Manifest.self, at: manifestURL) : nil
            if let existing = manifest { try validateOwnership(existing, request: request, localInstanceID: instance.instanceID, accountDigest: accountDigest) }
            let context = [configuration.containerIdentifier, configuration.environment, configuration.zoneName].joined(separator: "|")
            let dependencies = CloudKitSyncDependencies(configuration: { configuration }, makeClient: { _ in
                PeerTransport(native: try CloudKitLiveVerification.makeNativeQAClient(configuration: configuration,
                              qualityOfService: request.phase == .awaitPush || request.phase == .sendPush ? .utility : .userInitiated), configuration: configuration,
                              runID: request.runID, allowCreation: request.phase == .prepare, accountDigest: accountDigest)
            }, automaticTriggersEnabled: request.phase == .awaitPush || request.phase == .sendPush)
            let storage = directory.appendingPathComponent("journal.json")
            let fixture = PeerFixture(runID: request.runID)

            switch request.phase {
            case .prepare:
                if let existing = manifest {
                    guard existing.stage == "reserved" else { throw PeerFailure.check("Producer prepare already completed; continue with consumer exchange or producer verify") }
                } else {
                    try await CloudKitLiveVerification.requireEmptyQAResources(configuration: configuration, runID: request.runID)
                    manifest = Manifest(role: "producer", runID: request.runID.uuidString, zone: request.zoneName,
                                        localInstanceID: instance.instanceID, producerInstanceID: instance.instanceID,
                                        accountDigest: accountDigest, challenge: UUID().uuidString, stage: "reserved")
                    try write(manifest!, to: manifestURL) // Reserve ownership before any creation request.
                }
                let owner = manifest!
                let bytes = producerReceipt(runID: request.runID, producer: owner.producerInstanceID, challenge: owner.challenge)
                let receipt = fixture.producerAsset(size: bytes.count)
                let path = directory.appendingPathComponent(receipt.storedPath)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: path.path) {
                    guard digest(try Data(contentsOf: path)) == digest(bytes) else { throw PeerFailure.check("Existing producer receipt differs from its ownership manifest") }
                } else { try bytes.write(to: path, options: .atomic) }
                let marker = Marker(runID: request.runID.uuidString, producerInstanceID: owner.producerInstanceID, challenge: owner.challenge,
                                    role: "producer", receiptID: receipt.id.uuidString, receiptSHA256: digest(bytes))
                let data = try fixture.data(marker: marker, receipt: receipt, amount: "12.34")
                let producer = makeStore(storage, data, dependencies); store = producer
                try require(!producer.requiresJournalRecovery, "Producer QA journal could not be loaded")
                try await sync(producer, label: "Producer publish")
                try verifyData(producer, request: request, marker: marker, amount: "12.34")
                manifest!.stage = "prepared"; try write(manifest!, to: manifestURL)
                populate(&report, marker: marker, amount: "12.34")
                report.cleanup = "producer-owned-zone-retained"

            case .exchange, .awaitPush:
                // Read only the deterministic QA transaction first. A consumer
                // never creates a zone or invokes hard deletion.
                try await CloudKitLiveVerification.requireExistingQAZone(configuration: configuration, runID: request.runID)
                let probe = try CloudKitLiveVerification.makeNativeQAClient(configuration: configuration)
                let remote = PeerValue<CloudKitSyncRecord?>(nil)
                try await CloudKitLiveVerification.bounded("Producer marker", seconds: 60, cancel: { probe.cancel() }) {
                    remote.set(try await probe.fetchRecord(recordType: "transaction", recordID: fixture.transactionID.uuidString))
                }
                probe.cancel()
                guard let record = remote.get(), let payload = record.payloadJSON?.data(using: .utf8) else { throw PeerFailure.check("Producer marker was not found") }
                let transaction = try JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: payload)
                let producerMarker = try marker(from: transaction, request: request)
                try require(producerMarker.producerInstanceID != instance.instanceID, "Producer and consumer are the same app instance; use another device")
                try require(producerMarker.role == "producer" || producerMarker.consumerInstanceID == instance.instanceID, "A different consumer already exchanged this run")
                if let existing = manifest {
                    try require(existing.producerInstanceID == producerMarker.producerInstanceID && existing.challenge == producerMarker.challenge, "Consumer manifest does not match this producer")
                } else {
                    manifest = Manifest(role: "consumer", runID: request.runID.uuidString, zone: request.zoneName,
                                        localInstanceID: instance.instanceID, producerInstanceID: producerMarker.producerInstanceID,
                                        accountDigest: accountDigest, challenge: producerMarker.challenge, stage: "joining")
                    try write(manifest!, to: manifestURL)
                }
                let consumer = makeStore(storage, JournalData(), dependencies); store = consumer
                try require(!consumer.requiresJournalRecovery, "Consumer QA journal could not be loaded")
                let cancelBootstrap: (@MainActor @Sendable () -> Void)?
                if request.phase == .awaitPush {
                    // Capture the first registration callback caused by enable.
                    // Delivery remains gated until the verified READY boundary.
                    let session = try CloudKitPeerPushRelay.begin(request: request, configuration: configuration) {
                        await consumer.handleAutomaticPushNotification()
                    }
                    pushSessionID = session
                    cancelBootstrap = {
                        retirePushSession(session, evidence: pushEvidence)
                        consumer.stopAutomaticPushVerification(); consumer.setSyncEnabled(false)
                    }
                } else { cancelBootstrap = nil }
                try await sync(consumer, label: "Consumer pull", cancel: cancelBootstrap)
                guard let pulled = consumer.data.transactions.first(where: { $0.id == fixture.transactionID }) else { throw PeerFailure.check("Consumer did not receive the producer transaction") }
                var currentMarker = try marker(from: pulled, request: request)
                try require(currentMarker.producerInstanceID == manifest!.producerInstanceID && currentMarker.challenge == manifest!.challenge,
                            "Producer challenge changed during the consumer pull")
                if request.phase == .awaitPush {
                    try require(currentMarker.role == "producer" && currentMarker.pushNonce == nil, "Automatic push QA requires the unchanged producer baseline")
                    try verifyData(consumer, request: request, marker: currentMarker, amount: "12.34")
                    try await CloudKitLiveVerification.ensureExistingQAZoneSubscription(configuration: configuration, runID: request.runID)
                    guard let session = pushSessionID else { throw PeerFailure.check("The consumer registration session was lost") }
                    try consumer.startAutomaticPushVerification()
                    try await waitForAutomatic(consumer, label: "APNs registration", seconds: 30, cancel: {
                        retirePushSession(session, evidence: pushEvidence)
                        consumer.stopAutomaticPushVerification(); consumer.setSyncEnabled(false)
                    }) {
                        let evidence = try CloudKitPeerPushRelay.snapshot(sessionID: session)
                        try require(!evidence.registrationFailed, "APNs registration failed in the consumer app")
                        return evidence.registrationSucceeded
                    }
                    try await CloudKitLiveVerification.bounded("Consumer ready baseline", seconds: 30, cancel: {
                        retirePushSession(session, evidence: pushEvidence)
                        consumer.stopAutomaticPushVerification(); consumer.setSyncEnabled(false)
                    }) { await consumer.waitForCloudKitSyncIdle() }
                    try require(consumer.cloudSyncProgress.state == .succeeded
                                && consumer.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context).isEmpty
                                && consumer.cloudKitSyncConflicts().isEmpty, "Consumer baseline is not fully synchronized")
                    try verifyData(consumer, request: request, marker: currentMarker, amount: "12.34")
                    try CloudKitPeerPushRelay.markReady(sessionID: session)
                    report.pushRegistrationSucceeded = true
                    var ready = report; ready.status = "READY"; ready.cleanup = "awaiting-producer-send-push"
                    populate(&ready, marker: currentMarker, amount: "12.34"); ready.consumerInstanceID = instance.instanceID
                    try write(ready, to: directory.appendingPathComponent("consumer-push-ready.json"))
                    emit(ready); onScenario("READY awaiting producer push")
                    let baseline = currentMarker
                    try await waitForAutomatic(consumer, label: "Automatic push convergence", seconds: 240, cancel: {
                        retirePushSession(session, evidence: pushEvidence)
                        consumer.stopAutomaticPushVerification(); consumer.setSyncEnabled(false)
                    }) {
                        let evidence = try CloudKitPeerPushRelay.snapshot(sessionID: session)
                        guard evidence.matchingNotificationCount > 0,
                              let transaction = consumer.data.transactions.first(where: { $0.id == fixture.transactionID }) else { return false }
                        let candidate = try marker(from: transaction, request: request)
                        guard candidate.role == "producer", candidate.pushNonce != nil, candidate.pushNonce != baseline.pushNonce else { return false }
                        try require(candidate.producerInstanceID == baseline.producerInstanceID && candidate.challenge == baseline.challenge, "Producer identity changed while waiting for automatic convergence")
                        try verifyData(consumer, request: request, marker: candidate, amount: "78.90")
                        return try acknowledgedMarker(consumer, fixture: fixture, request: request, expected: candidate)
                    }
                    let received = try requiredPeerTransaction(consumer, fixture: fixture)
                    currentMarker = try marker(from: received, request: request)
                    report.matchingPushNotificationCount = try CloudKitPeerPushRelay.snapshot(sessionID: session).matchingNotificationCount
                    report.matchingPushDeliveryVerified = true; report.automaticConvergenceVerified = true
                    report.convergenceObservedExecutionContext = consumer.automaticPushExecutionContext
                    let delivery = try CloudKitPeerPushRelay.snapshot(sessionID: session)
                    report.pushDeliveryExecutionContexts = delivery.matchingDeliveryContexts
                    report.backgroundPushDeliveryVerified = delivery.matchingDeliveryContexts.contains(.background)
                    if platform.hasPrefix("iOS"), consumer.automaticPushExecutionContext != .foreground {
                        var received = report; received.status = "RECEIVED_NEEDS_FOREGROUND"
                        received.cleanup = "foreground-the-consumer-for-automatic-return"
                        populate(&received, marker: currentMarker, amount: "78.90")
                        try write(received, to: directory.appendingPathComponent("consumer-push-received.json"))
                        emit(received); onScenario("RECEIVED_NEEDS_FOREGROUND")
                        try await waitForAutomatic(consumer, label: "Foreground consumer return", seconds: 240, cancel: {
                            retirePushSession(session, evidence: pushEvidence)
                            consumer.stopAutomaticPushVerification(); consumer.setSyncEnabled(false)
                        }) { consumer.automaticPushExecutionContext == .foreground }
                    }
                    manifest!.pushNonce = currentMarker.pushNonce
                }
                if currentMarker.role == "producer" {
                    try verifyData(consumer, request: request, marker: currentMarker, amount: currentMarker.pushNonce == nil ? "12.34" : "78.90")
                    if request.phase != .awaitPush { consumer.setSyncEnabled(false) }
                    let bytes = consumerReceipt(runID: request.runID, producer: currentMarker.producerInstanceID,
                                                consumer: instance.instanceID, challenge: currentMarker.challenge, pushNonce: currentMarker.pushNonce)
                    let input = directory.appendingPathComponent("consumer-receipt-input.txt")
                    try bytes.write(to: input, options: .atomic)
                    let receipt = try consumer.importAttachment(from: input)
                    var reply = Marker(runID: request.runID.uuidString, producerInstanceID: currentMarker.producerInstanceID,
                                       consumerInstanceID: instance.instanceID, challenge: currentMarker.challenge, role: "consumer",
                                       receiptID: receipt.id.uuidString, receiptSHA256: digest(bytes), pushNonce: currentMarker.pushNonce)
                    reply.roundTripDigest = roundTripDigest(reply)
                    var draft = consumer.draft(for: try requiredPeerTransaction(consumer, fixture: fixture))
                    draft.note = try markerJSON(reply)
                    draft.payee = "Peer Consumer Return"
                    for index in draft.postings.indices {
                        draft.postings[index].amount = draft.postings[index].accountID == fixture.checkingID ? "-56.78" : "56.78"
                    }
                    draft.attachments = [receipt]
                    consumer.saveTransaction(draft)
                    try require(consumer.validationError == nil, "Consumer edit was rejected")
                    try applyConsumerRecurringEdit(consumer, request: request, marker: reply)
                    if request.phase == .awaitPush {
                        let expected = reply
                        guard let session = pushSessionID else { throw PeerFailure.check("The push verification session was lost") }
                        try await waitForAutomatic(consumer, label: "Automatic consumer return", seconds: 90, cancel: {
                            retirePushSession(session, evidence: pushEvidence)
                            consumer.stopAutomaticPushVerification(); consumer.setSyncEnabled(false)
                        }) {
                            try acknowledgedMarker(consumer, fixture: fixture, request: request, expected: expected)
                                && consumer.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context).isEmpty
                        }
                        report.automaticUploadVerified = true
                    } else { try await sync(consumer, label: "Consumer return upload") }
                }
                guard let saved = consumer.data.transactions.first(where: { $0.id == fixture.transactionID }) else { throw PeerFailure.check("Consumer return disappeared") }
                let reply = try marker(from: saved, request: request)
                try require(reply.consumerInstanceID == instance.instanceID && reply.role == "consumer", "Consumer return identity differs")
                try verifyData(consumer, request: request, marker: reply, amount: "56.78")
                manifest!.stage = "exchanged"; manifest!.consumerInstanceID = instance.instanceID; manifest!.roundTripDigest = reply.roundTripDigest
                try write(manifest!, to: manifestURL)
                populate(&report, marker: reply, amount: "56.78")
                report.cleanup = "zone-left-for-producer"

            case .sendPush:
                guard let owner = manifest else { throw PeerFailure.check("Producer push ownership is missing") }
                try validatePushSend(owner, request: request, localInstanceID: instance.instanceID, accountDigest: accountDigest)
                try await CloudKitLiveVerification.requireExistingQAZone(configuration: configuration, runID: request.runID)
                let producer = makeStore(storage, JournalData(), dependencies); store = producer
                let result = try await automaticallySendProducerPush(producer, request: request, owner: owner, directory: directory) {
                    try write($0, to: manifestURL)
                }
                manifest = result.owner // Keep stage=prepared so owned abort remains valid.
                populate(&report, marker: result.marker, amount: "78.90")
                report.resumedPushAttempt = result.resumed
                report.automaticUploadVerified = result.automaticUploadVerified
                report.cleanup = "producer-owned-zone-retained"

            case .verify:
                guard var owner = manifest, ["prepared", "verified"].contains(owner.stage) else { throw PeerFailure.check("Producer prepare ownership is required before verification") }
                try await CloudKitLiveVerification.requireExistingQAZone(configuration: configuration, runID: request.runID)
                let producer = makeStore(storage, JournalData(), dependencies); store = producer
                try require(!producer.requiresJournalRecovery, "Producer QA journal could not be reopened")
                try await sync(producer, label: "Producer round-trip pull")
                guard let received = producer.data.transactions.first(where: { $0.id == fixture.transactionID }) else { throw PeerFailure.check("Producer did not receive the return transaction") }
                let reply = try marker(from: received, request: request)
                try require(reply.role == "consumer" && reply.producerInstanceID == owner.producerInstanceID && reply.challenge == owner.challenge,
                            "Return marker does not match the producer challenge")
                try require(reply.consumerInstanceID != nil && reply.consumerInstanceID != owner.producerInstanceID, "A distinct consumer instance is required")
                try require(reply.pushNonce == owner.pushNonce, "The consumer return does not match the producer's push attempt")
                try verifyData(producer, request: request, marker: reply, amount: "56.78")
                owner.stage = "verified"; owner.consumerInstanceID = reply.consumerInstanceID; owner.roundTripDigest = reply.roundTripDigest
                try write(owner, to: manifestURL)
                populate(&report, marker: reply, amount: "56.78")
                report.peerRoundTripVerified = true
                report.cleanup = "ready-for-explicit-producer-cleanup"

            case .abort:
                guard let owner = manifest else { throw PeerFailure.check("Producer ownership manifest is missing") }
                let aborted = try await abortOwnedRun(owner, request: request, localInstanceID: instance.instanceID, accountDigest: accountDigest,
                    stopLocal: {
                        // The phase lock excludes another run in this app. Only
                        // this proven-owned path is reopened, with automatic
                        // triggers disabled, before any remote removal.
                        let producer = makeStore(storage, JournalData(), dependencies)
                        store = producer
                        try require(!producer.requiresJournalRecovery, "Producer QA journal must be readable before aborting")
                        producer.setSyncEnabled(false)
                        try await wait(producer, label: "Stop producer before abort", seconds: 30)
                        try require(!producer.data.syncEnabled && producer.validationError == nil, "Producer QA sync could not be stopped")
                        try require(producer.cloudKitSQLiteStore.loadData()?.syncEnabled == false, "Producer QA Sync Off was not saved")
                    }, persistOwnership: { try write($0, to: manifestURL) },
                    removeRemote: { try await CloudKitLiveVerification.removeOwnedQAResources(configuration: configuration, runID: request.runID) },
                    requireAbsent: { try await CloudKitLiveVerification.requireEmptyQAResources(configuration: configuration, runID: request.runID) })
                manifest = aborted
                report = abortReport(aborted, request: request, platform: platform)
                // Retain local journals, pending changes and prior reports as
                // failure evidence; the aborted stage prevents run resumption.

            case .cleanup:
                guard var owner = manifest else { throw PeerFailure.check("Producer ownership manifest is missing") }
                try validateCleanup(owner, request: request, localInstanceID: instance.instanceID, accountDigest: accountDigest)
                if owner.stage == "cleaned" {
                    try await CloudKitLiveVerification.requireEmptyQAResources(configuration: configuration, runID: request.runID)
                } else {
                    owner.stage = "cleanup-pending"; try write(owner, to: manifestURL)
                    try await CloudKitLiveVerification.removeOwnedQAResources(configuration: configuration, runID: request.runID)
                    owner.stage = "cleaned"; try write(owner, to: manifestURL)
                }
                report.producerInstanceID = owner.producerInstanceID; report.consumerInstanceID = owner.consumerInstanceID
                report.challengeDigest = digest(Data(owner.challenge.utf8)); report.roundTripDigest = owner.roundTripDigest
                report.peerRoundTripVerified = true
                report.cleanup = "verified-absent"
                for name in ["journal.sqlite", "journal.sqlite-wal", "journal.sqlite-shm", "journal.json", "Attachments"] {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
            }
            if request.phase != .abort, let store {
                try require(store.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context).isEmpty, "Peer phase still has unacknowledged changes")
                try require(store.cloudKitSyncConflicts().isEmpty, "Peer phase has unresolved conflicts")
            }
            report.status = "PASS"
        } catch { report.failure = safeDescription(error) }
        if let pushSessionID { retirePushSession(pushSessionID, evidence: pushEvidence) }
        if let evidence = pushEvidence.get() {
            report.pushRegistrationSucceeded = evidence.registrationSucceeded
            report.pushRegistrationFailed = evidence.registrationFailed
            report.matchingPushNotificationCount = evidence.matchingNotificationCount
            report.pushDeliveryExecutionContexts = evidence.matchingDeliveryContexts
            report.backgroundPushDeliveryVerified = report.status == "PASS" && evidence.matchingDeliveryContexts.contains(.background)
        }
        if let store {
            store.stopAutomaticPushVerification()
            store.setSyncEnabled(false)
            let shutdown = await Task { @MainActor in
                do { try await wait(store, label: "Peer shutdown", seconds: 30); return true }
                catch { return false }
            }.value
            if !shutdown { report.status = "FAIL"; report.failure = report.failure ?? "Peer store did not stop" }
        }
        if report.status != "PASS" {
            report.matchingPushDeliveryVerified = false; report.automaticConvergenceVerified = false; report.automaticUploadVerified = false
            report.backgroundPushDeliveryVerified = false
        }
        if let phaseDirectory { try? write(report, to: phaseDirectory.appendingPathComponent("\(request.phase.rawValue)-report.json")) }
        return report
    }

    nonisolated static func validateOwnership(_ manifest: Manifest, request: Request, localInstanceID: String, accountDigest: String) throws {
        guard manifest.version == 1, manifest.runID == request.runID.uuidString, manifest.zone == request.zoneName,
              manifest.container == "iCloud.dev.gan.FinanceApp", manifest.environment == "Development",
              manifest.role == request.phase.role, manifest.localInstanceID == localInstanceID,
              manifest.accountDigest == accountDigest, UUID(uuidString: manifest.producerInstanceID) != nil,
              UUID(uuidString: manifest.challenge) != nil,
              manifest.pushNonce == nil || manifest.pushNonce.flatMap(UUID.init(uuidString:)) != nil else { throw PeerFailure.check("Peer ownership, run scope, or iCloud account changed") }
        if request.phase.role == "producer", manifest.producerInstanceID != localInstanceID { throw PeerFailure.check("Only the creating producer can manage this QA zone") }
    }
    struct ProducerPushResult {
        let owner: Manifest
        let marker: Marker
        let resumed: Bool
        // A retry may recover a previously accepted value. It cannot certify a
        // newly observed automatic edit/upload in this attempt.
        var automaticUploadVerified: Bool { !resumed }
    }

    /// This seam is exercised with an isolated store and fake automatic transport.
    /// It deliberately has no explicit Sync request, including on a pending retry.
    static func automaticallySendProducerPush(_ producer: any CloudKitLiveVerificationStore, request: Request,
                                             owner originalOwner: Manifest, directory: URL,
                                             persistOwnership: (Manifest) throws -> Void) async throws -> ProducerPushResult {
        try validatePushSend(originalOwner, request: request, localInstanceID: originalOwner.localInstanceID, accountDigest: originalOwner.accountDigest)
        try require(!producer.requiresJournalRecovery, "Producer QA journal could not be reopened")
        let fixture = PeerFixture(runID: request.runID)
        let initial = try requiredPeerTransaction(producer, fixture: fixture)
        let initialMarker = try marker(from: initial, request: request)
        try require(initialMarker.role == "producer" && initialMarker.producerInstanceID == originalOwner.producerInstanceID
                    && initialMarker.challenge == originalOwner.challenge, "Producer push baseline identity differs")
        try verifyData(producer, request: request, marker: initialMarker, amount: initialMarker.pushNonce == nil ? "12.34" : "78.90")
        var owner = originalOwner
        let resumed = owner.pushNonce != nil
        if owner.pushNonce == nil { owner.pushNonce = UUID().uuidString; try persistOwnership(owner) }
        try require(initialMarker.pushNonce == nil || initialMarker.pushNonce == owner.pushNonce, "An unrelated push attempt already changed the fixture")
        try producer.startAutomaticPushVerification()
        if !producer.data.syncEnabled { producer.setSyncEnabled(true) }
        let nonce = owner.pushNonce!
        var sent = initialMarker
        if initialMarker.pushNonce == nil {
            let bytes = producerReceipt(runID: request.runID, producer: owner.producerInstanceID, challenge: owner.challenge, pushNonce: nonce)
            let input = directory.appendingPathComponent("producer-push-receipt-input.txt")
            try bytes.write(to: input, options: .atomic)
            let receipt = try producer.importAttachment(from: input)
            sent.pushNonce = nonce; sent.receiptID = receipt.id.uuidString; sent.receiptSHA256 = digest(bytes)
            var draft = producer.draft(for: initial)
            draft.note = try markerJSON(sent)
            for index in draft.postings.indices { draft.postings[index].amount = draft.postings[index].accountID == fixture.checkingID ? "-78.90" : "78.90" }
            draft.attachments = [receipt]
            producer.saveTransaction(draft)
            try require(producer.validationError == nil, "Producer push edit was rejected")
        }
        let expected = sent
        let context = ["iCloud.dev.gan.FinanceApp", "Development", request.zoneName].joined(separator: "|")
        try await waitForAutomatic(producer, label: "Automatic producer upload", seconds: 90) {
            try acknowledgedMarker(producer, fixture: fixture, request: request, expected: expected)
                && producer.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context).isEmpty
        }
        try verifyData(producer, request: request, marker: expected, amount: "78.90")
        return ProducerPushResult(owner: owner, marker: expected, resumed: resumed)
    }

    nonisolated static func validatePushSend(_ manifest: Manifest, request: Request, localInstanceID: String, accountDigest: String) throws {
        try validateOwnership(manifest, request: request, localInstanceID: localInstanceID, accountDigest: accountDigest)
        guard request.phase == .sendPush, manifest.stage == "prepared", manifest.consumerInstanceID == nil,
              manifest.roundTripDigest == nil else { throw PeerFailure.check("Producer push requires an owned prepared fixture") }
    }

    nonisolated static func validateCleanup(_ manifest: Manifest, request: Request, localInstanceID: String, accountDigest: String) throws {
        try validateOwnership(manifest, request: request, localInstanceID: localInstanceID, accountDigest: accountDigest)
        guard request.phase == .cleanup, ["verified", "cleanup-pending", "cleaned"].contains(manifest.stage),
              let consumer = manifest.consumerInstanceID, consumer != manifest.producerInstanceID,
              UUID(uuidString: consumer) != nil, manifest.roundTripDigest?.count == 64 else {
            throw PeerFailure.check("Producer cleanup requires a completed, distinct-consumer round trip")
        }
    }
    nonisolated static func validateAbort(_ manifest: Manifest, request: Request, localInstanceID: String, accountDigest: String) throws {
        try validateOwnership(manifest, request: request, localInstanceID: localInstanceID, accountDigest: accountDigest)
        guard request.phase == .abort, ["reserved", "prepared", "abort-pending", "aborted"].contains(manifest.stage),
              manifest.consumerInstanceID == nil, manifest.roundTripDigest == nil else {
            throw PeerFailure.check("Producer abort requires ownership of an unfinished peer run; use producer-cleanup after verification")
        }
    }

    /// The same ordering is exercised offline with deterministic failure hooks.
    /// A failed stop or ownership write cannot authorize remote deletion, and a
    /// failed deletion leaves a resumable manifest without a success report.
    static func abortOwnedRun(_ manifest: Manifest, request: Request, localInstanceID: String, accountDigest: String,
                              stopLocal: () async throws -> Void, persistOwnership: (Manifest) throws -> Void,
                              removeRemote: () async throws -> Void, requireAbsent: () async throws -> Void) async throws -> Manifest {
        try validateAbort(manifest, request: request, localInstanceID: localInstanceID, accountDigest: accountDigest)
        try await stopLocal()
        try Task.checkCancellation()
        var owner = manifest
        if owner.stage == "aborted" {
            try await requireAbsent()
        } else {
            owner.stage = "abort-pending"
            try persistOwnership(owner)
            try Task.checkCancellation()
            try await removeRemote()
            try Task.checkCancellation()
            owner.stage = "aborted"
            try persistOwnership(owner)
        }
        return owner
    }

    static func abortReport(_ owner: Manifest, request: Request, platform: String) -> Report {
        var report = Report(phase: request.phase.rawValue, role: request.phase.role, runID: request.runID.uuidString, zone: request.zoneName, platform: platform)
        report.producerInstanceID = owner.producerInstanceID
        report.challengeDigest = digest(Data(owner.challenge.utf8))
        report.peerRoundTripVerified = false
        report.cleanup = "verified-absent"
        return report
    }

    static func applyConsumerRecurringEdit(_ store: any CloudKitLiveVerificationStore, request: Request, marker: Marker) throws {
        let fixture = PeerFixture(runID: request.runID)
        let before = store.data.transactions.filter { $0.recurrenceRule?.id == fixture.recurringRuleID }.sorted { $0.date < $1.date }
        try require(before.count == 3, "Peer recurring fixture is incomplete")
        var draft = store.draft(for: before[1])
        draft.note = "Peer recurring one-off \(marker.challenge)"
        for index in draft.postings.indices { draft.postings[index].amount = draft.postings[index].accountID == fixture.recurringCheckingID ? "-7.50" : "7.50" }
        store.saveTransaction(draft)
        try require(store.validationError == nil, "Consumer recurring one-off edit was rejected")
        let after = store.data.transactions.filter { $0.recurrenceRule?.id == fixture.recurringRuleID }.sorted { $0.date < $1.date }
        try require(after == fixture.recurringRows(marker: marker), "Consumer recurring values, IDs or history differ")
        try require(after[0] == before[0] && after[2] == before[2], "Consumer one-off edit affected another occurrence")
    }

    static func verifyData(_ store: any CloudKitLiveVerificationStore, request: Request, marker: Marker, amount: String) throws {
        let fixture = PeerFixture(runID: request.runID)
        try require(store.balance(for: fixture.checkingID) == -(Decimal(string: amount)!), "Peer amount or derived balance differs")
        guard let transaction = store.data.transactions.first(where: { $0.id == fixture.transactionID }),
              let receipt = transaction.attachment?.assets.first, transaction.attachment?.assets.count == 1,
              receipt.id.uuidString == marker.receiptID else { throw PeerFailure.check("Peer receipt relationship differs") }
        let expectedData = try fixture.data(marker: marker, receipt: receipt, amount: amount)
        try CloudKitLiveVerification.requireInitialDomains(store.data, expected: expectedData)
        let recurringBalance = marker.role == "producer" ? Decimal(string: "-11.50")! : Decimal(string: "-15")!
        try require(store.balance(for: fixture.recurringCheckingID) == recurringBalance, "Peer recurring balance differs")
        let file = try store.cloudKitAttachmentURL(for: receipt)
        let bytes = try Data(contentsOf: file)
        let expected = marker.role == "producer"
            ? producerReceipt(runID: request.runID, producer: marker.producerInstanceID, challenge: marker.challenge, pushNonce: marker.pushNonce)
            : consumerReceipt(runID: request.runID, producer: marker.producerInstanceID, consumer: marker.consumerInstanceID ?? "", challenge: marker.challenge, pushNonce: marker.pushNonce)
        try require(bytes == expected && digest(bytes) == marker.receiptSHA256, "Peer receipt bytes did not match the challenge")
        if marker.role == "consumer" { try require(marker.roundTripDigest == roundTripDigest(marker), "Peer round-trip digest differs") }
        try require(store.liveIntegrityIsValid(), "Peer local journal integrity failed")
    }
    private static func marker(from transaction: LedgerTransaction, request: Request) throws -> Marker {
        let marker = try JSONDecoder().decode(Marker.self, from: Data(transaction.note.utf8))
        try require(transaction.id == PeerFixture(runID: request.runID).transactionID && marker.version == 1 && marker.runID == request.runID.uuidString,
                    "The cloud transaction is not this peer QA run")
        try require(UUID(uuidString: marker.producerInstanceID) != nil && UUID(uuidString: marker.challenge) != nil && ["producer", "consumer"].contains(marker.role), "Peer marker is invalid")
        try require(marker.pushNonce == nil || marker.pushNonce.flatMap(UUID.init(uuidString:)) != nil, "Peer push nonce is invalid")
        return marker
    }
    private static func populate(_ report: inout Report, marker: Marker, amount: String) {
        report.producerInstanceID = marker.producerInstanceID; report.consumerInstanceID = marker.consumerInstanceID
        report.challengeDigest = digest(Data(marker.challenge.utf8)); report.roundTripDigest = marker.roundTripDigest
        report.receiptSHA256 = marker.receiptSHA256; report.transactionAmount = amount
        report.pushNonceDigest = marker.pushNonce.map { digest(Data($0.utf8)) }
    }
    private static func retirePushSession(_ session: UUID, evidence: PeerValue<CloudKitPeerPushEvidence?>) {
        if let current = try? CloudKitPeerPushRelay.snapshot(sessionID: session) { evidence.set(current) }
        CloudKitPeerPushRelay.end(sessionID: session)
    }

    private static func requiredPeerTransaction(_ store: any CloudKitLiveVerificationStore, fixture: PeerFixture) throws -> LedgerTransaction {
        guard let transaction = store.data.transactions.first(where: { $0.id == fixture.transactionID }) else {
            throw PeerFailure.check("The peer QA transaction is missing")
        }
        return transaction
    }
    private static func acknowledgedMarker(_ store: any CloudKitLiveVerificationStore, fixture: PeerFixture, request: Request, expected: Marker) throws -> Bool {
        let context = ["iCloud.dev.gan.FinanceApp", "Development", request.zoneName].joined(separator: "|")
        let known = try store.cloudKitSQLiteStore.knownCloudKitRecords(contextKey: context)
        guard let transaction = known["transaction:\(fixture.transactionID.uuidString)"]?.payloadJSON?.data(using: .utf8),
              let asset = known["attachment_asset:\(expected.receiptID)"], asset.operation == "upsert",
              asset.assetSHA256 == expected.receiptSHA256, asset.parentRecordID == fixture.containerID.uuidString else { return false }
        return try marker(from: JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: transaction), request: request) == expected
    }
    private static func waitForAutomatic(_ store: any CloudKitLiveVerificationStore, label: String, seconds: Double,
                                         cancel: (@MainActor @Sendable () -> Void)? = nil,
                                         until complete: @escaping @MainActor @Sendable () throws -> Bool) async throws {
        try await CloudKitLiveVerification.bounded(label, seconds: seconds, cancel: cancel ?? { store.setSyncEnabled(false) }) {
            while true {
                try Task.checkCancellation()
                try require(store.data.syncEnabled && !store.requiresJournalRecovery, "Automatic peer sync stopped before verification completed")
                try require(store.validationError == nil && store.cloudKitSyncConflicts().isEmpty, "Automatic peer sync requires recovery or conflict resolution")
                if try complete() { return }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
    private static func emit(_ report: Report) {
        if let data = try? encoded(report) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func sync(_ store: any CloudKitLiveVerificationStore, label: String,
                             cancel: (@MainActor @Sendable () -> Void)? = nil) async throws {
        store.validationError = nil
        if !store.data.syncEnabled { store.setSyncEnabled(true) }
        store.requestCloudKitSync(reportProgress: true, requireFollowUpIfBusy: false)
        try await wait(store, label: label, cancel: cancel)
        try require(store.cloudSyncProgress.state == .succeeded, "\(label) failed (\(store.cloudSyncProgress.message))")
    }
    private static func wait(_ store: any CloudKitLiveVerificationStore, label: String, seconds: Double = 90,
                             cancel: (@MainActor @Sendable () -> Void)? = nil) async throws {
        try await CloudKitLiveVerification.bounded(label, seconds: seconds, cancel: cancel ?? { store.setSyncEnabled(false) }) { await store.waitForCloudKitSyncIdle() }
    }
    private static func markerJSON(_ marker: Marker) throws -> String { String(decoding: try encoded(marker), as: UTF8.self) }
    private static func roundTripDigest(_ marker: Marker) -> String {
        digest(Data(([marker.runID, marker.producerInstanceID, marker.consumerInstanceID ?? "", marker.challenge, "56.78", marker.receiptID, marker.receiptSHA256] + (marker.pushNonce.map { [$0] } ?? [])).joined(separator: "|").utf8))
    }
    static func producerReceipt(runID: UUID, producer: String, challenge: String, pushNonce: String? = nil) -> Data { Data(("Finances peer QA v1\nrun=\(runID.uuidString)\nproducer=\(producer)\nchallenge=\(challenge)\nrole=producer\n" + (pushNonce.map { "push=\($0)\n" } ?? "")).utf8) }
    private static func consumerReceipt(runID: UUID, producer: String, consumer: String, challenge: String, pushNonce: String? = nil) -> Data { Data(("Finances peer QA v1\nrun=\(runID.uuidString)\nproducer=\(producer)\nconsumer=\(consumer)\nchallenge=\(challenge)\nrole=consumer\n" + (pushNonce.map { "push=\($0)\n" } ?? "")).utf8) }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { guard try condition() else { throw PeerFailure.check(message) } }
    private static func safeDescription(_ error: Error) -> String {
        if case PeerFailure.check(let message) = error { return message }
        return CloudKitLiveVerification.safeDescription(error)
    }
    nonisolated private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws { try encoded(value).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    private static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let data = try Data(contentsOf: url); guard data.count < 65_536 else { throw PeerFailure.check("Peer manifest is invalid") }
        return try JSONDecoder().decode(type, from: data)
    }
    struct PeerFixture {
        let runID: UUID
        var ledgerID: UUID { id("ledger") }; var currencyID: UUID { id("currency") }
        var assetsID: UUID { id("assets") }; var expensesID: UUID { id("expenses") }
        var checkingID: UUID { id("checking") }; var foodID: UUID { id("food") }
        var transactionID: UUID { id("transaction") }; var containerID: UUID { id("attachment-container") }
        func id(_ label: String) -> UUID {
            var bytes = Array(SHA256.hash(data: Data("\(runID.uuidString)|\(label)".utf8)).prefix(16))
            bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
            return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        }
        func producerAsset(size: Int) -> AttachmentAsset { AttachmentAsset(id: id("producer-receipt"), originalFilename: "producer-qa.txt", storedPath: "Attachments/peer-producer-\(runID.uuidString).txt", mimeType: "text/plain", sizeBytes: Int64(size)) }
        var sourceID: UUID { id("source") }
        var recurringCheckingID: UUID { id("recurring-checking") }
        var recurringExpenseID: UUID { id("recurring-expense") }
        var recurringRuleID: UUID { id("recurring-rule") }
        @MainActor func data(marker: Marker, receipt: AttachmentAsset, amount: String) throws -> JournalData {
            let ledger = Ledger(id: ledgerID, name: "Peer QA \(runID.uuidString)")
            let currency = Commodity(id: currencyID, ledgerID: ledgerID, symbol: "USD", name: "US Dollar")
            let accounts = [Account(id: assetsID, ledgerID: ledgerID, name: "Assets", kind: .asset), Account(id: expensesID, ledgerID: ledgerID, name: "Expenses", kind: .expense),
                            Account(id: checkingID, ledgerID: ledgerID, parentID: assetsID, commodityID: currencyID, name: "Peer Checking", kind: .asset), Account(id: foodID, ledgerID: ledgerID, parentID: expensesID, commodityID: currencyID, name: "Peer Food", kind: .expense),
                            Account(id: recurringCheckingID, ledgerID: ledgerID, parentID: assetsID, commodityID: currencyID, name: "Peer Recurring Checking", kind: .asset), Account(id: recurringExpenseID, ledgerID: ledgerID, parentID: expensesID, commodityID: currencyID, name: "Peer Recurring Expense", kind: .expense)]
            let date = Date(timeIntervalSince1970: 1_577_836_800)
            let source = TransactionSource(id: sourceID, ledgerID: ledgerID, type: 2, date: date, externalID: "synthetic-peer-source-\(runID.uuidString)")
            let template = TransactionTemplate(id: id("template"), ledgerID: ledgerID, name: "Peer shared template", note: "Peer template details", payee: "Peer template payee", cleared: false, enabled: true, scanInvoice: false, listIndex: 1,
                                               postings: [PostingTemplate(id: id("template-credit"), accountID: checkingID), PostingTemplate(id: id("template-debit"), accountID: foodID, listIndex: 1)])
            let transaction = LedgerTransaction(id: transactionID, ledgerID: ledgerID, sourceID: sourceID, date: date, payee: marker.role == "producer" ? "Peer Producer" : "Peer Consumer Return", note: try markerJSON(marker), number: "PEER-001", cleared: true,
                                                postings: [Posting(id: id("posting-credit"), accountID: checkingID, commodityID: currencyID, amount: -(Decimal(string: amount)!)), Posting(id: id("posting-debit"), accountID: foodID, commodityID: currencyID, amount: Decimal(string: amount)!, listIndex: 1)],
                                                attachment: AttachmentContainer(id: containerID, assets: [receipt], createdAt: date), externalTransactionID: "synthetic-peer-transaction-\(runID.uuidString)")
            return JournalData(ledgers: [ledger], commodities: [currency], accounts: accounts, transactions: [transaction] + recurringRows(marker: marker), sources: [source], transactionTemplates: [template], selectedLedgerID: ledgerID, dateFormat: .iso, appearance: .dark)
        }

        @MainActor func recurringRows(marker: Marker) -> [LedgerTransaction] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let date = calendar.date(from: DateComponents(year: 2020, month: 1, day: 15, hour: 12))!
            var anchor = LedgerTransaction(id: id("recurring-anchor"), ledgerID: ledgerID, sourceID: sourceID, date: date, payee: "Peer recurring base", note: "Peer recurring base history", number: "PEER-R", cleared: true,
                                           postings: [Posting(id: id("recurring-credit"), accountID: recurringCheckingID, commodityID: currencyID, amount: Decimal(string: "-3.50")!), Posting(id: id("recurring-debit"), accountID: recurringExpenseID, commodityID: currencyID, amount: Decimal(string: "3.50")!, listIndex: 1)])
            var future = anchor; future.note = "Peer recurring future history"
            for index in future.postings.indices { future.postings[index].amount = future.postings[index].accountID == recurringCheckingID ? -4 : 4 }
            let cutoff = calendar.date(from: DateComponents(year: 2020, month: 2, day: 15))!
            let history = RecurrenceTemplateHistory(baseTemplate: RecurrenceTransactionTemplate(transaction: anchor), changes: [RecurrenceTemplateChange(effectiveDate: cutoff, template: RecurrenceTransactionTemplate(transaction: future))])
            anchor.recurrenceRule = RecurrenceRule(id: recurringRuleID, frequency: .monthly, occurrenceCount: 3, templateHistory: history, continuation: RecurrenceContinuation(anchorDate: date, calendar: calendar))
            let base = JournalData(ledgers: [Ledger(id: ledgerID, name: "Peer recurrence")], transactions: [anchor])
            var rows = RecurringJournalEditor.materialized(base, referenceDate: date, calendar: calendar).transactions.sorted { $0.date < $1.date }
            if marker.role == "consumer" {
                rows[1].note = "Peer recurring one-off \(marker.challenge)"
                for index in rows[1].postings.indices { rows[1].postings[index].amount = rows[1].postings[index].accountID == recurringCheckingID ? Decimal(string: "-7.50")! : Decimal(string: "7.50")! }
            }
            return rows
        }
    }
}

private enum PeerFailure: Error { case check(String) }
private final class PeerValue<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
private final class PeerTransport: CloudKitSyncTransport, @unchecked Sendable {
    let native: CloudKitSyncClient
    let configuration: CloudKitSyncConfiguration
    let runID: UUID
    let allowCreation: Bool
    let accountDigest: String
    init(native: CloudKitSyncClient, configuration: CloudKitSyncConfiguration, runID: UUID, allowCreation: Bool, accountDigest: String) {
        self.native = native; self.configuration = configuration; self.runID = runID; self.allowCreation = allowCreation; self.accountDigest = accountDigest
    }
    func accountIdentifier() async throws -> String {
        let account = try await native.accountIdentifier()
        let hash = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        guard hash == accountDigest else { throw PeerFailure.check("The peer iCloud account changed") }
        return account
    }
    func prepareZone() async throws {
        if allowCreation { try await native.prepareZone() }
        else { try await CloudKitLiveVerification.requireExistingQAZone(configuration: configuration, runID: runID) }
    }
    func fetchChanges(since: Data?) async throws -> CloudKitSyncPage { try await native.fetchChanges(since: since) }
    func fetchRecord(recordType: String, recordID: String) async throws -> CloudKitSyncRecord { try await native.fetchRecord(recordType: recordType, recordID: recordID) }
    func modifyRecords(_ records: [CloudKitSyncRecord]) async throws -> CloudKitSyncModifyResult { try await native.modifyRecords(records) }
    func cancel() { native.cancel() }
}
