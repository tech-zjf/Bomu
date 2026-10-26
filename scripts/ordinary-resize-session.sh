#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCHMARK_APP="$PROJECT_ROOT/.build/DerivedData/Build/Products/Debug/BomuBenchmark.app"
FIXTURE="$PROJECT_ROOT/.build/window-fixture"
ENVIRONMENT_KEYS=(
  BOMU_BENCHMARK_MODE
  BOMU_BENCHMARK_MEDIA
  BOMU_BENCHMARK_OUTPUT
  BOMU_BENCHMARK_CYCLES
  BOMU_BENCHMARK_SOAK_SECONDS
  BOMU_BENCHMARK_MINIMIZE_RESTORE_PROBE
)

if [[ "${1:-}" == --help ]]; then
  echo "Prepare one ordinary-resize benchmark session without launching a window."
  echo "Keep this command running, launch the printed app path with desktop automation,"
  echo "wait for its single-window test to finish, then press Return to collect and clean up."
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "No arguments are supported. Use --help for the procedure." >&2
  exit 2
fi

python3 "$PROJECT_ROOT/scripts/toolchain.py"
python3 "$PROJECT_ROOT/scripts/dependencies.py" check
test -d "$BENCHMARK_APP" || { echo "Build BomuBenchmark.app first." >&2; exit 1; }
python3 "$PROJECT_ROOT/scripts/media_fixtures.py" "$FIXTURE"
for key in "${ENVIRONMENT_KEYS[@]}"; do
  if [[ -n "$(launchctl getenv "$key" 2>/dev/null || true)" ]]; then
    echo "$key is already set; refusing to replace an existing benchmark session." >&2
    exit 1
  fi
done

TEMPORARY_ROOT="$(getconf DARWIN_USER_TEMP_DIR)"
SESSION_DIRECTORY="$(mktemp -d "$TEMPORARY_ROOT/bomu-ordinary-resize.XXXXXX")"
MARKER="$SESSION_DIRECTORY/.bomu-ordinary-resize-session"
printf 'Bomu ordinary resize session\n' > "$MARKER"
RESULTS="$PROJECT_ROOT/.build/benchmarks/ordinary-resize-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS"
ARMED=true

cleanup() {
  if [[ "$ARMED" == true ]]; then
    for key in "${ENVIRONMENT_KEYS[@]}"; do launchctl unsetenv "$key" || true; done
  fi
  if [[ -d "$SESSION_DIRECTORY" && -f "$MARKER" ]] &&
     [[ "$(cat "$MARKER")" == 'Bomu ordinary resize session' ]] &&
     [[ "$(basename "$SESSION_DIRECTORY")" == bomu-ordinary-resize.* ]]; then
    rm -rf -- "$SESSION_DIRECTORY"
  fi
  if [[ -d "$RESULTS" && ! -f "$RESULTS/window-lifecycle.json" ]]; then
    rm -f -- "$RESULTS/source-provenance.json" "$RESULTS/toolchain.json" \
      "$RESULTS/dependencies.json" "$RESULTS/window-manifest.json"
    rmdir "$RESULTS" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# APFS clones the licensed synthetic fixture without duplicating 751 MiB of blocks.
cp -c "$FIXTURE/window-stress-1080p.mp4" "$SESSION_DIRECTORY/window-stress-1080p.mp4"
python3 "$PROJECT_ROOT/scripts/build_identity.py" capture --output "$RESULTS/source-provenance.json"
python3 "$PROJECT_ROOT/scripts/toolchain.py" --json > "$RESULTS/toolchain.json"
cp "$PROJECT_ROOT/Config/Dependencies.lock.json" "$RESULTS/dependencies.json"
cp "$FIXTURE/manifest.json" "$RESULTS/window-manifest.json"
OUTPUT="$SESSION_DIRECTORY/window-lifecycle.json"
launchctl setenv BOMU_BENCHMARK_MODE ordinary-resize
launchctl setenv BOMU_BENCHMARK_MEDIA "$SESSION_DIRECTORY/window-stress-1080p.mp4"
launchctl setenv BOMU_BENCHMARK_OUTPUT "$OUTPUT"
launchctl setenv BOMU_BENCHMARK_CYCLES 100
launchctl setenv BOMU_BENCHMARK_SOAK_SECONDS 120
launchctl setenv BOMU_BENCHMARK_MINIMIZE_RESTORE_PROBE 0

echo "Benchmark app: $BENCHMARK_APP"
echo "Result directory: $RESULTS"
echo "Launch only this app through desktop automation; do not start scripts/benchmark-dev.sh."
echo "After that single-window test exits, press Return here to collect its report and clean up."
IFS= read -r _
if [[ -f "$OUTPUT" ]]; then
  cp "$OUTPUT" "$RESULTS/window-lifecycle.json"
  python3 "$PROJECT_ROOT/scripts/summarize-window-benchmark.py" "$RESULTS"
else
  echo "No benchmark report was produced; no A07 resize result can be recorded." >&2
  exit 1
fi
