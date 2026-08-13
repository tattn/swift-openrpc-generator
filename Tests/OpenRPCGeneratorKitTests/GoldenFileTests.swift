import Foundation
import OpenRPCGeneratorKit
import Testing

/// Whole-file reference tests: the output generated from each example document
/// must match the files checked in under `Golden/<example>/`.
///
/// To re-record after an intentional output change:
///     RECORD_GOLDEN=1 swift test --filter GoldenFileTests
@Suite struct GoldenFileTests {
    @Test("Generated output matches the golden files", arguments: ["petstore", "features"])
    func matchesGolden(example: String) throws {
        let document = try parseExampleDocument(example)
        let output = OpenRPCSwiftGenerator(document: document).generate()
        let goldenDirectory = packageRoot.appendingPathComponent("Tests/OpenRPCGeneratorKitTests/Golden/\(example)")

        if ProcessInfo.processInfo.environment["RECORD_GOLDEN"] != nil {
            try record(output, into: goldenDirectory)
            Issue.record("Recorded \(output.files.count) golden files for \(example); re-run without RECORD_GOLDEN.")
            return
        }

        let goldenNames = try FileManager.default.contentsOfDirectory(atPath: goldenDirectory.path)
            .filter { $0.hasSuffix(".golden") }
            .map { String($0.dropLast(".golden".count)) }
        #expect(output.files.map(\.name).sorted() == goldenNames.sorted())

        for file in output.files {
            let goldenURL = goldenDirectory.appendingPathComponent(file.name + ".golden")
            let golden = try String(contentsOf: goldenURL, encoding: .utf8)
            if file.contents != golden {
                Issue.record(
                    "\(file.name) differs from its golden file\(firstDifference(file.contents, golden)); run with RECORD_GOLDEN=1 to re-record"
                )
            }
        }
    }

    private func record(_ output: GeneratorOutput, into directory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in output.files {
            let url = directory.appendingPathComponent(file.name + ".golden")
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func firstDifference(_ actual: String, _ golden: String) -> String {
        let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let goldenLines = golden.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, (actualLine, goldenLine)) in zip(actualLines, goldenLines).enumerated()
        where actualLine != goldenLine {
            return " (first difference at line \(index + 1): \"\(actualLine)\" vs \"\(goldenLine)\")"
        }
        if actualLines.count != goldenLines.count {
            return " (line counts differ: \(actualLines.count) vs \(goldenLines.count))"
        }
        return ""
    }
}
