# swift-openrpc-generator

A CLI tool that generates Swift JSON-RPC 2.0 clients and servers from [OpenRPC](https://spec.open-rpc.org/) documents: embed the generated server in one Swift application, and connect to it from other Swift apps with the generated client.

## Requirements

- Running the generator: macOS 15+ / Swift 6.3+
- Using the generated code: macOS 15+ / iOS 18+ / Swift 6.2+

## Installation

### Homebrew

```console
$ brew trust https://github.com/tattn/swift-openrpc-generator
$ brew tap tattn/openrpc https://github.com/tattn/swift-openrpc-generator
$ brew install tattn/openrpc/swift-openrpc-generator
```

### From source

```console
$ swift build -c release
$ cp .build/release/swift-openrpc-generator /usr/local/bin/
```

## Usage

```console
$ swift-openrpc-generator path/to/openrpc.json -o ./Generated
```

| Option | Description |
| --- | --- |
| `-o, --output <dir>` | Output directory (default: `./Generated`) |
| `-n, --name <ClientName>` | Type name of the generated client (default: derived from `info.title`) |
| `-a, --access <level>` | Access level of the generated code: `public` / `package` / `internal` (default: `public`) |
| `-c, --components <set>` | Which components to generate: `all` / `client` / `server` (default: `all`) |
| `--allow-remote-refs` | Allow `$ref`s to remote http(s) documents (off by default; local file `$ref`s are always resolved) |

## Generated output

The generated code is self-contained with no external dependencies. Add the output directory to your app target and it is ready to use.

| File | Contents |
| --- | --- |
| `<Base>Models.swift` | `Codable` models from `components/schemas` and inline schemas, plus the shared error enum |
| `<Base>Notification.swift` | Server-to-client notifications as one shared enum; only emitted when the document declares some |
| `<Base>Client.swift` | The client (protocol + struct) with one `async throws` function per method |
| `<Base>Server.swift` | The server: a `<Base>Handler` protocol your app implements, plus a transport-agnostic dispatcher |
| `JSONRPCRuntime.swift` | The JSON-RPC 2.0 runtime: envelopes, transports, `JSONValue`, and so on |

### Using the generated client

```swift
let client = PetstoreClient(
    url: URL(string: "https://api.example.com/rpc")!,
    headers: ["Authorization": "Bearer ..."]
)

let pets = try await client.listPets(limit: 10)
let pet = try await client.createPet(newPetName: "Tama")
try await client.deletePet(petId: pet.id)
```

Errors declared in the document are mapped to a typed enum; anything else surfaces as `JSONRPCError.server`:

```swift
do {
    let pet = try await client.getPet(petId: 42)
} catch let PetstoreError.petNotFound(error) {
    // a declared error code, with the full error object as payload
} catch let JSONRPCError.server(error) {
    // any undeclared error code
}
```

The client also conforms to `<Name>Protocol` (so tests can swap in a mock), and non-HTTP transports can be plugged in via `init(transport:)` with any `JSONRPCTransport`.

### Using the generated server

Implement the handler protocol and feed request bodies to the server — it is
transport-agnostic, so wiring it to Vapor, Hummingbird, or anything else that
moves `Data` is a few lines:

```swift
struct PetstoreService: PetstoreHandler {
    func getPet(petId: Int) async throws -> Pet {
        guard let pet = store.pet(id: petId) else {
            throw PetstoreError.petNotFound()  // a declared error
        }
        return pet
    }
    // ... one method per OpenRPC method
}

let server = PetstoreServer(handler: PetstoreService())

// e.g. Vapor:
app.post("rpc") { request async throws -> Response in
    let body = Data(buffer: request.body.data ?? ByteBuffer())
    let response = await server.handle(body)  // nil for notifications
    return Response(status: .ok, body: .init(data: response ?? Data()))
}
```

Declared errors thrown by the handler become proper error responses; anything else becomes `-32603 Internal error`. JSON-RPC 2.0 plumbing — by-name and by-position params, batch requests, notifications, and standard protocol errors (`-32700` / `-32600` / `-32601` / `-32602`) — is handled for you.

<details>
<summary>Actor-isolated handlers</summary>

The handler requirements are `@concurrent`, so witnesses can be actor-isolated (e.g. a `@MainActor` service). Note that a type-level global-actor annotation alone is overridden by the `@concurrent` inferred from the requirement (SE-0461) — annotate each witness method explicitly.

</details>

## Advanced

<details>
<summary><b>Server-to-client notifications</b> — push notifications from the server via the <code>x-direction</code> extension</summary>

OpenRPC has no standard way to describe notifications the server pushes to
clients, so this generator uses the `x-direction` extension: mark a method
with `"x-direction": "serverToClient"` (and no `result`) and it is excluded
from the client and the handler protocol. Instead, all such methods become
one enum both sides share — the server encodes a case into a request body
and pushes it over its transport, and clients decode incoming bodies back
into a case:

```json
{
  "name": "pet.adopted",
  "x-direction": "serverToClient",
  "paramStructure": "by-name",
  "params": [
    { "name": "pet", "required": true, "schema": { "$ref": "#/components/schemas/Pet" } }
  ]
}
```

```swift
// Server side: encode and push over your transport of choice.
let body = try PetstoreNotification.petAdopted(pet: pet).body()

// Client side: decode incoming bodies; unknown methods return nil,
// so newer servers stay compatible with older clients.
if let notification = try PetstoreNotification.decode(body) {
    switch notification {
    case .petAdopted(let pet): ...
    }
}
```

`x-direction` accepts `"clientToServer"` (the default when omitted) and
`"serverToClient"`. A `result` or `errors` on a serverToClient method is
ignored with a warning: notifications get no response.

</details>

<details>
<summary><b>WebSocket and peer-to-peer connections</b> — persistent connections that serve both directions</summary>

`WebSocketJSONRPCTransport` keeps one persistent connection with concurrent
in-flight calls, and can serve the peer's requests over the same socket:

```swift
// Plain client over WebSocket:
let client = PetstoreClient(transport: WebSocketJSONRPCTransport(url: url))

// Peer setup — this app also answers the other side's calls:
let transport = WebSocketJSONRPCTransport(url: url) { body in
    await PetstoreServer(handler: PetstoreService()).handle(body)
}
```

The underlying `JSONRPCConnection` is pipe-agnostic: on the accepting side
(where the app owns the socket via Vapor, Network.framework, and so on), wire
its `send` closure to the socket's write and feed incoming messages to
`receive(_:)` — id correlation and request dispatch are handled for you.

</details>

<details>
<summary><b>Batching</b> — collect concurrent calls into one JSON-RPC batch request</summary>

`JSONRPCBatcher` collects concurrent calls into one JSON-RPC batch request.
It flushes automatically once the expected number of calls has been buffered:

```swift
let batcher = JSONRPCBatcher(transport: HTTPJSONRPCTransport(url: url), expecting: 2)
let client = PetstoreClient(transport: batcher)
async let pet = client.getPet(petId: 1)
async let pets = client.listPets()
let (first, second) = try await (pet, pets)  // one round trip
```

</details>

## Supported OpenRPC / JSON Schema features

Method `params` / `result` / `errors`, `paramStructure`, `$ref` resolution (including external documents), `allOf` / `oneOf` / `anyOf`, enums, formats (`date-time`, `uuid`, `byte`, `uri`), and recursive schemas are supported.

<details>
<summary>Full list</summary>

- Method `params` / `result`, `paramStructure`, and `deprecated`
- Method `errors` → a shared typed error enum: clients catch declared codes as `<Base>Error.petNotFound(...)`-style cases (undeclared codes still surface as `JSONRPCError.server`), and server handlers throw them via static factories
- Params are sent by-position (as an array) by default, and as an object only when `paramStructure: "by-name"` is specified — the same behavior as the official [open-rpc/generator](https://github.com/open-rpc/generator)
- Methods without a `result` are sent as JSON-RPC notifications (no `id`, no response awaited)
- The `x-direction: "serverToClient"` extension → a shared notification enum for server-pushed notifications (see "Server-to-client notifications" above)
- `$ref` to `#/components/schemas/...` and `#/components/contentDescriptors/...`; `$ref`s to external documents (relative paths, or http(s) URLs with `--allow-remote-refs`) and `$ref`s inside `methods` are resolved by dereferencing the document before generation. External schemas on a reference cycle are hoisted into `components/schemas` automatically
- `type: object` + `properties` → `struct` (optionality driven by `required`)
- `allOf` → a single `struct` merging the properties of every branch (and the enclosing schema's own properties)
- `oneOf` / `anyOf` → `enum` with associated values, decoded untagged (each variant tried in declaration order — the same shape as the official generator's Rust output); a schema with multiple non-null `type`s becomes the same kind of union
- String `enum`s → `String` raw-value `enum`s; integer `enum`s → `Int` raw-value `enum`s; mixed-type `enum`s (strings, numbers, booleans, null) → payload-less `enum`s decoded by constant comparison
- Arrays, dictionaries (`additionalProperties`), primitive types, and `nullable` / `type: [..., "null"]`
- String `format`s: `date-time` → `Date` (ISO 8601, fractional seconds accepted), `uuid` → `UUID`, `byte` → `Data` (base64), `uri` → `URL`; unknown formats stay `String`
- Recursive schemas: self-referencing properties are stored in a copy-on-write `Indirect` box (the public API stays the plain type), and unions on a cycle become `indirect enum`s
- Inline schemas are synthesized as types named after the method or property (for example, the result of `get_state` becomes `GetStateResult`)

</details>

<details>
<summary>Limitations</summary>

The following cannot be represented and fall back to `JSONValue` (an arbitrary JSON value), with a warning at generation time:

- `allOf` containing branches that are not object schemas
- `enum` values that are arrays or objects
- Cyclic references through non-schema locations (for example, a method definition that references itself)

</details>
