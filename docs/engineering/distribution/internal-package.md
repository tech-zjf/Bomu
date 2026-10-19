# Internal development package

The internal DMG checks that Bomu carries its locked runtime dependencies. It is for development use and is not a public release.

Create or refresh it with:

```sh
./scripts/package-internal-dev.sh
```

The script validates the pinned toolchain and dependency hashes, builds the Debug app, copies it to a staging directory, checks the Mach-O runtime closure, applies an ad-hoc signature, verifies that signature, and creates a read-only compressed DMG. After the image verifies successfully, it removes the staging app so the workspace keeps one canonical development app plus the DMG. The ignored output is `.build/distribution/internal/Bomu-<version>-internal-arm64.dmg`.

## Latest verified package

On 2026-10-16, the script rebuilt `Bomu-0.0.1-internal-arm64.dmg` with Xcode 27.0, Swift 6.4, and the pinned arm64 dependencies. The package passed these checks:

- All 44 locked dylibs and 47 Mach-O images resolve to files inside the app or to macOS system libraries.
- `codesign --verify --deep --strict` accepts the ad-hoc signature.
- `hdiutil verify` reports a valid disk image.
- The app bundles only `en.lproj`; it contains no HTML view resources or the obsolete `library.playedSeconds` localization key.
- The DMG SHA-256 is `34b03ec76e5bbf5a34c2f15e2d2fb5f4dd33c675c5db3f4d206240b99659308e`.

The current source also passes `./scripts/build-dev.sh`, `./scripts/build-dev.sh --analyze`, and the 2026-10-16 17:25 `./scripts/test-dev.sh --direct-hostless` run (139 Python tests and 113 XCTest cases). The verified DMG is no longer retained under `.build/distribution/internal`; regenerate it with the command above when needed. It has not been launched from Finder, and clean installation on another Mac remains unverified.

## Runtime closure

`scripts/package_internal.py` inspects the actual arm64 Mach-O files. It resolves `@rpath`, `@loader_path`, and `@executable_path` using the run paths declared by each image and the main executable. It follows symlinks to their final targets and rejects dependencies outside `Bomu.app/Contents`, except macOS system libraries. It does not treat `Contents/Frameworks` as an implicit run path.

## Installation and limits

Mount the DMG in Finder and drag Bomu to Applications. To uninstall, quit Bomu and remove the app; the media library database is stored separately, and original media files are never inside the package.

This package is unsigned by Developer ID and is not notarized. Gatekeeper download approval, launch on a separate Mac without Homebrew, update behavior, and clean install/uninstall remain unverified. Do not describe this artifact as a release build. The release gates and license review are tracked in [`release-workflow.md`](release-workflow.md) and [`license-provenance.md`](license-provenance.md).
