# Development guide

## Prerequisites

- macOS 15+ with Swift 6.3+ (Xcode 26.3+), or Linux with Swift 6.3+

## Common tasks

```console
$ swift build                                        # build
$ swift test                                         # run tests (Swift Testing)
$ swift format lint --recursive Sources Tests        # lint (configured by .swift-format)
$ ./scripts/e2e-check.sh                             # end-to-end check (generate → compile → run against a mock)
```

## Project structure

- `Sources/OpenRPCGeneratorKit` — the library. No external dependencies.
  - `OpenRPCDocument.swift` / `JSONSchema.swift` / `JSONValue.swift` — parsing the OpenRPC document and its JSON Schema subset
  - `CodegenContext.swift` — semantic resolution: schemas and methods become Swift declarations (`ModelDecl` / `MethodDecl`), including type-name allocation and synthesis of inline types
  - `ModelsRenderer.swift` / `ClientRenderer.swift` / `ServerRenderer.swift` / `RenderHelpers.swift` — pure string rendering of the resolved declarations
  - `RuntimeTemplate.swift` — the JSON-RPC 2.0 runtime emitted verbatim into the generated output
  - `Generator.swift` — orchestration and public API (`OpenRPCSwiftGenerator`)
- `Sources/swift-openrpc-generator` — the CLI entry point (uses [swift-argument-parser](https://github.com/apple/swift-argument-parser))
- `Tests/OpenRPCGeneratorKitTests` — unit tests (Swift Testing)
  - `Golden/` — reference outputs for the example documents, compared in full by
    `GoldenFileTests`. After an intentional output change, re-record with
    `RECORD_GOLDEN=1 swift test --filter GoldenFileTests` and review the diff
- `examples/petstore.openrpc.json` — the sample document used by tests and the e2e check
- `Formula/` — the Homebrew formula (see the [release guide](release.md))

## Code generation pipeline

1. `OpenRPCDocument.parse` first runs `DocumentDereferencer`, which resolves the
   `$ref`s the generator cannot handle itself (`$ref`s inside `methods`, internal
   pointers outside `components`, and external documents) — mirroring the official
   generator pipeline, which dereferences before type generation. Refs into
   `#/components/schemas|contentDescriptors` are left for the generator, since
   they may be recursive. External targets on a reference cycle cannot be inlined,
   so the dereferencer analyzes the reference graph first and hoists them into the
   root document's `components/schemas`, rewriting all references to local
   component refs. It then decodes the JSON leniently: unsupported schema
   constructs degrade rather than fail.
2. `CodegenContext` pre-allocates type names for all `components/schemas` entries
   (so `$ref` resolution does not depend on order) and detects inline-layout
   reference cycles among them (arrays and dictionaries already break recursion
   and are not counted). It then resolves component models and methods,
   normalizing as it goes: multi-type schemas become per-type unions, `allOf`
   branches merge into a single struct, and enums dispatch to raw-value
   (string/integer) or constant-comparison (mixed) forms. Inline object/enum
   schemas encountered along the way are appended as synthesized model
   declarations. Properties whose type is on a cycle are boxed in the generated
   `Indirect` copy-on-write wrapper (mirroring how the official Rust output uses
   `Box`), unions on a cycle become `indirect enum`s, and anything
   unrepresentable falls back to `JSONValue` with a warning.
3. The renderers turn declarations into four files: models (including the
   shared error enum), client (protocol + struct), server (handler protocol +
   transport-agnostic dispatcher), and the runtime template. `--components`
   selects client and/or server; models and the runtime are always emitted.

Behavioral notes:

- Params default to by-position and results are required for a response, matching
  the official [open-rpc/generator](https://github.com/open-rpc/generator);
  methods without a `result` are emitted as JSON-RPC notifications.
- The generated runtime synchronizes only ID generation (`Mutex`), so concurrent
  calls encode and decode in parallel.

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on pushes to `main` and on pull requests:

- Build and test on macOS (`macos-26`) and Linux (`swift:6.3` container)
- `swift format lint --strict` over `Sources`, `Tests`, `scripts`, and `Package.swift`
- The end-to-end check (`scripts/e2e-check.sh`, run on both macOS and Linux):
  generates code from both example documents, compiles each as a standalone
  package, and runs it against a mock transport —
  - `petstore.openrpc.json`: by-name / by-position params, notifications,
    integer enums, recursive properties, untagged unions, error handling
    (typed error mapping for declared codes, `JSONRPCError.server` for
    undeclared ones), a loopback run where the generated server serves the
    generated client in-process, batched calls through `JSONRPCBatcher`, and
    a bidirectional peer run over two `JSONRPCConnection`s
  - `features.openrpc.json`: allOf merging, multi-type unions, mixed-type
    enums, string-format mapping, and external cyclic references
