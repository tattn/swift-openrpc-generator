# Release guide

## Versioning

The CLI version lives in `Sources/swift-openrpc-generator/OpenRPCGeneratorCommand.swift`
(`CommandConfiguration(version:)`). Bump it before releasing.

## Creating a release

Tags are created *by* the Release workflow, not by hand — the tag is pushed only
after the tests and the release build have passed, so a failed run can never
leave a broken tag behind.

1. Update the version constant and merge it into `main`.
2. Run the Release workflow (`.github/workflows/release.yml`) from the Actions tab
   ("Run workflow") against the ref you want to release, entering the version
   (`0.2.0`; a leading `v` is accepted). Or from the CLI:

   ```console
   $ gh workflow run release.yml --ref main -f version=0.2.0
   ```

3. The workflow validates the version, refuses to continue if the tag already
   exists, runs the tests, builds a universal (arm64 + x86_64) binary, then tags
   the commit and creates a GitHub release with:
   - `swift-openrpc-generator-v<version>-macos.tar.gz` — the prebuilt binary
   - Release notes containing the sha256 of both the binary and the source tarball

   If a step after tagging fails, the workflow deletes the tag (and any partial
   release) so the run can simply be retried.

## Updating the Homebrew formula

`Formula/swift-openrpc-generator.rb` builds from the release source tarball. After each
release, update it with the values from the release notes:

```ruby
url "https://github.com/tattn/swift-openrpc-generator/archive/refs/tags/v0.2.0.tar.gz"
sha256 "<source tarball sha256 from the release notes>"
```

Commit the change to `main`. Users get the new version via `brew update && brew upgrade`.

## How the tap works

Homebrew treats any git repository containing a `Formula/` directory as a tap, so
this repository doubles as its own tap — no separate `homebrew-*` repository is
needed:

```console
$ brew tap tattn/openrpc https://github.com/tattn/swift-openrpc-generator
$ brew install tattn/openrpc/swift-openrpc-generator
```

Notes:

- The formula builds with `swift build --disable-sandbox` because SwiftPM's own
  sandbox cannot start inside Homebrew's build sandbox.
- Before the first release exists, only `brew install --HEAD` works (it builds
  from `main`); the `url`/`sha256` pair requires a published tag.
- The same setup works on GitHub Enterprise by replacing the URLs; for private
  repositories, users need credentials that `git`/`curl` can pick up (for example,
  `HOMEBREW_GITHUB_API_TOKEN` on github.com).
