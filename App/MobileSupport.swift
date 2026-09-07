import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AppColors {
    static let names = ["gray", "red", "brown", "orange", "yellow", "green", "cyan", "blue", "purple", "pink"]

    static func displayName(_ name: String) -> String {
        switch name {
        case "gray": "Gray"
        case "red": "Red"
        case "brown": "Brown"
        case "orange": "Orange"
        case "yellow": "Yellow"
        case "green": "Green"
        case "cyan": "Turquoise"
        case "blue": "Blue"
        case "purple": "Purple"
        case "pink": "Pink"
        default: name.capitalized
        }
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "red": .red
        case "brown": .brown
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "cyan": .cyan
        case "blue": .blue
        case "purple": .purple
        case "pink": .pink
        default: .gray
        }
    }
}

struct CloudSyncProgress: Equatable {
    enum Phase: Equatable {
        case preparing, downloading, uploading

        var title: String {
            switch self {
            case .preparing: "Syncing..."
            case .downloading: "Downloading..."
            case .uploading: "Uploading..."
            }
        }

        var symbol: String {
            switch self {
            case .preparing: "arrow.triangle.2.circlepath"
            case .downloading: "icloud.and.arrow.down"
            case .uploading: "icloud.and.arrow.up"
            }
        }
    }

    enum State: Equatable {
        case idle
        case running
        case succeeded
        case failed
    }

    var state: State
    var message: String
    var detail: String?
    var fractionCompleted: Double?
    var phase: Phase = .preparing

    var isRunning: Bool { state == .running }

    static let idle = CloudSyncProgress(state: .idle, message: "", detail: nil, fractionCompleted: nil)

    static func running(message: String, detail: String? = nil, fractionCompleted: Double? = nil, phase: Phase = .preparing) -> CloudSyncProgress {
        CloudSyncProgress(
            state: .running,
            message: message,
            detail: detail,
            fractionCompleted: fractionCompleted.map { min(max($0, 0), 1) },
            phase: phase
        )
    }

    static func succeeded(message: String, detail: String? = nil) -> CloudSyncProgress {
        CloudSyncProgress(state: .succeeded, message: message, detail: detail, fractionCompleted: 1)
    }

    static func failed(message: String, detail: String? = nil) -> CloudSyncProgress {
        CloudSyncProgress(state: .failed, message: message, detail: detail, fractionCompleted: nil)
    }
}

extension UTType {
    static let financesMobileBackup = UTType(exportedAs: "dev.gan.FinancesApp.backup", conformingTo: .json)
    static let financesBackupPackage = UTType(filenameExtension: "fin") ?? .package
    static let financesCompressedBackup = UTType(filenameExtension: "zip") ?? .data
    static let bankStatementCSV = UTType(filenameExtension: "csv") ?? .commaSeparatedText
    static let bankStatementTSV = UTType(filenameExtension: "tsv") ?? .tabSeparatedText
    static let ofxStatement = UTType(filenameExtension: "ofx") ?? .data
    static let qfxStatement = UTType(filenameExtension: "qfx") ?? .data
    static let qifStatement = UTType(filenameExtension: "qif") ?? .data
    static let sqliteDatabase = UTType(filenameExtension: "sqlite") ?? .database
    static let dbDatabase = UTType(filenameExtension: "db") ?? .database
}

struct MobileBackupAttachment: Codable, Hashable {
    var storedPath: String
    var originalFilename: String
    var data: Data
}

struct MobileBackupPayload: Codable {
    var formatVersion = 1
    var exportedAt = Date()
    var journalData: JournalData
    var attachments: [MobileBackupAttachment]
}

struct MobileBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.financesMobileBackup, .json]
    }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct AttachmentLocalizationSummary: Equatable {
    var totalAttachments = 0
    var copiedAttachments = 0
    var alreadyLocalAttachments = 0
    var missingAttachments = 0
    var failedAttachments = 0
}

struct OriginalImportResult {
    var ledgerCount: Int
    var commodityCount: Int
    var accountCount: Int
    var transactionCount: Int
    var recurringTransactionCount: Int
    var attachmentSummary: AttachmentLocalizationSummary
}

extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }

    var isZero: Bool {
        self == Decimal.zero
    }
}

extension JSONEncoder {
    static let appEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(AppJSONDateCoding.string(from: date))
        }
        return encoder
    }()
}

extension JSONDecoder {
    static let appDecoder = makeAppDecoder()

    /// Parallel snapshot decoding uses a separate configured decoder per worker.
    static func makeAppDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = AppJSONDateCoding.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(value)")
        }
        return decoder
    }
}

extension Collection where Element == Posting {
    func sortedForDisplay() -> [Posting] {
        sorted {
            if $0.listIndex == $1.listIndex {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.listIndex < $1.listIndex
        }
    }
}

private enum FormatterCache {
    static let lock = NSLock()
    nonisolated(unsafe) static var moneyBySymbol: [String: NumberFormatter] = [:]
    nonisolated(unsafe) static var dateByFormat: [String: DateFormatter] = [:]

    static func moneyString(_ amount: Decimal, symbol: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        let formatter = moneyBySymbol[symbol] ?? {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = symbol
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            moneyBySymbol[symbol] = formatter
            return formatter
        }()
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    static func dateString(_ date: Date, format: AppDateFormat) -> String {
        lock.lock()
        defer { lock.unlock() }

        let key = format.rawValue
        let formatter = dateByFormat[key] ?? {
            let formatter = DateFormatter()
            formatter.timeStyle = .none
            switch format {
            case .medium:
                formatter.dateStyle = .medium
            case .iso:
                formatter.dateFormat = "yyyy-MM-dd"
            }
            dateByFormat[key] = formatter
            return formatter
        }()
        return formatter.string(from: date)
    }
}

func moneyString(_ amount: Decimal, symbol: String = "USD") -> String {
    FormatterCache.moneyString(amount, symbol: symbol)
}

func dateString(_ date: Date, format: AppDateFormat) -> String {
    FormatterCache.dateString(date, format: format)
}

func decimalFromInput(_ value: String) -> Decimal? {
    AmountExpressionEvaluator.evaluate(value)
}

func decimalInputString(_ amount: Decimal) -> String {
    let text = NSDecimalNumber(decimal: amount).stringValue
    if !text.contains(".") { return text + ".00" }
    return text
}
