public import ArgumentParser
import Foundation
public import OpenRPCGeneratorKit

@main
struct OpenRPCGeneratorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-openrpc-generator",
        abstract: "Generate a Swift JSON-RPC client and server from an OpenRPC document.",
        version: "0.1.0"
    )

    enum ComponentSelection: String, ExpressibleByArgument {
        case all, client, server

        var generatedComponents: Set<GeneratedComponent> {
            switch self {
            case .all: return [.client, .server]
            case .client: return [.client]
            case .server: return [.server]
            }
        }
    }

    @Argument(help: "Path to an OpenRPC document (JSON).")
    var input: String

    @Option(name: .shortAndLong, help: "Output directory.")
    var output: String = "./Generated"

    @Option(
        name: [.customShort("n"), .customLong("name")],
        help: "Type name of the generated client (derived from info.title when omitted)."
    )
    var clientName: String?

    @Option(name: .shortAndLong, help: "Access level of the generated code (public / package / internal).")
    var access: AccessLevel = .public

    @Option(name: .shortAndLong, help: "Which components to generate (all / client / server).")
    var components: ComponentSelection = .all

    @Flag(name: .customLong("allow-remote-refs"), help: "Allow $refs to remote http(s) documents.")
    var allowRemoteRefs = false

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let data: Data
        do {
            data = try Data(contentsOf: inputURL)
        } catch {
            throw RuntimeError("Cannot read input file \(input): \(error.localizedDescription)")
        }

        let document: OpenRPCDocument
        do {
            document = try OpenRPCDocument.parse(
                data: data,
                baseURL: inputURL,
                allowsRemoteReferences: allowRemoteRefs
            )
        } catch {
            if case .dereferencing(.remoteReferencesDisabled) = error {
                throw RuntimeError("\(error). Pass --allow-remote-refs to enable them.")
            }
            throw RuntimeError("Failed to parse the OpenRPC document: \(error)")
        }

        let generator = OpenRPCSwiftGenerator(
            document: document,
            options: GeneratorOptions(
                clientName: clientName,
                accessLevel: access,
                components: components.generatedComponents
            )
        )
        let result = generator.generate()

        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        for file in result.files {
            let fileURL = outputURL.appendingPathComponent(file.name)
            try file.contents.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Generated: \(fileURL.path)")
        }

        for warning in result.warnings {
            FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8))
        }
    }
}

extension AccessLevel: ExpressibleByArgument {}

/// A runtime failure (as opposed to a usage error, which prints help text).
private struct RuntimeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
