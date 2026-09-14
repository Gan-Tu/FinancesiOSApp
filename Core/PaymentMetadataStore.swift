import CloudKit
import Combine
import CryptoKit
import Foundation

@MainActor final class PaymentMetadataStore: ObservableObject {
    static let shared: PaymentMetadataStore = {
        let sample =
            CommandLine.arguments.contains("--demo")
            || CommandLine.arguments.contains(where: {
                $0 == "--qa-data-directory" || $0.hasPrefix("--qa-data-directory=")
            })
        return sample
            ? PaymentMetadataStore(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "FinancesAssist-Sample-" + UUID().uuidString), network: LocalPaymentMetadataTransport())
            : PaymentMetadataStore()
    }()
    struct Pending: Codable {
        var record: CloudKitSyncRecord
        var base: CloudKitSyncRecord?
    }
    struct Cache: Codable {
        var records: [CloudKitSyncRecord] = []
        var pending: [Pending] = []
    }
    @Published private(set) var metadata: [UUID: PaymentAccountMetadata] = [:]
    @Published private(set) var conflicts: Set<UUID> = []
    @Published private(set) var busy = false
    @Published private(set) var error = ""
    @Published private(set) var scope = ""
    @Published private(set) var pendingCount = 0
    private var cache = Cache()
    private var network: (any CloudKitSyncTransport)?
    private let directory: URL
    private let suppliedNetwork: (any CloudKitSyncTransport)?
    private var generation = UUID()
    private var observation: NSObjectProtocol?
    init(directory: URL? = nil, network: (any CloudKitSyncTransport)? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinancesAssist_v1", isDirectory: true)
        suppliedNetwork = network
        observation = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.disconnect() }
        }
    }
    private func disconnect() {
        generation = UUID()
        network?.cancel()
        network = nil
        metadata = [:]
        conflicts = []
        scope = ""
        cache = Cache()
        pendingCount = 0
        error = ""
    }
    private var cacheURL: URL { directory.appendingPathComponent(scope + ".json") }
    private func same(_ lhs: CloudKitSyncRecord?, _ rhs: CloudKitSyncRecord?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let a), .some(let b)): a.operation == b.operation && a.contentHash == b.contentHash
        default: false
        }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        try publish()
    }
    private func publish() throws {
        var records = Dictionary(uniqueKeysWithValues: cache.records.map { ($0.recordID, $0) })
        for pending in cache.pending { records[pending.record.recordID] = pending.record }
        var result: [UUID: PaymentAccountMetadata] = [:]
        for record in records.values {
            if let value = try PaymentAccountMetadata.decode(record) { result[value.id] = value }
        }
        metadata = result
        pendingCount = cache.pending.count
    }
    private func connect() async throws -> any CloudKitSyncTransport {
        let stamp = generation
        var configuration = CloudKitSyncConfiguration.availableConfiguration()
        configuration?.zoneName = "FinancesAssist_v1"
        if network == nil {
            if let suppliedNetwork {
                network = suppliedNetwork
            } else if let configuration {
                network = try CloudKitSyncClient(configuration: configuration)
            } else {
                throw AssistError.message("Card sync needs a signed app with iCloud enabled.")
            }
        }
        let current = network!
        let identity = try await current.accountIdentifier()
        guard stamp == generation else { throw CancellationError() }
        let key =
            "\(configuration?.containerIdentifier ?? "test"):\(configuration?.environment ?? "test"):\(identity)"
        let nextScope = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        if scope != nextScope {
            scope = nextScope
            cache = Cache()
            metadata = [:]
            conflicts = []
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL))
                try publish()
            }
        }
        return current
    }
    func refreshIfStarted() {
        guard !scope.isEmpty else { return }
        Task { await refresh() }
    }
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let stamp = generation
        do {
            let current = try await connect()
            guard stamp == generation else { throw CancellationError() }
            var remote: [CloudKitSyncRecord] = []
            var token: Data?
            var missing = false
            for pageIndex in 0..<1000 {
                let page: CloudKitSyncPage
                do { page = try await current.fetchChanges(since: token) } catch CloudKitSyncError.zoneDeleted
                    where pageIndex == 0
                {
                    missing = true
                    break
                }
                guard stamp == generation else { throw CancellationError() }
                for record in page.records { _ = try PaymentAccountMetadata.decode(record) }
                remote += page.records
                if !page.moreComing { break }
                guard let next = page.changeToken, next != token, pageIndex < 999 else {
                    throw AssistError.message("Card sync did not finish.")
                }
                token = next
            }
            cache.records = remote
            conflicts = []
            let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.recordID, $0) })
            cache.pending = cache.pending.compactMap { pending in
                let found = remoteByID[pending.record.recordID]
                if same(found, pending.record) { return nil }
                if !same(found, pending.base), let id = UUID(uuidString: pending.record.recordID) {
                    conflicts.insert(id)
                }
                var updated = pending
                if same(found, pending.base) { updated.record.systemFields = found?.systemFields }
                return updated
            }
            try persist()
            let writes = cache.pending.filter { !conflicts.contains(UUID(uuidString: $0.record.recordID)!) }
            if missing && !writes.isEmpty { try await current.prepareZone() }
            for offset in stride(from: 0, to: writes.count, by: 100) {
                let batch = Array(writes[offset..<min(offset + 100, writes.count)]).map(\.record)
                let result = try await current.modifyRecords(batch)
                guard stamp == generation else { throw CancellationError() }
                for record in result.saved {
                    _ = try PaymentAccountMetadata.decode(record)
                    guard
                        batch.contains(where: {
                            $0.recordID == record.recordID && $0.operation == record.operation
                                && $0.contentHash == record.contentHash
                        })
                    else { throw AssistError.message("Unexpected card write acknowledgement.") }
                    cache.records.removeAll { $0.recordID == record.recordID }
                    cache.records.append(record)
                    cache.pending.removeAll {
                        $0.record.recordID == record.recordID && $0.record.contentHash == record.contentHash
                    }
                }
                for record in result.conflicts {
                    _ = try PaymentAccountMetadata.decode(record)
                    cache.records.removeAll { $0.recordID == record.recordID }
                    cache.records.append(record)
                    if let id = UUID(uuidString: record.recordID) { conflicts.insert(id) }
                }
                try persist()
                if let message = result.failureMessage { throw AssistError.message(message) }
                if result.saved.count + result.conflicts.count != batch.count {
                    throw AssistError.message("Some cards are waiting to sync. Retry when online.")
                }
            }
            error = ""
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func save(_ value: PaymentAccountMetadata, expected: PaymentAccountMetadata?) async throws {
        guard !busy, !scope.isEmpty else { throw AssistError.message("Wait for card sync before saving.") }
        guard !conflicts.contains(value.id), metadata[value.id] == expected else {
            throw AssistError.message("Cards changed elsewhere. Reload before saving.")
        }
        if value == expected { return }
        let old = cache.pending.first { $0.record.recordID == value.id.uuidString }
        let previous = cache.records.first { $0.recordID == value.id.uuidString }
        let record = try value.record(previous: previous)
        let before = cache
        cache.pending.removeAll { $0.record.recordID == value.id.uuidString }
        cache.pending.append(Pending(record: record, base: old?.base ?? previous))
        do { try persist() } catch {
            cache = before
            throw error
        }
        await refresh()
    }
    func resolve(_ id: UUID, keepLocal: Bool) async throws {
        guard !busy, conflicts.contains(id) else { return }
        if keepLocal {
            if let index = cache.pending.firstIndex(where: { $0.record.recordID == id.uuidString }) {
                let remote = cache.records.first { $0.recordID == id.uuidString }
                cache.pending[index].base = remote
                cache.pending[index].record.systemFields = remote?.systemFields
            }
        } else {
            cache.pending.removeAll { $0.record.recordID == id.uuidString }
        }
        conflicts.remove(id)
        try persist()
        await refresh()
    }
    func backup() throws -> Data { try JSONEncoder().encode(Array(metadata.values)) }
    func restore(_ data: Data, validAccounts: [Account]) async throws {
        let values = try JSONDecoder().decode([PaymentAccountMetadata].self, from: data)
        guard Set(values.map(\.id)).count == values.count else {
            throw AssistError.message("Duplicate accounts in card backup. Nothing restored.")
        }
        let accounts = Dictionary(uniqueKeysWithValues: validAccounts.map { ($0.id, $0) })
        for value in values {
            try value.validate()
            guard let account = accounts[value.id], account.ledgerID == value.ledgerID,
                [.asset, .liability, .equity].contains(account.kind),
                metadata[value.id] == nil || metadata[value.id] == value
            else {
                throw AssistError.message(
                    "Backup conflicts with existing cards or accounts. Nothing restored.")
            }
        }
        for value in values where metadata[value.id] == nil { try await save(value, expected: nil) }
    }
}

private actor LocalPaymentMetadataTransport: CloudKitSyncTransport {
    private var records: [CloudKitSyncRecord] = []
    func accountIdentifier() async throws -> String { "isolated-sample" }
    func prepareZone() async throws {}
    func fetchChanges(since: Data?) async throws -> CloudKitSyncPage {
        .init(records: records, changeToken: nil, moreComing: false)
    }
    func modifyRecords(_ rows: [CloudKitSyncRecord]) async throws -> CloudKitSyncModifyResult {
        for row in rows {
            records.removeAll { $0.recordID == row.recordID }
            records.append(row)
        }
        return .init(saved: rows, conflicts: [])
    }
    nonisolated func cancel() {}
}
