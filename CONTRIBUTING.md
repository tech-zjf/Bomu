# Contributing to Bomu

Thanks for your interest in Bomu. The project is in pre-release development. Bomu-authored source and documentation are licensed under the [MIT License](LICENSE); third-party components and upstream materials retain their own terms. By submitting a contribution, you agree that your contribution may be distributed under the project's MIT License. You retain your copyright, and no separate CLA is currently required. Please discuss substantial features and behavior changes in an issue first; small, focused fixes can be proposed directly.

## Development setup

Bomu targets macOS 14 or later on Apple silicon. Use the exact Xcode, Swift, SDK, and dependency versions in [`Config/Dependencies.lock.json`](Config/Dependencies.lock.json).

The scripts require Python 3. Generating the synthetic media fixtures also requires `ffmpeg` and `ffprobe` on `PATH`; these development tools are separate from the pinned runtime bundled with Bomu. Fixture preparation checks its manifests and reuses valid local output.

```sh
python3 scripts/dependencies.py bootstrap
./scripts/build-dev.sh
./scripts/test-dev.sh --direct-hostless
./scripts/build-dev.sh --analyze
```

Compile the independent playback benchmark with `./scripts/build-dev.sh --benchmark -quiet` after changing shared playback APIs. This entry does not launch a window or generate the full media matrix. See [B11 media preparation](docs/playback/media-suite/b11-preparation.md) for the separate fixture and visible acceptance steps.

Native playback tests require a visible app-host window. Run them only when needed, using one ordinary Bomu window on the active test display. Do not commit generated `.build` output, user media, credentials, or machine-specific signing files.

When reproducing playback issues, generate local synthetic media with `python3 scripts/prepare-test-media.py`. These fixtures stay under `.build/fixtures/`; do not upload personal video files in an issue.

## Test organization

`Tests/PlaybackStateTests.swift` covers state transitions; `Tests/PlayerModelTests.swift` covers application playback and persistence behavior; `Tests/NowPlayingControllerTests.swift` covers system metadata and command ownership. The latter two share a recording engine in `Tests/Support/`. Native libmpv behavior stays in `Tests/MPVIntegrationTests.swift`. Shared recording adapters do not substitute for real playback acceptance.

For explicit APFS remount and capacity-failure acceptance, run `./scripts/test-dev.sh --direct-storage`. It uses disposable 64 MiB sparse images, requires at least 256 MiB free space, runs without an app window, and cleans up its mounts. The two cases are skipped by the default logic suite; see [storage acceptance and limits](docs/playback/library/storage-integration.md).

## Design and review

- Keep SwiftUI focused on presentation and user intent. Playback and rendering details belong behind their existing adapters; persistence owns its database connection and migrations.
- Keep C APIs inside the playback/rendering boundary and preserve explicit ownership, cancellation, and shutdown behavior.
- Follow the repository's [engineering conventions](AGENTS.md) and the [accepted product requirements](player_plan/开发定稿/Mori播放器开发定稿.html). Do not add abstractions without a concrete variation or reuse case.
- Keep third-party versions, checksums, notices, and provenance records synchronized when changing dependencies.
- Run `python3 scripts/license_audit.py check` after dependency or notice changes. CI runs this audit against the complete current manifest, in addition to the audit tool's regression tests; a passing audit does not authorize public binary distribution.
- Add behavior-focused tests for observable changes, state races, and resource boundaries. Do not replace runtime or visible acceptance with source-text checks.
- Update the feature's `docs/<domain>/<feature>/` page with its final design, real call flow, and verification evidence. Do not describe unverified behavior as complete.
- Use repository-relative paths in tracked documentation. Keep personal home-directory paths and captures showing local source locations out of the public tree. README screenshots should show the built app with media whose reuse terms are recorded, and their captions should stay within the behavior actually verified.

## Pull requests

Explain the user-visible behavior, the reason for the design, and the evidence used to verify it. Include relevant test results and any remaining acceptance gaps. Keep changes focused and avoid bundling unrelated generated documents or UI prototypes.
