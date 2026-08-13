import Foundation
import OpenRPCGeneratorKit

/// The package root, located from this file's position in the source tree.
let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // OpenRPCGeneratorKitTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // package root

/// The URL of an example document at `examples/<name>.openrpc.json`.
func exampleDocumentURL(_ name: String) -> URL {
    packageRoot.appendingPathComponent("examples/\(name).openrpc.json")
}

/// Parses an OpenRPC document from a file, resolving external references
/// relative to its location.
func parseDocument(at url: URL) throws -> OpenRPCDocument {
    try OpenRPCDocument.parse(data: Data(contentsOf: url), baseURL: url)
}

/// Parses the example document at `examples/<name>.openrpc.json`, resolving
/// external references relative to the document's location.
func parseExampleDocument(_ name: String) throws -> OpenRPCDocument {
    try parseDocument(at: exampleDocumentURL(name))
}

/// Runs `body` with a fresh temporary directory, removing it afterwards.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}
