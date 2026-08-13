import Foundation

/// Renders resolved methods as a JSON-RPC client (protocol + implementation).
struct ClientRenderer {
    let access: AccessLevel
    let clientName: String
    /// The shared error enum declared in the models file; nil when the
    /// document declares no errors.
    let errorTypeName: String?

    func render(methods: [MethodDecl], header: String) -> String {
        renderedFile([
            header,
            """
            import Foundation
            #if canImport(FoundationNetworking)
            import FoundationNetworking
            #endif
            """,
            renderProtocol(methods: methods),
            renderClient(methods: methods),
        ])
    }

    private func renderProtocol(methods: [MethodDecl]) -> String {
        renderProtocolDecl(
            name: "\(clientName)Protocol",
            doc: ["The generated client's interface. Useful for mocking in tests."],
            methods: methods,
            access: access,
            extraDoc: Self.notificationDoc
        )
    }

    private func renderClient(methods: [MethodDecl]) -> String {
        var lines: [String] = []
        lines.append("\(access.prefix)struct \(clientName): \(clientName)Protocol {")
        lines.append("    private let rpc: JSONRPCClient")
        lines.append("")
        lines.append("    \(access.prefix)init(transport: any JSONRPCTransport) {")
        lines.append("        self.rpc = JSONRPCClient(transport: transport)")
        lines.append("    }")
        lines.append("")
        lines.append("    /// Creates a client that connects to an HTTP(S) endpoint.")
        lines.append(
            "    \(access.prefix)init(url: URL, headers: [String: String] = [:], session: URLSession = .shared) {")
        lines.append(
            "        self.init(transport: HTTPJSONRPCTransport(url: url, additionalHeaders: headers, session: session))"
        )
        lines.append("    }")

        for method in methods {
            lines.append("")
            lines.append(contentsOf: renderMethod(method).map { $0.isEmpty ? $0 : "    " + $0 })
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func renderMethod(_ method: MethodDecl) -> [String] {
        var lines = methodDocLines(method, extraDoc: Self.notificationDoc(method))
        for param in method.params {
            if let doc = param.doc, !doc.isEmpty {
                let oneLine = doc.split(separator: "\n").joined(separator: " ")
                lines.append("/// - Parameter \(param.swiftName): \(oneLine)")
            }
        }
        if method.deprecated {
            lines.append("@available(*, deprecated)")
        }
        lines.append("\(access.prefix)\(methodSignature(method, includeDefaults: true)) {")

        let methodLiteral = swiftStringLiteral(method.rpcName)
        // Methods without a result are sent as JSON-RPC notifications.
        let invocation = method.returnType == nil ? "try await rpc.notify" : "return try await rpc.call"

        let call: String
        if method.params.isEmpty {
            call = "\(invocation)(method: \(methodLiteral))"
        } else if method.byPosition {
            let elements = method.params
                .map { "AnyJSONRPCParam(\($0.swiftName))" }
                .joined(separator: ", ")
            lines.append("    let params: [AnyJSONRPCParam] = [\(elements)]")
            call = "\(invocation)(method: \(methodLiteral), params: params)"
        } else {
            lines.append("    struct Params: Encodable, Sendable {")
            for param in method.params {
                lines.append("        var \(param.swiftName): \(param.renderedType)")
            }
            lines.append(
                contentsOf: codingKeysLines(
                    for: method.params.map { ($0.swiftName, $0.jsonName) },
                    indent: "        "
                ))
            lines.append("    }")
            let arguments = method.params
                .map { "\($0.swiftName): \($0.swiftName)" }
                .joined(separator: ", ")
            call = "\(invocation)(method: \(methodLiteral), params: Params(\(arguments)))"
        }
        lines.append(contentsOf: invocationLines(call, for: method))
        lines.append("}")
        return lines
    }

    private func invocationLines(_ call: String, for method: MethodDecl) -> [String] {
        guard method.mapsServerErrors, let errorTypeName else { return ["    " + call] }
        return [
            "    do {",
            "        " + call,
            "    } catch let JSONRPCError.server(error) {",
            "        throw \(errorTypeName)(error) ?? JSONRPCError.server(error)",
            "    }",
        ]
    }

    /// The doc line added to methods sent as notifications; nil for methods
    /// with a result.
    private static func notificationDoc(_ method: MethodDecl) -> String? {
        guard method.returnType == nil else { return nil }
        return "/// Sent as a JSON-RPC notification: the request carries no id and no response is awaited."
    }
}
