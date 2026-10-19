# A08 SDR/HDR output validation

## Output contract

The current player has a deliberately SDR output path. `BMVideoLayer` declares an sRGB color space and creates an OpenGL 3.2 CGL pixel format with a 24-bit color buffer. `BMMPVSession` fixes mpv's target primaries to BT.709 and target transfer to sRGB. The locked mpv 0.41.0 GPU renderer applies its default `tone-mapping=auto` path to HDR input before presenting into that SDR layer. This is HDR-to-SDR playback, not HDR passthrough.

The product does not configure an HDR presentation surface, a 10-bit output surface, or HDR display metadata. Native HDR output and HDR passthrough are therefore unsupported by this implementation and must not be advertised. The relevant mpv policy is described in the [mpv 0.41.0 color and tone-mapping options](https://github.com/mpv-player/mpv/blob/v0.41.0/DOCS/man/options.rst); the layer's presentation color space follows [Apple's CAOpenGLLayer contract](https://developer.apple.com/documentation/quartzcore/caopengllayer).

## Internal display smoke test

On 2026-10-15, the existing Bomu window on Screen 1 played two local synthetic samples without opening another player window or entering fullscreen:

| Input | Signal | Visible result |
| --- | --- | --- |
| `h264-sdr.mp4` | 960×540, H.264, 8-bit 4:2:0, limited-range BT.709, 15 seconds | Color bars and moving luminance pattern were visible without an obvious decode or color-channel failure. This is a visual smoke test, not calibrated color validation. |
| `hdr10-pq-patches.mp4` | 1920×1080, HEVC Main 10, limited-range BT.2020 non-constant-luminance, SMPTE ST 2084 PQ, static HDR10 mastering metadata, 6 seconds | PQ grayscale steps from 0.1 to 1000 cd/m² remained visually distinct after conversion to SDR; six BT.2020 color patches appeared without black output or obvious channel corruption. Playback reached its normal finished state. This does not measure tone-mapping accuracy or physical display luminance. |

On 2026-10-16 at 11:23 +0800, the same HDR10 sample was replayed in the existing Bomu window on Screen 1 using the current Xcode 27 Debug build. A captured playback frame showed distinct grayscale steps and all six color patches after HDR-to-SDR conversion; the clip then reached its normal finished state. This repeat confirms visible output on the built-in display, not calibrated color accuracy or HDR passthrough.

On 2026-10-19, the canonical Xcode 27.1 Debug app played `.build/media-suite/19-h264-pcm.mov`, a 960×540 H.264 8-bit 4:2:0 limited-range BT.709-matrix CC0 test pattern. An active screenshot showed the moving color bars/pattern without an obvious black-output or channel failure. This is an SDR presentation smoke check only; the fixture does not define complete mastering/transfer metadata, and this observation does not measure color accuracy, sound, synchronization, or physical display output. The 2026-10-19 screenshot is recorded in the adjacent visible-playback validation notes.

A separate 2026-10-13 display-transition preflight used `window-stress-1080p.mp4`, a synthetic 8-bit BT.709 pattern. Its first checkpoint on external display ID 3 recorded 29 submitted video frames; the following checkpoint on built-in display ID 1 recorded 49. The report marks the overall acceptance incomplete and contains no visual color judgment or calibration, so this confirms rendering on that display during the transition preflight but does not count as A08 external color validation. The raw report and media manifest are preserved in [`window-validation-2026-10-13.json`](window-validation-2026-10-13.json).

The HDR pattern is generated locally from deterministic PQ-encoded patches. Its generator validates codec, profile, dimensions, pixel format, range, primaries, matrix and transfer before writing a manifest:

```sh
python3 scripts/generate-display-color-fixture.py
```

The media file and manifest are kept under ignored `.build/a08-color/`. The 2026-10-15 run used FFmpeg 8.1 and produced SHA-256 `60e2b0f2289d73b984259082dd51e7f875e5bae67357afcb5c8204fcd2674147`. The manifest records the exact stream metadata and patch levels.

On 2026-10-16, the current local fixture hash and `ffprobe` fields were rechecked against that manifest: SHA-256, HEVC Main 10, 1920×1080, `yuv420p10le`, limited range, BT.2020 non-constant-luminance, and SMPTE ST 2084 all match. This confirms the test input is intact; it does not add color-accuracy evidence.

## Limits and status

- The internal display has SDR smoke-test evidence for a Rec.709 clip and an HDR10 clip mapped into the configured SDR output.
- No colorimeter or trusted mastering reference was used; color accuracy, black level, peak luminance and display scanout are unmeasured.
- No external-display color judgment or calibration was performed in this validation. The current desktop-use instruction confines testing to Screen 1; moving the player to another display requires separate authorization.
- No native HDR or metadata passthrough test was run because the application does not implement that output path.

A08 is partially verified and remains open for external-display evidence and calibrated SDR color validation. The current supported behavior is Rec.709/sRGB SDR output, including a smoke-tested HDR-to-SDR path.
