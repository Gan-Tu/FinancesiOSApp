import Foundation

/// A choice is tied to the exact versions the person reviewed.
struct CloudKitConflictResolution: Equatable, Sendable {
    let conflict: CloudKitSyncConflict
    let keepLocal: Bool
}

struct CloudKitConflictField: Identifiable, Equatable {
    let id: String
    let label: String
    let local: String
    let remote: String
    let changed: Bool
}

enum CloudKitConflictComparison {
    private struct Value { let label: String; let raw: String; let display: String }

    private indirect enum JSONValue: Decodable {
        case object([String: JSONValue]), array([JSONValue]), scalar(raw: String, display: String)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .scalar(raw: "null", display: "None") }
            else if let bool = try? value.decode(Bool.self) { self = .scalar(raw: String(bool), display: bool ? "Yes" : "No") }
            else if let text = try? value.decode(String.self) { self = .scalar(raw: text, display: text.isEmpty ? "—" : text) }
            else if let number = try? value.decode(Decimal.self) {
                let exact = NSDecimalNumber(decimal: number).stringValue
                self = .scalar(raw: exact, display: exact)
            } else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
            else { self = .array(try value.decode([JSONValue].self)) }
        }
    }


    static func title(_ record: CloudKitSyncRecord) -> String {
        guard let bytes = record.payloadJSON?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            return label(record.recordType)
        }
        return (object["payee"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (object["name"] as? String) ?? (object["originalFilename"] as? String) ?? label(record.recordType)
    }

    static func context(_ record: CloudKitSyncRecord, data: JournalData) -> String {
        guard record.recordType == "transaction", let bytes = record.payloadJSON?.data(using: .utf8),
              let transaction = try? JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: bytes) else { return "" }
        return [transaction.date.formatted(date: .abbreviated, time: .omitted),
                data.ledgers.first { $0.id == transaction.ledgerID }?.name ?? "",
                transaction.note].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func fields(_ conflict: CloudKitSyncConflict, data: JournalData) -> [CloudKitConflictField] {
        let left = values(conflict.local, data: data), right = values(conflict.remote, data: data)
        return Set(left.keys).union(right.keys).sorted().map { key in
            let a = left[key], b = right[key]
            let changed = a?.raw != b?.raw
            let sameDisplay = changed && a?.display == b?.display
            return CloudKitConflictField(id: key, label: a?.label ?? b?.label ?? key,
                local: sameDisplay ? "\(a?.display ?? "—") (\(a?.raw ?? "absent"))" : a?.display ?? "—",
                remote: sameDisplay ? "\(b?.display ?? "—") (\(b?.raw ?? "absent"))" : b?.display ?? "—", changed: changed)
        }
    }

    private static func values(_ record: CloudKitSyncRecord, data: JournalData) -> [String: Value] {
        var result: [String: Value] = ["!status": .init(label: "Status", raw: record.operation, display: record.operation == "delete" ? "Deleted" : "Present")]
        guard record.operation != "delete" else { return result }
        guard let bytes = record.payloadJSON?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: bytes), case .object(let object) = decoded else {
            result["payload"] = .init(label: "Stored data", raw: record.payloadJSON ?? "", display: record.payloadJSON ?? "Unavailable")
            return result
        }
        func visit(_ value: JSONValue, path: String, name: String, key: String) {
            switch value {
            case .object(let object):
                if object.isEmpty { result[path] = .init(label: name, raw: "{}", display: "None") }
                for child in object.keys.sorted() {
                    visit(object[child]!, path: path + "." + child, name: name.isEmpty ? label(child) : name + " · " + label(child), key: child)
                }
            case .array(let array):
                if array.isEmpty { result[path] = .init(label: name, raw: "[]", display: "None") }
                for (index, child) in array.enumerated() {
                    visit(child, path: path + ".\(index)", name: name + " \(index + 1)", key: key)
                }
            case .scalar(let raw, var display):
                if key == "kind", let value = Int(raw), let kind = AccountKind(rawValue: value) { display = kind.title }
                if key == "frequency", let frequency = RecurrenceFrequency(rawValue: raw) { display = frequency.title }
                if let id = UUID(uuidString: raw) {
                    if key == "accountID" || key == "parentID" { display = accountName(id, data: data) ?? raw }
                    else if key == "commodityID" { display = data.commodities.first { $0.id == id }?.symbol ?? raw }
                    else if key == "ledgerID" { display = data.ledgers.first { $0.id == id }?.name ?? raw }
                }
                if key.lowercased().contains("date"), let date = ISO8601DateFormatter().date(from: raw) {
                    display = date.formatted(date: .abbreviated, time: .shortened)
                }
                result[path] = .init(label: name, raw: raw, display: display)
            }
        }
        for key in object.keys.sorted() { visit(object[key]!, path: key, name: label(key), key: key) }
        // File contents may differ while their display filename and metadata match.
        if record.recordType == "attachment_asset" {
            result["!contents"] = .init(label: "Receipt checksum", raw: record.assetSHA256 ?? "", display: record.assetSHA256 ?? "Unavailable")
            result["!filename"] = .init(label: "Receipt filename", raw: record.assetFilename ?? "", display: record.assetFilename ?? "—")
            result["!mime"] = .init(label: "Receipt type", raw: record.assetMIMEType ?? "", display: record.assetMIMEType ?? "—")
        }
        result["!parent"] = .init(label: "Parent record", raw: record.parentRecordID ?? "", display: record.parentRecordID ?? "None")
        return result
    }

    private static func accountName(_ id: UUID, data: JournalData) -> String? {
        var names: [String] = [], current: UUID? = id, visited = Set<UUID>()
        while let id = current, visited.insert(id).inserted, let account = data.accounts.first(where: { $0.id == id }) {
            names.insert(account.name, at: 0); current = account.parentID
        }
        return names.isEmpty ? nil : names.joined(separator: " / ")
    }

    private static func label(_ key: String) -> String {
        let names = ["postings": "Split", "accountID": "Account", "commodityID": "Currency", "ledgerID": "Journal", "parentID": "Parent account", "id": "Record ID", "recurrenceRule": "Recurrence", "attachment": "Receipts", "assets": "File", "storedPath": "File path", "originalFilename": "Filename", "sizeBytes": "Size in bytes", "mimeType": "File type", "listIndex": "Order", "sourceID": "Source", "kind": "Type", "externalTransactionID": "External transaction ID"]
        if let name = names[key] { return name }
        return key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).replacingOccurrences(of: "_", with: " ").capitalized
    }
}
