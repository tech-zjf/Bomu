# Bomu

Bomu is a native video player for local media on macOS. It is built with Swift, SwiftUI, AppKit, and a pinned libmpv runtime. Playback works offline; the app does not upload or modify the original media files.

## Project status

Bomu is in early development. The core local-playback path is implemented, but the v0.0 acceptance work and later product features are not complete. See the [current development status](docs/engineering/roadmap/progress.md) and the [83-item acceptance plan](player_plan/开发定稿/开发任务.json).

Bomu-authored source and documentation are licensed under the [MIT License](LICENSE). Third-party code, notices, bundled runtime components, media fixtures, and upstream materials retain their own terms; see the [license and provenance record](docs/engineering/distribution/license-provenance.md) and [`ThirdParty/libmpv/README.md`](ThirdParty/libmpv/README.md). Choosing MIT does not complete release readiness: Developer ID signing, notarization, and clean-machine installation still require acceptance.

## Requirements

- macOS 14 or later
- Apple silicon (arm64)
- The exact Xcode, Swift, and SDK versions recorded in [`Config/Dependencies.lock.json`](Config/Dependencies.lock.json)

## Build and test

From the repository root, prepare the pinned development dependencies and build the app:

```sh
python3 scripts/dependencies.py bootstrap
./scripts/build-dev.sh
```

Run Python and hostless Swift tests without opening the player, then run static analysis:

```sh
./scripts/test-dev.sh --direct-hostless
./scripts/build-dev.sh --analyze
```

Native playback tests use `./scripts/test-dev.sh --native` and open one app-host window. The internal DMG produced by `./scripts/package-internal-dev.sh` is an ad-hoc signed development artifact, not a release build. Signing, notarization, and clean-machine installation have not passed release acceptance.

## Code map

- `Sources/App` — application setup and window composition
- `Sources/PlayerFeature` and `Sources/Library` — user-facing playback and library features
- `Sources/Playback` and `Sources/Rendering` — playback state, libmpv adapter, and native video output
- `Sources/Persistence` — SQLite storage and migrations
- `Sources/DesignSystem` — shared visual tokens and controls
- `Tests` — behavior, dependency, packaging, and playback tests
- `ThirdParty` — pinned runtime notices and provenance records

## Documentation

- [Playback design and call flow](docs/playback/native-poc/technical-design.md) · [flow diagram](docs/playback/native-poc/flow.md)
- [Playback requirements and validation](docs/playback/native-poc/requirements.md)
- [Manual acceptance tasks](docs/product/acceptance-tasks.md)
- [Toolchain and CI](docs/engineering/toolchain/continuous-integration.md)
- [Runtime provenance and release license gate](docs/engineering/distribution/license-provenance.md)
- [Contribution guide](CONTRIBUTING.md) · [Security reporting](SECURITY.md)

Product requirements, the final visual reference, design tokens, and task dependencies remain in [`player_plan/开发定稿`](player_plan/开发定稿/). Early UI prototypes, research exports, and naming studies are kept out of the tracked source tree.
