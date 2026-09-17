import Foundation
import CryptoKit

/// A Sendable JSON boundary; money is always passed as decimal strings.
enum AssistantJSON: Codable, Equatable, Sendable {
    case object([String: AssistantJSON]), array([AssistantJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: AssistantJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([AssistantJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> AssistantJSON { if case .object(let o) = self { o[key] ?? .null } else { .null } }
    var object: [String: AssistantJSON] { if case .object(let v) = self { v } else { [:] } }
    var array: [AssistantJSON] { if case .array(let v) = self { v } else { [] } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var int: Int? { if case .number(let v) = self, v.isFinite, v.rounded() == v, abs(v) < 9_007_199_254_740_992 { Int(v) } else { nil } }
    func required(_ key: String) throws -> String {
        guard let s = self[key].string, !s.isEmpty else { throw AssistantFailure("invalid_arguments", "\(key) must be a nonempty string.") }
        return s
    }
    func uuid(_ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try required(key)) else { throw AssistantFailure("invalid_arguments", "\(key) must be a UUID.") }; return id
    }
    func encoded() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(self) }
    var digest: String { (try? encoded()).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "" }
    static func model<T: Encodable>(_ value: T) throws -> AssistantJSON { try JSONDecoder().decode(AssistantJSON.self, from: JSONEncoder.appEncoder.encode(value)) }
    static func modelDigest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try JSONEncoder.appEncoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func text(_ value: String?) -> AssistantJSON { value.map(AssistantJSON.string) ?? .null }
    func setting(_ key: String, _ value: AssistantJSON) -> AssistantJSON {
        var result = object; result[key] = value; return .object(result)
    }
    static func decimal(_ value: Decimal) -> AssistantJSON { .string(NSDecimalNumber(decimal: value).stringValue) }
    var jsonString: String { String(decoding: (try? encoded()) ?? Data("null".utf8), as: UTF8.self) }
}

struct AssistantFailure: LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}
