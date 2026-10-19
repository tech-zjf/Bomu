#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS="$PROJECT_ROOT/.build/DerivedData/Build/Products/Debug"
SOURCE_APP="$PRODUCTS/Bomu.app"
OUTPUT_DIR="$PROJECT_ROOT/.build/distribution/internal"
STAGING="$OUTPUT_DIR/staging"

"$PROJECT_ROOT/scripts/build-dev.sh" -quiet
test -d "$SOURCE_APP"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$SOURCE_APP" "$STAGING/Bomu.app"

python3 "$PROJECT_ROOT/scripts/package_internal.py" "$STAGING/Bomu.app"
codesign --force --deep --sign - "$STAGING/Bomu.app"
codesign --verify --deep --strict "$STAGING/Bomu.app"

ln -s /Applications "$STAGING/Applications"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGING/Bomu.app/Contents/Info.plist")
DMG="$OUTPUT_DIR/Bomu-$VERSION-internal-arm64.dmg"
mkdir -p "$OUTPUT_DIR"
rm -f "$DMG"
hdiutil create -quiet -volname "Bomu $VERSION Internal" -srcfolder "$STAGING" -format UDZO "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG"
rm -rf "$STAGING"
echo "Internal development package: $DMG"
