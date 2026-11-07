# Homebrew formula for swift-openrpc-generator.
#
# This repository itself works as a tap because Homebrew picks up Formula/.
# Homebrew requires third-party taps to be trusted, and a tap with a custom
# remote can only be trusted by its remote URL:
#   brew trust https://github.com/tattn/swift-openrpc-generator
#   brew tap tattn/openrpc https://github.com/tattn/swift-openrpc-generator
#   brew install tattn/openrpc/swift-openrpc-generator
#
# `url`/`sha256` below point at the universal macOS binary published by the
# Release workflow (.github/workflows/release.yml), which bumps them on release.
class SwiftOpenrpcGenerator < Formula
  desc "Generate Swift JSON-RPC client code from OpenRPC documents"
  homepage "https://github.com/tattn/swift-openrpc-generator"
  url "https://github.com/tattn/swift-openrpc-generator/releases/download/v1.0.3/swift-openrpc-generator-v1.0.3-macos.tar.gz"
  sha256 "c1cb5ce3e24b6af2eb1ac0eea24df7b9cd7e06d499285a3115081ab77ab191be"
  license "Apache-2.0"

  head do
    url "https://github.com/tattn/swift-openrpc-generator.git", branch: "main"

    depends_on xcode: ["26.3", :build]
  end

  depends_on :macos

  def install
    if build.head?
      # SwiftPM's own sandbox cannot start inside Homebrew's build sandbox.
      system "swift", "build", "--configuration", "release", "--disable-sandbox"
      bin.install ".build/release/swift-openrpc-generator"
    else
      bin.install "swift-openrpc-generator"
    end
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
    assert_path_exists testpath/"Generated/PingModels.swift"
    assert_path_exists testpath/"Generated/PingServer.swift"
    assert_path_exists testpath/"Generated/JSONRPCRuntime.swift"
    assert_match "func ping()", (testpath/"Generated/PingClient.swift").read
  end
end
