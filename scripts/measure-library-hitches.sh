#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECEIPT="$PROJECT_ROOT/.build/DerivedData/Build/Products/Debug/Bomu.build-identity.json"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData-HitchTests"
RESULT_DIRECTORY="$PROJECT_ROOT/.build/benchmarks"

# Bounds only this invocation and its child process group, never an existing Bomu.
run_bounded() {
  python3 - "$@" <<'BOUNDED_PY'
import os
import signal
import subprocess
import sys

def interrupted(signum, frame):
    raise SystemExit(128 + signum)

for signum in (signal.SIGINT, signal.SIGTERM):
    signal.signal(signum, interrupted)
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
cleanup_required = True
try:
    try:
        code = process.wait(timeout=float(sys.argv[1]))
        cleanup_required = code != 0
        raise SystemExit(code if code >= 0 else 128 - code)
    except subprocess.TimeoutExpired:
        print("Hitch command exceeded its wall limit; this sample is invalid.", file=sys.stderr)
        raise SystemExit(124)
finally:
    if cleanup_required:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        # The leader may exit before a child; still clean this owned group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
BOUNDED_PY
}

BUILD_ONLY=false
if [[ $# -eq 1 && "$1" == "--build-only" ]]; then
  BUILD_ONLY=true
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--build-only]" >&2
  exit 2
fi

# The UI test attaches to an already running canonical app; this script never launches Bomu.
check_unlocked() {
python3 - <<'PY'
import re
import subprocess

state = subprocess.run(
    ["/usr/sbin/ioreg", "-r", "-k", "IOConsoleLocked", "-d", "1"],
    capture_output=True, text=True, check=True,
).stdout
if not re.search(r'"IOConsoleLocked"\s*=\s*No\b', state):
    raise SystemExit("The screen is locked or its unlock state is unknown; no UI measurement was started.")
PY
}
if [[ "$BUILD_ONLY" == false ]]; then
  python3 "$PROJECT_ROOT/scripts/build_identity.py" verify --receipt "$RECEIPT"
  check_unlocked
fi

MODULE_CACHE="$PROJECT_ROOT/.build/ClangModuleCache"
PACKAGE_CACHE="$PROJECT_ROOT/.build/SwiftPMCache"
mkdir -p "$MODULE_CACHE" "$PACKAGE_CACHE" "$RESULT_DIRECTORY"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
python3 "$PROJECT_ROOT/scripts/toolchain.py"

COMMON_ARGS=(
  -destination 'platform=macOS,arch=arm64'
  -parallel-testing-enabled NO
  -derivedDataPath "$DERIVED_DATA"
  -clonedSourcePackagesDirPath "$PROJECT_ROOT/.build/SourcePackages"
  -packageCachePath "$PACKAGE_CACHE"
)
run_bounded 300 xcodebuild -project "$PROJECT_ROOT/Bomu.xcodeproj" -scheme BomuHitchUITests \
  -configuration Debug "${COMMON_ARGS[@]}" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing -quiet

shopt -s nullglob
RUN_FILES=("$DERIVED_DATA"/Build/Products/BomuHitchUITests_macosx*-arm64.xctestrun)
if [[ ${#RUN_FILES[@]} -ne 1 ]]; then
  echo "Expected one UI test run file, found ${#RUN_FILES[@]}." >&2
  exit 1
fi
RUN_FILE="${RUN_FILES[0]}"
RUNNER_APP="$DERIVED_DATA/Build/Products/Debug/BomuHitchUITests-Runner.app"
if [[ ! -x "$RUNNER_APP/Contents/MacOS/BomuHitchUITests-Runner" ||
      ! -d "$RUNNER_APP/Contents/PlugIns/BomuHitchUITests.xctest" ]]; then
  echo "The UI test runner or its test bundle is missing; no measurement was started." >&2
  exit 1
fi
if ! codesign --verify --deep --strict "$RUNNER_APP"; then
  echo "The UI test runner signature is invalid; no measurement was started." >&2
  exit 1
fi
python3 - "$RUN_FILE" <<'RUNFILE_PY'
import plistlib
import sys
from pathlib import Path
run = plistlib.loads(Path(sys.argv[1]).read_bytes())
targets = {key: value for key, value in run.items() if not key.startswith("__")}
if list(targets) != ["BomuHitchUITests"]:
    raise SystemExit("Unexpected test targets; no UI measurement was started.")
target = targets["BomuHitchUITests"]
if (target.get("TestHostPath") != "__TESTROOT__/Debug/BomuHitchUITests-Runner.app"
        or target.get("IsUITestBundle") is not True
        or target.get("UseUITargetAppProvidedByTests") is not True
        or target.get("UITargetAppPath")):
    raise SystemExit("Unexpected host or configured target-app launch; refusing measurement.")
RUNFILE_PY
if [[ "$BUILD_ONLY" == true ]]; then
  echo "Hitch runner compiled and launch configuration checked; no UI test was started."
  exit 0
fi
# A unique directory prevents same-second runs from overwriting evidence.
RUN_DIRECTORY="$(mktemp -d "$RESULT_DIRECTORY/library-hitches-$(date +%Y%m%d-%H%M%S).XXXXXX")"
RESULT_BUNDLE="$RUN_DIRECTORY/result.xcresult"
# Building the runner may take time: recheck the package and lock state immediately before use.
python3 "$PROJECT_ROOT/scripts/build_identity.py" verify --receipt "$RECEIPT"
check_unlocked
cp "$RUN_FILE" "$RUN_DIRECTORY/configuration.xctestrun"
echo "Measuring the already-open Library window. XCTest must find one verified Bomu process."
run_bounded 180 xcodebuild -xctestrun "$RUN_FILE" "${COMMON_ARGS[@]}" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 90 \
  -maximum-test-execution-time-allowance 90 \
  -only-testing:BomuHitchUITests/LibraryHitchUITests/testLibraryScrollWhilePlaying \
  test-without-building -quiet
echo "UI performance result: $RESULT_BUNDLE"
