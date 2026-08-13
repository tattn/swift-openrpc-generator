import Foundation

/// A resolved Swift type. `nullable` means the schema allows JSON null.
struct TypeRef {
    var base: String
    var nullable: Bool
    /// true when the type participates in an inline-layout reference cycle.
    /// Only component references can be cyclic, so this is set where they
    /// are resolved and carried to consumers (boxing, indirect enums).
    var isCyclic: Bool = false

    /// The type expression with nullability folded into `?`.
    var optionalized: String {
        nullable ? base + "?" : base
    }
}

/// A model declaration to generate.
enum ModelDecl {
    case structDecl(StructDecl)
    case enumDecl(EnumDecl)
    case valueEnumDecl(ValueEnumDecl)
    case unionDecl(UnionDecl)
    case aliasDecl(AliasDecl)
    case errorEnumDecl(ErrorEnumDecl)
}

struct StructDecl {
    var name: String
    var doc: String?
    var properties: [PropertyDecl]
}

/// A named member backed by a JSON value: a struct property or a method parameter.
struct PropertyDecl {
    var swiftName: String
    var jsonName: String
    var baseType: String
    var optional: Bool
    var doc: String?
    /// true when the property's type participates in a reference cycle and the
    /// stored value must be wrapped in `Indirect` to break the recursion.
    /// Only relevant when rendering model structs; method params ignore it.
    var isBoxed: Bool = false

    /// The type as written in generated code, with `?` appended when optional.
    var renderedType: String {
        baseType + (optional ? "?" : "")
    }
}

struct EnumDecl {
    var name: String
    var doc: String?
    /// "String" or "Int".
    var rawType: String
    /// `rawValueLiteral` is a Swift source literal (quoted for strings);
    /// nil means the raw value is derived from the case name.
    var cases: [(caseName: String, rawValueLiteral: String?)]
}

/// A JSON primitive constant that an enum case matches against.
/// Restricting to primitives (no arrays or objects) is what lets the
/// renderer emit exhaustive decode/encode code for every case.
enum ConstantValue {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)

    init?(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .int(value)
        case .number(let value): self = .number(value)
        case .string(let value): self = .string(value)
        case .array, .object: return nil
        }
    }

    /// The seed a case name is derived from.
    var caseNameSeed: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return "\(value)"
        case .int(let value): return value < 0 ? "minus\(-value)" : "\(value)"
        case .number(let value):
            return "\(value)"
                .replacingOccurrences(of: "-", with: "minus")
                .replacingOccurrences(of: ".", with: "Point")
        case .string(let value): return value
        }
    }
}

/// A JSON Schema enum whose constants are not uniformly string or integer
/// (mixed types, doubles, booleans, null). Swift raw values cannot express
/// this, so it renders as a payload-less enum whose Codable matches the
/// decoded value against each constant.
struct ValueEnumDecl {
    var name: String
    var doc: String?
    var cases: [(caseName: String, value: ConstantValue)]
}

/// A oneOf/anyOf union rendered as an enum with associated values.
/// Decoded untagged: each variant is tried in declaration order,
/// mirroring the official generator's Rust output (serde untagged).
struct UnionDecl {
    var name: String
    var doc: String?
    /// true when the union participates in a reference cycle; rendered as
    /// `indirect enum` so its payloads are stored out of line.
    var isIndirect: Bool
    var variants: [(caseName: String, typeName: String)]
}

struct AliasDecl {
    var name: String
    var typeName: String
    var doc: String?
}

/// A resolved RPC method, ready for rendering.
struct MethodDecl {
    var rpcName: String
    var funcName: String
    var doc: String?
    var deprecated: Bool
    var params: [PropertyDecl]
    var byPosition: Bool
    /// nil means the method declares no result and is sent as a
    /// JSON-RPC notification (no id, no response awaited).
    var returnType: String?
    /// true when the method declares errors; its body maps server errors
    /// to the generated typed error enum.
    var declaresErrors: Bool = false

    /// Notifications get no response, so declared errors are only mappable
    /// on methods that await one.
    var mapsServerErrors: Bool {
        declaresErrors && returnType != nil
    }
}

/// A server-to-client notification (`x-direction: serverToClient`), rendered
/// as one case of the shared notification enum.
struct NotificationDecl {
    var rpcName: String
    var caseName: String
    var doc: String?
    var deprecated: Bool
    var params: [PropertyDecl]
    var byPosition: Bool
}

/// The document's methods split by direction.
struct ResolvedMethods {
    /// Client-to-server methods, served by the handler and callable on the client.
    var calls: [MethodDecl] = []
    /// Server-to-client notifications, rendered as the shared notification enum.
    var notifications: [NotificationDecl] = []
}

/// A case of the generated client-wide error enum, mapped by error code.
struct ErrorCaseDecl {
    var caseName: String
    var code: Int
    var message: String
}

/// The error enum shared by the generated client (catching) and server
/// (throwing), holding one case per distinct declared error code.
struct ErrorEnumDecl {
    var name: String
    var cases: [ErrorCaseDecl]
}

/// Resolves schemas and methods into Swift declarations, collecting the model
/// declarations (including ones synthesized for inline schemas) along the way.
final class CodegenContext {
    let document: OpenRPCDocument
    private(set) var modelDecls: [ModelDecl] = []
    /// Errors declared by any method, one case per distinct error code.
    private(set) var errorCases: [ErrorCaseDecl] = []
    private(set) var warnings: [String] = []

    private var errorCaseCodes: Set<Int> = []
    private var usedErrorCaseNames: Set<String> = []

    /// components/schemas key → assigned Swift type name
    private var componentTypeNames: [String: String] = [:]
    private var declaredNames: Set<String> = []
    /// Swift names of component schemas that sit on an inline-layout reference
    /// cycle. Properties of these types are boxed and unions containing them
    /// are rendered as `indirect enum`.
    private var cyclicTypeNames: Set<String> = []

    init(document: OpenRPCDocument) {
        self.document = document
        // Fix component type names up front so $ref resolution does not
        // depend on generation order.
        let schemas = document.components?.schemas ?? [:]
        for key in schemas.keys.sorted() {
            componentTypeNames[key] = uniqueTypeName(SwiftNaming.typeName(key))
        }
        cyclicTypeNames = Self.detectCycles(in: schemas, typeNames: componentTypeNames)
    }

    /// Finds component schemas that can reach themselves through inline-layout
    /// references (properties, oneOf/anyOf/allOf, aliases). Arrays and
    /// dictionaries allocate on the heap and already break recursion, so
    /// `items` and `additionalProperties` are not walked.
    private static func detectCycles(
        in schemas: [String: JSONSchema],
        typeNames: [String: String]
    ) -> Set<String> {
        var edges: [String: Set<String>] = [:]
        for (key, schema) in schemas {
            var refs: Set<String> = []
            collectInlineLayoutRefKeys(schema, into: &refs)
            edges[key] = refs
        }

        return Set(selfReachableNodes(in: edges).compactMap { typeNames[$0] })
    }

    /// Contract: this walk must cover a superset of every position that
    /// `mergedAllOfObject` can inline properties from — merged edges are
    /// then reachable as raw paths, keeping cycle detection sound.
    private static func collectInlineLayoutRefKeys(_ schema: JSONSchema, into keys: inout Set<String>) {
        switch schema {
        case .boolean:
            break
        case .reference(let ref):
            if let key = ComponentReference.key(of: ref, kind: "schemas") {
                keys.insert(key)
            }
        case .object(let object):
            for property in object.properties.values {
                collectInlineLayoutRefKeys(property, into: &keys)
            }
            for branch in object.oneOf + object.anyOf + object.allOf {
                collectInlineLayoutRefKeys(branch, into: &keys)
            }
        }
    }

    func warn(_ message: String) {
        warnings.append(message)
    }

    // MARK: - components/schemas

    func generateComponentModels() {
        guard let schemas = document.components?.schemas else { return }
        for key in schemas.keys.sorted() {
            declareTopLevel(schema: schemas[key]!, name: componentTypeNames[key]!)
        }
    }

    /// Declares a schema that must be emitted under the given (already
    /// allocated) name, such as a components/schemas entry. Schemas that do
    /// not become a struct or an enum are declared as a typealias.
    private func declareTopLevel(schema: JSONSchema, name: String) {
        switch schema {
        case .boolean, .reference:
            let ref = swiftType(for: schema, hint: name + "Value")
            modelDecls.append(.aliasDecl(AliasDecl(name: name, typeName: ref.optionalized, doc: nil)))
        case .object(let object):
            if isStringEnum(object) || isIntegerEnum(object) {
                declareEnum(object: object, name: name)
            } else if let constants = constantValues(of: object) {
                declareValueEnum(constants: constants, doc: object.description ?? object.title, name: name)
            } else if isStructLike(object) {
                declareStruct(object: object, name: name)
            } else if isUnionLike(object) {
                declareUnion(object: object, name: name)
            } else if !object.allOf.isEmpty, !(object.allOf.count == 1 && object.properties.isEmpty),
                let merged = mergedAllOfObject(object, hint: name)
            {
                declareStruct(object: merged, name: name)
            } else {
                let ref = resolveObjectSchema(object, hint: name + "Value")
                modelDecls.append(
                    .aliasDecl(
                        AliasDecl(
                            name: name,
                            typeName: ref.optionalized,
                            doc: object.description ?? object.title
                        )))
            }
        }
    }

    // MARK: - Methods

    func resolveMethods() -> ResolvedMethods {
        var usedFuncNames: Set<String> = []
        var usedCaseNames: Set<String> = []
        var resolved = ResolvedMethods()
        for entry in document.methods {
            switch entry {
            case .reference(let ref):
                warn("$ref \"\(ref)\" in methods is not supported; skipped")
            case .value(let method):
                if isServerToClient(method) {
                    resolved.notifications.append(
                        resolveNotification(method, usedCaseNames: &usedCaseNames))
                } else {
                    resolved.calls.append(resolveMethod(method, usedFuncNames: &usedFuncNames))
                }
            }
        }
        return resolved
    }

    private func isServerToClient(_ method: Method) -> Bool {
        switch method.direction {
        case nil, "clientToServer":
            return false
        case "serverToClient":
            return true
        case let direction?:
            warn(
                "Method \"\(method.name)\" has unknown x-direction \"\(direction)\"; treated as clientToServer"
            )
            return false
        }
    }

    private func resolveParams(of method: Method) -> [PropertyDecl] {
        let hintBase = SwiftNaming.typeName(method.name)
        var usedParamNames: Set<String> = []
        var params: [PropertyDecl] = []
        for entry in method.params {
            guard let descriptor = resolveDescriptor(entry) else { continue }
            params.append(
                resolveProperty(
                    jsonName: descriptor.name,
                    schema: descriptor.schema,
                    isRequired: descriptor.required ?? false,
                    hintBase: hintBase,
                    doc: descriptor.summary ?? descriptor.description,
                    usedNames: &usedParamNames
                ))
        }
        return params
    }

    private func resolveNotification(_ method: Method, usedCaseNames: inout Set<String>) -> NotificationDecl {
        if method.result != nil {
            warn(
                "Method \"\(method.name)\" is serverToClient; its result is ignored (notifications get no response)"
            )
        }
        if !method.errors.isEmpty {
            warn(
                "Method \"\(method.name)\" is serverToClient; its errors are ignored (notifications get no response)"
            )
        }
        let doc = [method.summary, method.description].compactMap { $0 }.joined(separator: "\n\n")
        return NotificationDecl(
            rpcName: method.name,
            caseName: SwiftNaming.uniqueMemberName(method.name, in: &usedCaseNames),
            doc: doc.isEmpty ? nil : doc,
            deprecated: method.deprecated ?? false,
            params: resolveParams(of: method),
            byPosition: method.paramStructure != "by-name"
        )
    }

    private func resolveMethod(_ method: Method, usedFuncNames: inout Set<String>) -> MethodDecl {
        let funcName = SwiftNaming.uniqueMemberName(method.name, in: &usedFuncNames)
        let hintBase = SwiftNaming.typeName(method.name)
        let params = resolveParams(of: method)

        var returnType: String?
        if let resultEntry = method.result {
            if let descriptor = resolveDescriptor(resultEntry) {
                returnType = swiftType(for: descriptor.schema, hint: hintBase + "Result").optionalized
            } else {
                // The result exists but cannot be resolved (warning already
                // recorded); fall back rather than degrading to a notification.
                returnType = "JSONValue"
            }
        }

        var declaresErrors = false
        for entry in method.errors {
            guard let (nameHint, error) = resolveError(entry) else { continue }
            declaresErrors = true
            registerErrorCase(nameHint: nameHint, error: error)
        }
        let doc = [method.summary, method.description].compactMap { $0 }.joined(separator: "\n\n")
        let decl = MethodDecl(
            rpcName: method.name,
            funcName: funcName,
            doc: doc.isEmpty ? nil : doc,
            deprecated: method.deprecated ?? false,
            params: params,
            // Matches the official open-rpc/generator: params are sent
            // by-position unless the method explicitly opts into by-name.
            byPosition: method.paramStructure != "by-name",
            returnType: returnType,
            declaresErrors: declaresErrors
        )
        if decl.declaresErrors, !decl.mapsServerErrors {
            warn(
                "Method \"\(method.name)\" declares errors but no result; notifications get no response, so the errors cannot be mapped"
            )
        }
        return decl
    }

    private func resolveError(_ entry: MethodErrorOrReference) -> (nameHint: String?, error: MethodError)? {
        switch entry {
        case .value(let error):
            return (nil, error)
        case .reference(let ref):
            if let key = ComponentReference.key(of: ref, kind: "errors"),
                let error = document.components?.errors?[key]
            {
                return (key, error)
            }
            warn("Cannot resolve error $ref \"\(ref)\"; skipped")
            return nil
        }
    }

    /// Registers a declared error as a case of the client-wide error enum.
    /// Codes are shared service-wide in JSON-RPC, so re-declarations of the
    /// same code collapse into one case. Cases are named after the
    /// components/errors key when referenced, or the message when inline.
    private func registerErrorCase(nameHint: String?, error: MethodError) {
        guard errorCaseCodes.insert(error.code).inserted else { return }
        let caseName = SwiftNaming.uniqueMemberName(nameHint ?? error.message, in: &usedErrorCaseNames)
        errorCases.append(ErrorCaseDecl(caseName: caseName, code: error.code, message: error.message))
    }

    /// Declares the shared error enum as a model once methods are resolved,
    /// returning its name; nil when no method declared errors. The name goes
    /// through the registry so it cannot collide with a schema type.
    func declareErrorEnum(baseName: String) -> String? {
        guard !errorCases.isEmpty else { return nil }
        let name = uniqueTypeName(baseName + "Error")
        modelDecls.append(.errorEnumDecl(ErrorEnumDecl(name: name, cases: errorCases)))
        return name
    }

    private func resolveDescriptor(_ entry: ContentDescriptorOrReference) -> ContentDescriptor? {
        switch entry {
        case .value(let descriptor):
            return descriptor
        case .reference(let ref):
            if let key = ComponentReference.key(of: ref, kind: "contentDescriptors"),
                let descriptor = document.components?.contentDescriptors?[key]
            {
                return descriptor
            }
            warn("Cannot resolve content descriptor $ref \"\(ref)\"; skipped")
            return nil
        }
    }

    /// Resolves one JSON-named member (a struct property or a method
    /// parameter) into a Swift member declaration.
    private func resolveProperty(
        jsonName: String,
        schema: JSONSchema,
        isRequired: Bool,
        hintBase: String,
        doc: String?,
        usedNames: inout Set<String>
    ) -> PropertyDecl {
        let swiftName = SwiftNaming.uniqueMemberName(jsonName, in: &usedNames)
        let ref = swiftType(for: schema, hint: hintBase + SwiftNaming.typeName(jsonName))
        return PropertyDecl(
            swiftName: swiftName,
            jsonName: jsonName,
            baseType: ref.base,
            optional: !isRequired || ref.nullable,
            doc: doc,
            isBoxed: ref.isCyclic
        )
    }

    // MARK: - Type resolution

    /// Resolves a schema to a Swift type. Inline objects and enums are
    /// declared as models named after `hint`, and that name is returned.
    func swiftType(for schema: JSONSchema, hint: String) -> TypeRef {
        switch schema {
        case .boolean(let allowsAnything):
            if !allowsAnything {
                warn("The `false` schema is not supported; falling back to JSONValue (\(hint))")
            }
            return TypeRef(base: "JSONValue", nullable: false)
        case .reference(let ref):
            return resolveReference(ref, hint: hint)
        case .object(let object):
            return resolveObjectSchema(object, hint: hint)
        }
    }

    private func resolveReference(_ ref: String, hint: String) -> TypeRef {
        if let key = ComponentReference.key(of: ref, kind: "schemas") {
            if let name = componentTypeNames[key] {
                return TypeRef(base: name, nullable: false, isCyclic: cyclicTypeNames.contains(name))
            }
            warn("$ref \"\(ref)\" is not found in components/schemas")
        } else {
            warn("$ref \"\(ref)\" is not supported (only #/components/schemas/ references are)")
        }
        return TypeRef(base: "JSONValue", nullable: false)
    }

    private func resolveObjectSchema(_ object: SchemaObject, hint: String) -> TypeRef {
        let nullable = object.nullable || object.types.contains("null")
        let types = object.types.filter { $0 != "null" }

        if !object.enumValues.isEmpty {
            if isStringEnum(object) || isIntegerEnum(object) {
                let name = declareEnum(
                    object: object,
                    name: uniqueTypeName(preferredName(for: object, hint: hint))
                )
                return TypeRef(base: name, nullable: nullable)
            }
            if let constants = constantValues(of: object) {
                let name = declareValueEnum(
                    constants: constants,
                    doc: object.description ?? object.title,
                    name: uniqueTypeName(preferredName(for: object, hint: hint))
                )
                return TypeRef(base: name, nullable: nullable)
            }
            warn("Enum values that are arrays or objects are not supported; falling back to JSONValue (\(hint))")
            return TypeRef(base: "JSONValue", nullable: nullable)
        }

        if types.count > 1 {
            // Multiple non-null types normalize to a per-type union, matching
            // the official generator's behavior.
            let name = declareUnion(
                object: object,
                name: uniqueTypeName(preferredName(for: object, hint: hint))
            )
            return TypeRef(base: name, nullable: nullable)
        }

        if !object.allOf.isEmpty {
            // A lone `$ref` branch with no sibling properties is an alias;
            // resolving it directly preserves the referenced type's identity.
            if object.allOf.count == 1, object.properties.isEmpty {
                let inner = swiftType(for: object.allOf[0], hint: hint)
                return TypeRef(base: inner.base, nullable: nullable || inner.nullable, isCyclic: inner.isCyclic)
            }
            if let merged = mergedAllOfObject(object, hint: hint) {
                let name = declareStruct(
                    object: merged,
                    name: uniqueTypeName(preferredName(for: object, hint: hint))
                )
                return TypeRef(base: name, nullable: nullable)
            }
            warn("allOf branches other than object schemas cannot be merged; falling back to JSONValue (\(hint))")
            return TypeRef(base: "JSONValue", nullable: nullable)
        }

        // Infer the type from the structure even when `type` is omitted.
        let effectiveType: String?
        if let first = types.first {
            effectiveType = first
        } else if !object.properties.isEmpty {
            effectiveType = "object"
        } else if object.items != nil {
            effectiveType = "array"
        } else {
            effectiveType = nil
        }

        switch effectiveType {
        case "string":
            let base = Self.stringFormatTypes[object.format ?? ""] ?? "String"
            return TypeRef(base: base, nullable: nullable)
        case "integer":
            return TypeRef(base: "Int", nullable: nullable)
        case "number":
            return TypeRef(base: "Double", nullable: nullable)
        case "boolean":
            return TypeRef(base: "Bool", nullable: nullable)
        case "array":
            guard let items = object.items else {
                return TypeRef(base: "[JSONValue]", nullable: nullable)
            }
            let element = swiftType(for: items, hint: hint + "Item")
            return TypeRef(base: "[\(element.optionalized)]", nullable: nullable)
        case "object":
            if !object.properties.isEmpty {
                let name = declareStruct(
                    object: object,
                    name: uniqueTypeName(preferredName(for: object, hint: hint))
                )
                return TypeRef(base: name, nullable: nullable)
            }
            if let additional = object.additionalProperties {
                let value = swiftType(for: additional, hint: hint + "Value")
                return TypeRef(base: "[String: \(value.optionalized)]", nullable: nullable)
            }
            return TypeRef(base: "[String: JSONValue]", nullable: nullable)
        default:
            if !object.oneOf.isEmpty || !object.anyOf.isEmpty {
                let name = declareUnion(
                    object: object,
                    name: uniqueTypeName(preferredName(for: object, hint: hint))
                )
                return TypeRef(base: name, nullable: nullable)
            }
            // A missing type falls back to JSONValue.
            return TypeRef(base: "JSONValue", nullable: nullable)
        }
    }

    // MARK: - Declarations

    /// Well-known string formats mapped to dedicated Foundation types.
    /// Dates ride on the runtime's ISO 8601 coding configuration; UUID, URL,
    /// and base64 Data are handled natively by Codable.
    private static let stringFormatTypes: [String: String] = [
        "date-time": "Date",
        "uuid": "UUID",
        "byte": "Data",
        "uri": "URL",
    ]

    private func isStringEnum(_ object: SchemaObject) -> Bool {
        guard !object.enumValues.isEmpty else { return false }
        let types = object.types.filter { $0 != "null" }
        guard types.isEmpty || types == ["string"] else { return false }
        return object.enumValues.allSatisfy { $0.stringValue != nil }
    }

    private func isIntegerEnum(_ object: SchemaObject) -> Bool {
        guard !object.enumValues.isEmpty else { return false }
        let types = object.types.filter { $0 != "null" }
        guard types.isEmpty || types == ["integer"] || types == ["number"] else { return false }
        return object.enumValues.allSatisfy { $0.intValue != nil }
    }

    private func isStructLike(_ object: SchemaObject) -> Bool {
        // Schemas with allOf go through merging instead.
        guard object.enumValues.isEmpty, object.allOf.isEmpty else { return false }
        let types = object.types.filter { $0 != "null" }
        return !object.properties.isEmpty && (types.isEmpty || types == ["object"])
    }

    private func isUnionLike(_ object: SchemaObject) -> Bool {
        guard object.enumValues.isEmpty else { return false }
        let types = object.types.filter { $0 != "null" }
        // Multiple non-null types always form a union (any properties belong
        // to the object projection), matching resolveObjectSchema's dispatch.
        if types.count > 1 { return true }
        return types.isEmpty && object.properties.isEmpty
            && (!object.oneOf.isEmpty || !object.anyOf.isEmpty)
    }

    /// The schema's enum values as Swift constants; nil when the schema has
    /// no enum values or any value has no constant form (such schemas fall
    /// back to JSONValue instead of silently dropping cases).
    private func constantValues(of object: SchemaObject) -> [ConstantValue]? {
        guard !object.enumValues.isEmpty else { return nil }
        let constants = object.enumValues.compactMap(ConstantValue.init)
        return constants.count == object.enumValues.count ? constants : nil
    }

    private func preferredName(for object: SchemaObject, hint: String) -> String {
        if let title = object.title, !title.isEmpty {
            return SwiftNaming.typeName(title)
        }
        return SwiftNaming.typeName(hint)
    }

    /// Declares a raw-value enum (String- or Int-backed) under the given
    /// (already allocated) name. Integer enums are a Swift-side improvement:
    /// the official Rust generator degrades them to an unconstrained alias.
    @discardableResult
    private func declareEnum(object: SchemaObject, name: String) -> String {
        let rawType = isStringEnum(object) ? "String" : "Int"
        var usedCaseNames: Set<String> = []
        var cases: [(caseName: String, rawValueLiteral: String?)] = []
        for value in object.enumValues {
            if rawType == "String", let rawValue = value.stringValue {
                let caseName = SwiftNaming.uniqueMemberName(rawValue, in: &usedCaseNames)
                let literal = unescapedName(caseName) == rawValue ? nil : swiftStringLiteral(rawValue)
                cases.append((caseName, literal))
            } else if rawType == "Int", let intValue = value.intValue {
                let seed = ConstantValue.int(intValue).caseNameSeed
                cases.append((SwiftNaming.uniqueMemberName(seed, in: &usedCaseNames), "\(intValue)"))
            }
        }
        modelDecls.append(
            .enumDecl(
                EnumDecl(
                    name: name,
                    doc: object.description ?? object.title,
                    rawType: rawType,
                    cases: cases
                )))
        return name
    }

    /// Declares an enum of the given heterogeneous constants under the given
    /// (already allocated) name.
    @discardableResult
    private func declareValueEnum(constants: [ConstantValue], doc: String?, name: String) -> String {
        var usedCaseNames: Set<String> = []
        let cases = constants.map { constant in
            (caseName: SwiftNaming.uniqueMemberName(constant.caseNameSeed, in: &usedCaseNames), value: constant)
        }
        modelDecls.append(
            .valueEnumDecl(
                ValueEnumDecl(
                    name: name,
                    doc: doc,
                    cases: cases
                )))
        return name
    }

    /// The variant schemas a union is built from: explicit oneOf/anyOf
    /// branches, or per-type projections of a multi-type schema.
    private func unionBranches(of object: SchemaObject) -> [JSONSchema] {
        if !object.oneOf.isEmpty { return object.oneOf }
        if !object.anyOf.isEmpty { return object.anyOf }
        return object.types.filter { $0 != "null" }.map { type in
            var branch = object
            branch.types = [type]
            return .object(branch)
        }
    }

    /// Declares a union enum under the given (already allocated) name.
    @discardableResult
    private func declareUnion(object: SchemaObject, name: String) -> String {
        let branches = unionBranches(of: object)
        var usedCaseNames: Set<String> = []
        var variants: [(caseName: String, typeName: String)] = []
        var referencesCyclicType = false
        for (index, branch) in branches.enumerated() {
            let ref = swiftType(for: branch, hint: name + "Variant\(index + 1)")
            let caseName = SwiftNaming.uniqueMemberName(unionCaseSeed(for: ref.base), in: &usedCaseNames)
            variants.append((caseName, ref.optionalized))
            if ref.isCyclic {
                referencesCyclicType = true
            }
        }
        modelDecls.append(
            .unionDecl(
                UnionDecl(
                    name: name,
                    doc: object.description ?? object.title,
                    isIndirect: referencesCyclicType || cyclicTypeNames.contains(name),
                    variants: variants
                )))
        return name
    }

    /// Merges a multi-branch `allOf` (plus the enclosing schema's own members)
    /// into a single object schema. Returns nil when any branch is not an
    /// object schema or a reference cannot be followed; the caller then falls
    /// back to `JSONValue`.
    private func mergedAllOfObject(_ object: SchemaObject, hint: String) -> SchemaObject? {
        var mergedProperties: [String: JSONSchema] = [:]
        var mergedRequired: Set<String> = []
        var visitedRefs: Set<String> = []

        func merge(_ object: SchemaObject) -> Bool {
            for branch in object.allOf {
                guard let branchObject = objectSchema(of: branch, visitedRefs: &visitedRefs) else {
                    return false
                }
                guard merge(branchObject) else { return false }
                for (name, schema) in branchObject.properties {
                    if mergedProperties[name] != nil {
                        warn(
                            "allOf branches define the property \"\(name)\" more than once; the later definition wins (\(hint))"
                        )
                    }
                    mergedProperties[name] = schema
                }
                mergedRequired.formUnion(branchObject.required)
            }
            return true
        }

        guard merge(object) else { return nil }
        // The enclosing schema's own members apply on top of the branches.
        mergedProperties.merge(object.properties) { _, own in own }
        mergedRequired.formUnion(object.required)

        var merged = object
        merged.allOf = []
        merged.types = ["object"]
        merged.properties = mergedProperties
        merged.required = mergedRequired.sorted()
        return merged
    }

    /// Follows a branch to its object schema: inline objects directly,
    /// component references through components/schemas, and nested allOf
    /// recursively. Returns nil for anything that is not a plain object.
    private func objectSchema(of branch: JSONSchema, visitedRefs: inout Set<String>) -> SchemaObject? {
        switch branch {
        case .boolean:
            return nil
        case .reference(let ref):
            guard !visitedRefs.contains(ref),
                let key = ComponentReference.key(of: ref, kind: "schemas"),
                let target = document.components?.schemas?[key]
            else { return nil }
            visitedRefs.insert(ref)
            return objectSchema(of: target, visitedRefs: &visitedRefs)
        case .object(let object):
            let types = object.types.filter { $0 != "null" }
            guard types.isEmpty || types == ["object"],
                object.enumValues.isEmpty, object.oneOf.isEmpty, object.anyOf.isEmpty
            else { return nil }
            return object
        }
    }

    /// Derives a case name seed from a variant's Swift type name.
    private func unionCaseSeed(for typeName: String) -> String {
        switch typeName {
        case "String": return "string"
        case "Int": return "int"
        case "Double": return "double"
        case "Bool": return "bool"
        case "JSONValue": return "value"
        default:
            if typeName.hasPrefix("[String:") { return "object" }
            if typeName.hasPrefix("[") {
                let element = typeName.filter { $0.isLetter || $0.isNumber }
                return element + "Array"
            }
            return typeName
        }
    }

    /// Declares a struct under the given (already allocated) name.
    @discardableResult
    private func declareStruct(object: SchemaObject, name: String) -> String {
        let requiredNames = Set(object.required)
        var usedNames: Set<String> = []
        var properties: [PropertyDecl] = []
        for jsonName in object.properties.keys.sorted() {
            let schema = object.properties[jsonName]!
            properties.append(
                resolveProperty(
                    jsonName: jsonName,
                    schema: schema,
                    isRequired: requiredNames.contains(jsonName),
                    hintBase: name,
                    doc: propertyDoc(schema),
                    usedNames: &usedNames
                ))
        }
        modelDecls.append(
            .structDecl(
                StructDecl(
                    name: name,
                    doc: object.description ?? object.title,
                    properties: properties
                )))
        return name
    }

    private func propertyDoc(_ schema: JSONSchema) -> String? {
        if case .object(let object) = schema {
            return object.description
        }
        return nil
    }

    /// Allocates a type name that is unique across all declarations.
    func uniqueTypeName(_ base: String) -> String {
        SwiftNaming.uniqueName(base, in: &declaredNames)
    }
}
