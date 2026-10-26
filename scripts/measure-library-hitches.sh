#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECEIPT="$PROJECT_ROOT/.build/DerivedData/Build/Products/Debug/Bomu.build-identity.json"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData-HitchTests"
RESULT_DIRECTORY="$PROJECT_ROOT/.build/benchmarks"

if [[ $# -ne 0 ]]; then
  echo "This opt-in measurement accepts no arguments." >&2
  exit 2
fi

# The UI test attaches to an already running canonical app; this script never launches Bomu.
python3 "$PROJECT_ROOT/scripts/build_identity.py" verify --receipt "$RECEIPT"
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
xcodebuild -project "$PROJECT_ROOT/Bomu.xcodeproj" -scheme BomuHitchUITests \
  -configuration Debug "${COMMON_ARGS[@]}" CODE_SIGNING_ALLOWED=NO build-for-testing -quiet

shopt -s nullglob
RUN_FILES=("$DERIVED_DATA"/Build/Products/BomuHitchUITests_macosx*-arm64.xctestrun)
if [[ ${#RUN_FILES[@]} -ne 1 ]]; then
  echo "Expected one UI test run file, found ${#RUN_FILES[@]}." >&2
  exit 1
fi
RUN_FILE="${RUN_FILES[0]}"
RESULT_BUNDLE="$RESULT_DIRECTORY/library-hitches-$(date +%Y%m%d-%H%M%S).xcresult"
echo "Measuring the already-open Library window. XCTest must find one verified Bomu process."
xcodebuild -xctestrun "$RUN_FILE" "${COMMON_ARGS[@]}" \
  -resultBundlePath "$RESULT_BUNDLE" test-without-building -quiet
echo "UI performance result: $RESULT_BUNDLE"
