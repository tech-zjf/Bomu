#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$PROJECT_ROOT/.build/benchmark-media"
mkdir -p "$FIXTURES"
command -v ffmpeg >/dev/null
command -v ffprobe >/dev/null

generate_video() {
  local name="$1" size="$2" duration="$3" codec="$4" format="$5"
  local codec_options=(-c:v "$codec" -preset fast)
  if [[ "$codec" == libx265 ]]; then
    codec_options+=(-x265-params 'log-level=error:pools=2' -tag:v hvc1)
  fi
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=$size:rate=30" \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t "$duration" \
    -pix_fmt "$format" "${codec_options[@]}" \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac -b:a 128k -movflags +faststart "$FIXTURES/$name.mp4"
}

generate_video h264-1080p 1920x1080 30 libx264 yuv420p
generate_video h265-main10-1080p 1920x1080 30 libx265 yuv420p10le
generate_video h265-main10-4k 3840x2160 8 libx265 yuv420p10le

python3 - "$FIXTURES" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
samples = []
for name in ['h264-1080p', 'h265-main10-1080p', 'h265-main10-4k']:
    path = root / f'{name}.mp4'
    probe = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)
    ]))
    probe['format']['filename'] = path.name
    samples.append({
        'file': path.name,
        'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'source': 'Bomu generated testsrc2 pattern and sine wave',
        'license': 'CC0-1.0',
        'probe': probe,
    })
manifest = {
    'schemaVersion': 1,
    'generator': subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0],
    'samples': samples,
}
(root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print('Generated 3 benchmark samples with source, hashes and actual media properties.')
PY
