#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$PROJECT_ROOT/.build/fixtures"
mkdir -p "$FIXTURES"
command -v ffmpeg >/dev/null || { echo 'FFmpeg is required only to generate synthetic test media.' >&2; exit 1; }
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=960x540:rate=30' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 15 -c:v libx264 -preset fast \
  -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -b:a 128k -movflags +faststart "$FIXTURES/h264-sdr.mp4"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=30' \
  -f lavfi -i 'sine=frequency=880:sample_rate=48000' -t 15 -c:v libx265 -preset fast \
  -x265-params 'log-level=error:pools=2' -pix_fmt yuv420p10le \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -tag:v hvc1 \
  -c:a aac -b:a 128k -movflags +faststart "$FIXTURES/h265-main10-sdr.mp4"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=24' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
  -f lavfi -i 'sine=frequency=880:sample_rate=48000' -t 3 \
  -map 0:v:0 -map 1:a:0 -map 2:a:0 -c:v libx264 -preset fast -pix_fmt yuv420p \
  -c:a:0 aac -b:a:0 96k -c:a:1 alac -movflags +faststart \
  "$FIXTURES/mixed-audio-tracks.mp4"
printf 'Bomu intentionally invalid media fixture\n' > "$FIXTURES/corrupt.mp4"
python3 - "$FIXTURES" <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
rows = []
# Only label media produced by this script; never import arbitrary user files.
for name in ['h264-sdr.mp4', 'h265-main10-sdr.mp4', 'mixed-audio-tracks.mp4', 'corrupt.mp4']:
    path = root / name
    row = {
        'file': name,
        'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'source': 'Bomu synthetic test pattern and sine wave; generated locally',
        'license': 'CC0-1.0',
        'expected': 'decoding failure' if name == 'corrupt.mp4' else 'readable video+audio',
    }
    if name != 'corrupt.mp4':
        row['probe'] = json.loads(subprocess.check_output([
            'ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)
        ]))
    rows.append(row)
version = subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0]
manifest = {'schemaVersion': 1, 'generator': version, 'samples': rows}
(root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print('Generated 3 licensed synthetic playback samples and 1 corruption fixture.')
PY
