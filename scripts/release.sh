#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_ROOT="$PROJECT_ROOT/dist"

: "${CODE_SIGN_IDENTITY:?Set CODE_SIGN_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"

"$PROJECT_ROOT/scripts/build-app.sh" "$OUTPUT_ROOT"
APP_PATH="$OUTPUT_ROOT/IPALens.app"
ZIP_PATH="$OUTPUT_ROOT/IPALens.zip"
DMG_PATH="$OUTPUT_ROOT/IPALens.dmg"

rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"

hdiutil create -volname IPALens -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
codesign --force --sign "$CODE_SIGN_IDENTITY" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"

echo "$DMG_PATH"
