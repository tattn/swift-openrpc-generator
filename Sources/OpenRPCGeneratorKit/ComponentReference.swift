import Foundation

/// Parsing for `#/components/<kind>/<key>` references — the single source of
/// truth for which refs the generator resolves itself. The dereferencer leaves
/// exactly these refs in place (schema refs may legitimately be recursive) and
/// inlines everything else.
enum ComponentReference {
    /// The component kinds `CodegenContext` can resolve.
    static let generatorHandledKinds = ["schemas", "contentDescriptors", "errors"]

    /// Extracts the key from a `#/components/<kind>/<key>` reference.
    static func key(of ref: String, kind: String) -> String? {
        let prefix = "#/components/\(kind)/"
        guard ref.hasPrefix(prefix) else { return nil }
        return String(ref.dropFirst(prefix.count))
    }

    static func isGeneratorHandled(_ ref: String) -> Bool {
        generatorHandledKinds.contains { key(of: ref, kind: $0) != nil }
    }
}
