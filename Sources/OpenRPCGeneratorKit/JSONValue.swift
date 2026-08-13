import Foundation

/// An arbitrary JSON value. Used for schema fragments such as `enum` entries,
/// and as the mutable tree the pre-generation `$ref` dereferencer operates on.
/// Integers get their own case so a decode/encode round trip preserves them
/// exactly (no `1` → `1.0` drift, no precision loss for large IDs).
/// Keep in sync with the runtime's JSONValue in RuntimeTemplate.swift.
public enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The value if it is a string, otherwise nil.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The value if it is an integer, otherwise nil.
    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}
