#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="$PROJECT_ROOT/.build/ClangModuleCache"
PACKAGE_CACHE="$PROJECT_ROOT/.build/SwiftPMCache"
BUILD_ACTION=build
BUILD_SCHEME=Bomu
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"
case "${1:-}" in
  --benchmark)
    BUILD_SCHEME=BomuBenchmark
    shift
    ;;
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
IDENTITY_RECEIPT=""
if [[ "$BUILD_ACTION" == "build" && "$BUILD_SCHEME" == "Bomu" ]]; then
  IDENTITY_RECEIPT="$DERIVED_DATA/Build/Products/Debug/Bomu.build-identity.json"
  rm -f "$IDENTITY_RECEIPT"
fi
mkdir -p "$MODULE_CACHE" "$PACKAGE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

python3 "$PROJECT_ROOT/scripts/toolchain.py"
python3 "$PROJECT_ROOT/scripts/dependencies.py" check

if [[ "$BUILD_ACTION" == "build-for-testing" ]]; then
  python3 "$PROJECT_ROOT/scripts/prepare-test-media.py"
fi

IDENTITY_SNAPSHOT=""
if [[ -n "$IDENTITY_RECEIPT" ]]; then
  mkdir -p "$PROJECT_ROOT/.build/BuildIdentity"
  IDENTITY_SNAPSHOT="$(mktemp "$PROJECT_ROOT/.build/BuildIdentity/source.XXXXXX")"
  trap 'rm -f "$IDENTITY_SNAPSHOT"' EXIT
  python3 "$PROJECT_ROOT/scripts/build_identity.py" capture --output "$IDENTITY_SNAPSHOT"
fi

xcodebuild \
  -project "$PROJECT_ROOT/Bomu.xcodeproj" \
  -scheme "$BUILD_SCHEME" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$PROJECT_ROOT/.build/SourcePackages" \
  -packageCachePath "$PACKAGE_CACHE" \
  CODE_SIGNING_ALLOWED=NO \
  "$BUILD_ACTION" "$@"

if [[ -n "$IDENTITY_SNAPSHOT" ]]; then
  python3 "$PROJECT_ROOT/scripts/build_identity.py" finalize \
    --snapshot "$IDENTITY_SNAPSHOT" \
    --app "$DERIVED_DATA/Build/Products/Debug/Bomu.app" \
    --output "$IDENTITY_RECEIPT"
fi
