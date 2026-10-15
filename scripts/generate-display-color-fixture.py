#!/usr/bin/env python3
"""Generate a local SDR/HDR display test pattern and a verified media manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WIDTH = 1920
HEIGHT = 1080
GRAY_PATCH_NITS = (0.1, 1, 10, 50, 100, 203, 400, 1000)
COLOR_PATCH_NITS = (
    (203, 0, 0),
    (0, 203, 0),
    (0, 0, 203),
    (203, 203, 0),
    (0, 203, 203),
    (203, 0, 203),
)
X265_HDR10_PARAMS = (
    "log-level=error:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:"
    "colormatrix=bt2020nc:"
    "master-display=G(13250,34500)B(7500,3000)R(34000,16000)"
    "WP(15635,16450)L(10000000,50):max-cll=1000,203"
)


def pq_code_value(nits: float) -> int:
    """Encode absolute luminance in cd/m² as a 16-bit SMPTE ST 2084 code value."""
    m1 = 2610 / 16384
    m2 = 2523 / 32
    c1 = 3424 / 4096
    c2 = 2413 / 128
    c3 = 2392 / 128
    normalized = max(0.0, min(1.0, nits / 10000))
    powered = normalized**m1
    encoded = ((c1 + c2 * powered) / (1 + c3 * powered)) ** m2
    return round(encoded * 65535)


def rgb_sample(values: tuple[float, float, float]) -> bytes:
    import struct

    return struct.pack(">HHH", *(pq_code_value(value) for value in values))


def write_pattern(path: Path) -> None:
    row_width = WIDTH // len(GRAY_PATCH_NITS)
    color_width = WIDTH // len(COLOR_PATCH_NITS)
    gray_row = b"".join(
        rgb_sample((nits, nits, nits)) * row_width for nits in GRAY_PATCH_NITS
    )
    color_row = b"".join(
        rgb_sample(rgb) * color_width for rgb in COLOR_PATCH_NITS
    )

    header = f"P6\n{WIDTH} {HEIGHT}\n65535\n".encode("ascii")
    with path.open("wb") as pattern:
        pattern.write(header)
        for row in range(HEIGHT):
            pattern.write(gray_row if row < 720 else color_row)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def probe(ffprobe: str, video: Path) -> dict:
    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-show_entries",
            "format=duration,size:stream=codec_name,profile,width,height,pix_fmt,"
            "color_range,color_space,color_transfer,color_primaries,avg_frame_rate",
            "-of",
            "json",
            str(video),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / ".build" / "a08-color",
        help="Ignored local output directory (default: .build/a08-color)",
    )
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    parser.add_argument("--ffprobe", default=shutil.which("ffprobe"))
    args = parser.parse_args()
    if not args.ffmpeg or not args.ffprobe:
        parser.error("ffmpeg and ffprobe must be available on PATH or provided explicitly")

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    pattern = output_dir / "hdr10-pq-patches.ppm"
    video = output_dir / "hdr10-pq-patches.mp4"
    write_pattern(pattern)

    subprocess.run(
        [
            args.ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-loop",
            "1",
            "-framerate",
            "24",
            "-i",
            str(pattern),
            "-t",
            "6",
            "-vf",
            "format=yuv420p10le",
            "-an",
            "-c:v",
            "libx265",
            "-preset",
            "ultrafast",
            "-x265-params",
            X265_HDR10_PARAMS,
            "-color_primaries",
            "bt2020",
            "-color_trc",
            "smpte2084",
            "-colorspace",
            "bt2020nc",
            "-color_range",
            "tv",
            "-tag:v",
            "hvc1",
            str(video),
        ],
        check=True,
    )

    stream_probe = probe(args.ffprobe, video)
    stream = stream_probe["streams"][0]
    expected = {
        "codec_name": "hevc",
        "profile": "Main 10",
        "width": WIDTH,
        "height": HEIGHT,
        "pix_fmt": "yuv420p10le",
        "color_range": "tv",
        "color_space": "bt2020nc",
        "color_transfer": "smpte2084",
        "color_primaries": "bt2020",
    }
    mismatches = {
        key: {"expected": value, "actual": stream.get(key)}
        for key, value in expected.items()
        if stream.get(key) != value
    }
    if mismatches:
        raise SystemExit(f"Generated HDR fixture failed metadata validation: {mismatches}")

    ffmpeg_version = subprocess.run(
        [args.ffmpeg, "-hide_banner", "-version"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()[0]
    manifest = {
        "schemaVersion": 1,
        "generator": ffmpeg_version,
        "source": "Locally generated SMPTE ST 2084 PQ grayscale and BT.2020 color patches",
        "license": "CC0-1.0",
        "file": video.name,
        "sha256": sha256(video),
        "expected": expected,
        "pattern": {
            "grayPatchLuminanceNitsLeftToRight": list(GRAY_PATCH_NITS),
            "colorPatchChannelNitsLeftToRight": [list(rgb) for rgb in COLOR_PATCH_NITS],
            "durationSeconds": 6,
            "frameRate": "24/1",
            "audio": False,
        },
        "probe": stream_probe,
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(manifest_path)
    print(manifest["sha256"])


if __name__ == "__main__":
    main()
