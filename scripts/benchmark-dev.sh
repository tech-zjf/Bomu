#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIA="$PROJECT_ROOT/.build/benchmark-media"
SYNC_MEDIA="$PROJECT_ROOT/.build/sync-fixture"
case "${1:-}" in
  --single-window) MODE=single-window ;;
  --media-suite) MODE=media-suite ;;
  --replacement-burst) MODE=replacement-burst ;;
  --playback) MODE=playback ;;
  --display-transitions) MODE=display-transitions ;;
  --help|-h|"")
    echo "Choose a visible test explicitly:"
    echo "  --single-window        One stationary ordinary window; no automatic fullscreen or display migration."
    echo "  --media-suite          30 local media cases, then lifecycle checks in that same window."
    echo "  --replacement-burst    Rapid cancel/replacement and MPEG-TS seek recovery in one ordinary window."
    echo "  --playback             Renderer baseline; opens/closes test windows and performs resize tests."
    echo "  --display-transitions  Disruptive fullscreen and multi-display cycles; arrange desktop use first."
    exit 0 ;;
  *) echo "Unknown benchmark mode. Use --help." >&2; exit 2 ;;
esac
shift
python3 "$PROJECT_ROOT/scripts/toolchain.py"
RESULTS="$PROJECT_ROOT/.build/benchmarks/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS"
python3 "$PROJECT_ROOT/scripts/dependencies.py" check
if [[ ! -f "$MEDIA/manifest.json" ]]; then
  "$PROJECT_ROOT/scripts/generate-benchmark-media.sh"
fi
if [[ ! -f "$SYNC_MEDIA/manifest.json" ]]; then
  python3 "$PROJECT_ROOT/scripts/generate-sync-fixture.py"
fi
if [[ "$MODE" != playback && ! -f "$PROJECT_ROOT/.build/window-fixture/manifest.json" ]]; then
  python3 "$PROJECT_ROOT/scripts/generate-window-fixture.py"
fi
FIXTURES=("$MEDIA" "$SYNC_MEDIA")
if [[ "$MODE" != playback ]]; then
  FIXTURES+=("$PROJECT_ROOT/.build/window-fixture")
fi
if [[ "$MODE" == media-suite || "$MODE" == replacement-burst ]]; then
  if [[ ! -f "$PROJECT_ROOT/.build/media-suite/manifest.json" ]]; then
    python3 "$PROJECT_ROOT/scripts/generate-media-suite.py"
  fi
  FIXTURES+=("$PROJECT_ROOT/.build/media-suite")
fi
python3 "$PROJECT_ROOT/scripts/media_fixtures.py" "${FIXTURES[@]}"
python3 - "$PROJECT_ROOT" "$RESULTS" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root, results = map(Path, sys.argv[1:3])
sources = {}
for directory in ['Sources', 'Tests', 'Tools', 'Config', 'scripts', 'Bomu.xcodeproj']:
    for path in sorted((root / directory).rglob('*')):
        if path.is_file() and path.suffix in {'.swift', '.m', '.h', '.py', '.sh', '.json', '.plist', '.xcconfig', '.pbxproj', '.xcscheme'}:
            sources[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
provenance = {
    'baseCommit': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
    'sourceSHA256': sources,
    'note': 'Source hashes describe the working files, including uncommitted changes.',
}
(results / 'source-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
PY
cp "$MEDIA/manifest.json" "$RESULTS/media-manifest.json"
cp "$SYNC_MEDIA/manifest.json" "$RESULTS/sync-manifest.json"
if [[ "$MODE" != playback ]]; then
  cp "$PROJECT_ROOT/.build/window-fixture/manifest.json" "$RESULTS/window-manifest.json"
fi
if [[ "$MODE" == media-suite ]]; then
  cp "$PROJECT_ROOT/.build/media-suite/manifest.json" "$RESULTS/suite-manifest.json"
fi
cp "$PROJECT_ROOT/Config/Dependencies.lock.json" "$RESULTS/dependencies.json"
sysctl -n hw.model machdep.cpu.brand_string > "$RESULTS/hardware.txt"
xcodebuild -version > "$RESULTS/toolchain.txt"
python3 "$PROJECT_ROOT/scripts/toolchain.py" --json > "$RESULTS/toolchain.json"
echo "Running playback measurements: $RESULTS"
echo "Visible test mode: $MODE. Muted test windows close when this run finishes."
xcodebuild -project "$PROJECT_ROOT/Bomu.xcodeproj" -scheme BomuBenchmark \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PROJECT_ROOT/.build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build "$@" > "$RESULTS/build.log" 2>&1
python3 - "$PROJECT_ROOT" "$MEDIA" "$SYNC_MEDIA" "$RESULTS" "$MODE" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import time

root, media, sync_media, results = map(Path, sys.argv[1:5])
mode = sys.argv[5]
output = results / ('playback-baseline.json' if mode == 'playback' else 'window-lifecycle.json')
configuration = dict(mode=mode, media=str(media), output=str(output),
    syncMedia=str(sync_media / 'av-sync-1080p60.mov'),
    cycles=os.environ.get('BOMU_BENCHMARK_CYCLES', '100'),
    soakSeconds=os.environ.get('BOMU_BENCHMARK_SOAK_SECONDS', '120'),
    previewSeconds=os.environ.get('BOMU_BENCHMARK_PREVIEW_SECONDS', '0'),
    activationGraceSeconds=os.environ.get('BOMU_BENCHMARK_ACTIVATION_GRACE_SECONDS', '0'),
    minimizeRestoreProbe=os.environ.get('BOMU_BENCHMARK_MINIMIZE_RESTORE_PROBE', '1') != '0')
if os.environ.get('BOMU_BENCHMARK_DISPLAY_ID'):
    configuration['displayID'] = os.environ['BOMU_BENCHMARK_DISPLAY_ID']
timeout = 300
if mode != 'playback':
    configuration['media'] = str(root / '.build/window-fixture/window-stress-1080p.mp4')
    timeout = 1800
if mode == 'media-suite':
    configuration['suite'] = str(root / '.build/media-suite')
if mode == 'replacement-burst':
    configuration['replacementMedia'] = str(root / '.build/media-suite/20-h264-aac.ts')
config_path = results / 'launch.json'
config_path.write_text(__import__('json').dumps(configuration, indent=2) + '\n')
application = root / '.build/DerivedData/Build/Products/Debug/BomuBenchmark.app'
launch = subprocess.run(['open', '-n', '-a', str(application), '--args', '--config', str(config_path)],
                        capture_output=True, text=True)
if launch.returncode:
    raise SystemExit(f'Launch Services failed to start the benchmark app: {launch.stderr.strip()}')
deadline = time.monotonic() + timeout
while time.monotonic() < deadline:
    if output.exists():
        report = __import__('json').loads(output.read_text())
        if report.get('completed') or report.get('failure'):
            break
    time.sleep(0.5)
else:
    raise SystemExit(f'Benchmark exceeded {timeout} seconds. Inspect {results}')
if not report.get('completed'):
    raise SystemExit(f'Benchmark failed: {report.get("failure")}. Inspect {results}')
PY
if [[ "$MODE" == replacement-burst ]]; then
  python3 "$PROJECT_ROOT/scripts/summarize-replacement-burst.py" "$RESULTS"
elif [[ "$MODE" != playback ]]; then
  python3 "$PROJECT_ROOT/scripts/summarize-window-benchmark.py" "$RESULTS"
else
  python3 "$PROJECT_ROOT/scripts/summarize-benchmark.py" "$RESULTS"
fi
echo "Playback measurements: $RESULTS"
