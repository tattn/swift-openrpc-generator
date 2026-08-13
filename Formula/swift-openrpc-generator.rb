# Homebrew formula for swift-openrpc-generator.
#
# This repository itself works as a tap because Homebrew picks up Formula/:
#   brew tap tattn/openrpc https://github.com/tattn/swift-openrpc-generator
#   brew install tattn/openrpc/swift-openrpc-generator
#
# Before the first release, fill in sha256 below with the value printed by the
# Release workflow (.github/workflows/release.yml).
# Until a release tag exists, install from the default branch instead:
#   brew install --HEAD tattn/openrpc/swift-openrpc-generator
class SwiftOpenrpcGenerator < Formula
  desc "Generate Swift JSON-RPC client code from OpenRPC documents"
  homepage "https://github.com/tattn/swift-openrpc-generator"
  url "https://github.com/tattn/swift-openrpc-generator/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_SOURCE_TARBALL_SHA256"
  head "https://github.com/tattn/swift-openrpc-generator.git", branch: "main"

  depends_on xcode: ["26.3", :build]

  def install
    # SwiftPM's own sandbox cannot start inside Homebrew's build sandbox.
    system "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin.install ".build/release/swift-openrpc-generator"
  end

  test do
    (testpath/"api.json").write <<~JSON
      {
        "openrpc": "1.3.2",
        "info": { "title": "Ping", "version": "1.0.0" },
        "methods": [
          {
            "name": "ping",
            "params": [],
            "result": { "name": "pong", "schema": { "type": "string" } }
          }
        ]
      }
    JSON
    system bin/"swift-openrpc-generator", testpath/"api.json", "--output", testpath/"Generated"
    assert_path_exists testpath/"Generated/PingClient.swift"
    assert_path_exists testpath/"Generated/PingClientModels.swift"
    assert_path_exists testpath/"Generated/JSONRPCRuntime.swift"
    assert_match "func ping()", (testpath/"Generated/PingClient.swift").read
  end
end
