# Bomu

Bomu is a native video player for local media on macOS. It is built with Swift, SwiftUI, AppKit, and a pinned libmpv runtime. Playback works offline; the app does not upload or modify the original media files.

## Project status

Bomu is in early development. The core local-playback path is implemented, but the v0.0 acceptance work and later product features are not complete. See the [current development status](docs/engineering/roadmap/progress.md) and the [83-item acceptance plan](player_plan/开发定稿/开发任务.json).

Local H.265/HEVC playback is a primary goal. The [30-file playback matrix](docs/playback/media-suite/validation.md) has passed on the current Xcode 27.1 toolchain with H.264 and HEVC Main/Main10 SDR video in MP4 and MKV, plus MOV, MPEG-TS, WebM, AAC, MP3, FLAC, and WAV samples. HEVC Main and Main10 SDR have also produced visible video in the Debug app. Final sound, sync, and device checks remain open. The prepared [60-file expansion](docs/playback/media-suite/b11-preparation.md) is not yet a passed app-playback matrix. HLS (`.m3u8`) playback is planned for v0.5; the current app accepts local media files and does not offer a stream URL input.

Bomu-authored source and documentation are licensed under the [MIT License](LICENSE). Third-party code, notices, bundled runtime components, media fixtures, and upstream materials retain their own terms; see the [license and provenance record](docs/engineering/distribution/license-provenance.md) and [`ThirdParty/libmpv/README.md`](ThirdParty/libmpv/README.md). Choosing MIT does not complete release readiness: Developer ID signing, notarization, and clean-machine installation still require acceptance.

## Requirements

- macOS 14 or later
- Apple silicon (arm64)
- The exact Xcode, Swift, and SDK versions recorded in [`Config/Dependencies.lock.json`](Config/Dependencies.lock.json)
- Python 3 for the build and verification scripts
- FFmpeg and ffprobe on `PATH` to generate test fixtures; the app itself uses its bundled runtime

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

CI also audits the current third-party license/provenance records and the built app's runtime closure:

```sh
python3 scripts/license_audit.py check
python3 scripts/package_internal.py .build/DerivedData/Build/Products/Debug/Bomu.app
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

- Product: [v0.0 acceptance checklist](docs/engineering/roadmap/v0.0-acceptance-todo.md), [manual acceptance tasks](docs/product/acceptance-tasks.md), [native UI specification](docs/product/native-ui-spec.md), and [typography decision](docs/product/typography/decision.md)
- Playback: [architecture and acceptance](docs/player/playback/architecture-and-acceptance.md), [file ingress and queue](docs/playback/queue/file-ingress-and-queue.md), [replay](docs/playback/controls/replay.md), [resume choice](docs/playback/controls/resume-choice.md), [failure recovery](docs/playback/controls/playback-failure-recovery.md), and [first-version settings](docs/playback/preferences/first-version-settings.md)
- Library: [Home and sidebar](docs/playback/library/home-and-sidebar.md), [search and classification](docs/playback/library/search-and-classification.md), [media metadata](docs/playback/library/metadata.md), [source reconciliation](docs/playback/library/incremental-sync.md), and [accessibility and performance](docs/playback/library/accessibility-and-performance.md)
- Format evidence: [media-suite validation](docs/playback/media-suite/validation.md) and [known issues](docs/playback/media-suite/known-issues.md)
- Engineering: [toolchain and CI](docs/engineering/toolchain/continuous-integration.md), [internal development package](docs/engineering/distribution/internal-package.md), [runtime provenance and license gate](docs/engineering/distribution/license-provenance.md), and [log privacy](docs/engineering/distribution/log-privacy.md)
- [Contribution guide](CONTRIBUTING.md) · [Security reporting](SECURITY.md)

Product requirements, the final visual reference, design tokens, and task dependencies remain in [`player_plan/开发定稿`](player_plan/开发定稿/). Early UI prototypes, research exports, and naming studies are kept out of the tracked source tree.
Historical development milestone snapshots remain available in Git tags `v0.0.1-dev.1` and `v0.0.1-dev.2`.
