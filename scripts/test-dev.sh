#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$PROJECT_ROOT/scripts/toolchain.py"
python3 -m unittest discover -s "$PROJECT_ROOT/Tests" -p 'test_*.py'
SCHEME=BomuLogicTests
if [[ "${1:-}" == --native ]]; then
  SCHEME=Bomu
  shift
  python3 "$PROJECT_ROOT/scripts/dependencies.py" check
  if [[ ! -f "$PROJECT_ROOT/.build/fixtures/manifest.json" ]]; then
    "$PROJECT_ROOT/scripts/generate-fixtures.sh"
  fi
  python3 "$PROJECT_ROOT/scripts/media_fixtures.py" "$PROJECT_ROOT/.build/fixtures"
  echo "Native integration tests launch an application host and render-test window."
fi
exec xcodebuild \
  -project "$PROJECT_ROOT/Bomu.xcodeproj" -scheme "$SCHEME" -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PROJECT_ROOT/.build/DerivedData" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test "$@"
