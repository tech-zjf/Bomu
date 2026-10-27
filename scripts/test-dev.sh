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
DIRECT_STORAGE=false
TEST_DERIVED_DATA_PATH="$PROJECT_ROOT/.build/DerivedData-Tests"
CODE_SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [[ "${1:-}" == --direct-hostless ]]; then
  DIRECT_HOSTLESS=true
  shift
  if [[ $# -gt 0 ]]; then
    echo "--direct-hostless runs the full hostless suite and cannot be combined with native tests or test filters." >&2
    exit 2
  fi
elif [[ "${1:-}" == --direct-storage ]]; then
  DIRECT_HOSTLESS=true
  DIRECT_STORAGE=true
  shift
  if [[ $# -gt 0 ]]; then
    echo "--direct-storage runs only disposable-volume acceptance and accepts no additional filters." >&2
    exit 2
  fi
elif [[ "${1:-}" == --native ]]; then
  SCHEME=Bomu
  # Xcode launches a real app host; it must have a sealed ad-hoc bundle signature.
  CODE_SIGNING_ARGS=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
  # A test app inside this Desktop checkout can block in dyld while macOS waits
  # for Desktop-folder consent. Keep the launched host in the user's temp area.
  TEST_DERIVED_DATA_PATH="${TMPDIR:-/private/tmp}/Bomu-NativeTests"
  shift
  python3 "$PROJECT_ROOT/scripts/dependencies.py" check
  echo "Native integration tests reuse one application host window; no additional render-test window."
fi
python3 "$PROJECT_ROOT/scripts/prepare-test-media.py"
python3 -m unittest discover -s "$PROJECT_ROOT/Tests" -p 'test_*.py'
XCODEBUILD_ARGS=(
  -project "$PROJECT_ROOT/Bomu.xcodeproj"
  -scheme "$SCHEME"
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$TEST_DERIVED_DATA_PATH"
  -clonedSourcePackagesDirPath "$PROJECT_ROOT/.build/SourcePackages"
  -packageCachePath "$PACKAGE_CACHE"
  -parallel-testing-enabled NO
  "${CODE_SIGNING_ARGS[@]}"
)
if [[ "$DIRECT_HOSTLESS" == true ]]; then
  if [[ "$SCHEME" != BomuLogicTests ]]; then
    echo "--direct-hostless requires the hostless BomuLogicTests scheme." >&2
    exit 2
  fi
  xcodebuild "${XCODEBUILD_ARGS[@]}" build-for-testing -quiet
  XCTEST_EXECUTABLE="$(xcrun --find xctest)"
  TEST_ENV=(/usr/bin/env -i "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$HOME" "TMPDIR=${TMPDIR:-/tmp}")
  TEST_BUNDLE="$PROJECT_ROOT/.build/DerivedData-Tests/Build/Products/Debug/BomuLogicTests.xctest"
  if [[ "$DIRECT_STORAGE" == true ]]; then
    exec "${TEST_ENV[@]}" BOMU_STORAGE_INTEGRATION=1 "$XCTEST_EXECUTABLE" \
      -XCTest StorageIntegrationTests "$TEST_BUNDLE"
  fi
  exec "${TEST_ENV[@]}" "$XCTEST_EXECUTABLE" "$TEST_BUNDLE"
fi
exec xcodebuild \
  "${XCODEBUILD_ARGS[@]}" test "$@"
