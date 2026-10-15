#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="$PROJECT_ROOT/.build/ClangModuleCache"
PACKAGE_CACHE="$PROJECT_ROOT/.build/SwiftPMCache"
mkdir -p "$MODULE_CACHE" "$PACKAGE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
python3 "$PROJECT_ROOT/scripts/toolchain.py"
SCHEME=BomuLogicTests
DIRECT_HOSTLESS=false
if [[ "${1:-}" == --direct-hostless ]]; then
  DIRECT_HOSTLESS=true
  shift
  if [[ $# -gt 0 ]]; then
    echo "--direct-hostless runs the full hostless suite and cannot be combined with native tests or test filters." >&2
    exit 2
  fi
elif [[ "${1:-}" == --native ]]; then
  SCHEME=Bomu
  shift
  python3 "$PROJECT_ROOT/scripts/dependencies.py" check
  python3 "$PROJECT_ROOT/scripts/prepare-test-media.py"
  echo "Native integration tests reuse one application host window; no additional render-test window."
else
  python3 "$PROJECT_ROOT/scripts/prepare-test-media.py"
fi
python3 -m unittest discover -s "$PROJECT_ROOT/Tests" -p 'test_*.py'
XCODEBUILD_ARGS=(
  -project "$PROJECT_ROOT/Bomu.xcodeproj"
  -scheme "$SCHEME"
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$PROJECT_ROOT/.build/DerivedData-Tests"
  -clonedSourcePackagesDirPath "$PROJECT_ROOT/.build/SourcePackages"
  -packageCachePath "$PACKAGE_CACHE"
  -parallel-testing-enabled NO
  CODE_SIGNING_ALLOWED=NO
)
if [[ "$DIRECT_HOSTLESS" == true ]]; then
  if [[ "$SCHEME" != BomuLogicTests ]]; then
    echo "--direct-hostless requires the hostless BomuLogicTests scheme." >&2
    exit 2
  fi
  xcodebuild "${XCODEBUILD_ARGS[@]}" build-for-testing -quiet
  exec xcrun xctest "$PROJECT_ROOT/.build/DerivedData-Tests/Build/Products/Debug/BomuLogicTests.xctest"
fi
exec xcodebuild \
  "${XCODEBUILD_ARGS[@]}" test "$@"
