public import Foundation

/// The parts of an OpenRPC document (https://spec.open-rpc.org/) needed
/// for code generation.
public struct OpenRPCDocument: Decodable, Sendable {
    public let openrpc: String
    public let info: Info
    public let methods: [MethodOrReference]
    public let components: Components?

    public struct Info: Decodable, Sendable {
        public let title: String
        public let version: String
        public let description: String?
    }

    public struct Components: Decodable, Sendable {
        public let schemas: [String: JSONSchema]?
        public let contentDescriptors: [String: ContentDescriptor]?
        public let errors: [String: MethodError]?
    }

    /// A failure while loading an OpenRPC document.
    public enum ParseError: Error, CustomStringConvertible, LocalizedError {
        /// The data is not a valid OpenRPC document.
        case invalidDocument(underlying: any Error)
        /// A `$ref` in the document could not be resolved.
        case dereferencing(DereferenceError)

        public var description: String {
            switch self {
            case .invalidDocument(let underlying):
                return "Invalid OpenRPC document: \(String(reflecting: underlying))"
            case .dereferencing(let error):
                return error.description
            }
        }

        public var errorDescription: String? { description }
    }

    /// Loads a document from JSON data, resolving `$ref`s the generator cannot
    /// handle itself (refs inside `methods`, non-component internal pointers,
    /// and external documents) before decoding. `baseURL` is the location of
    /// the document, used to resolve relative external references.
    ///
    /// `$ref`s to local files are always resolved; `$ref`s to remote http(s)
    /// documents are fetched only when `allowsRemoteReferences` is true.
    ///
    /// - Throws: ``ParseError``.
    public static func parse(
        data: Data,
        baseURL: URL? = nil,
        allowsRemoteReferences: Bool = false
    ) throws(ParseError) -> OpenRPCDocument {
        do {
            let raw = try JSONDecoder().decode(JSONValue.self, from: data)
            var dereferencer = DocumentDereferencer(
                baseURL: baseURL,
                allowsRemoteReferences: allowsRemoteReferences
            )
            let dereferenced = try dereferencer.dereference(raw)
            let normalized = try JSONEncoder().encode(dereferenced)
            return try JSONDecoder().decode(OpenRPCDocument.self, from: normalized)
        } catch let error as DereferenceError {
            throw ParseError.dereferencing(error)
        } catch {
            throw ParseError.invalidDocument(underlying: error)
        }
    }
}

/// Either an inline value or a `{"$ref": "..."}` reference.
public enum RefOr<Value: Decodable & Sendable>: Decodable, Sendable {
    case reference(String)
    case value(Value)

    private enum CodingKeys: String, CodingKey {
        case ref = "$ref"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ref = try container.decodeIfPresent(String.self, forKey: .ref) {
            self = .reference(ref)
            return
        }
        self = .value(try Value(from: decoder))
    }
}

public typealias MethodOrReference = RefOr<Method>
public typealias ContentDescriptorOrReference = RefOr<ContentDescriptor>
public typealias MethodErrorOrReference = RefOr<MethodError>

/// An error a method declares it can return.
public struct MethodError: Decodable, Sendable {
    public let code: Int
    public let message: String
}

public struct Method: Decodable, Sendable {
    public let name: String
    public let summary: String?
    public let description: String?
    public let params: [ContentDescriptorOrReference]
    public let result: ContentDescriptorOrReference?
    public let errors: [MethodErrorOrReference]
    /// "by-name" / "by-position" / "either" ("either" when omitted)
    public let paramStructure: String?
    public let deprecated: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, summary, description, params, result, errors, paramStructure, deprecated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        params = try container.decodeIfPresent([ContentDescriptorOrReference].self, forKey: .params) ?? []
        result = try container.decodeIfPresent(ContentDescriptorOrReference.self, forKey: .result)
        errors = try container.decodeIfPresent([MethodErrorOrReference].self, forKey: .errors) ?? []
        paramStructure = try container.decodeIfPresent(String.self, forKey: .paramStructure)
        deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated)
    }
}

public struct ContentDescriptor: Decodable, Sendable {
    public let name: String
    public let summary: String?
    public let description: String?
    public let required: Bool?
    public let schema: JSONSchema
}
