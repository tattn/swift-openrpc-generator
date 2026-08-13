import Foundation

/// Renders resolved methods as a JSON-RPC server: a handler protocol the
/// application implements, plus a transport-agnostic dispatcher.
struct ServerRenderer {
    let access: AccessLevel
    let handlerName: String
    let serverName: String

    func render(methods: [MethodDecl], header: String) -> String {
        renderedFile([
            header,
            "import Foundation",
            renderHandlerProtocol(methods: methods),
            renderServer(methods: methods),
        ])
    }

    private func renderHandlerProtocol(methods: [MethodDecl]) -> String {
        renderProtocolDecl(
            name: handlerName,
            doc: [
                "The application-side implementation of the API.",
                "Implement this and wrap it in `\(serverName)` to serve requests.",
            ],
            methods: methods,
            access: access
        )
    }

    private func renderServer(methods: [MethodDecl]) -> String {
        var lines: [String] = []
        lines.append("/// A transport-agnostic JSON-RPC server for the API: feed request")
        lines.append("/// bodies to `handle(_:)` and send back the returned responses.")
        lines.append("\(access.prefix)struct \(serverName): Sendable {")
        lines.append("    private let handler: any \(handlerName)")
        lines.append("")
        lines.append("    \(access.prefix)init(handler: any \(handlerName)) {")
        lines.append("        self.handler = handler")
        lines.append("    }")
        lines.append("")
        lines.append("    /// Handles one JSON-RPC request body. Returns nil when no response")
        lines.append("    /// should be sent (the request was a notification).")
        lines.append("    \(access.prefix)func handle(_ body: Data) async -> Data? {")
        lines.append("        await JSONRPCServer.handle(body) { request in")
        lines.append("            try await dispatch(request)")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    private func dispatch(_ request: JSONRPCServerRequest) async throws -> Data? {")
        lines.append("        switch request.method {")
        for method in methods {
            lines.append(contentsOf: renderCase(method).map { "        " + $0 })
        }
        lines.append("        default:")
        lines.append("            throw JSONRPCErrorObject.methodNotFound(method: request.method)")
        lines.append("        }")
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func renderCase(_ method: MethodDecl) -> [String] {
        var lines: [String] = []
        lines.append("case \(swiftStringLiteral(method.rpcName)):")
        if !method.params.isEmpty {
            lines.append("    let params = JSONRPCParameters(request.params)")
        }
        // Params are accepted by-name and by-position alike, per JSON-RPC 2.0.
        let arguments = method.params.enumerated().map { index, param in
            let accessor = param.optional ? "optional" : "required"
            return "\(param.swiftName): try params.\(accessor)(\(swiftStringLiteral(param.jsonName)), at: \(index))"
        }.joined(separator: ", ")
        let call = "handler.\(method.funcName)(\(arguments))"
        if method.returnType == nil {
            lines.append("    try await \(call)")
            lines.append("    return try JSONRPCServer.resultResponse(id: request.id)")
        } else {
            lines.append("    let result = try await \(call)")
            lines.append("    return try JSONRPCServer.resultResponse(id: request.id, result: result)")
        }
        return lines
    }
}
