#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIA="$PROJECT_ROOT/.build/benchmark-media"
SYNC_MEDIA="$PROJECT_ROOT/.build/sync-fixture"
case "${1:-}" in
  --single-window) MODE=single-window ;;
  --playback) MODE=playback ;;
  --display-transitions) MODE=display-transitions ;;
  --help|-h|"")
    echo "Choose a visible test explicitly:"
    echo "  --single-window        One stationary ordinary window; no automatic fullscreen or display migration."
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

root, media, sync_media, results = map(Path, sys.argv[1:5])
mode = sys.argv[5]
environment = dict(os.environ,
    BOMU_BENCHMARK_MODE=mode,
    BOMU_BENCHMARK_MEDIA=str(media),
    BOMU_BENCHMARK_SYNC_MEDIA=str(sync_media / 'av-sync-1080p60.mov'),
    BOMU_BENCHMARK_OUTPUT=str(results / 'playback-baseline.json'),
    CA_ASSERT_MAIN_THREAD_TRANSACTIONS='1')
timeout = 300
if mode != 'playback':
    environment['BOMU_BENCHMARK_MEDIA'] = str(root / '.build/window-fixture/window-stress-1080p.mp4')
    environment['BOMU_BENCHMARK_OUTPUT'] = str(results / 'window-lifecycle.json')
    timeout = 1800
binary = root / '.build/DerivedData/Build/Products/Debug/BomuBenchmark.app/Contents/MacOS/BomuBenchmark'
with (results / 'process.log').open('w') as log:
    try:
        result = subprocess.run([str(binary)], env=environment, stdout=log,
                                stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        # subprocess.run terminates and waits for this child only.
        raise SystemExit(f'Benchmark exceeded {timeout} seconds. Inspect {results / "process.log"}')
if result.returncode:
    raise SystemExit(f'Benchmark failed ({result.returncode}). Inspect {results / "process.log"}')
PY
if [[ "$MODE" != playback ]]; then
  python3 "$PROJECT_ROOT/scripts/summarize-window-benchmark.py" "$RESULTS"
else
  python3 "$PROJECT_ROOT/scripts/summarize-benchmark.py" "$RESULTS"
fi
echo "Playback measurements: $RESULTS"
