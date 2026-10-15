# Runtime licenses and source provenance

This record covers the development runtime currently pinned by `Config/Dependencies.lock.json`. It does not approve a public binary release.

## Verified inputs

- The runtime closure contains 44 hashed dylibs. Each library has a machine-readable record under `ThirdParty/`, linked from `Config/ThirdPartyLicenses.json`.
- Most binaries come from the hash-verified IINA 1.5.0 arm64 dependency image. Five libraries—`libSvtAv1Enc.4.dylib`, `libjpeg.62.dylib`, `libmpv.2.dylib`, `libvorbis.0.dylib`, and `libvorbisenc.2.dylib`—are taken byte-for-byte from the pinned [IINA dependency release archive](https://github.com/iina/deps-buildscripts/releases/tag/iina-1.5.0-release).
- `libavformat.63.dylib` is built from FFmpeg 9.0.1 with Bomu's recorded transport-stream seek patch. The dependency lock and recipe record its source archive, patch, build settings, output hash, and notices.
- The per-library audit checks dependency-lock hashes, license expressions, notice text, recipe hashes, source versions, and binary provenance. Run `python3 scripts/license_audit.py check` after changing any dependency evidence.

The IINA build repository is pinned to commit `f86d54276547df6d14104583ea604af67433f1e1`. Its recipes keep permanent source permalinks and Git blob IDs rather than redistributing copies of upstream build scripts; the upstream repository does not declare a detectable license. These references establish which build inputs were reviewed, not permission to redistribute the upstream scripts.

The [runtime comparison report](iina-1.5.0-deps-comparison-2026-10-14.json) records the original image comparison. The [artifact adoption record](iina-runtime-artifact-adoption-2026-10-15.json) explains why five binaries were replaced with files from the pinned release archive.

## Release gate

The repository's MIT license applies to Bomu-authored source and documentation. Third-party runtime libraries, headers, notices, media fixtures, and upstream materials retain their own terms. A passing audit confirms that recorded evidence is internally consistent; it does not determine whether distributing the combined application satisfies every license obligation.

The bundled mpv and FFmpeg builds include GPL components. Before publishing an application binary, review the exact linked components, applicable source-offer and notice requirements, and the effect of Bomu's patches and build configuration. See [FFmpeg legal considerations](https://ffmpeg.org/legal.html) and [mpv's copyright and license notes](https://github.com/mpv-player/mpv/blob/v0.41.0/Copyright). This repository record is not legal advice.

The release build remains blocked until the license review is complete. The development machine currently has no Developer ID signing identity, so the internal ad-hoc-signed DMG is not notarized and has not passed Gatekeeper or clean-Mac installation checks. The release workflow must keep these gates explicit; a successful Debug build or internal package is not a public release.

## Upstream references

- [IINA dependency build scripts](https://github.com/iina/deps-buildscripts) and the [pinned 1.5.0 build commit](https://github.com/iina/deps-buildscripts/commit/f86d54276547df6d14104583ea604af67433f1e1).
- [IINA 1.5.0 dependency release](https://github.com/iina/deps-buildscripts/releases/tag/iina-1.5.0-release), used as the exact binary source for the five listed libraries.
- [IINA's versioned dylib file list](https://iina.io/dylibs/1.5.0/universal/filelist.txt), retained as a comparison input, not as a source or binary integrity guarantee.
