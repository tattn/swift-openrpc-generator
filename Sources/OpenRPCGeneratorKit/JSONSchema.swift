import Foundation

/// JSON Schema (the subset used by OpenRPC).
public indirect enum JSONSchema: Decodable, Sendable {
    /// A `true` / `false` boolean schema.
    case boolean(Bool)
    /// A `{"$ref": "..."}` reference.
    case reference(String)
    /// A regular schema object.
    case object(SchemaObject)

    private enum CodingKeys: String, CodingKey {
        case ref = "$ref"
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
            let boolValue = try? single.decode(Bool.self)
        {
            self = .boolean(boolValue)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ref = try container.decodeIfPresent(String.self, forKey: .ref) {
            self = .reference(ref)
            return
        }
        self = .object(try SchemaObject(from: decoder))
    }
}

/// The object form of a JSON Schema. Only the keys needed for code
/// generation are handled.
public struct SchemaObject: Decodable, Sendable {
    /// `type` normalized to an array (`"string"` → `["string"]`).
    public var types: [String]
    public var title: String?
    public var description: String?
    public var format: String?
    public var properties: [String: JSONSchema]
    public var required: [String]
    public var items: JSONSchema?
    public var additionalProperties: JSONSchema?
    public var enumValues: [JSONValue]
    public var oneOf: [JSONSchema]
    public var anyOf: [JSONSchema]
    public var allOf: [JSONSchema]
    /// Also supports the OpenAPI-style `nullable: true`.
    public var nullable: Bool

    private enum CodingKeys: String, CodingKey {
        case type, title, description, format, properties, required
        case items, additionalProperties, nullable
        case enumValues = "enum"
        case oneOf, anyOf, allOf
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let single = try? container.decode(String.self, forKey: .type) {
            types = [single]
        } else if let multiple = try? container.decode([String].self, forKey: .type) {
            types = multiple
        } else {
            types = []
        }
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        properties = (try? container.decodeIfPresent([String: JSONSchema].self, forKey: .properties)) ?? [:]
        required = (try? container.decodeIfPresent([String].self, forKey: .required)) ?? []
        // Array-form items (tuple validation) is unsupported and becomes nil.
        items = try? container.decodeIfPresent(JSONSchema.self, forKey: .items)
        additionalProperties = try? container.decodeIfPresent(JSONSchema.self, forKey: .additionalProperties)
        enumValues = (try? container.decodeIfPresent([JSONValue].self, forKey: .enumValues)) ?? []
        oneOf = (try? container.decodeIfPresent([JSONSchema].self, forKey: .oneOf)) ?? []
        anyOf = (try? container.decodeIfPresent([JSONSchema].self, forKey: .anyOf)) ?? []
        allOf = (try? container.decodeIfPresent([JSONSchema].self, forKey: .allOf)) ?? []
        nullable = (try? container.decodeIfPresent(Bool.self, forKey: .nullable)) ?? false
    }
}
