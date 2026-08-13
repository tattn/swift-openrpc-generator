#!/usr/bin/env bash
set -euo pipefail

# End-to-end check: generate clients from the example documents, compile each
# as a standalone package, and exercise it against a mock transport.
# - petstore.openrpc.json + e2e-main.swift assert the JSON-RPC request shapes
#   (by-name / by-position / notification) and core model decoding.
# - features.openrpc.json + e2e-features-main.swift assert allOf merging,
#   multi-type unions, mixed-type enums, and external cyclic references.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

check() {
    local name=$1 spec=$2 harness=$3
    local pkg="$WORKDIR/$name"
    mkdir -p "$pkg/Sources/$name"

    swift run --package-path "$ROOT" swift-openrpc-generator \
        "$ROOT/$spec" \
        --output "$pkg/Sources/$name"

    cat > "$pkg/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "$name",
    platforms: [.macOS(.v15), .iOS(.v18)],
    targets: [.executableTarget(name: "$name")]
)
EOF

    cp "$ROOT/scripts/$harness" "$pkg/Sources/$name/main.swift"
    swift run --package-path "$pkg"
}

check PetstoreCheck examples/petstore.openrpc.json e2e-main.swift
check FeaturesCheck examples/features.openrpc.json e2e-features-main.swift
echo "e2e check passed"
