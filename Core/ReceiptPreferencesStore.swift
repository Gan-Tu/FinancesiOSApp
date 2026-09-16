import CloudKit
import Combine
import CryptoKit
import Foundation

struct ReceiptPreferences: Codable, Equatable, Sendable {
    static let zone = "FinancesPreferences_v1"
    static let domain = "receipt_preferences"
    static let recordID = "00000000-0000-0000-0000-000000000001"
    var id = Self.recordID
    var version = 1
    var model = "gpt-5.6-terra"
    var effort = "medium"
    var instructions = ""

    init() {}
    init(_ settings: ReceiptAISettings) {
        model = settings.model; effort = settings.effort; instructions = settings.instructions
    }
    func validate() throws {
        let efforts = (model == "gpt-6-astra" ? [] : ["none"]) + ["low", "medium", "high", "xhigh", "max"]
        guard id == Self.recordID, version == 1, ReceiptAISettings.models.contains(model),
              efforts.contains(effort), instructions.utf8.count <= 100_000 else {
            throw AssistError.message("Invalid receipt AI settings.")
        }
    }
    static func decode(_ record: CloudKitSyncRecord?) throws -> Self {
        guard let record else { return Self() }
        guard record.recordType == domain, record.recordID == recordID,
              record.operation == "upsert", let raw = record.payloadJSON,
              raw.utf8.count <= 200_000,
              SHA256.hash(data: Data(raw.utf8)).map({ String(format: "%02x", $0) }).joined() == record.contentHash else {
            throw AssistError.message("Receipt AI settings integrity check failed.")
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(raw.utf8))
        try value.validate()
        return value
    }
    func record(previous: CloudKitSyncRecord?) throws -> CloudKitSyncRecord {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return CloudKitSyncRecord(recordType: Self.domain, recordID: Self.recordID,
            contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            payloadJSON: String(decoding: data, as: UTF8.self), clientChangeID: UUID().uuidString,
            systemFields: previous?.systemFields)
    }
    static func merge(base: Self, local: Self, remote: Self) -> (value: Self, conflicts: [String]) {
        var value = remote
        var conflicts: [String] = []
        let localPairChanged = local.model != base.model || local.effort != base.effort
        let remotePairChanged = remote.model != base.model || remote.effort != base.effort
        if localPairChanged {
            if remotePairChanged && (local.model != remote.model || local.effort != remote.effort) {
                conflicts.append("Model and reasoning effort")
            }
            value.model = local.model; value.effort = local.effort
        }
        if local.instructions != base.instructions {
            if remote.instructions != base.instructions && local.instructions != remote.instructions {
                conflicts.append("Custom instructions")
            }
            value.instructions = local.instructions
        }
        return (value, conflicts)
    }
}

/// Preferences use their own account-scoped outbox and zone. Journal snapshots and
/// old clients cannot overwrite them. Model/effort form one atomic merge field.
@MainActor final class ReceiptPreferencesStore: ObservableObject {
    static let shared = ReceiptPreferencesStore()
    struct Pending: Codable { var value: ReceiptPreferences; var base: CloudKitSyncRecord? }
    struct Cache: Codable {
        var remote: CloudKitSyncRecord?
        var pending: Pending?
        var loaded = false
        var conflicts: [String] = []
    }
    @Published private(set) var value = ReceiptPreferences()
    @Published private(set) var remote = ReceiptPreferences()
    @Published private(set) var conflicts: [String] = []
    @Published private(set) var pending = false
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var error = ""
    private(set) var scope = ""
    private var cache = Cache()
    private var generation = UUID()
    private var network: (any CloudKitSyncTransport)?
    private let suppliedNetwork: (any CloudKitSyncTransport)?
    private let directory: URL
    private let defaults: UserDefaults
    private var observation: NSObjectProtocol?
    private var scheduled: Task<Void, Never>?
    private var refreshAgain = false

    init(directory: URL? = nil, network: (any CloudKitSyncTransport)? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinancesPreferences_v1", isDirectory: true)
        suppliedNetwork = network
        self.defaults = defaults
        observation = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.disconnect()
                await self?.refresh()
            }
        }
    }
    var settings: ReceiptAISettings {
        var result = ReceiptAISettings.load()
        result.model = value.model; result.effort = value.effort; result.instructions = value.instructions
        return result
    }
    func disconnect() {
        generation = UUID(); network?.cancel(); network = nil
        scheduled?.cancel(); scheduled = nil
        scope = ""; cache = Cache(); value = ReceiptPreferences(); remote = ReceiptPreferences()
        conflicts = []; pending = false; ready = false; error = ""
    }
    private var cacheURL: URL { directory.appendingPathComponent(scope + ".json") }
    private func publish() throws {
        remote = try ReceiptPreferences.decode(cache.remote)
        value = cache.pending?.value ?? remote
        conflicts = cache.conflicts; pending = cache.pending != nil; ready = cache.loaded
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        try publish()
    }
    private func connect() async throws -> any CloudKitSyncTransport {
        let stamp = generation
        var configuration = CloudKitSyncConfiguration.availableConfiguration()
        configuration?.zoneName = ReceiptPreferences.zone
        if network == nil {
            if let suppliedNetwork { network = suppliedNetwork }
            else if CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains(where: { $0.hasPrefix("--qa-data-directory") }) {
                throw AssistError.message("Receipt settings stay offline in sample mode.")
            } else if let configuration { network = try CloudKitSyncClient(configuration: configuration) }
            else { throw AssistError.message("Receipt settings sync needs a signed app with iCloud enabled.") }
        }
        let current = network!
        let identity = try await current.accountIdentifier()
        guard stamp == generation else { throw CancellationError() }
        let key = "\(configuration?.containerIdentifier ?? "test"):\(configuration?.environment ?? "test"):\(identity)"
        let next = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        if scope != next {
            scope = next; cache = Cache()
            value = ReceiptPreferences(); remote = ReceiptPreferences()
            conflicts = []; pending = false; ready = false; error = ""
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL))
                try cache.pending?.value.validate()
            }
            try publish()
        }
        return current
    }
    /// Saves the local outbox before scheduling network work. Edits during an
    /// in-flight save retain their own pending value until separately acknowledged.
    func edit(_ settings: ReceiptAISettings, expected: ReceiptPreferences) throws {
        let next = ReceiptPreferences(settings)
        try next.validate()
        guard !scope.isEmpty, ready else { throw AssistError.message("Connect to iCloud once before editing receipt settings.") }
        guard conflicts.isEmpty else { throw AssistError.message("Resolve the receipt AI settings conflict first.") }
        let merged = ReceiptPreferences.merge(base: expected, local: next, remote: value)
        guard merged.conflicts.isEmpty else { throw AssistError.message("Receipt settings changed. Review the latest values.") }
        if merged.value == value { return }
        let before = cache
        let base = cache.pending.map { $0.base } ?? cache.remote
        cache.pending = Pending(value: merged.value, base: base)
        do { try persist() } catch { cache = before; throw error }
        scheduleRefresh()
    }
    private func scheduleRefresh() {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.refresh()
        }
    }
    func resolve(keepLocal: Bool, expectedLocal: ReceiptPreferences, expectedRemote: ReceiptPreferences) throws {
        guard value == expectedLocal, remote == expectedRemote, let pending = cache.pending, !conflicts.isEmpty else {
            throw AssistError.message("The conflict changed. Review it again.")
        }
        var merged = ReceiptPreferences.merge(base: try ReceiptPreferences.decode(pending.base), local: pending.value, remote: remote)
        if !keepLocal {
            if merged.conflicts.contains("Model and reasoning effort") { merged.value.model = remote.model; merged.value.effort = remote.effort }
            if merged.conflicts.contains("Custom instructions") { merged.value.instructions = remote.instructions }
        }
        let before = cache
        cache.pending = Pending(value: merged.value, base: cache.remote); cache.conflicts = []
        do { try persist() } catch { cache = before; throw error }
        scheduleRefresh()
    }
    func refresh() async {
        guard !busy else { refreshAgain = true; return }
        busy = true
        defer {
            busy = false
            if refreshAgain { refreshAgain = false; scheduleRefresh() }
        }
        let stamp = generation
        do {
            let current = try await connect()
            for _ in 0..<3 {
                guard stamp == generation else { throw CancellationError() }
                var fetched: CloudKitSyncRecord?
                var token: Data?
                var missing = false
                for index in 0..<1000 {
                    let page: CloudKitSyncPage
                    do { page = try await current.fetchChanges(since: token) }
                    catch CloudKitSyncError.zoneDeleted where index == 0 { missing = true; break }
                    guard stamp == generation else { throw CancellationError() }
                    for record in page.records { _ = try ReceiptPreferences.decode(record); fetched = record }
                    if !page.moreComing { break }
                    guard let next = page.changeToken, next != token, index < 999 else { throw AssistError.message("Receipt settings download did not finish.") }
                    token = next
                }
                let remoteValue = try ReceiptPreferences.decode(fetched)
                // Legacy local settings may seed one account, only if it has no
                // remote record. A later iCloud account never inherits those values.
                if !cache.loaded, cache.pending == nil, fetched == nil, defaults.string(forKey: "receipt-ai-migration-account-v1") == nil {
                    if let data = defaults.data(forKey: "receipt-ai-settings-v1"), let legacy = try? JSONDecoder().decode(ReceiptAISettings.self, from: data) {
                        let value = ReceiptPreferences(legacy)
                        try value.validate()
                        cache.pending = Pending(value: value, base: nil)
                    }
                }
                cache.remote = fetched; cache.loaded = true; cache.conflicts = []
                if let pending = cache.pending {
                    let merged = ReceiptPreferences.merge(base: try ReceiptPreferences.decode(pending.base), local: pending.value, remote: remoteValue)
                    if !merged.conflicts.isEmpty { cache.conflicts = merged.conflicts }
                    else { cache.pending = merged.value == remoteValue ? nil : Pending(value: merged.value, base: fetched) }
                }
                try persist()
                if defaults.string(forKey: "receipt-ai-migration-account-v1") == nil { defaults.set(scope, forKey: "receipt-ai-migration-account-v1") }
                guard cache.conflicts.isEmpty, let pending = cache.pending else { error = ""; return }
                if missing { try await current.prepareZone() }
                guard stamp == generation else { throw CancellationError() }
                let write = try pending.value.record(previous: cache.remote)
                let result = try await current.modifyRecords([write])
                guard stamp == generation else { throw CancellationError() }
                if !result.conflicts.isEmpty { continue }
                guard result.saved.count == 1, let ack = result.saved.first,
                      try ReceiptPreferences.decode(ack) == pending.value,
                      ack.clientChangeID == write.clientChangeID else {
                    throw AssistError.message(result.failureMessage ?? "iCloud did not acknowledge receipt settings. Changes remain saved locally.")
                }
                cache.remote = ack
                if cache.pending?.value == pending.value { cache.pending = nil }
                else { cache.pending?.base = ack }
                try persist()
                if let message = result.failureMessage { throw AssistError.message(message) }
                if cache.pending == nil { error = ""; return }
            }
            throw AssistError.message("Receipt settings changed again in iCloud. Refresh to retry.")
        } catch is CancellationError {} catch {
            if stamp == generation { self.error = error.localizedDescription }
        }
    }
}
