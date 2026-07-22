#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_ROOT="$PROJECT_ROOT/dist"

"$PROJECT_ROOT/scripts/build-app.sh" "$OUTPUT_ROOT"
APP_PATH="$OUTPUT_ROOT/IPALens.app"
ZIP_PATH="$OUTPUT_ROOT/IPALens.zip"
DMG_PATH="$OUTPUT_ROOT/IPALens.dmg"

rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

hdiutil create -volname IPALens -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
codesign --force --sign - "$DMG_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "$DMG_PATH"
