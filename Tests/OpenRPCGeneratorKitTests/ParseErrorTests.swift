import Foundation
import OpenRPCGeneratorKit
import Testing

@Suite struct ParseErrorTests {
    /// Parses a minimal document whose `methods` array holds the given entry
    /// and returns the ParseError it throws (recording an issue when parsing
    /// succeeds).
    private func parseError(
        methods: String,
        baseURL: URL? = nil,
        allowsRemoteReferences: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> OpenRPCDocument.ParseError? {
        let json = """
            {
              "openrpc": "1.3.2",
              "info": { "title": "Test", "version": "0.1.0" },
              "methods": [ \(methods) ]
            }
            """
        return #expect(throws: OpenRPCDocument.ParseError.self, sourceLocation: sourceLocation) {
            try OpenRPCDocument.parse(
                data: Data(json.utf8),
                baseURL: baseURL,
                allowsRemoteReferences: allowsRemoteReferences
            )
        }
    }

    @Test("Malformed data throws ParseError.invalidDocument")
    func malformedDocument() {
        let error = #expect(throws: OpenRPCDocument.ParseError.self) {
            try OpenRPCDocument.parse(data: Data("not json".utf8))
        }
        guard case .invalidDocument = error else {
            Issue.record("Expected .invalidDocument, got \(String(describing: error))")
            return
        }
        #expect(error?.errorDescription?.isEmpty == false)
    }

    @Test("An unresolvable $ref throws ParseError.dereferencing(.unresolvedPointer)")
    func unresolvedPointer() {
        let error = parseError(methods: ##"{ "$ref": "#/does/not/exist" }"##)
        guard case .dereferencing(.unresolvedPointer(let ref)) = error else {
            Issue.record("Expected .dereferencing(.unresolvedPointer), got \(String(describing: error))")
            return
        }
        #expect(ref == "#/does/not/exist")
        #expect(error?.errorDescription?.contains("#/does/not/exist") == true)
    }

    @Test("A remote $ref is rejected unless allowsRemoteReferences is enabled")
    func remoteReferencesDisabledByDefault() {
        let error = parseError(methods: #"{ "$ref": "https://example.invalid/methods.json#/ping" }"#)
        guard case .dereferencing(.remoteReferencesDisabled(let url)) = error else {
            Issue.record("Expected .dereferencing(.remoteReferencesDisabled), got \(String(describing: error))")
            return
        }
        #expect(url.host == "example.invalid")
    }

    @Test("A $ref with an unsupported scheme throws .dereferencing(.unreadableDocument)")
    func unsupportedScheme() {
        let error = parseError(
            methods: #"{ "$ref": "ftp://example.invalid/methods.json#/ping" }"#,
            allowsRemoteReferences: true
        )
        guard case .dereferencing(.unreadableDocument) = error else {
            Issue.record("Expected .dereferencing(.unreadableDocument), got \(String(describing: error))")
            return
        }
    }

    @Test("A $ref to a missing external file throws ParseError.dereferencing(.unreadableDocument)")
    func unreadableExternalDocument() {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("doc.json")
        let error = parseError(methods: #"{ "$ref": "missing.json#/method" }"#, baseURL: baseURL)
        guard case .dereferencing(.unreadableDocument(let url, underlying: _)) = error else {
            Issue.record("Expected .dereferencing(.unreadableDocument), got \(String(describing: error))")
            return
        }
        #expect(url.lastPathComponent == "missing.json")
    }
}
