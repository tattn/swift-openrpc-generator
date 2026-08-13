import Foundation
import Testing

@testable import OpenRPCGeneratorKit

@Suite struct GeneratorTests {
    private func generate(
        _ json: String,
        options: GeneratorOptions = GeneratorOptions()
    ) throws -> GeneratorOutput {
        let document = try OpenRPCDocument.parse(data: Data(json.utf8))
        return OpenRPCSwiftGenerator(document: document, options: options).generate()
    }

    private func file(_ output: GeneratorOutput, _ name: String) throws -> String {
        try #require(output.files.first { $0.name == name }).contents
    }

    @Test("The Petstore example generates the expected code")
    func petstoreExample() throws {
        let document = try parseExampleDocument("petstore")
        let output = OpenRPCSwiftGenerator(document: document).generate()

        #expect(output.warnings.isEmpty)
        #expect(
            output.files.map(\.name).sorted()
                == ["JSONRPCRuntime.swift", "PetstoreClient.swift", "PetstoreModels.swift", "PetstoreServer.swift"]
        )

        let models = try file(output, "PetstoreModels.swift")
        #expect(models.contains("public struct Pet: Codable, Hashable, Sendable {"))
        #expect(models.contains("public var id: Int"))
        #expect(models.contains("public var tag: String?"))
        #expect(models.contains("public var status: PetStatus?"))
        #expect(models.contains("public enum PetStatus: String, Codable, CaseIterable, Sendable {"))
        #expect(models.contains("case soldOut = \"sold-out\""))
        #expect(models.contains("public typealias Pets = [Pet]"))
        #expect(models.contains("public enum PetSize: Int, Codable, CaseIterable, Sendable {"))
        // Pet is recursive (parent), so the union referencing it is indirect.
        #expect(models.contains("public indirect enum SearchResult: Codable, Hashable, Sendable {"))
        #expect(models.contains("    case pet(Pet)"))
        #expect(models.contains("    case pets(Pets)"))
        #expect(models.contains("private var _parent: Indirect<Pet>?"))

        let client = try file(output, "PetstoreClient.swift")
        #expect(client.contains("public protocol PetstoreClientProtocol: Sendable {"))
        #expect(client.contains("public struct PetstoreClient: PetstoreClientProtocol {"))
        #expect(client.contains("public func listPets(limit: Int? = nil) async throws -> Pets {"))
        #expect(
            client.contains(
                "public func createPet(newPetName: String, newPetTag: String? = nil) async throws -> Pet {"))
        // by-position methods encode params as an array
        #expect(client.contains("public func getPet(petId: Int) async throws -> Pet {"))
        #expect(client.contains("let params: [AnyJSONRPCParam] = [AnyJSONRPCParam(petId)]"))
        // methods without a result are sent as JSON-RPC notifications
        #expect(client.contains("public func deletePet(petId: Int) async throws {"))
        #expect(client.contains("try await rpc.notify(method: \"delete_pet\", params: params)"))
    }

    @Test("Inline objects and enums are synthesized with derived names")
    func inlineObjectAndEnumSynthesis() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Inline", "version": "0.1.0" },
              "methods": [
                {
                  "name": "get_state",
                  "params": [],
                  "result": {
                    "name": "state",
                    "schema": {
                      "type": "object",
                      "required": ["mode"],
                      "properties": {
                        "mode": { "type": "string", "enum": ["on", "off"] },
                        "count": { "type": "integer" }
                      }
                    }
                  }
                }
              ]
            }
            """)
        let models = try file(output, "InlineModels.swift")
        #expect(models.contains("public struct GetStateResult: Codable, Hashable, Sendable {"))
        #expect(models.contains("public enum GetStateResultMode: String, Codable, CaseIterable, Sendable {"))
        #expect(models.contains("public var mode: GetStateResultMode"))
        #expect(models.contains("public var count: Int?"))

        let client = try file(output, "InlineClient.swift")
        #expect(client.contains("public func getState() async throws -> GetStateResult {"))
        #expect(client.contains("return try await rpc.call(method: \"get_state\")"))
    }

    @Test("The internal access level omits the public modifier")
    func accessLevelInternal() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Minimal", "version": "0.1.0" },
              "methods": [
                { "name": "ping", "params": [] }
              ]
            }
            """,
            options: GeneratorOptions(accessLevel: .internal)
        )
        let client = try file(output, "MinimalClient.swift")
        #expect(client.contains("struct MinimalClient: MinimalClientProtocol {"))
        #expect(!client.contains("public "))
        #expect(client.contains("func ping() async throws {"))
    }

    @Test("The client type name can be overridden")
    func clientNameOverride() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Some API", "version": "0.1.0" },
              "methods": [
                { "name": "ping", "params": [] }
              ]
            }
            """,
            options: GeneratorOptions(clientName: "MyClient")
        )
        #expect(output.files.contains { $0.name == "MyClient.swift" })
        let client = try file(output, "MyClient.swift")
        #expect(client.contains("public struct MyClient: MyClientProtocol {"))
    }

    @Test("The generated server dispatches methods and accepts both param forms")
    func serverGeneration() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Petstore", "version": "0.1.0" },
              "methods": [
                {
                  "name": "get_pet",
                  "params": [
                    { "name": "petId", "required": true, "schema": { "type": "integer" } },
                    { "name": "verbose", "schema": { "type": "boolean" } }
                  ],
                  "result": { "name": "name", "schema": { "type": "string" } }
                },
                { "name": "reset", "params": [] }
              ]
            }
            """)
        let server = try file(output, "PetstoreServer.swift")
        #expect(server.contains("public protocol PetstoreHandler: Sendable {"))
        #expect(server.contains("    @concurrent func getPet(petId: Int, verbose: Bool?) async throws -> String"))
        #expect(server.contains("        case \"get_pet\":"))
        // Required params throw -32602 when missing; optionals default to nil.
        #expect(
            server.contains(
                "let result = try await handler.getPet(petId: try params.required(\"petId\", at: 0), verbose: try params.optional(\"verbose\", at: 1))"
            ))
        #expect(server.contains("return try JSONRPCServer.resultResponse(id: request.id, result: result)"))
        // Methods without a result respond with a null result (or nothing for notifications).
        #expect(server.contains("    try await handler.reset()"))
        #expect(server.contains("    return try JSONRPCServer.resultResponse(id: request.id)"))
        #expect(server.contains("throw JSONRPCErrorObject.methodNotFound(method: request.method)"))
    }

    @Test("Component selection limits the generated files")
    func componentSelection() throws {
        let json = """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Minimal", "version": "0.1.0" },
              "methods": [
                { "name": "ping", "params": [] }
              ]
            }
            """
        let clientOnly = try generate(json, options: GeneratorOptions(components: [.client]))
        #expect(
            clientOnly.files.map(\.name).sorted()
                == ["JSONRPCRuntime.swift", "MinimalClient.swift", "MinimalModels.swift"]
        )
        let serverOnly = try generate(json, options: GeneratorOptions(components: [.server]))
        #expect(
            serverOnly.files.map(\.name).sorted()
                == ["JSONRPCRuntime.swift", "MinimalModels.swift", "MinimalServer.swift"]
        )
    }

    @Test("Well-known string formats map to Foundation types")
    func stringFormatMapping() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Formats", "version": "0.1.0" },
              "methods": [
                {
                  "name": "get_document",
                  "params": [
                    { "name": "since", "schema": { "type": "string", "format": "date-time" } }
                  ],
                  "result": {
                    "name": "document",
                    "schema": {
                      "type": "object",
                      "required": ["id", "createdAt"],
                      "properties": {
                        "id": { "type": "string", "format": "uuid" },
                        "createdAt": { "type": "string", "format": "date-time" },
                        "payload": { "type": "string", "format": "byte" },
                        "link": { "type": "string", "format": "uri" },
                        "note": { "type": "string", "format": "unknown-format" }
                      }
                    }
                  }
                }
              ]
            }
            """)
        #expect(output.warnings.isEmpty)
        let models = try file(output, "FormatsModels.swift")
        #expect(models.contains("public var id: UUID"))
        #expect(models.contains("public var createdAt: Date"))
        #expect(models.contains("public var payload: Data?"))
        #expect(models.contains("public var link: URL?"))
        // Unknown formats stay plain strings.
        #expect(models.contains("public var note: String?"))
        let client = try file(output, "FormatsClient.swift")
        #expect(client.contains("public func getDocument(since: Date? = nil) async throws -> GetDocumentResult {"))
    }

    @Test("oneOf/anyOf schemas generate untagged unions")
    func unionSynthesis() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Union", "version": "0.1.0" },
              "methods": [
                {
                  "name": "any_call",
                  "params": [
                    {
                      "name": "value",
                      "required": true,
                      "schema": { "oneOf": [ { "type": "string" }, { "type": "integer" } ] }
                    }
                  ],
                  "result": { "name": "result", "schema": { "anyOf": [ { "type": "boolean" }, { "type": "number" } ] } }
                }
              ]
            }
            """)
        #expect(output.warnings.isEmpty)
        let models = try file(output, "UnionModels.swift")
        #expect(models.contains("public enum AnyCallValue: Codable, Hashable, Sendable {"))
        #expect(models.contains("    case string(String)"))
        #expect(models.contains("    case int(Int)"))
        // Untagged decoding: variants are tried in declaration order.
        #expect(models.contains("if let value = try? container.decode(String.self) {"))
        #expect(models.contains("public enum AnyCallResult: Codable, Hashable, Sendable {"))
        #expect(models.contains("    case bool(Bool)"))
        #expect(models.contains("    case double(Double)"))

        let client = try file(output, "UnionClient.swift")
        #expect(client.contains("public func anyCall(value: AnyCallValue) async throws -> AnyCallResult {"))
    }

    @Test("Unsupported schemas fall back to JSONValue")
    func unsupportedSchemaFallsBackToJSONValue() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Fallback", "version": "0.1.0" },
              "methods": [
                {
                  "name": "any_call",
                  "params": [
                    {
                      "name": "value",
                      "required": true,
                      "schema": { "allOf": [ { "type": "string" }, { "type": "integer" } ] }
                    }
                  ],
                  "result": { "name": "result", "schema": true }
                }
              ]
            }
            """)
        let client = try file(output, "FallbackClient.swift")
        #expect(client.contains("public func anyCall(value: JSONValue) async throws -> JSONValue {"))
        #expect(output.warnings.count == 1)
    }

    @Test("Integer enums generate Int raw-value enums")
    func integerEnumSynthesis() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Levels", "version": "0.1.0" },
              "methods": [
                {
                  "name": "set_level",
                  "params": [
                    {
                      "name": "level",
                      "required": true,
                      "schema": { "type": "integer", "enum": [-1, 0, 2] }
                    }
                  ]
                }
              ]
            }
            """)
        #expect(output.warnings.isEmpty)
        let models = try file(output, "LevelsModels.swift")
        #expect(models.contains("public enum SetLevelLevel: Int, Codable, CaseIterable, Sendable {"))
        #expect(models.contains("    case minus1 = -1"))
        #expect(models.contains("    case _0 = 0"))
        #expect(models.contains("    case _2 = 2"))

        let client = try file(output, "LevelsClient.swift")
        #expect(client.contains("public func setLevel(level: SetLevelLevel) async throws {"))
    }

    @Test("Multiple non-null types normalize to a union")
    func multiTypeUnion() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Multi", "version": "0.1.0" },
              "methods": [
                {
                  "name": "get_id",
                  "params": [],
                  "result": {
                    "name": "id",
                    "schema": { "type": ["string", "integer", "null"] }
                  }
                }
              ]
            }
            """)
        #expect(output.warnings.isEmpty)
        let models = try file(output, "MultiModels.swift")
        #expect(models.contains("public enum GetIdResult: Codable, Hashable, Sendable {"))
        #expect(models.contains("    case string(String)"))
        #expect(models.contains("    case int(Int)"))
        let client = try file(output, "MultiClient.swift")
        // "null" in the type list folds into optionality.
        #expect(client.contains("public func getId() async throws -> GetIdResult? {"))
    }

    @Test("allOf branches merge into a single struct")
    func allOfMerge() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Merge", "version": "0.1.0" },
              "methods": [
                {
                  "name": "get_employee",
                  "params": [],
                  "result": {
                    "name": "employee",
                    "schema": { "$ref": "#/components/schemas/Employee" }
                  }
                }
              ],
              "components": {
                "schemas": {
                  "Person": {
                    "type": "object",
                    "required": ["name"],
                    "properties": {
                      "name": { "type": "string" },
                      "nickname": { "type": "string" }
                    }
                  },
                  "Employee": {
                    "allOf": [
                      { "$ref": "#/components/schemas/Person" },
                      {
                        "type": "object",
                        "required": ["employeeId"],
                        "properties": { "employeeId": { "type": "integer" } }
                      }
                    ],
                    "properties": {
                      "team": { "type": "string" }
                    }
                  }
                }
              }
            }
            """)
        #expect(output.warnings.isEmpty)
        let models = try file(output, "MergeModels.swift")
        #expect(models.contains("public struct Employee: Codable, Hashable, Sendable {"))
        // Required properties from every branch stay non-optional.
        #expect(models.contains("public var name: String"))
        #expect(models.contains("public var employeeId: Int"))
        #expect(models.contains("public var nickname: String?"))
        // The enclosing schema's own properties merge in as well.
        #expect(models.contains("public var team: String?"))
    }

    @Test("Mixed-type enums decode by constant comparison")
    func mixedTypeEnum() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Mixed", "version": "0.1.0" },
              "methods": [
                {
                  "name": "get_mode",
                  "params": [],
                  "result": {
                    "name": "mode",
                    "schema": { "enum": ["auto", 0, 1.5, true, null] }
                  }
                }
              ]
            }
            """)
        #expect(output.warnings.isEmpty)
        let models = try file(output, "MixedModels.swift")
        #expect(models.contains("public enum GetModeResult: Codable, Hashable, CaseIterable, Sendable {"))
        #expect(models.contains("    case auto"))
        #expect(models.contains("    case _0"))
        #expect(models.contains("    case _1Point5"))
        #expect(models.contains("    case `true`"))
        #expect(models.contains("    case null"))
        #expect(models.contains("if let value = try? container.decode(String.self), value == \"auto\" {"))
        #expect(models.contains("} else if let value = try? container.decode(Double.self), value == 1.5 {"))
        #expect(models.contains("} else if container.decodeNil() {"))
        #expect(models.contains("case .auto: try container.encode(\"auto\")"))
        #expect(models.contains("case .null: try container.encodeNil()"))
    }

    @Test("Declared method errors generate a typed error enum")
    func typedErrors() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Errors", "version": "0.1.0" },
              "methods": [
                {
                  "name": "get_pet",
                  "params": [],
                  "result": { "name": "pet", "schema": { "type": "string" } },
                  "errors": [
                    { "$ref": "#/components/errors/PetNotFound" },
                    { "code": -32099, "message": "Store closed" }
                  ]
                },
                {
                  "name": "ping",
                  "params": [],
                  "result": { "name": "pong", "schema": { "type": "string" } }
                }
              ],
              "components": {
                "errors": {
                  "PetNotFound": { "code": 40400, "message": "Pet not found" }
                }
              }
            }
            """)
        #expect(output.warnings.isEmpty)
        // The error enum is shared by client and server, so it lives in Models.
        let models = try file(output, "ErrorsModels.swift")
        #expect(models.contains("public enum ErrorsError: JSONRPCErrorConvertible, Hashable, Sendable {"))
        // Referenced errors are named after the components/errors key,
        // inline errors after their message.
        #expect(models.contains("    case petNotFound(JSONRPCErrorObject)"))
        #expect(models.contains("    case storeClosed(JSONRPCErrorObject)"))
        #expect(models.contains("        case 40400: self = .petNotFound(error)"))
        #expect(models.contains("        case -32099: self = .storeClosed(error)"))
        // Handlers throw declared errors through the static factories.
        #expect(models.contains("public static func petNotFound(data: JSONValue? = nil) -> Self {"))
        #expect(models.contains("public var errorObject: JSONRPCErrorObject {"))

        // Methods with declared errors map server errors to the typed enum;
        // ping declares none, so exactly one method body gets the mapping.
        let client = try file(output, "ErrorsClient.swift")
        let mapping = "throw ErrorsError(error) ?? JSONRPCError.server(error)"
        #expect(client.ranges(of: mapping).count == 1)

        // The server maps typed errors back to error objects and routes methods.
        let server = try file(output, "ErrorsServer.swift")
        #expect(server.contains("public protocol ErrorsHandler: Sendable {"))
        #expect(server.contains("    @concurrent func getPet() async throws -> String"))
        #expect(server.contains("public struct ErrorsServer: Sendable {"))
        // Typed errors reach the runtime via JSONRPCErrorConvertible, so the
        // generated server body has a single shape.
        #expect(server.contains("try await dispatch(request)"))
        #expect(!server.contains("catch let error as ErrorsError"))
    }

    @Test("Recursive schemas box the recursive properties")
    func recursiveSchemaBoxing() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Tree", "version": "0.1.0" },
              "methods": [
                {
                  "name": "get_root",
                  "params": [],
                  "result": { "name": "root", "schema": { "$ref": "#/components/schemas/Node" } }
                }
              ],
              "components": {
                "schemas": {
                  "Node": {
                    "type": "object",
                    "required": ["name"],
                    "properties": {
                      "name": { "type": "string" },
                      "parent": { "$ref": "#/components/schemas/Node" },
                      "children": { "type": "array", "items": { "$ref": "#/components/schemas/Node" } }
                    }
                  }
                }
              }
            }
            """)
        #expect(output.warnings.isEmpty)
        let models = try file(output, "TreeModels.swift")
        // The direct self-reference is boxed behind a computed property...
        #expect(models.contains("public var parent: Node? {"))
        #expect(models.contains("private var _parent: Indirect<Node>?"))
        #expect(models.contains("case _parent = \"parent\""))
        // ...but the array-typed one is not: arrays already break recursion.
        #expect(models.contains("public var children: [Node]?"))
    }

    @Test("Unions on a reference cycle become indirect enums")
    func recursiveUnionIsIndirect() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Mutual", "version": "0.1.0" },
              "methods": [
                {
                  "name": "get_a",
                  "params": [],
                  "result": { "name": "a", "schema": { "$ref": "#/components/schemas/A" } }
                }
              ],
              "components": {
                "schemas": {
                  "A": {
                    "type": "object",
                    "properties": {
                      "b": { "$ref": "#/components/schemas/B" }
                    }
                  },
                  "B": {
                    "oneOf": [
                      { "$ref": "#/components/schemas/A" },
                      { "type": "string" }
                    ]
                  }
                }
              }
            }
            """)
        #expect(output.warnings.isEmpty)
        let models = try file(output, "MutualModels.swift")
        #expect(models.contains("public indirect enum B: Codable, Hashable, Sendable {"))
        #expect(models.contains("private var _b: Indirect<B>?"))
    }

    @Test("Internal $refs outside components are dereferenced")
    func dereferencesInternalMethodRefs() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Internal", "version": "0.1.0" },
              "methods": [
                { "$ref": "#/x-methods/ping" }
              ],
              "x-methods": {
                "ping": { "name": "ping", "params": [] }
              }
            }
            """)
        #expect(output.warnings.isEmpty)
        let client = try file(output, "InternalClient.swift")
        #expect(client.contains("public func ping() async throws {"))
    }

    @Test("$refs to external documents are dereferenced")
    func dereferencesExternalRefs() throws {
        let output = try withTemporaryDirectory { directory in
            try Data(
                """
                {
                  "methods": {
                    "ping": {
                      "name": "ping",
                      "params": [],
                      "result": { "name": "pong", "schema": { "$ref": "#/schemas/Pong" } }
                    }
                  },
                  "schemas": {
                    "Pong": {
                      "type": "object",
                      "title": "Pong",
                      "required": ["message"],
                      "properties": { "message": { "type": "string" } }
                    }
                  }
                }
                """.utf8
            ).write(to: directory.appendingPathComponent("shared.json"))

            let mainURL = directory.appendingPathComponent("main.json")
            try Data(
                """
                {
                  "openrpc": "1.3.2",
                  "info": { "title": "Refs", "version": "0.1.0" },
                  "methods": [
                    { "$ref": "shared.json#/methods/ping" }
                  ]
                }
                """.utf8
            ).write(to: mainURL)

            let document = try parseDocument(at: mainURL)
            return OpenRPCSwiftGenerator(document: document).generate()
        }
        #expect(output.warnings.isEmpty)

        let client = try file(output, "RefsClient.swift")
        #expect(client.contains("public func ping() async throws -> Pong {"))
        let models = try file(output, "RefsModels.swift")
        #expect(models.contains("public struct Pong: Codable, Hashable, Sendable {"))
        #expect(models.contains("public var message: String"))
    }

    @Test("Cyclic schemas in external documents are hoisted into components")
    func hoistsExternalCyclicSchemas() throws {
        let output = try withTemporaryDirectory { directory in
            try Data(
                """
                {
                  "schemas": {
                    "TreeNode": {
                      "type": "object",
                      "required": ["label"],
                      "properties": {
                        "label": { "type": "string" },
                        "parent": { "$ref": "#/schemas/TreeNode" },
                        "sibling": { "$ref": "other.json#/schemas/Leaf" }
                      }
                    }
                  }
                }
                """.utf8
            ).write(to: directory.appendingPathComponent("shared.json"))

            try Data(
                """
                {
                  "schemas": {
                    "Leaf": {
                      "type": "object",
                      "properties": {
                        "back": { "$ref": "shared.json#/schemas/TreeNode" }
                      }
                    }
                  }
                }
                """.utf8
            ).write(to: directory.appendingPathComponent("other.json"))

            let mainURL = directory.appendingPathComponent("main.json")
            try Data(
                """
                {
                  "openrpc": "1.3.2",
                  "info": { "title": "Trees", "version": "0.1.0" },
                  "methods": [
                    {
                      "name": "get_tree",
                      "params": [],
                      "result": { "name": "tree", "schema": { "$ref": "shared.json#/schemas/TreeNode" } }
                    }
                  ]
                }
                """.utf8
            ).write(to: mainURL)

            let document = try parseDocument(at: mainURL)
            return OpenRPCSwiftGenerator(document: document).generate()
        }
        #expect(output.warnings.isEmpty)

        let models = try file(output, "TreesModels.swift")
        // Both cyclic external schemas become components; the self-reference
        // is boxed by the generator's recursion machinery.
        #expect(models.contains("public struct TreeNode: Codable, Hashable, Sendable {"))
        #expect(models.contains("public struct Leaf: Codable, Hashable, Sendable {"))
        #expect(models.contains("private var _parent: Indirect<TreeNode>?"))
        #expect(models.contains("private var _sibling: Indirect<Leaf>?"))
        #expect(models.contains("private var _back: Indirect<TreeNode>?"))

        let client = try file(output, "TreesClient.swift")
        #expect(client.contains("public func getTree() async throws -> TreeNode {"))
    }

    @Test("serverToClient methods generate a shared notification enum")
    func serverToClientNotifications() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Studio", "version": "0.1.0" },
              "methods": [
                {
                  "name": "render.start",
                  "params": [
                    { "name": "sceneId", "required": true, "schema": { "type": "string" } }
                  ],
                  "result": { "name": "ok", "schema": { "type": "boolean" } }
                },
                {
                  "name": "render.finished",
                  "x-direction": "serverToClient",
                  "paramStructure": "by-name",
                  "params": [
                    { "name": "sceneId", "required": true, "schema": { "type": "string" } },
                    { "name": "frameCount", "schema": { "type": "integer" } }
                  ]
                },
                {
                  "name": "shutdown",
                  "x-direction": "serverToClient",
                  "deprecated": true,
                  "params": []
                }
              ]
            }
            """)
        #expect(output.warnings.isEmpty)

        let notifications = try file(output, "StudioNotification.swift")
        #expect(notifications.contains("public enum StudioNotification: Hashable, Sendable {"))
        #expect(notifications.contains("    case renderFinished(sceneId: String, frameCount: Int?)"))
        #expect(notifications.contains("    @available(*, deprecated)"))
        #expect(notifications.contains("    case shutdown"))
        #expect(notifications.contains("case .renderFinished: return \"render.finished\""))
        #expect(notifications.contains("public func body() throws -> Data {"))
        #expect(notifications.contains("public static func decode(_ body: Data) throws -> Self? {"))
        #expect(notifications.contains("guard request.id == nil else { return nil }"))

        // serverToClient methods are excluded from the client and the server.
        let client = try file(output, "StudioClient.swift")
        #expect(client.contains("renderStart"))
        #expect(!client.contains("renderFinished"))
        let server = try file(output, "StudioServer.swift")
        #expect(!server.contains("render.finished"))
        #expect(!server.contains("shutdown"))
    }

    @Test("A document without serverToClient methods generates no notification file")
    func noNotificationFileWithoutServerToClientMethods() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Plain", "version": "0.1.0" },
              "methods": [
                { "name": "ping", "params": [] }
              ]
            }
            """)
        #expect(!output.files.contains { $0.name == "PlainNotification.swift" })
    }

    @Test("serverToClient results, errors, and unknown directions warn")
    func serverToClientWarnings() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Warned", "version": "0.1.0" },
              "methods": [
                {
                  "name": "job.finished",
                  "x-direction": "serverToClient",
                  "params": [],
                  "result": { "name": "ok", "schema": { "type": "boolean" } },
                  "errors": [ { "code": 1, "message": "nope" } ]
                },
                {
                  "name": "ping",
                  "x-direction": "sideways",
                  "params": []
                }
              ]
            }
            """)
        #expect(output.warnings.count == 3)
        #expect(output.warnings.contains { $0.contains("job.finished") && $0.contains("result is ignored") })
        #expect(output.warnings.contains { $0.contains("job.finished") && $0.contains("errors are ignored") })
        #expect(output.warnings.contains { $0.contains("unknown x-direction \"sideways\"") })
        // The unknown direction falls back to clientToServer.
        let client = try file(output, "WarnedClient.swift")
        #expect(client.contains("func ping()"))
    }

    @Test("Swift keyword parameter names are escaped with backticks")
    func swiftKeywordParamIsEscaped() throws {
        let output = try generate(
            """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Keywords", "version": "0.1.0" },
              "methods": [
                {
                  "name": "run",
                  "params": [
                    { "name": "operator", "required": true, "schema": { "type": "string" } }
                  ]
                }
              ]
            }
            """)
        let client = try file(output, "KeywordsClient.swift")
        #expect(client.contains("public func run(`operator`: String) async throws {"))
        // paramStructure is omitted, so params default to by-position,
        // matching the official open-rpc/generator.
        #expect(client.contains("let params: [AnyJSONRPCParam] = [AnyJSONRPCParam(`operator`)]"))
    }
}
