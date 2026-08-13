import Dispatch
public import Foundation
import Synchronization

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A failure while resolving the `$ref`s of an OpenRPC document.
public enum DereferenceError: Error, CustomStringConvertible, LocalizedError {
    /// The `$ref` string is not a valid reference.
    case invalidReference(String)
    /// The `$ref` does not point to an existing value.
    case unresolvedPointer(String)
    /// A referenced external document could not be loaded.
    case unreadableDocument(URL, underlying: any Error)
    /// The `$ref` points to a remote document, and remote reference loading
    /// is disabled (the default).
    case remoteReferencesDisabled(URL)

    public var description: String {
        switch self {
        case .invalidReference(let ref):
            return "Invalid $ref \"\(ref)\""
        case .unresolvedPointer(let ref):
            return "$ref \"\(ref)\" does not point to an existing value"
        case .unreadableDocument(let url, let underlying):
            return "Cannot load referenced document \(url.absoluteString): \(underlying)"
        case .remoteReferencesDisabled(let url):
            return "$ref to remote document \(url.absoluteString) is not allowed"
                + " (remote reference loading is disabled by default)"
        }
    }

    public var errorDescription: String? { description }
}

/// Resolves `$ref`s that the code generator cannot handle itself, before the
/// document is decoded. This mirrors the official generator pipeline, which
/// dereferences the document ahead of type generation.
///
/// - `$ref`s into `#/components/schemas/` and `#/components/contentDescriptors/`
///   of the root document are left in place: the generator resolves those, and
///   schema references may legitimately be recursive.
/// - Every other `$ref` — inside `methods`, other internal pointers, and
///   references to external documents (relative paths or URLs) — is replaced
///   by the referenced value. References inside inlined external content are
///   resolved against the external document.
/// - External targets that sit on a reference cycle cannot be inlined (their
///   expansion would never terminate). They are hoisted into the root
///   document's components/schemas and all references to them rewrite to
///   local component refs, so the generator's recursion machinery applies.
/// - Cyclic references inside the root document that are not component refs
///   are left as-is; the generator falls back to `JSONValue` with a warning.
struct DocumentDereferencer {
    /// A document scope that references are resolved against.
    private struct DocumentContext {
        var root: JSONValue
        var url: URL?
        var isRootDocument: Bool
    }

    /// A resolved reference target inside some document.
    private struct Target {
        /// Identity of the target: "documentURL#pointer".
        var key: String
        var value: JSONValue
        var context: DocumentContext
    }

    /// The URL of the root document, used to resolve relative external refs.
    let baseURL: URL?
    /// Whether `$ref`s to remote http(s) documents may be fetched.
    let allowsRemoteReferences: Bool

    private var externalDocuments: [URL: JSONValue] = [:]
    /// Cyclic external target key → the component key it hoists into and
    /// the target itself.
    private var hoistedSchemas: [String: (componentKey: String, target: Target)] = [:]

    init(baseURL: URL?, allowsRemoteReferences: Bool = false) {
        self.baseURL = baseURL
        self.allowsRemoteReferences = allowsRemoteReferences
    }

    mutating func dereference(_ root: JSONValue) throws -> JSONValue {
        let rootContext = DocumentContext(root: root, url: baseURL, isRootDocument: true)
        try planHoisting(root: root, context: rootContext)
        let resolved = try resolve(root, context: rootContext, stack: [])
        return try insertHoistedSchemas(into: resolved)
    }

    // MARK: - Phase 1: reference-cycle analysis

    /// Scans the reference graph reachable from the root document and assigns
    /// component keys to external targets that can reach themselves.
    private mutating func planHoisting(root: JSONValue, context: DocumentContext) throws {
        let rootTarget = Target(key: Self.targetKey(url: baseURL, fragment: ""), value: root, context: context)
        var targets: [String: Target] = [rootTarget.key: rootTarget]
        var edges: [String: Set<String>] = [:]
        var pending = [rootTarget]
        while let current = pending.popLast() {
            var found: [Target] = []
            try collectRefTargets(in: current.value, context: current.context, into: &found)
            edges[current.key] = Set(found.map(\.key))
            for target in found where targets[target.key] == nil {
                targets[target.key] = target
                pending.append(target)
            }
        }

        var usedKeys = Set(componentSchemaKeys(of: root))
        for key in selfReachableNodes(in: edges).sorted() {
            guard let target = targets[key], !target.context.isRootDocument else { continue }
            let componentKey = SwiftNaming.uniqueName(preferredComponentKey(for: key), in: &usedKeys)
            hoistedSchemas[key] = (componentKey, target)
        }
    }

    /// The identity of a reference target.
    private static func targetKey(url: URL?, fragment: String) -> String {
        "\(url?.absoluteString ?? "")#\(fragment)"
    }

    private mutating func collectRefTargets(
        in node: JSONValue,
        context: DocumentContext,
        into found: inout [Target]
    ) throws {
        switch node {
        case .object(let object):
            if let ref = object["$ref"]?.stringValue {
                if context.isRootDocument, ComponentReference.isGeneratorHandled(ref) {
                    return
                }
                // Unresolvable pointers are reported by the resolve phase.
                if let target = try target(of: ref, context: context) {
                    found.append(target)
                }
                return
            }
            for value in object.values {
                try collectRefTargets(in: value, context: context, into: &found)
            }
        case .array(let array):
            for value in array {
                try collectRefTargets(in: value, context: context, into: &found)
            }
        default:
            break
        }
    }

    // MARK: - Phase 2: resolution

    private mutating func resolve(
        _ node: JSONValue,
        context: DocumentContext,
        stack: Set<String>
    ) throws -> JSONValue {
        switch node {
        case .object(let object):
            if let ref = object["$ref"]?.stringValue {
                if context.isRootDocument, ComponentReference.isGeneratorHandled(ref) {
                    return node
                }
                // nil means the reference is cyclic and stays in place; the
                // generator then degrades it to JSONValue with a warning.
                let resolved = try resolveReference(ref, context: context, stack: stack)
                return resolved ?? node
            }
            var resolved: [String: JSONValue] = [:]
            for (key, value) in object {
                resolved[key] = try resolve(value, context: context, stack: stack)
            }
            return .object(resolved)
        case .array(let array):
            return .array(try array.map { try resolve($0, context: context, stack: stack) })
        default:
            return node
        }
    }

    private mutating func resolveReference(
        _ ref: String,
        context: DocumentContext,
        stack: Set<String>
    ) throws -> JSONValue? {
        guard let target = try target(of: ref, context: context) else {
            throw DereferenceError.unresolvedPointer(ref)
        }
        if let componentKey = hoistedSchemas[target.key]?.componentKey {
            return .object(["$ref": .string("#/components/schemas/\(componentKey)")])
        }
        guard !stack.contains(target.key) else {
            return nil
        }
        return try resolve(target.value, context: target.context, stack: stack.union([target.key]))
    }

    /// Resolves a hoisted schema's own subtree (references to hoisted targets,
    /// including itself, rewrite to local component refs — preserving the
    /// recursion) and inserts it into the root document's components/schemas.
    private mutating func insertHoistedSchemas(into root: JSONValue) throws -> JSONValue {
        guard !hoistedSchemas.isEmpty, case .object(var rootObject) = root else { return root }
        var components: [String: JSONValue] = [:]
        if case .object(let existing)? = rootObject["components"] {
            components = existing
        }
        var schemas: [String: JSONValue] = [:]
        if case .object(let existing)? = components["schemas"] {
            schemas = existing
        }
        for (_, entry) in hoistedSchemas.sorted(by: { $0.key < $1.key }) {
            schemas[entry.componentKey] = try resolve(entry.target.value, context: entry.target.context, stack: [])
        }
        components["schemas"] = .object(schemas)
        rootObject["components"] = .object(components)
        return .object(rootObject)
    }

    // MARK: - Reference targets

    /// Resolves a reference string to its target. Returns nil when the
    /// pointer does not match a value.
    private mutating func target(of ref: String, context: DocumentContext) throws -> Target? {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let documentPart = String(parts[0])
        let fragment = parts.count > 1 ? String(parts[1]) : ""

        let targetContext: DocumentContext
        if documentPart.isEmpty {
            targetContext = context
        } else {
            guard let url = URL(string: documentPart, relativeTo: context.url)?.absoluteURL.standardized else {
                throw DereferenceError.invalidReference(ref)
            }
            targetContext = DocumentContext(
                root: try loadExternalDocument(at: url),
                url: url,
                isRootDocument: false
            )
        }
        guard let value = value(at: fragment, in: targetContext.root) else { return nil }
        return Target(
            key: Self.targetKey(url: targetContext.url, fragment: fragment),
            value: value,
            context: targetContext
        )
    }

    private mutating func loadExternalDocument(at url: URL) throws -> JSONValue {
        if let cached = externalDocuments[url] {
            return cached
        }
        let document = try JSONDecoder().decode(JSONValue.self, from: loadExternalData(at: url))
        externalDocuments[url] = document
        return document
    }

    private func loadExternalData(at url: URL) throws -> Data {
        if url.isFileURL {
            do {
                return try Data(contentsOf: url)
            } catch {
                throw DereferenceError.unreadableDocument(url, underlying: error)
            }
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DereferenceError.unreadableDocument(url, underlying: URLError(.unsupportedURL))
        }
        guard allowsRemoteReferences else {
            throw DereferenceError.remoteReferencesDisabled(url)
        }
        return try fetchRemoteDocument(at: url)
    }

    /// Shared across fetches so connections are reused when several
    /// referenced documents live on the same host.
    private static let remoteSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// Fetches a remote document synchronously with a request timeout.
    /// Dereferencing is a synchronous tree walk, so the wait happens here
    /// rather than making the whole pipeline async.
    private func fetchRemoteDocument(at url: URL) throws -> Data {
        let box = Mutex<Result<Data, any Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        Self.remoteSession.dataTask(with: url) { data, response, error in
            let result: Result<Data, any Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(HTTPStatusError(statusCode: http.statusCode))
            } else {
                result = .success(data ?? Data())
            }
            box.withLock { $0 = result }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        // The wait above guarantees the completion handler has filled the box.
        switch box.withLock({ $0 })! {
        case .success(let data):
            return data
        case .failure(let error):
            throw DereferenceError.unreadableDocument(url, underlying: error)
        }
    }

    /// Walks a JSON Pointer fragment ("/a/b/0") within a document.
    private func value(at pointer: String, in document: JSONValue) -> JSONValue? {
        guard !pointer.isEmpty else { return document }
        guard pointer.hasPrefix("/") else { return nil }
        var current = document
        for component in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let key = Self.unescapePointerToken(String(component))
            switch current {
            case .object(let object):
                guard let next = object[key] else { return nil }
                current = next
            case .array(let array):
                guard let index = Int(key), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    // MARK: - Hoisted component naming

    private func componentSchemaKeys(of root: JSONValue) -> [String] {
        guard case .object(let rootObject) = root,
            case .object(let components)? = rootObject["components"],
            case .object(let schemas)? = components["schemas"]
        else { return [] }
        return Array(schemas.keys)
    }

    /// Derives a component key from the target's pointer (its last segment),
    /// or from the document file name for whole-document references.
    private func preferredComponentKey(for targetKey: String) -> String {
        let parts = targetKey.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let fragment = parts.count > 1 ? String(parts[1]) : ""
        if let last = fragment.split(separator: "/").last, !last.isEmpty {
            return Self.unescapePointerToken(String(last))
        }
        let documentPart = String(parts[0])
        let stem = URL(string: documentPart)?.deletingPathExtension().lastPathComponent ?? ""
        return stem.isEmpty ? "Schema" : stem
    }

    /// RFC 6901 token unescaping; `~1` must be replaced before `~0`.
    private static func unescapePointerToken(_ token: String) -> String {
        token
            .replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
    }
}

/// A non-2xx response while fetching a remote document.
private struct HTTPStatusError: Error, CustomStringConvertible {
    let statusCode: Int

    var description: String { "HTTP status \(statusCode)" }
}
