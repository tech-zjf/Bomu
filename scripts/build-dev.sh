#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "$PROJECT_ROOT/scripts/toolchain.py"
python3 "$PROJECT_ROOT/scripts/dependencies.py" check

exec xcodebuild \
  -project "$PROJECT_ROOT/Bomu.xcodeproj" \
  -scheme Bomu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PROJECT_ROOT/.build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build "$@"
