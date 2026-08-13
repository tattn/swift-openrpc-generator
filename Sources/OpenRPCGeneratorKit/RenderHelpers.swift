import Foundation

/// Shared string-building helpers used by both renderers.

/// Assembles a generated file from its top-level sections: one blank line
/// between sections, exactly one trailing newline.
func renderedFile(_ sections: [String]) -> String {
    sections.joined(separator: "\n\n") + "\n"
}

/// Builds documentation comment lines, supporting multi-line descriptions.
func docLines(_ text: String?, indent: String = "") -> [String] {
    guard let text, !text.isEmpty else { return [] }
    return
        text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { "\(indent)/// \($0)" }
}

private func escapeStringLiteral(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": result += "\\\\"
        case "\"": result += "\\\""
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        case "\0": result += "\\0"
        default:
            if scalar.properties.generalCategory == .control {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    return result
}

/// Renders a quoted Swift string literal.
func swiftStringLiteral(_ text: String) -> String {
    "\"\(escapeStringLiteral(text))\""
}

/// The Swift signature of a method, shared by the client protocol, the client
/// implementation, and the server handler protocol so they always agree.
func methodSignature(_ method: MethodDecl, includeDefaults: Bool) -> String {
    let params = method.params.map { param in
        let defaultValue = includeDefaults && param.optional ? " = nil" : ""
        return "\(param.swiftName): \(param.renderedType)\(defaultValue)"
    }.joined(separator: ", ")
    let returns = method.returnType.map { " -> \($0)" } ?? ""
    return "func \(method.funcName)(\(params)) async throws\(returns)"
}

/// Builds a method's documentation preamble: its doc comment plus an optional
/// extra doc line. Shared by the protocols and the client implementation.
func methodDocLines(_ method: MethodDecl, extraDoc: String? = nil, indent: String = "") -> [String] {
    var lines = docLines(method.doc, indent: indent)
    if let extraDoc {
        lines.append("\(indent)\(extraDoc)")
    }
    return lines
}

/// Renders a protocol declaration whose requirements are the methods'
/// doc comments, deprecation attributes, and signatures. Shared by the
/// client protocol and the server handler protocol.
func renderProtocolDecl(
    name: String,
    doc: [String],
    methods: [MethodDecl],
    access: AccessLevel,
    extraDoc: (MethodDecl) -> String? = { _ in nil }
) -> String {
    var lines = doc.map { "/// \($0)" }
    lines.append("\(access.prefix)protocol \(name): Sendable {")
    for method in methods {
        lines.append(contentsOf: methodDocLines(method, extraDoc: extraDoc(method), indent: "    "))
        if method.deprecated {
            lines.append("    @available(*, deprecated)")
        }
        lines.append("    \(methodSignature(method, includeDefaults: false))")
    }
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// Strips backtick escaping from a member name for comparison with JSON names.
func unescapedName(_ name: String) -> String {
    name.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
}

/// Renders a `CodingKeys` enum for the given Swift-name/JSON-name pairs.
/// Returns no lines when every Swift name already matches its JSON name.
func codingKeysLines(for pairs: [(swiftName: String, jsonName: String)], indent: String) -> [String] {
    guard pairs.contains(where: { unescapedName($0.swiftName) != $0.jsonName }) else { return [] }
    var lines = ["\(indent)private enum CodingKeys: String, CodingKey {"]
    for pair in pairs {
        if unescapedName(pair.swiftName) == pair.jsonName {
            lines.append("\(indent)    case \(pair.swiftName)")
        } else {
            lines.append("\(indent)    case \(pair.swiftName) = \(swiftStringLiteral(pair.jsonName))")
        }
    }
    lines.append("\(indent)}")
    return lines
}
