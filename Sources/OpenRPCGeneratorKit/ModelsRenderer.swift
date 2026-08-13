import Foundation

/// Renders model declarations as Swift source code.
struct ModelsRenderer {
    let access: AccessLevel

    func render(decls: [ModelDecl], header: String) -> String {
        var sections: [String] = [header, "import Foundation"]
        for decl in decls {
            switch decl {
            case .structDecl(let structDecl):
                sections.append(render(structDecl))
            case .enumDecl(let enumDecl):
                sections.append(render(enumDecl))
            case .valueEnumDecl(let valueEnumDecl):
                sections.append(render(valueEnumDecl))
            case .unionDecl(let unionDecl):
                sections.append(render(unionDecl))
            case .aliasDecl(let alias):
                sections.append(render(alias))
            case .errorEnumDecl(let errorEnum):
                sections.append(renderErrorEnum(errorEnum.cases, name: errorEnum.name))
            }
        }
        return renderedFile(sections)
    }

    /// Renders the error enum shared by the generated client (catching) and
    /// server (throwing), mapped from the error codes the document declares.
    private func renderErrorEnum(_ errors: [ErrorCaseDecl], name: String) -> String {
        var lines: [String] = []
        lines.append("/// Errors declared in the OpenRPC document, mapped by error code.")
        lines.append("/// Clients catch these; handlers can throw them via the static factories.")
        lines.append("/// Undeclared codes surface as `JSONRPCError.server`.")
        lines.append("\(access.prefix)enum \(name): JSONRPCErrorConvertible, Hashable, Sendable {")
        for error in errors {
            lines.append("    /// \(error.message) (code \(error.code))")
            lines.append("    case \(error.caseName)(JSONRPCErrorObject)")
        }
        lines.append("")
        lines.append("    \(access.prefix)init?(_ error: JSONRPCErrorObject) {")
        lines.append("        switch error.code {")
        for error in errors {
            lines.append("        case \(error.code): self = .\(error.caseName)(error)")
        }
        lines.append("        default: return nil")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    /// The underlying JSON-RPC error object.")
        lines.append("    \(access.prefix)var errorObject: JSONRPCErrorObject {")
        lines.append("        switch self {")
        for error in errors {
            lines.append("        case .\(error.caseName)(let error): return error")
        }
        lines.append("        }")
        lines.append("    }")
        for error in errors {
            lines.append("")
            lines.append("    /// \(error.message) (code \(error.code))")
            lines.append("    \(access.prefix)static func \(error.caseName)(data: JSONValue? = nil) -> Self {")
            lines.append(
                "        .\(error.caseName)(JSONRPCErrorObject(code: \(error.code), message: \(swiftStringLiteral(error.message)), data: data))"
            )
            lines.append("    }")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func render(_ decl: StructDecl) -> String {
        var lines: [String] = []
        lines.append(contentsOf: docLines(decl.doc))
        lines.append("\(access.prefix)struct \(decl.name): Codable, Hashable, Sendable {")
        for property in decl.properties {
            lines.append(contentsOf: docLines(property.doc, indent: "    "))
            if property.isBoxed {
                // Recursive property: store an Indirect box, expose the plain type.
                let storage = storageName(of: property)
                let chain = property.optional ? "?" : ""
                lines.append("    \(access.prefix)var \(property.swiftName): \(property.renderedType) {")
                lines.append("        get { \(storage)\(chain).wrappedValue }")
                if property.optional {
                    lines.append("        set { \(storage) = newValue.map(Indirect.init) }")
                } else {
                    // Assign through wrappedValue to keep the copy-on-write fast path.
                    lines.append("        set { \(storage).wrappedValue = newValue }")
                }
                lines.append("    }")
                lines.append("    private var \(storage): Indirect<\(property.baseType)>\(chain)")
            } else {
                lines.append("    \(access.prefix)var \(property.swiftName): \(property.renderedType)")
            }
        }

        // Write the memberwise initializer out to give it an explicit access level.
        lines.append("")
        let parameters = decl.properties.map { property in
            "\(property.swiftName): \(property.renderedType)\(property.optional ? " = nil" : "")"
        }.joined(separator: ", ")
        lines.append("    \(access.prefix)init(\(parameters)) {")
        for property in decl.properties {
            if property.isBoxed {
                lines.append("        self.\(storageName(of: property)) = \(boxedExpression(property))")
            } else {
                lines.append("        self.\(property.swiftName) = \(property.swiftName)")
            }
        }
        lines.append("    }")

        let keyLines = codingKeysLines(
            for: decl.properties.map { property in
                (property.isBoxed ? storageName(of: property) : property.swiftName, property.jsonName)
            },
            indent: "    "
        )
        if !keyLines.isEmpty {
            lines.append("")
            lines.append(contentsOf: keyLines)
        }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// The name of the private stored box behind a recursive property.
    private func storageName(of property: PropertyDecl) -> String {
        "_" + unescapedName(property.swiftName)
    }

    /// The expression that boxes a memberwise-init argument into Indirect storage.
    private func boxedExpression(_ property: PropertyDecl) -> String {
        property.optional
            ? "\(property.swiftName).map(Indirect.init)"
            : "Indirect(\(property.swiftName))"
    }

    private func render(_ decl: EnumDecl) -> String {
        var lines: [String] = []
        lines.append(contentsOf: docLines(decl.doc))
        lines.append("\(access.prefix)enum \(decl.name): \(decl.rawType), Codable, CaseIterable, Sendable {")
        for enumCase in decl.cases {
            if let literal = enumCase.rawValueLiteral {
                lines.append("    case \(enumCase.caseName) = \(literal)")
            } else {
                lines.append("    case \(enumCase.caseName)")
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Renders an enum of heterogeneous constants. Decoding matches the
    /// value against each constant in declaration order.
    private func render(_ decl: ValueEnumDecl) -> String {
        var lines: [String] = []
        lines.append(contentsOf: docLines(decl.doc))
        lines.append("\(access.prefix)enum \(decl.name): Codable, Hashable, CaseIterable, Sendable {")
        for enumCase in decl.cases {
            lines.append("    case \(enumCase.caseName)")
        }
        lines.append("")
        lines.append(
            contentsOf: untaggedInitLines(
                branches: decl.cases.map { (matchCondition(for: $0.value), "self = .\($0.caseName)") },
                typeName: decl.name
            ))
        lines.append("")
        lines.append(
            contentsOf: singleValueEncodeLines(
                switchCases: decl.cases.map { "case .\($0.caseName): \(encodeStatement(for: $0.value))" }
            ))
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// The `init(from:)` of an untagged type: each branch is tried in
    /// declaration order against a single-value container named `container`.
    private func untaggedInitLines(branches: [(condition: String, assignment: String)], typeName: String)
        -> [String]
    {
        var lines: [String] = []
        lines.append("    \(access.prefix)init(from decoder: any Decoder) throws {")
        lines.append("        let container = try decoder.singleValueContainer()")
        for (index, branch) in branches.enumerated() {
            let keyword = index == 0 ? "if" : "} else if"
            lines.append("        \(keyword) \(branch.condition) {")
            lines.append("            \(branch.assignment)")
        }
        lines.append("        } else {")
        lines.append("            throw DecodingError.dataCorruptedError(")
        lines.append("                in: container,")
        lines.append("                debugDescription: \"No \(typeName) value matched\"")
        lines.append("            )")
        lines.append("        }")
        lines.append("    }")
        return lines
    }

    /// The `encode(to:)` of a type that writes one value into a
    /// single-value container, switching over `self`.
    private func singleValueEncodeLines(switchCases: [String]) -> [String] {
        var lines: [String] = []
        lines.append("    \(access.prefix)func encode(to encoder: any Encoder) throws {")
        lines.append("        var container = encoder.singleValueContainer()")
        lines.append("        switch self {")
        for switchCase in switchCases {
            lines.append("        \(switchCase)")
        }
        lines.append("        }")
        lines.append("    }")
        return lines
    }

    private func matchCondition(for value: ConstantValue) -> String {
        guard let (type, literal) = typedLiteral(of: value) else {
            return "container.decodeNil()"
        }
        return "let value = try? container.decode(\(type).self), value == \(literal)"
    }

    private func encodeStatement(for value: ConstantValue) -> String {
        guard let (_, literal) = typedLiteral(of: value) else {
            return "try container.encodeNil()"
        }
        return "try container.encode(\(literal))"
    }

    /// The Swift type and source literal of a constant; nil for null.
    private func typedLiteral(of value: ConstantValue) -> (type: String, literal: String)? {
        switch value {
        case .null: return nil
        case .bool(let value): return ("Bool", "\(value)")
        case .int(let value): return ("Int", "\(value)")
        case .number(let value): return ("Double", "\(value)")
        case .string(let value): return ("String", swiftStringLiteral(value))
        }
    }

    /// Renders a oneOf/anyOf union as an enum with associated values.
    /// Decoding is untagged: each variant is tried in declaration order.
    private func render(_ decl: UnionDecl) -> String {
        var lines: [String] = []
        lines.append(contentsOf: docLines(decl.doc))
        let indirect = decl.isIndirect ? "indirect " : ""
        lines.append("\(access.prefix)\(indirect)enum \(decl.name): Codable, Hashable, Sendable {")
        for variant in decl.variants {
            lines.append("    case \(variant.caseName)(\(variant.typeName))")
        }

        lines.append("")
        lines.append(
            contentsOf: untaggedInitLines(
                branches: decl.variants.map { variant in
                    (
                        "let value = try? container.decode(\(variant.typeName).self)",
                        "self = .\(variant.caseName)(value)"
                    )
                },
                typeName: decl.name
            ))
        lines.append("")
        lines.append(
            contentsOf: singleValueEncodeLines(
                switchCases: decl.variants.map {
                    "case .\($0.caseName)(let value): try container.encode(value)"
                }
            ))
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func render(_ decl: AliasDecl) -> String {
        var lines: [String] = []
        lines.append(contentsOf: docLines(decl.doc))
        lines.append("\(access.prefix)typealias \(decl.name) = \(decl.typeName)")
        return lines.joined(separator: "\n")
    }
}
