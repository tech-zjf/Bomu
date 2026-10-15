#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="$PROJECT_ROOT/.build/ClangModuleCache"
PACKAGE_CACHE="$PROJECT_ROOT/.build/SwiftPMCache"
BUILD_ACTION=build
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"
case "${1:-}" in
  --for-testing)
    BUILD_ACTION=build-for-testing
    DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData-ForTesting"
    shift
    ;;
  --analyze)
    BUILD_ACTION=analyze
    shift
    ;;
esac
mkdir -p "$MODULE_CACHE" "$PACKAGE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

python3 "$PROJECT_ROOT/scripts/toolchain.py"
python3 "$PROJECT_ROOT/scripts/dependencies.py" check

if [[ "$BUILD_ACTION" == "build-for-testing" ]]; then
  python3 "$PROJECT_ROOT/scripts/prepare-test-media.py"
fi

exec xcodebuild \
  -project "$PROJECT_ROOT/Bomu.xcodeproj" \
  -scheme Bomu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$PROJECT_ROOT/.build/SourcePackages" \
  -packageCachePath "$PACKAGE_CACHE" \
  CODE_SIGNING_ALLOWED=NO \
  "$BUILD_ACTION" "$@"
