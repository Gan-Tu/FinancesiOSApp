import Foundation

enum SystemIntegrationStorage {
    static var directory: URL {
        #if DEBUG
        if CommandLine.arguments.contains("--demo") {
            return URL.applicationSupportDirectory.appending(path: "FinancesSystemIntegrationDemo", directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "FinancesSystemIntegration", directoryHint: .isDirectory)
    }
}

/// Pending captures are intentionally separate from posted ledger entries.
struct CaptureSuggestion: Identifiable, Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case applePay, shortcut }
    var id = UUID()
    var source: Source
    var date: Date
    var amount: Decimal?
    var currencyCode: String
    var merchant: String
    var card: String
    var note: String
    var journalID: UUID?

    func validated() throws -> Self {
        guard amount.map({ !$0.isNaN && $0 > 0 }) ?? true else {
            throw ValidationError(message: "Enter a positive purchase amount.")
        }
        var result = self
        result.currencyCode = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard amount == nil || !result.currencyCode.isEmpty else {
            throw ValidationError(message: "A purchase amount needs its currency code.")
        }
        guard result.currencyCode.isEmpty || (result.currencyCode.count >= 3 && result.currencyCode.count <= 8
            && result.currencyCode.allSatisfy({ $0.isASCII && $0.isLetter })) else {
            throw ValidationError(message: "Use a currency code such as USD or EUR.")
        }
        guard merchant.count <= 1_000, card.count <= 1_000, note.count <= 10_000 else {
            throw ValidationError(message: "The captured text is too long.")
        }
        result.merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}

actor CaptureSuggestionRepository {
    static let shared = CaptureSuggestionRepository(directory: SystemIntegrationStorage.directory
        .appending(path: "Suggestions", directoryHint: .isDirectory))
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func add(_ suggestion: CaptureSuggestion) throws {
        let value = try suggestion.validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(value.id.uuidString + ".json")
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func all() throws -> [CaptureSuggestion] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        return try files.filter { $0.pathExtension == "json" }.map { url in
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 100_000 else {
                throw ValidationError(message: "A saved suggestion could not be read.")
            }
            let value = try JSONDecoder().decode(CaptureSuggestion.self, from: Data(contentsOf: url)).validated()
            guard url.deletingPathExtension().lastPathComponent == value.id.uuidString else {
                throw ValidationError(message: "A saved suggestion has an invalid identity.")
            }
            return value
        }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }

    func remove(_ id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

struct SystemIntegrationCatalog: Codable, Equatable, Sendable {
    struct Journal: Codable, Equatable, Sendable, Identifiable { var id: UUID; var name: String }
    struct Template: Codable, Equatable, Sendable, Identifiable { var id: UUID; var journalID: UUID; var name: String; var journalName: String }
    var journals: [Journal] = []
    var templates: [Template] = []
}

actor SystemIntegrationCatalogRepository {
    static let shared = SystemIntegrationCatalogRepository(url: SystemIntegrationStorage.directory.appendingPathComponent("Catalog.json"))
    let url: URL
    init(url: URL) { self.url = url }
    func save(_ catalog: SystemIntegrationCatalog) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func load() throws -> SystemIntegrationCatalog {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(SystemIntegrationCatalog.self, from: Data(contentsOf: url))
    }
}
