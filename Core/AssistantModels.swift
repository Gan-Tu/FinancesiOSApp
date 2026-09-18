import Foundation

enum AssistantTimeContext {
    static let transactionGuidance = "For new transactions (including duplicates and entries from templates), provide a specific ISO 8601 timestamp with hours, minutes and a timezone offset when the intended time is known. Otherwise use date: \"now\"; the iPhone resolves it to its current local time when saving. Never use a date-only YYYY-MM-DD value or invent midnight. For a past date with no known time, ask for the time or explain the use of the current local time. Date-only bounds remain valid for searches and reports."

    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func message(now: Date, timeZone: TimeZone = .current) -> AssistantJSON {
        .object(["type": .string("message"), "role": .string("user"), "text": .string("Current iPhone local time: \(timestamp(now, timeZone: timeZone)). Time zone: \(timeZone.identifier). Refresh this context on each step; older tool results may show an earlier time. \(transactionGuidance)")])
    }
}

struct AssistantModelChoice: Decodable, Sendable, Identifiable {
    var id: String
    var label: String
    var efforts: [String]
}

struct AssistantSettings: Codable, Equatable, Sendable {
    static let models: [AssistantModelChoice] = (try? AssistantContract.load().models) ?? []
    var model = "gpt-5.6-terra"
    var effort = "medium"
    var customInstructions = ""
}

struct AssistantMessage: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var role: String
    var text: String
    var created = Date()
}

struct AssistantToolCall: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
    var operationID = UUID().uuidString
    var approvedDigest: String?
    var result: String?
    var args: AssistantJSON { (try? JSONDecoder().decode(AssistantJSON.self, from: Data(arguments.utf8))) ?? .null }
    var digest: String { AssistantJSON.object(["name": .string(name), "arguments": args]).digest }
    var label: String { name.replacingOccurrences(of: "_", with: " ").capitalized }
}

struct AssistantContext: Codable, Equatable, Sendable {
    var journalID: UUID?
    var accountID: UUID?
    var transactionID: UUID?
}

struct AssistantConversation: Identifiable, Codable, Sendable {
    var id = UUID()
    var title = "New Conversation"
    /// Optional for older on-device history checkpoints.
    var customTitle: Bool?
    var updated = Date()
    /// Separate from edits so reopening an older chat makes it the active chat.
    var lastActiveAt: Date?
    var messages: [AssistantMessage] = []
    var items: [AssistantJSON] = []
    /// Follow-ups are durable before the interrupted worker finishes settling.
    /// Optional so older on-device checkpoints continue to decode.
    var pendingSteering: [AssistantJSON]?
    var calls: [AssistantToolCall] = []
    var activity: [AssistantToolCall] = []
    var context = AssistantContext()
    var paused = false
    var hasPendingInference = false
    var turnSteps = 0
    var settings = AssistantSettings()
    var hasPendingSteering: Bool { !(pendingSteering ?? []).isEmpty }
    var canResume: Bool { paused && (hasPendingInference || !calls.isEmpty || hasPendingSteering) }
}

struct AssistantStepEvent: Decodable, Sendable {
    var type: String
    var text: String?
    var message: String?
    var continuation: String?
    var calls: [AssistantToolCall]?
    var needsFollowUp: Bool?
    var usage: AssistantJSON?
}

extension AssistantToolCall {
    private enum CodingKeys: String, CodingKey { case id, name, arguments, operationID, approvedDigest, result }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        arguments = try c.decode(String.self, forKey: .arguments)
        operationID = try c.decodeIfPresent(String.self, forKey: .operationID) ?? UUID().uuidString
        approvedDigest = try c.decodeIfPresent(String.self, forKey: .approvedDigest)
        result = try c.decodeIfPresent(String.self, forKey: .result)
    }
}

struct AssistantToolDefinition: Decodable, Sendable {
    var name: String
    var description: String
    var inputSchema: AssistantJSON
    var annotations: [String: Bool]
    var needsApproval: Bool { annotations["consequentialHint"] == true }
    var isReadOnly: Bool { annotations["readOnlyHint"] == true }
}

struct AssistantContract: Decodable, Sendable {
    var version: Int
    var tools: [AssistantToolDefinition]
    var models: [AssistantModelChoice]?
    static func load(bundle: Bundle = .main) throws -> AssistantContract {
        guard let url = bundle.url(forResource: "AssistantContract", withExtension: "json") else {
            throw AssistantFailure("missing_contract", "The assistant tools are missing from this build.")
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw AssistantFailure("contract_version", "Update Finances to use this assistant version.") }
        return value
    }

    static func validate(_ value: AssistantJSON, schema: AssistantJSON, path: String = "arguments") throws {
        let types = schema["type"].array.compactMap(\.string) + (schema["type"].string.map { [$0] } ?? [])
        let actual: String
        switch value { case .object: actual = "object"; case .array: actual = "array"; case .string: actual = "string"; case .number: actual = "number"; case .bool: actual = "boolean"; case .null: actual = "null" }
        guard types.isEmpty || types.contains(actual) || (actual == "number" && types.contains("integer") && value.int != nil) else { throw AssistantFailure("invalid_arguments", "\(path) has the wrong type.") }
        if case .array(let choices) = schema["enum"], !choices.contains(value) { throw AssistantFailure("invalid_arguments", "\(path) has an unsupported value.") }
        if case .object(let values) = value {
            let properties = schema["properties"].object
            for required in schema["required"].array.compactMap(\.string) where values[required] == nil { throw AssistantFailure("invalid_arguments", "\(path).\(required) is required.") }
            for (key, child) in values {
                guard let childSchema = properties[key] else {
                    if schema["additionalProperties"].bool == false { throw AssistantFailure("invalid_arguments", "Unknown field \(path).\(key).") }
                    continue
                }
                try validate(child, schema: childSchema, path: path + "." + key)
            }
        }
        if case .array(let values) = value {
            guard values.count >= (schema["minItems"].int ?? 0), values.count <= (schema["maxItems"].int ?? 10000) else { throw AssistantFailure("invalid_arguments", "\(path) has an invalid number of items.") }
            for (index, child) in values.enumerated() { try validate(child, schema: schema["items"], path: "\(path)[\(index)]") }
        }
        if case .string(let text) = value, text.count > (schema["maxLength"].int ?? 1_000_000) { throw AssistantFailure("invalid_arguments", "\(path) is too long.") }
        if case .number(let number) = value {
            if case .number(let min) = schema["minimum"], number < min { throw AssistantFailure("invalid_arguments", "\(path) is below its minimum.") }
            if case .number(let max) = schema["maximum"], number > max { throw AssistantFailure("invalid_arguments", "\(path) exceeds its maximum.") }
        }
    }
}
