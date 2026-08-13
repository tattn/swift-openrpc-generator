import Foundation

/// Renders server-to-client notifications (methods marked
/// `x-direction: serverToClient`) as one enum shared by both sides:
/// servers encode a case into a request body, clients decode incoming
/// bodies back into a case.
struct NotificationsRenderer {
    let access: AccessLevel
    let typeName: String

    func render(notifications: [NotificationDecl], header: String) -> String {
        renderedFile([
            header,
            "import Foundation",
            renderEnum(notifications),
            renderEnvelope(),
        ])
    }

    private func renderEnum(_ notifications: [NotificationDecl]) -> String {
        var lines: [String] = []
        lines.append("/// The server-to-client notifications declared in the OpenRPC document.")
        lines.append("/// Servers encode one with `body()` and push it over their transport;")
        lines.append("/// clients decode incoming bodies with `decode(_:)`.")
        lines.append("\(access.prefix)enum \(typeName): Hashable, Sendable {")
        for notification in notifications {
            lines.append(contentsOf: docLines(notification.doc, indent: "    "))
            if notification.deprecated {
                lines.append("    @available(*, deprecated)")
            }
            lines.append("    case \(caseDeclaration(notification))")
        }
        lines.append("")
        lines.append(contentsOf: renderMethodName(notifications).map(indented))
        lines.append("")
        lines.append(contentsOf: renderBody(notifications).map(indented))
        lines.append("")
        lines.append(contentsOf: renderDecode(notifications).map(indented))
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func caseDeclaration(_ notification: NotificationDecl) -> String {
        guard !notification.params.isEmpty else { return notification.caseName }
        let payload = notification.params
            .map { "\($0.swiftName): \($0.renderedType)" }
            .joined(separator: ", ")
        return "\(notification.caseName)(\(payload))"
    }

    private func renderMethodName(_ notifications: [NotificationDecl]) -> [String] {
        var lines: [String] = []
        lines.append("/// The JSON-RPC method name of the notification.")
        lines.append("\(access.prefix)var method: String {")
        lines.append("    switch self {")
        for notification in notifications {
            lines.append(
                "    case .\(notification.caseName): return \(swiftStringLiteral(notification.rpcName))")
        }
        lines.append("    }")
        lines.append("}")
        return lines
    }

    private func renderBody(_ notifications: [NotificationDecl]) -> [String] {
        var lines: [String] = []
        lines.append("/// Encodes this notification as a JSON-RPC request body (no id,")
        lines.append("/// so no response is expected).")
        lines.append("\(access.prefix)func body() throws -> Data {")
        lines.append("    let encoder = JSONRPCCoding.encoder()")
        lines.append("    switch self {")
        for notification in notifications {
            lines.append(contentsOf: renderBodyCase(notification).map { "    " + $0 })
        }
        lines.append("    }")
        lines.append("}")
        return lines
    }

    private func renderBodyCase(_ notification: NotificationDecl) -> [String] {
        let methodLiteral = swiftStringLiteral(notification.rpcName)
        guard !notification.params.isEmpty else {
            return [
                "case .\(notification.caseName):",
                "    return try encoder.encode(\(typeName)Envelope<JSONRPCNoParams>(method: \(methodLiteral), params: nil))",
            ]
        }

        let bindings = notification.params
            .map { "let \($0.swiftName)" }
            .joined(separator: ", ")
        var lines = ["case .\(notification.caseName)(\(bindings)):"]
        if notification.byPosition {
            let elements = notification.params
                .map { "AnyJSONRPCParam(\($0.swiftName))" }
                .joined(separator: ", ")
            lines.append("    let params: [AnyJSONRPCParam] = [\(elements)]")
        } else {
            lines.append("    struct Params: Encodable, Sendable {")
            for param in notification.params {
                lines.append("        var \(param.swiftName): \(param.renderedType)")
            }
            lines.append(
                contentsOf: codingKeysLines(
                    for: notification.params.map { ($0.swiftName, $0.jsonName) },
                    indent: "        "
                ))
            lines.append("    }")
            let arguments = notification.params
                .map { "\($0.swiftName): \($0.swiftName)" }
                .joined(separator: ", ")
            lines.append("    let params = Params(\(arguments))")
        }
        lines.append(
            "    return try encoder.encode(\(typeName)Envelope(method: \(methodLiteral), params: params))")
        return lines
    }

    private func renderDecode(_ notifications: [NotificationDecl]) -> [String] {
        var lines: [String] = []
        lines.append("/// Decodes a server-to-client notification body. Returns nil when the")
        lines.append("/// body is not a notification or its method is not declared, so callers")
        lines.append("/// can skip unknown notifications for forward compatibility.")
        lines.append("\(access.prefix)static func decode(_ body: Data) throws -> Self? {")
        lines.append("    let request = try JSONRPCCoding.decoder().decode(JSONRPCServerRequest.self, from: body)")
        lines.append("    guard request.id == nil else { return nil }")
        lines.append("    switch request.method {")
        for notification in notifications {
            lines.append(contentsOf: renderDecodeCase(notification).map { "    " + $0 })
        }
        lines.append("    default:")
        lines.append("        return nil")
        lines.append("    }")
        lines.append("}")
        return lines
    }

    private func renderDecodeCase(_ notification: NotificationDecl) -> [String] {
        var lines = ["case \(swiftStringLiteral(notification.rpcName)):"]
        guard !notification.params.isEmpty else {
            lines.append("    return .\(notification.caseName)")
            return lines
        }
        lines.append("    let params = JSONRPCParameters(request.params)")
        // Params are accepted by-name and by-position alike, per JSON-RPC 2.0.
        let arguments = notification.params.enumerated().map { index, param in
            let accessor = param.optional ? "optional" : "required"
            return "\(param.swiftName): try params.\(accessor)(\(swiftStringLiteral(param.jsonName)), at: \(index))"
        }.joined(separator: ", ")
        lines.append("    return .\(notification.caseName)(\(arguments))")
        return lines
    }

    /// The JSON-RPC notification envelope: a request without an id.
    private func renderEnvelope() -> String {
        """
        private struct \(typeName)Envelope<Params: Encodable>: Encodable {
            let jsonrpc = "2.0"
            let method: String
            let params: Params?
        }
        """
    }

    private func indented(_ line: String) -> String {
        line.isEmpty ? line : "    " + line
    }
}
