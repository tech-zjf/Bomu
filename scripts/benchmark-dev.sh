#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="$PROJECT_ROOT/.build/ClangModuleCache"
PACKAGE_CACHE="$PROJECT_ROOT/.build/SwiftPMCache"
mkdir -p "$MODULE_CACHE" "$PACKAGE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
MEDIA="$PROJECT_ROOT/.build/benchmark-media"
SYNC_MEDIA="$PROJECT_ROOT/.build/sync-fixture"
case "${1:-}" in
  --single-window) MODE=single-window ;;
  --ordinary-resize) MODE=ordinary-resize ;;
  --media-suite) MODE=media-suite ;;
  --b11-suite) MODE=b11-suite ;;
  --replacement-burst) MODE=replacement-burst ;;
  --playback) MODE=playback ;;
  --display-transitions) MODE=display-transitions ;;
  --help|-h|"")
    echo "Choose a visible test explicitly:"
    echo "  --single-window        One stationary ordinary window; no automatic fullscreen or display migration."
    echo "  --ordinary-resize      Resize one ordinary window during 100 playback cycles; no fullscreen or display migration."
    echo "  --media-suite          30 local media cases, then lifecycle checks in that same window."
    echo "  --b11-suite            60 audiovisual cases, 100 file switches and 30-minute sync playback in one window."
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
APP_TEST_DATA="$(mktemp -d "${TMPDIR:-/tmp}/bomu-benchmark.XXXXXX")"
trap 'rm -rf -- "$APP_TEST_DATA"' EXIT
python3 "$PROJECT_ROOT/scripts/dependencies.py" check
if [[ ! -f "$MEDIA/manifest.json" ]]; then
  "$PROJECT_ROOT/scripts/generate-benchmark-media.sh"
fi
if [[ ! -f "$SYNC_MEDIA/manifest.json" ]]; then
  python3 "$PROJECT_ROOT/scripts/generate-sync-fixture.py"
fi
SYNC_SOAK_MEDIA="$PROJECT_ROOT/.build/sync-soak-fixture"
if [[ "$MODE" == b11-suite && ( ! -f "$SYNC_SOAK_MEDIA/manifest.json" || ! -f "$SYNC_SOAK_MEDIA/av-sync-33-minute.mp4" ) ]]; then
  python3 "$PROJECT_ROOT/scripts/generate-sync-soak-fixture.py"
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
if [[ "$MODE" == b11-suite ]]; then
  if [[ ! -f "$PROJECT_ROOT/.build/b11-media-suite/manifest.json" ]]; then
    python3 "$PROJECT_ROOT/scripts/generate-media-suite.py" --suite b11
  fi
  FIXTURES+=("$PROJECT_ROOT/.build/b11-media-suite" "$SYNC_SOAK_MEDIA")
fi
python3 "$PROJECT_ROOT/scripts/media_fixtures.py" "${FIXTURES[@]}"
# The benchmark is a separate macOS app. Keep every file it reads or writes in
# the system temporary directory so TCC does not block its launch while asking
# for access to the repository under Desktop.
for fixture in "${FIXTURES[@]}"; do
  cp -R "$fixture" "$APP_TEST_DATA/$(basename "$fixture")"
done
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
if [[ "$MODE" == b11-suite ]]; then
  cp "$PROJECT_ROOT/.build/b11-media-suite/manifest.json" "$RESULTS/suite-manifest.json"
  cp "$SYNC_SOAK_MEDIA/manifest.json" "$RESULTS/sync-soak-manifest.json"
fi
cp "$PROJECT_ROOT/Config/Dependencies.lock.json" "$RESULTS/dependencies.json"
if ! sysctl -n hw.model machdep.cpu.brand_string > "$RESULTS/hardware.txt" 2> "$RESULTS/hardware-error.txt"; then
  printf 'Hardware identity unavailable in this execution environment.\n' > "$RESULTS/hardware.txt"
fi
xcodebuild -version > "$RESULTS/toolchain.txt"
python3 "$PROJECT_ROOT/scripts/toolchain.py" --json > "$RESULTS/toolchain.json"
echo "Running playback measurements: $RESULTS"
echo "Visible test mode: $MODE. Muted test windows close when this run finishes."
xcodebuild -project "$PROJECT_ROOT/Bomu.xcodeproj" -scheme BomuBenchmark \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PROJECT_ROOT/.build/DerivedData" \
  -clonedSourcePackagesDirPath "$PROJECT_ROOT/.build/SourcePackages" \
  -packageCachePath "$PACKAGE_CACHE" \
  CODE_SIGNING_ALLOWED=NO build "$@" > "$RESULTS/build.log" 2>&1
python3 - "$PROJECT_ROOT" "$RESULTS" "$MODE" "$APP_TEST_DATA" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

root, results = map(Path, sys.argv[1:3])
mode = sys.argv[3]
app_data = Path(sys.argv[4])
output_name = 'playback-baseline.json' if mode == 'playback' else 'window-lifecycle.json'
output = app_data / output_name
media = app_data / 'benchmark-media'
sync_media = app_data / 'sync-fixture'
if mode != 'playback':
    media = app_data / 'window-fixture' / 'window-stress-1080p.mp4'
configuration = dict(mode=mode, media=str(media), output=str(output),
    syncMedia=str(sync_media / 'av-sync-1080p60.mov'),
    cycles=os.environ.get('BOMU_BENCHMARK_CYCLES', '100'),
    soakSeconds=os.environ.get('BOMU_BENCHMARK_SOAK_SECONDS', '120'),
    previewSeconds=os.environ.get('BOMU_BENCHMARK_PREVIEW_SECONDS', '0'),
    activationGraceSeconds=os.environ.get('BOMU_BENCHMARK_ACTIVATION_GRACE_SECONDS', '0'),
    minimizeRestoreProbe=os.environ.get('BOMU_BENCHMARK_MINIMIZE_RESTORE_PROBE', '1') != '0')
if os.environ.get('BOMU_BENCHMARK_DISPLAY_ID'):
    configuration['displayID'] = os.environ['BOMU_BENCHMARK_DISPLAY_ID']
if mode == 'ordinary-resize':
    configuration['minimizeRestoreProbe'] = False
timeout = 300
if mode != 'playback':
    timeout = 1800
if mode == 'media-suite':
    configuration['suite'] = str(app_data / 'media-suite')
if mode == 'b11-suite':
    configuration['suite'] = str(app_data / 'b11-media-suite')
    configuration['syncMedia'] = str(app_data / 'sync-soak-fixture/av-sync-33-minute.mp4')
    configuration['cycles'] = '100'
    configuration['soakSeconds'] = '1800'
    configuration['minimizeRestoreProbe'] = False
    timeout = 2400
if mode == 'replacement-burst':
    configuration['replacementMedia'] = str(app_data / 'media-suite/20-h264-aac.ts')
config_path = app_data / 'launch.json'
config_path.write_text(__import__('json').dumps(configuration, indent=2) + '\n')
try:
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
finally:
    if output.exists():
        shutil.copy2(output, results / output_name)
PY
if [[ "$MODE" == replacement-burst ]]; then
  python3 "$PROJECT_ROOT/scripts/summarize-replacement-burst.py" "$RESULTS"
elif [[ "$MODE" != playback ]]; then
  python3 "$PROJECT_ROOT/scripts/summarize-window-benchmark.py" "$RESULTS"
else
  python3 "$PROJECT_ROOT/scripts/summarize-benchmark.py" "$RESULTS"
fi
echo "Playback measurements: $RESULTS"
