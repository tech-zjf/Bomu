# Contributing to Bomu

Thanks for your interest in Bomu. The project is in pre-release development. Original Bomu source and project documentation are licensed under the [MIT License](LICENSE); third-party components remain under their own licenses. By submitting a contribution, you agree that it may be distributed under the project's MIT License. You retain your copyright, and no separate CLA is currently required. Please discuss substantial features and behavior changes in an issue first; small, focused fixes can be proposed directly.

## Development setup

Bomu targets macOS 14 or later on Apple silicon. Use the exact Xcode, Swift, SDK, and dependency versions in [`Config/Dependencies.lock.json`](Config/Dependencies.lock.json).

```sh
python3 scripts/dependencies.py bootstrap
./scripts/build-dev.sh
./scripts/test-dev.sh --direct-hostless
./scripts/build-dev.sh --analyze
```

Native playback tests require a visible app-host window. Run them only when needed, using one ordinary Bomu window on the active test display. Do not commit generated `.build` output, user media, credentials, or machine-specific signing files.

## Design and review

- Keep SwiftUI focused on presentation and user intent. Playback and rendering details belong behind their existing adapters; persistence owns its database connection and migrations.
- Keep C APIs inside the playback/rendering boundary and preserve explicit ownership, cancellation, and shutdown behavior.
- Follow the repository's [engineering conventions](AGENTS.md) and the [accepted product requirements](player_plan/开发定稿/Mori播放器开发定稿.html). Do not add abstractions without a concrete variation or reuse case.
- Keep third-party versions, checksums, notices, and provenance records synchronized when changing dependencies.
- Add behavior-focused tests for observable changes, state races, and resource boundaries. Do not replace runtime or visible acceptance with source-text checks.
- Update the feature's `docs/<domain>/<feature>/` page with its final design, real call flow, and verification evidence. Do not describe unverified behavior as complete.

## Pull requests

Explain the user-visible behavior, the reason for the design, and the evidence used to verify it. Include relevant test results and any remaining acceptance gaps. Keep changes focused and avoid bundling unrelated generated documents or UI prototypes.
