#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_ROOT="${1:-$PROJECT_ROOT/dist}"
APP_PATH="$OUTPUT_ROOT/IPALens.app"

cd "$PROJECT_ROOT"
swift build -c release --arch x86_64 --arch arm64
BIN_PATH="$(swift build -c release --arch x86_64 --arch arm64 --show-bin-path)/IPALens"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/IPALens"
cp "$PROJECT_ROOT/SupportingFiles/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_ROOT/SupportingFiles/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

IDENTITY="${CODE_SIGN_IDENTITY:--}"
codesign --force --options runtime --entitlements "$PROJECT_ROOT/SupportingFiles/IPALens.entitlements" --sign "$IDENTITY" "$APP_PATH"

lipo -archs "$APP_PATH/Contents/MacOS/IPALens"
codesign --verify --deep --strict "$APP_PATH"
echo "$APP_PATH"
