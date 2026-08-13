import Foundation

/// The JSON-RPC 2.0 runtime bundled with the generated code.
/// Emitted as source (rather than a library dependency) so the generated
/// output is self-contained.
enum RuntimeTemplate {
    static func render(access: AccessLevel, header: String) -> String {
        let acc = access.prefix
        return """
            \(header)
            import Foundation
            import Synchronization
            #if canImport(FoundationNetworking)
            import FoundationNetworking
            #endif

            /// A JSON value of arbitrary structure. Used where the schema cannot
            /// pin down a concrete type. Integers get their own case so they
            /// round-trip exactly (no precision loss for large IDs).
            /// Keep in sync with the generator's own JSONValue (JSONValue.swift).
            \(acc)enum JSONValue: Codable, Hashable, Sendable {
                case null
                case bool(Bool)
                case int(Int)
                case number(Double)
                case string(String)
                case array([JSONValue])
                case object([String: JSONValue])

                \(acc)init(from decoder: any Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if container.decodeNil() {
                        self = .null
                    } else if let value = try? container.decode(Bool.self) {
                        self = .bool(value)
                    } else if let value = try? container.decode(Int.self) {
                        self = .int(value)
                    } else if let value = try? container.decode(Double.self) {
                        self = .number(value)
                    } else if let value = try? container.decode(String.self) {
                        self = .string(value)
                    } else if let value = try? container.decode([JSONValue].self) {
                        self = .array(value)
                    } else if let value = try? container.decode([String: JSONValue].self) {
                        self = .object(value)
                    } else {
                        throw DecodingError.dataCorruptedError(
                            in: container,
                            debugDescription: "Unsupported JSON value"
                        )
                    }
                }

                \(acc)func encode(to encoder: any Encoder) throws {
                    var container = encoder.singleValueContainer()
                    switch self {
                    case .null: try container.encodeNil()
                    case .bool(let value): try container.encode(value)
                    case .int(let value): try container.encode(value)
                    case .number(let value): try container.encode(value)
                    case .string(let value): try container.encode(value)
                    case .array(let value): try container.encode(value)
                    case .object(let value): try container.encode(value)
                    }
                }
            }

            /// A type-erased Encodable for positional (by-position) JSON-RPC params.
            \(acc)struct AnyJSONRPCParam: Encodable, Sendable {
                private let encodeValue: @Sendable (any Encoder) throws -> Void

                \(acc)init<Value: Encodable & Sendable>(_ value: Value?) {
                    encodeValue = { encoder in
                        var container = encoder.singleValueContainer()
                        if let value {
                            try container.encode(value)
                        } else {
                            try container.encodeNil()
                        }
                    }
                }

                \(acc)func encode(to encoder: any Encoder) throws {
                    try encodeValue(encoder)
                }
            }

            /// A copy-on-write box that breaks recursion in generated value types
            /// (a struct cannot directly contain itself). Mutation copies the
            /// storage only when it is shared, preserving value semantics.
            \(acc)struct Indirect<Wrapped> {
                private final class Storage {
                    var value: Wrapped
                    init(_ value: Wrapped) { self.value = value }
                }

                private var storage: Storage

                \(acc)init(_ wrappedValue: Wrapped) {
                    storage = Storage(wrappedValue)
                }

                \(acc)var wrappedValue: Wrapped {
                    get { storage.value }
                    set {
                        if isKnownUniquelyReferenced(&storage) {
                            storage.value = newValue
                        } else {
                            storage = Storage(newValue)
                        }
                    }
                }
            }

            extension Indirect: Encodable where Wrapped: Encodable {
                \(acc)func encode(to encoder: any Encoder) throws {
                    try wrappedValue.encode(to: encoder)
                }
            }

            extension Indirect: Decodable where Wrapped: Decodable {
                \(acc)init(from decoder: any Decoder) throws {
                    self.init(try Wrapped(from: decoder))
                }
            }

            extension Indirect: Equatable where Wrapped: Equatable {
                \(acc)static func == (lhs: Indirect, rhs: Indirect) -> Bool {
                    lhs.wrappedValue == rhs.wrappedValue
                }
            }

            extension Indirect: Hashable where Wrapped: Hashable {
                \(acc)func hash(into hasher: inout Hasher) {
                    hasher.combine(wrappedValue)
                }
            }

            // Safe: mutation only ever writes to uniquely-referenced storage.
            extension Indirect: @unchecked Sendable where Wrapped: Sendable {}

            /// The JSON coding configuration shared by every generated
            /// encode/decode: dates use ISO 8601 (accepting fractional
            /// seconds on input), and Data uses base64 (Codable's default).
            \(acc)enum JSONRPCCoding {
                \(acc)static func encoder() -> JSONEncoder {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    return encoder
                }

                \(acc)static func decoder() -> JSONDecoder {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .custom { decoder in
                        let container = try decoder.singleValueContainer()
                        let text = try container.decode(String.self)
                        if let date = parseISO8601(text) {
                            return date
                        }
                        throw DecodingError.dataCorruptedError(
                            in: container,
                            debugDescription: "Not an ISO 8601 date: \\(text)"
                        )
                    }
                    return decoder
                }

                private static let iso8601WithFractionalSeconds =
                    Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                private static let iso8601 = Date.ISO8601FormatStyle()

                private static func parseISO8601(_ text: String) -> Date? {
                    (try? iso8601WithFractionalSeconds.parse(text)) ?? (try? iso8601.parse(text))
                }
            }

            /// An error that maps itself to a JSON-RPC error object. Generated
            /// error enums conform, so handlers can throw their typed errors
            /// and servers respond with the declared code.
            \(acc)protocol JSONRPCErrorConvertible: Error {
                var errorObject: JSONRPCErrorObject { get }
            }

            /// A JSON-RPC 2.0 error object. Conforms to Error so server-side
            /// handlers can throw it directly with a specific code.
            \(acc)struct JSONRPCErrorObject: Codable, Hashable, JSONRPCErrorConvertible, Sendable {
                \(acc)var errorObject: JSONRPCErrorObject { self }
                \(acc)let code: Int
                \(acc)let message: String
                \(acc)let data: JSONValue?

                \(acc)init(code: Int, message: String, data: JSONValue? = nil) {
                    self.code = code
                    self.message = message
                    self.data = data
                }

                /// The predefined "Method not found" (-32601) error, thrown by
                /// generated servers for unrecognized method names.
                \(acc)static func methodNotFound(method: String) -> JSONRPCErrorObject {
                    JSONRPCErrorObject(code: -32601, message: "Method not found: \\(method)")
                }
            }

            \(acc)enum JSONRPCError: Error, Sendable {
                /// The server returned an error response.
                case server(JSONRPCErrorObject)
                /// An HTTP-level error (non-2xx status).
                case http(statusCode: Int, body: Data)
                /// The response cannot be interpreted as JSON-RPC 2.0.
                case invalidResponse(String)
            }

            /// Sends a request body and returns the response body.
            /// For non-HTTP transports (WebSocket etc.), conform to this
            /// protocol and pass the transport to the client.
            \(acc)protocol JSONRPCTransport: Sendable {
                func send(_ body: Data) async throws -> Data
            }

            /// An HTTP(S) POST transport backed by URLSession.
            \(acc)struct HTTPJSONRPCTransport: JSONRPCTransport {
                \(acc)var url: URL
                \(acc)var additionalHeaders: [String: String]
                \(acc)var session: URLSession

                \(acc)init(url: URL, additionalHeaders: [String: String] = [:], session: URLSession = .shared) {
                    self.url = url
                    self.additionalHeaders = additionalHeaders
                    self.session = session
                }

                \(acc)func send(_ body: Data) async throws -> Data {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    for (field, value) in additionalHeaders {
                        request.setValue(value, forHTTPHeaderField: field)
                    }
                    request.httpBody = body
                    let (data, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw JSONRPCError.http(statusCode: http.statusCode, body: data)
                    }
                    return data
                }
            }

            /// Builds, sends, and decodes JSON-RPC 2.0 calls. Only ID generation
            /// is synchronized, so concurrent calls encode and decode in parallel.
            \(acc)final class JSONRPCClient: Sendable {
                private let transport: any JSONRPCTransport
                private let nextID = Mutex(0)

                \(acc)init(transport: any JSONRPCTransport) {
                    self.transport = transport
                }

                \(acc)func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
                    method: String,
                    params: Params
                ) async throws -> Result {
                    try await perform(JSONRPCRequest(id: makeID(), method: method, params: params))
                }

                \(acc)func call<Result: Decodable & Sendable>(method: String) async throws -> Result {
                    try await perform(JSONRPCRequest<JSONRPCNoParams>(id: makeID(), method: method, params: nil))
                }

                /// Sends a JSON-RPC notification: the request carries no id and
                /// no response is decoded.
                \(acc)func notify<Params: Encodable & Sendable>(method: String, params: Params) async throws {
                    _ = try await post(JSONRPCRequest(id: nil, method: method, params: params))
                }

                /// Sends a JSON-RPC notification without params.
                \(acc)func notify(method: String) async throws {
                    _ = try await post(JSONRPCRequest<JSONRPCNoParams>(id: nil, method: method, params: nil))
                }

                private func makeID() -> Int {
                    nextID.withLock { id in
                        id += 1
                        return id
                    }
                }

                private func post<Params: Encodable>(_ request: JSONRPCRequest<Params>) async throws -> Data {
                    try await transport.send(JSONRPCCoding.encoder().encode(request))
                }

                private func perform<Params: Encodable, Result: Decodable>(
                    _ request: JSONRPCRequest<Params>
                ) async throws -> Result {
                    let responseBody = try await post(request)
                    let response: JSONRPCResponse<Result>
                    do {
                        response = try JSONRPCCoding.decoder().decode(JSONRPCResponse<Result>.self, from: responseBody)
                    } catch {
                        throw JSONRPCError.invalidResponse(String(describing: error))
                    }
                    if let error = response.error {
                        throw JSONRPCError.server(error)
                    }
                    guard let result = response.result else {
                        throw JSONRPCError.invalidResponse("Response contains neither result nor error")
                    }
                    return result
                }
            }

            /// A placeholder for calls without params. Never actually encoded.
            \(acc)struct JSONRPCNoParams: Encodable, Sendable {}

            /// A decoded JSON-RPC 2.0 request as received by a server.
            \(acc)struct JSONRPCServerRequest: Decodable, Sendable {
                /// nil when the request is a notification (no id member);
                /// `id: null` stays distinguishable as `.null`.
                \(acc)let id: JSONValue?
                \(acc)let jsonrpc: String?
                \(acc)let method: String
                \(acc)let params: JSONValue?

                private enum CodingKeys: String, CodingKey {
                    case jsonrpc, id, method, params
                }

                \(acc)init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    id = container.contains(.id) ? try container.decode(JSONValue.self, forKey: .id) : nil
                    jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
                    method = try container.decode(String.self, forKey: .method)
                    params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
                }
            }

            /// Extracts typed parameters from a request, accepting both the
            /// by-name (object) and by-position (array) forms.
            \(acc)struct JSONRPCParameters: Sendable {
                private let value: JSONValue?
                // One coder pair per request, not per parameter.
                private let decoder = JSONRPCCoding.decoder()
                private let encoder = JSONRPCCoding.encoder()

                \(acc)init(_ value: JSONValue?) {
                    self.value = value
                }

                \(acc)func required<Value: Decodable>(_ name: String, at index: Int) throws -> Value {
                    guard let raw = rawValue(name: name, index: index) else {
                        throw JSONRPCErrorObject(code: -32602, message: "Missing required parameter \\"\\(name)\\"")
                    }
                    return try decode(Value.self, from: raw, name: name)
                }

                \(acc)func optional<Value: Decodable>(_ name: String, at index: Int) throws -> Value? {
                    guard let raw = rawValue(name: name, index: index) else { return nil }
                    if case .null = raw { return nil }
                    return try decode(Value.self, from: raw, name: name)
                }

                private func rawValue(name: String, index: Int) -> JSONValue? {
                    switch value {
                    case .object(let object): return object[name]
                    case .array(let array): return array.indices.contains(index) ? array[index] : nil
                    default: return nil
                    }
                }

                private func decode<Value: Decodable>(
                    _ type: Value.Type, from raw: JSONValue, name: String
                ) throws -> Value {
                    do {
                        return try decoder.decode(Value.self, from: encoder.encode(raw))
                    } catch {
                        throw JSONRPCErrorObject(code: -32602, message: "Invalid parameter \\"\\(name)\\"")
                    }
                }
            }

            /// Envelope parsing and response encoding for generated servers.
            /// Transport-agnostic: feed a request body in, send the returned
            /// response body back (nil means the request was a notification).
            \(acc)enum JSONRPCServer {
                \(acc)static func handle(
                    _ body: Data,
                    dispatch: (JSONRPCServerRequest) async throws -> Data?
                ) async -> Data? {
                    // A batch (array of requests) answers with an array of the
                    // responses to its non-notification elements. Batch vs
                    // single is decided by the first non-whitespace byte, so
                    // the common single-request case is parsed only once.
                    if body.first(where: { !Self.jsonWhitespace.contains($0) }) == UInt8(ascii: "[") {
                        guard let batch = try? JSONRPCCoding.decoder().decode([LenientRequest].self, from: body) else {
                            return errorResponse(id: .null, error: parseError)
                        }
                        guard !batch.isEmpty else {
                            return errorResponse(
                                id: .null, error: JSONRPCErrorObject(code: -32600, message: "Invalid request: empty batch"))
                        }
                        var responses: [Data] = []
                        for element in batch {
                            guard let response = await respond(to: element.request, dispatch: dispatch) else { continue }
                            responses.append(response)
                        }
                        guard !responses.isEmpty else { return nil }
                        // Each response is already valid JSON, so the batch
                        // response is assembled without re-encoding.
                        return joinedJSONArray(responses)
                    }
                    let request = try? JSONRPCCoding.decoder().decode(JSONRPCServerRequest.self, from: body)
                    return await respond(to: request, dispatch: dispatch)
                }

                private static let jsonWhitespace = Set(" \\t\\r\\n".utf8)
                private static let parseError = JSONRPCErrorObject(code: -32700, message: "Parse error")

                /// A batch element decoded leniently: `request` is nil when the
                /// element is not a structurally valid request, so it gets its
                /// own error response without failing the whole batch.
                private struct LenientRequest: Decodable {
                    let request: JSONRPCServerRequest?

                    init(from decoder: any Decoder) throws {
                        request = try? JSONRPCServerRequest(from: decoder)
                    }
                }

                private static func respond(
                    to request: JSONRPCServerRequest?,
                    dispatch: (JSONRPCServerRequest) async throws -> Data?
                ) async -> Data? {
                    guard let request else {
                        return errorResponse(id: .null, error: parseError)
                    }
                    guard request.jsonrpc == "2.0" else {
                        let error = JSONRPCErrorObject(code: -32600, message: "Invalid request: jsonrpc must be \\"2.0\\"")
                        return errorResponse(id: request.id ?? .null, error: error)
                    }
                    do {
                        return try await dispatch(request)
                    } catch {
                        // Notifications get no response, not even an error.
                        guard let id = request.id else { return nil }
                        let errorObject =
                            (error as? any JSONRPCErrorConvertible)?.errorObject
                            ?? JSONRPCErrorObject(code: -32603, message: "Internal error: \\(error)")
                        return errorResponse(id: id, error: errorObject)
                    }
                }

                /// Encodes a result response; nil when the request was a notification.
                \(acc)static func resultResponse<Result: Encodable>(id: JSONValue?, result: Result) throws -> Data? {
                    guard let id else { return nil }
                    return try JSONRPCCoding.encoder().encode(ServerResponse(id: id, result: result, error: nil))
                }

                /// Encodes a null-result response, for methods that return nothing.
                \(acc)static func resultResponse(id: JSONValue?) throws -> Data? {
                    try resultResponse(id: id, result: JSONValue.null)
                }

                \(acc)static func errorResponse(id: JSONValue, error: JSONRPCErrorObject) -> Data {
                    let encoder = JSONRPCCoding.encoder()
                    if let body = try? encoder.encode(ServerResponse<JSONValue>(id: id, result: nil, error: error)) {
                        return body
                    }
                    // error.data can hold values JSON cannot represent (non-finite
                    // numbers); strip it rather than dropping the response. The
                    // stripped form always encodes: ids come from parsed JSON.
                    let stripped = JSONRPCErrorObject(code: error.code, message: error.message)
                    return try! encoder.encode(ServerResponse<JSONValue>(id: id, result: nil, error: stripped))
                }

                private struct ServerResponse<Result: Encodable>: Encodable {
                    let jsonrpc = "2.0"
                    let id: JSONValue
                    let result: Result?
                    let error: JSONRPCErrorObject?
                }
            }

            /// Collects concurrent calls into a single JSON-RPC batch request.
            /// Buffers each call and flushes automatically once `expecting`
            /// calls have arrived, so `async let` fan-out is race-free:
            ///
            ///     let batcher = JSONRPCBatcher(transport: http, expecting: 2)
            ///     let client = MyClient(transport: batcher)
            ///     async let a = client.foo()
            ///     async let b = client.bar()
            ///
            /// Use one JSONRPCClient (one generated client) per batcher so
            /// request ids stay unique within the batch.
            \(acc)actor JSONRPCBatcher: JSONRPCTransport {
                private struct PendingCall {
                    let id: Int?
                    let body: Data
                    let continuation: CheckedContinuation<Data, any Error>
                }

                private let transport: any JSONRPCTransport
                private let expecting: Int
                private var buffered: [PendingCall] = []

                \(acc)init(transport: any JSONRPCTransport, expecting: Int) {
                    self.transport = transport
                    self.expecting = expecting
                }

                \(acc)func send(_ body: Data) async throws -> Data {
                    struct Probe: Decodable {
                        let id: Int?
                    }
                    let id = (try? JSONRPCCoding.decoder().decode(Probe.self, from: body))?.id
                    return try await withCheckedThrowingContinuation { continuation in
                        buffered.append(PendingCall(id: id, body: body, continuation: continuation))
                        if buffered.count >= expecting {
                            let batch = buffered
                            buffered = []
                            Task { await self.flush(batch) }
                        }
                    }
                }

                private func flush(_ batch: [PendingCall]) async {
                    do {
                        // Each buffered body is already valid JSON, so the batch
                        // is assembled without re-encoding the requests.
                        let responseBody = try await transport.send(joinedJSONArray(batch.map(\\.body)))
                        let responses = try JSONRPCCoding.decoder().decode([JSONValue].self, from: responseBody)
                        var responsesByID: [Int: JSONValue] = [:]
                        for response in responses {
                            if case .object(let object) = response, case .int(let id)? = object["id"] {
                                responsesByID[id] = response
                            }
                        }
                        let encoder = JSONRPCCoding.encoder()
                        for call in batch {
                            guard let id = call.id else {
                                // Notifications get no response.
                                call.continuation.resume(returning: Data())
                                continue
                            }
                            if let response = responsesByID[id] {
                                call.continuation.resume(returning: try encoder.encode(response))
                            } else {
                                call.continuation.resume(
                                    throwing: JSONRPCError.invalidResponse("No batch response for request id \\(id)"))
                            }
                        }
                    } catch {
                        for call in batch {
                            call.continuation.resume(throwing: error)
                        }
                    }
                }
            }

            /// A bidirectional JSON-RPC connection over any message pipe (a
            /// WebSocket, a local socket, an in-process channel). Correlates
            /// outgoing calls with responses by id, and dispatches incoming
            /// requests to an optional local server — so two peers can expose
            /// APIs to each other over a single connection.
            \(acc)actor JSONRPCConnection: JSONRPCTransport {
                \(acc)typealias SendMessage = @Sendable (Data) async throws -> Void
                \(acc)typealias HandleRequest = @Sendable (Data) async -> Data?

                private let sendMessage: SendMessage
                private let requestHandler: HandleRequest?
                private var nextID = 0
                private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
                private var closeError: (any Error)?

                /// - Parameters:
                ///   - send: writes one outgoing message to the pipe.
                ///   - requestHandler: serves the peer's incoming requests,
                ///     typically a generated server's `handle(_:)`.
                \(acc)init(send: @escaping SendMessage, requestHandler: HandleRequest? = nil) {
                    self.sendMessage = send
                    self.requestHandler = requestHandler
                }

                /// Sends one request and awaits its response. Request ids are
                /// rewritten into the connection's own namespace, so multiple
                /// generated clients can safely share one connection.
                \(acc)func send(_ body: Data) async throws -> Data {
                    if let closeError {
                        throw closeError
                    }
                    let message = try JSONRPCCoding.decoder().decode(JSONValue.self, from: body)
                    guard case .object(var object) = message else {
                        throw JSONRPCError.invalidResponse("Not a JSON-RPC request")
                    }
                    guard object["id"] != nil else {
                        // Notification: nothing to await.
                        try await sendMessage(body)
                        return Data()
                    }
                    nextID += 1
                    let id = nextID
                    object["id"] = .int(id)
                    let rewritten = try JSONRPCCoding.encoder().encode(JSONValue.object(object))
                    return try await withCheckedThrowingContinuation { continuation in
                        pending[id] = continuation
                        Task {
                            do {
                                try await self.sendMessage(rewritten)
                            } catch {
                                // The Task inherits this actor's isolation, so the call is direct
                                self.fail(id: id, with: error)
                            }
                        }
                    }
                }

                /// Feeds one incoming message from the pipe: responses resume
                /// their waiting call, requests go to the local server.
                \(acc)func receive(_ message: Data) {
                    struct Probe: Decodable {
                        let id: JSONValue?
                        let method: String?
                    }
                    guard let probe = try? JSONRPCCoding.decoder().decode(Probe.self, from: message) else {
                        return
                    }
                    if probe.method != nil {
                        guard let requestHandler else {
                            if let id = probe.id {
                                let error = JSONRPCErrorObject(code: -32601, message: "No handler on this peer")
                                Task { try? await self.sendMessage(JSONRPCServer.errorResponse(id: id, error: error)) }
                            }
                            return
                        }
                        Task {
                            if let response = await requestHandler(message) {
                                try? await self.sendMessage(response)
                            }
                        }
                    } else if case .int(let id)? = probe.id, let continuation = pending.removeValue(forKey: id) {
                        continuation.resume(returning: message)
                    }
                }

                /// Fails all in-flight and future calls, e.g. when the pipe closes.
                \(acc)func close(with error: any Error = CancellationError()) {
                    closeError = error
                    for continuation in pending.values {
                        continuation.resume(throwing: error)
                    }
                    pending.removeAll()
                }

                private func fail(id: Int, with error: any Error) {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }

            /// A persistent WebSocket transport built on URLSessionWebSocketTask.
            /// Supports concurrent in-flight calls; pass a `requestHandler`
            /// (typically a generated server's `handle(_:)`) to also serve the
            /// peer's requests over the same connection.
            \(acc)final class WebSocketJSONRPCTransport: JSONRPCTransport {
                private let task: URLSessionWebSocketTask
                private let connection: JSONRPCConnection

                \(acc)init(
                    url: URL,
                    session: URLSession = .shared,
                    requestHandler: JSONRPCConnection.HandleRequest? = nil
                ) {
                    let task = session.webSocketTask(with: url)
                    self.task = task
                    self.connection = JSONRPCConnection(
                        send: { data in try await task.send(.data(data)) },
                        requestHandler: requestHandler
                    )
                    task.resume()
                    receiveLoop()
                }

                deinit {
                    task.cancel(with: .goingAway, reason: nil)
                }

                \(acc)func send(_ body: Data) async throws -> Data {
                    try await connection.send(body)
                }

                /// Closes the socket and fails all in-flight calls.
                \(acc)func cancel() {
                    task.cancel(with: .normalClosure, reason: nil)
                    Task { await connection.close() }
                }

                private func receiveLoop() {
                    Task { [task, connection] in
                        while true {
                            do {
                                switch try await task.receive() {
                                case .data(let data): await connection.receive(data)
                                case .string(let text): await connection.receive(Data(text.utf8))
                                @unknown default: break
                                }
                            } catch {
                                await connection.close(with: error)
                                return
                            }
                        }
                    }
                }
            }

            /// Joins already-encoded JSON bodies into a JSON array without
            /// re-encoding them.
            private func joinedJSONArray(_ elements: [Data]) -> Data {
                var body = Data("[".utf8)
                for (index, element) in elements.enumerated() {
                    if index > 0 { body.append(UInt8(ascii: ",")) }
                    body.append(element)
                }
                body.append(UInt8(ascii: "]"))
                return body
            }

            private struct JSONRPCRequest<Params: Encodable>: Encodable {
                let jsonrpc = "2.0"
                /// nil for notifications; the key is omitted from the payload.
                let id: Int?
                let method: String
                let params: Params?
            }

            private struct JSONRPCResponse<Result: Decodable>: Decodable {
                let result: Result?
                let error: JSONRPCErrorObject?

                private enum CodingKeys: String, CodingKey {
                    case result, error
                }

                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    if let error = try container.decodeIfPresent(JSONRPCErrorObject.self, forKey: .error) {
                        self.error = error
                        self.result = nil
                        return
                    }
                    self.error = nil
                    if container.contains(.result) {
                        // Use decode (not decodeIfPresent) so `result: null` can be
                        // received by the Result type (JSONValue / Optional).
                        self.result = try container.decode(Result.self, forKey: .result)
                    } else {
                        self.result = nil
                    }
                }
            }
            """
    }
}
