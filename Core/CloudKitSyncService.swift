import CloudKit
import CryptoKit
import Foundation
import Security

struct CloudKitSyncConfiguration: Equatable, Sendable {
    var containerIdentifier = "iCloud.dev.gan.FinanceApp"
    var environment = "Development"
    var zoneName = "FinancesJournal_v1"

    static func availableConfiguration() -> Self? {
        let info = Bundle.main.infoDictionary ?? [:]
        let configuration = Self(
            containerIdentifier: info["FinancesCloudKitContainerIdentifier"] as? String ?? "iCloud.dev.gan.FinanceApp",
            environment: info["FinancesCloudKitEnvironment"] as? String ?? "Development",
            zoneName: "FinancesJournal_v1"
        )
        return configuration.validationErrorForCurrentApplication() == nil ? configuration : nil
    }

    func validationErrorForCurrentApplication() -> String? {
        guard containerIdentifier.hasPrefix("iCloud."), !zoneName.isEmpty,
              ["Development", "Production"].contains(environment) else { return "CloudKit configuration is invalid." }
        #if os(macOS)
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 0x0002 /* kSecCodeSignatureAdhoc */ == 0,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              (entitlements["com.apple.developer.icloud-services"] as? [String])?.contains("CloudKit") == true,
              (entitlements["com.apple.developer.icloud-container-identifiers"] as? [String])?.contains(containerIdentifier) == true,
              entitlements["com.apple.developer.icloud-container-environment"] as? String == environment else {
            return "CloudKit requires a signed build with the configured iCloud container. This local build stays offline."
        }
        #elseif targetEnvironment(simulator)
        // A compile-only simulator build cannot prove CloudKit entitlement access.
        return "CloudKit sync requires a signed device build; this simulator stays offline."
        #elseif os(iOS)
        // iOS has no public SecTask entitlement inspector. Device code signing is
        // enforced by the OS; these explicit markers mirror the signed target.
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["FinancesCloudKitEnabled"] as? Bool == true,
              info["FinancesCloudKitContainerIdentifier"] as? String == containerIdentifier,
              info["FinancesCloudKitEnvironment"] as? String == environment,
              let team = info["FinancesCloudKitTeamIdentifier"] as? String,
              !team.isEmpty, !team.contains("$("), Bundle.main.bundleURL.pathExtension == "app" else {
            return "CloudKit requires the configured, signed iOS app."
        }
        #else
        return "CloudKit sync is not configured on this platform."
        #endif
        return nil
    }
}

struct CloudKitSyncRecord: Equatable, Sendable {
    var recordType: String
    var recordID: String
    var operation: String = "upsert"
    var parentRecordID: String? = nil
    var contentHash: String? = nil
    var payloadJSON: String? = nil
    var clientChangeID: String? = nil
    var systemFields: Data? = nil
    /// Fetched files are owned by this client until moved by the caller or cancel/deinit.
    var assetFileURL: URL? = nil
    var assetSHA256: String? = nil
    var assetFilename: String? = nil
    var assetMIMEType: String? = nil
    var key: String { "\(recordType):\(recordID)" }
}

struct CloudKitSyncPage: Equatable, Sendable {
    var records: [CloudKitSyncRecord]
    var changeToken: Data?
    var moreComing: Bool
}

struct CloudKitSyncModifyResult: Equatable, Sendable {
    var saved: [CloudKitSyncRecord]
    var conflicts: [CloudKitSyncRecord]
    var retryAfter: TimeInterval? = nil
    var failureMessage: String? = nil
}

protocol CloudKitSyncTransport: Sendable {
    func accountIdentifier() async throws -> String
    func prepareZone() async throws
    func fetchChanges(since: Data?) async throws -> CloudKitSyncPage
    func fetchRecord(recordType: String, recordID: String) async throws -> CloudKitSyncRecord
    func modifyRecords(_ records: [CloudKitSyncRecord]) async throws -> CloudKitSyncModifyResult
    func cancel()
}

extension CloudKitSyncTransport {
    /// Value-only fallback keeps deterministic/offline transports compatible.
    /// The native client overrides this with one record fetch.
    func fetchRecord(recordType: String, recordID: String) async throws -> CloudKitSyncRecord {
        var token: Data?
        while true {
            try Task.checkCancellation()
            let page = try await fetchChanges(since: token)
            try Task.checkCancellation()
            if let record = page.records.first(where: { $0.recordType == recordType && $0.recordID == recordID }) { return record }
            guard page.moreComing else { throw CloudKitSyncError.invalidData("The selected iCloud record is no longer available.") }
            guard let next = page.changeToken, next != token else { throw CloudKitSyncError.invalidData("iCloud returned a non-advancing page.") }
            token = next
        }
    }
}

enum CloudKitSyncError: LocalizedError, Equatable {
    case unavailable(String), accountUnavailable, permissionDenied, quotaExceeded
    case changeTokenExpired, zoneDeleted, invalidData(String)
    case retryable(String, TimeInterval?), service(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidData(let message), .retryable(let message, _), .service(let message): message
        case .accountUnavailable: "Sign in to iCloud to sync this journal."
        case .permissionDenied: "This app does not have permission to use the configured iCloud container."
        case .quotaExceeded: "iCloud storage is full. Local changes remain queued."
        case .changeTokenExpired: "The iCloud change token expired. A fresh download is required before continuing."
        case .zoneDeleted: "The iCloud journal zone no longer exists. Local journals have been preserved."
        }
    }

    var retryAfter: TimeInterval? {
        if case .retryable(_, let delay) = self { return delay }
        return nil
    }

    static func translate(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let known = error as? Self { return known }
        guard let error = error as? CKError else { return Self.service("CloudKit could not complete the request.") }
        switch error.code {
        case .operationCancelled: return CancellationError()
        case .notAuthenticated, .accountTemporarilyUnavailable: return Self.accountUnavailable
        case .permissionFailure, .missingEntitlement, .badContainer: return Self.permissionDenied
        case .quotaExceeded: return Self.quotaExceeded
        case .changeTokenExpired: return Self.changeTokenExpired
        case .zoneNotFound, .userDeletedZone: return Self.zoneDeleted
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return Self.retryable("iCloud is temporarily unavailable. Local changes remain queued.", error.retryAfterSeconds)
        default: return Self.service("CloudKit request failed (code \(error.code.rawValue)). Local changes remain queued.")
        }
    }
}

/// The only submission boundary. A test executor captures operations without running them.
protocol CloudKitSyncOperationExecutor: Sendable {
    func add(_ operation: CKDatabaseOperation, to scope: CKDatabase.Scope)
}

private final class NativeCloudKitOperationExecutor: CloudKitSyncOperationExecutor, @unchecked Sendable {
    private let container: CKContainer
    init(container: CKContainer) { self.container = container }
    func add(_ operation: CKDatabaseOperation, to scope: CKDatabase.Scope) {
        container.database(with: scope).add(operation)
    }
}

/// Admission and add(operation:) are linearized with cancel. No shared queue is canceled.
final class CloudKitSyncOperationGate: @unchecked Sendable {
    private struct Entry { let operation: CKOperation; let completion: @Sendable () -> Void }
    private let lock = NSRecursiveLock()
    private var cancelled = false
    private var entries: [UUID: Entry] = [:]

    func whileActive<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        return try body()
    }
    func checkCancellation() throws { try Task.checkCancellation(); try whileActive {} }
    func registerAndStart(_ operation: CKOperation, id: UUID, start: () -> Void, onCancel: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !cancelled else { lock.unlock(); operation.cancel(); onCancel(); return }
        entries[id] = Entry(operation: operation, completion: onCancel)
        start()
        lock.unlock()
    }
    func finish(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.removeValue(forKey: id) != nil && !cancelled
    }
    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let owned = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        for entry in owned { entry.operation.cancel(); entry.completion() }
    }
}

private final class CloudKitSyncValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func access<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body(&value)
    }
}

private final class CloudKitSyncContinuation<Value: Sendable>: @unchecked Sendable {
    private let storage: CloudKitSyncValue<CheckedContinuation<Value, Error>?>
    init(_ continuation: CheckedContinuation<Value, Error>) { storage = CloudKitSyncValue(continuation) }
    func resume(_ result: Result<Value, Error>) {
        let continuation = storage.access { current in let value = current; current = nil; return value }
        continuation?.resume(with: result)
    }
}

/// Wire coding is separate from operations so schema and opaque metadata are testable offline.
struct CloudKitSyncRecordCodec: Sendable {
    static let cloudRecordType = "FinancesRecord"
    static let domainTypes: Set<String> = ["journal_metadata", "ledger", "commodity", "account", "source", "transaction", "transaction_template", "attachment_asset"]
    let zoneID: CKRecordZone.ID

    func recordID(type: String, id: String) throws -> CKRecord.ID {
        guard Self.domainTypes.contains(type), let uuid = UUID(uuidString: id), uuid.uuidString == id else {
            throw CloudKitSyncError.invalidData("The sync record has an invalid type or identifier.")
        }
        return CKRecord.ID(recordName: "\(type)_\(id)", zoneID: zoneID)
    }
    func identity(_ id: CKRecord.ID) throws -> (String, String) {
        guard id.zoneID == zoneID, let separator = id.recordName.lastIndex(of: "_") else {
            throw CloudKitSyncError.invalidData("The sync record belongs to an unexpected zone.")
        }
        let type = String(id.recordName[..<separator])
        let uuid = String(id.recordName[id.recordName.index(after: separator)...])
        guard try recordID(type: type, id: uuid) == id else { throw CloudKitSyncError.invalidData("Invalid cloud record name.") }
        return (type, uuid)
    }
    static func encodeToken(_ token: CKServerChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }
    static func decodeToken(_ data: Data?) throws -> CKServerChangeToken? {
        guard let data else { return nil }
        guard data.count <= 1_048_576 else { throw CloudKitSyncError.invalidData("The stored CloudKit token is invalid.") }
        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else { throw CloudKitSyncError.invalidData("The stored CloudKit token is invalid.") }
            return token
        } catch { throw CloudKitSyncError.invalidData("The stored CloudKit token cannot be decoded.") }
    }
    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder); coder.finishEncoding()
        return coder.encodedData
    }
    func makeRecord(_ value: CloudKitSyncRecord, stagedAsset: URL?) throws -> CKRecord {
        let id = try recordID(type: value.recordType, id: value.recordID)
        guard ["upsert", "delete"].contains(value.operation) else { throw CloudKitSyncError.invalidData("Unknown sync operation.") }
        let record: CKRecord
        if let data = value.systemFields {
            guard data.count <= 1_048_576 else { throw CloudKitSyncError.invalidData("Stored CloudKit record metadata is invalid.") }
            do {
                let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
                decoder.requiresSecureCoding = true
                decoder.decodingFailurePolicy = .setErrorAndReturn
                guard let decoded = CKRecord(coder: decoder), decoder.error == nil,
                      decoded.recordID == id, decoded.recordType == Self.cloudRecordType else {
                    throw CloudKitSyncError.invalidData("Stored CloudKit record metadata does not match this record.")
                }
                decoder.finishDecoding(); record = decoded
            } catch { throw CloudKitSyncError.invalidData("Stored CloudKit record metadata cannot be decoded.") }
        } else { record = CKRecord(recordType: Self.cloudRecordType, recordID: id) }
        record["schemaVersion"] = NSNumber(value: 1)
        record["domainType"] = value.recordType as CKRecordValue
        record["operation"] = value.operation as CKRecordValue
        record["parentID"] = value.parentRecordID as CKRecordValue?
        record["hash"] = value.contentHash as CKRecordValue?
        record["mutationID"] = value.clientChangeID as CKRecordValue?
        record["payload"] = (value.operation == "delete" ? nil : value.payloadJSON) as CKRecordValue?
        record["asset"] = stagedAsset.map(CKAsset.init(fileURL:))
        record["assetSHA256"] = (stagedAsset == nil ? nil : value.assetSHA256) as CKRecordValue?
        record["assetFilename"] = (stagedAsset == nil ? nil : value.assetFilename) as CKRecordValue?
        record["assetMIMEType"] = (stagedAsset == nil ? nil : value.assetMIMEType) as CKRecordValue?
        return record
    }
    func readRecord(_ record: CKRecord) throws -> CloudKitSyncRecord {
        let (type, id) = try identity(record.recordID)
        guard record.recordType == Self.cloudRecordType,
              (record["schemaVersion"] as? NSNumber)?.intValue == 1,
              record["domainType"] as? String == type,
              let operation = record["operation"] as? String, ["upsert", "delete"].contains(operation) else {
            throw CloudKitSyncError.invalidData("The iCloud record schema is unsupported.")
        }
        return CloudKitSyncRecord(recordType: type, recordID: id, operation: operation,
                                  parentRecordID: record["parentID"] as? String, contentHash: record["hash"] as? String,
                                  payloadJSON: record["payload"] as? String, clientChangeID: record["mutationID"] as? String,
                                  systemFields: Self.encodeSystemFields(record), assetFileURL: (record["asset"] as? CKAsset)?.fileURL,
                                  assetSHA256: record["assetSHA256"] as? String, assetFilename: record["assetFilename"] as? String,
                                  assetMIMEType: record["assetMIMEType"] as? String)
    }
}

final class CloudKitSyncClient: CloudKitSyncTransport, @unchecked Sendable {
    private let configuration: CloudKitSyncConfiguration
    private let executor: any CloudKitSyncOperationExecutor
    private let requestQualityOfService: QualityOfService
    private let gate = CloudKitSyncOperationGate()
    private let stagingDirectory: URL
    private let codec: CloudKitSyncRecordCodec
    private var zoneID: CKRecordZone.ID { codec.zoneID }
    private var subscriptionID: String { "Finances-\(configuration.zoneName)-changes-v1" }

    convenience init(configuration: CloudKitSyncConfiguration, qualityOfService: QualityOfService = .utility) throws {
        if let message = configuration.validationErrorForCurrentApplication() { throw CloudKitSyncError.unavailable(message) }
        self.init(configuration: configuration, executor: NativeCloudKitOperationExecutor(container: CKContainer(identifier: configuration.containerIdentifier)), qualityOfService: qualityOfService)
    }
    /// Internal offline seam: injected executors must not submit operations to CloudKit.
    init(configuration: CloudKitSyncConfiguration, executor: any CloudKitSyncOperationExecutor, temporaryDirectory: URL = FileManager.default.temporaryDirectory, qualityOfService: QualityOfService = .utility) {
        self.configuration = configuration; self.executor = executor
        requestQualityOfService = qualityOfService
        stagingDirectory = temporaryDirectory.appendingPathComponent("FinancesCloudKit-\(UUID().uuidString)", isDirectory: true)
        codec = CloudKitSyncRecordCodec(zoneID: CKRecordZone.ID(zoneName: configuration.zoneName, ownerName: CKCurrentUserDefaultName))
    }
    deinit { cancel() }
    func cancel() {
        gate.cancel()
        try? FileManager.default.removeItem(at: stagingDirectory)
    }
    private func withCancellation<T>(_ body: () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try gate.checkCancellation()
            do { let value = try await body(); try gate.checkCancellation(); return value }
            catch { try gate.checkCancellation(); throw CloudKitSyncError.translate(error) }
        } onCancel: { self.cancel() }
    }
    private func run<T: Sendable>(_ operation: CKDatabaseOperation, scope: CKDatabase.Scope = .private,
                                  configure: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try gate.checkCancellation()
        // Utility requests may be deferred while the app is not in use.
        // Explicit user-facing/QA clients can opt out of discretionary scheduling.
        operation.qualityOfService = requestQualityOfService
        let options = operation.configuration ?? CKOperation.Configuration()
        options.qualityOfService = requestQualityOfService
        options.timeoutIntervalForRequest = 60
        options.timeoutIntervalForResource = 180
        operation.configuration = options
        return try await withCheckedThrowingContinuation { continuation in
            let completion = CloudKitSyncContinuation<T>(continuation)
            let id = UUID(), gate = gate
            configure { result in
                guard gate.finish(id) else { completion.resume(.failure(CancellationError())); return }
                completion.resume(result)
            }
            gate.registerAndStart(operation, id: id, start: { executor.add(operation, to: scope) }, onCancel: {
                completion.resume(.failure(CancellationError()))
            })
        }
    }
    func accountIdentifier() async throws -> String {
        try await withCancellation {
            let operation = CKFetchRecordsOperation.fetchCurrentUserRecordOperation()
            operation.desiredKeys = [] // Only the system record ID is needed for account binding.
            let result = CloudKitSyncValue<Result<String, Error>?>(nil)
            return try await run(operation, scope: .public) { complete in
                operation.perRecordResultBlock = { _, record in result.access { $0 = record.map { $0.recordID.recordName } } }
                operation.fetchRecordsResultBlock = { outcome in
                    complete(outcome.flatMap { result.access { $0 ?? .failure(CloudKitSyncError.accountUnavailable) } })
                }
            }
        }
    }
    func prepareZone() async throws {
        try await withCancellation {
            if try await !zoneExists() {
                try gate.checkCancellation()
                let operation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: zoneID)], recordZoneIDsToDelete: nil)
                try await run(operation) { complete in operation.modifyRecordZonesResultBlock = complete }
            }
            try gate.checkCancellation()
            if try await !subscriptionExists() {
                try gate.checkCancellation()
                let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
                let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true; subscription.notificationInfo = info
                let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
                try await run(operation) { complete in operation.modifySubscriptionsResultBlock = complete }
            }
        }
    }
    private func zoneExists() async throws -> Bool {
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [zoneID])
        let result = CloudKitSyncValue<Result<Bool, Error>?>(nil)
        return try await run(operation) { complete in
            operation.perRecordZoneResultBlock = { _, value in result.access { $0 = Self.existence(value) } }
            operation.fetchRecordZonesResultBlock = { outcome in complete(result.access { $0 } ?? outcome.map { true }) }
        }
    }
    private func subscriptionExists() async throws -> Bool {
        let operation = CKFetchSubscriptionsOperation(subscriptionIDs: [subscriptionID])
        let result = CloudKitSyncValue<Result<Bool, Error>?>(nil)
        return try await run(operation) { complete in
            operation.perSubscriptionResultBlock = { _, value in result.access { $0 = Self.existence(value) } }
            operation.fetchSubscriptionsResultBlock = { outcome in complete(result.access { $0 } ?? outcome.map { true }) }
        }
    }
    private static func existence<T>(_ result: Result<T, Error>) -> Result<Bool, Error> {
        switch result {
        case .success: return .success(true)
        case .failure(let error):
            if let error = error as? CKError, [.unknownItem, .zoneNotFound].contains(error.code) { return .success(false) }
            return .failure(error)
        }
    }
    func fetchRecord(recordType: String, recordID: String) async throws -> CloudKitSyncRecord {
        try await withCancellation {
            let id = try codec.recordID(type: recordType, id: recordID)
            let operation = CKFetchRecordsOperation(recordIDs: [id])
            let result = CloudKitSyncValue<Result<CloudKitSyncRecord, Error>?>(nil)
            return try await run(operation) { complete in
                operation.perRecordResultBlock = { fetchedID, record in
                    do {
                        try self.gate.checkCancellation()
                        guard fetchedID == id else { throw CloudKitSyncError.invalidData("CloudKit returned an unrelated record.") }
                        let value = try self.decodeFetchedRecord(record.get())
                        guard value.recordType == recordType, value.recordID == recordID else { throw CloudKitSyncError.invalidData("CloudKit returned an unrelated record.") }
                        result.access { $0 = .success(value) }
                    } catch { result.access { $0 = .failure(error) } }
                }
                operation.fetchRecordsResultBlock = { outcome in
                    complete(outcome.flatMap { result.access { $0 } ?? .failure(CloudKitSyncError.invalidData("The selected iCloud record is no longer available.")) })
                }
            }
        }
    }
    private func decodeFetchedRecord(_ record: CKRecord) throws -> CloudKitSyncRecord {
        try gate.checkCancellation()
        var value = try codec.readRecord(record)
        if value.recordType == "attachment_asset", value.operation == "upsert" {
            guard let source = value.assetFileURL, let hash = value.assetSHA256 else {
                throw CloudKitSyncError.invalidData("The downloaded receipt is missing its file or checksum.")
            }
            value.assetFileURL = try stageFile(source, expectedHash: hash)
        } else { value.assetFileURL = nil }
        try gate.checkCancellation()
        return value
    }
    func fetchChanges(since: Data?) async throws -> CloudKitSyncPage {
        try await withCancellation {
            let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            options.previousServerChangeToken = try CloudKitSyncRecordCodec.decodeToken(since)
            options.resultsLimit = 200
            let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: options])
            operation.fetchAllChanges = false
            let records = CloudKitSyncValue<[CloudKitSyncRecord]>([])
            let failure = CloudKitSyncValue<Error?>(nil)
            let token = CloudKitSyncValue<(Data?, Bool)?>(nil)
            let page: CloudKitSyncPage = try await run(operation) { complete in
                operation.recordWasChangedBlock = { _, result in
                    do {
                        try self.gate.checkCancellation()
                        let value = try self.decodeFetchedRecord(result.get())
                        try self.gate.whileActive { records.access { $0.append(value) } }
                    } catch { failure.access { if $0 == nil { $0 = error } } }
                }
                operation.recordWithIDWasDeletedBlock = { id, _ in
                    do {
                        let (type, id) = try self.codec.identity(id)
                        try self.gate.whileActive { records.access { $0.append(CloudKitSyncRecord(recordType: type, recordID: id, operation: "delete")) } }
                    } catch { failure.access { if $0 == nil { $0 = error } } }
                }
                operation.recordZoneFetchResultBlock = { _, result in
                    do {
                        let value = try result.get()
                        let data = try CloudKitSyncRecordCodec.encodeToken(value.serverChangeToken)
                        token.access { $0 = (data, value.moreComing) }
                    } catch { failure.access { if $0 == nil { $0 = error } } }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    if let error = failure.access({ $0 }) { complete(.failure(error)); return }
                    complete(result.flatMap { _ in
                        guard let state = token.access({ $0 }) else { return .failure(CloudKitSyncError.invalidData("CloudKit did not return a change token.")) }
                        return .success(CloudKitSyncPage(records: records.access { $0 }, changeToken: state.0, moreComing: state.1))
                    })
                }
            }
            try gate.checkCancellation()
            return page
        }
    }
    func modifyRecords(_ values: [CloudKitSyncRecord]) async throws -> CloudKitSyncModifyResult {
        try await withCancellation {
            guard !values.isEmpty else { return CloudKitSyncModifyResult(saved: [], conflicts: []) }
            guard values.count <= 200, Set(values.map(\.key)).count == values.count else {
                throw CloudKitSyncError.invalidData("Send at most 200 distinct records in one CloudKit batch.")
            }
            var byID: [CKRecord.ID: CloudKitSyncRecord] = [:]
            var records: [CKRecord] = []
            for value in values {
                try gate.checkCancellation()
                var staged: URL?
                if value.recordType == "attachment_asset", value.operation == "upsert" {
                    guard let source = value.assetFileURL, let hash = value.assetSHA256 else {
                        throw CloudKitSyncError.invalidData("The receipt is missing its local file or checksum.")
                    }
                    staged = try stageFile(source, expectedHash: hash)
                }
                let record = try codec.makeRecord(value, stagedAsset: staged)
                byID[record.recordID] = value; records.append(record)
            }
            let submitted = byID
            let output = CloudKitSyncValue(CloudKitSyncModifyResult(saved: [], conflicts: []))
            let failures = CloudKitSyncValue<[Error]>([])
            let handled = CloudKitSyncValue<Set<CKRecord.ID>>([])
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.isAtomic = false
            let result: CloudKitSyncModifyResult = try await run(operation) { complete in
                operation.perRecordSaveBlock = { id, result in
                    do {
                        try self.gate.checkCancellation()
                        guard let input = submitted[id] else { throw CloudKitSyncError.invalidData("CloudKit returned an unexpected saved record.") }
                        _ = handled.access { $0.insert(id) }
                        switch result {
                        case .success(let record):
                            var saved = try self.codec.readRecord(record); saved.assetFileURL = nil
                            guard saved.key == input.key, saved.operation == input.operation,
                                  saved.contentHash == input.contentHash, saved.clientChangeID == input.clientChangeID else {
                                throw CloudKitSyncError.invalidData("CloudKit acknowledged a different record version.")
                            }
                            output.access { $0.saved.append(saved) }
                        case .failure(let error):
                            if let error = error as? CKError, error.code == .serverRecordChanged, let server = error.serverRecord {
                                var conflict = try self.codec.readRecord(server); conflict.assetFileURL = nil
                                guard conflict.key == input.key else { throw CloudKitSyncError.invalidData("CloudKit returned an unrelated conflict.") }
                                output.access { $0.conflicts.append(conflict) }
                            } else { failures.access { $0.append(error) } }
                        }
                    } catch { failures.access { $0.append(error) } }
                }
                operation.modifyRecordsResultBlock = { result in
                    var errors = failures.access { $0 }
                    if case .failure(let error) = result {
                        if (error as? CKError)?.code != .partialFailure || handled.access({ $0.count }) != submitted.count { errors.append(error) }
                    }
                    if handled.access({ $0.count }) != submitted.count && errors.isEmpty {
                        errors.append(CloudKitSyncError.invalidData("CloudKit did not acknowledge every submitted record."))
                    }
                    var value = output.access { $0 }
                    value.retryAfter = errors.compactMap { ($0 as? CKError)?.retryAfterSeconds }.max()
                    value.failureMessage = errors.first.map { CloudKitSyncError.translate($0).localizedDescription }
                    if value.saved.isEmpty, value.conflicts.isEmpty, let first = errors.first { complete(.failure(first)) }
                    else { complete(.success(value)) }
                }
            }
            try gate.checkCancellation()
            return result
        }
    }
    /// Copy in bounded chunks with a stable private filename; never install into journals.
    private func stageFile(_ source: URL, expectedHash: String) throws -> URL {
        let hash = expectedHash.lowercased()
        guard source.isFileURL, hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CloudKitSyncError.invalidData("The receipt checksum or file URL is invalid.")
        }
        let destination = stagingDirectory.appendingPathComponent(UUID().uuidString)
        try gate.whileActive {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CloudKitSyncError.invalidData("The receipt could not be staged.")
            }
        }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        while true {
            try gate.checkCancellation()
            let chunk = try input.read(upToCount: 1_048_576) ?? Data()
            try gate.checkCancellation()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == hash else { throw CloudKitSyncError.invalidData("The receipt checksum did not match its file.") }
        try gate.checkCancellation(); succeeded = true
        return destination
    }
}
