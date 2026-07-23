#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SOURCE_APP="${1:-$PROJECT_ROOT/dist/IPALens.app}"
OUTPUT_ROOT="${2:-$PROJECT_ROOT/dist/installers}"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Build the Universal app first: scripts/build-app.sh" >&2
    exit 2
fi

mkdir -p "$OUTPUT_ROOT"

build_installer() {
    local architecture="$1"
    local label="$2"
    local staging_root
    staging_root="$(mktemp -d "$OUTPUT_ROOT/.staging-$architecture.XXXXXX")"
    local staged_app="$staging_root/IPALens.app"
    local service_path="$staged_app/Contents/XPCServices/IPALensContainerService.xpc"
    local package_path="$OUTPUT_ROOT/IPALens-1.0.0-$label.pkg"

    if [[ -e "$package_path" ]]; then
        mv "$package_path" "$OUTPUT_ROOT/.IPALens-1.0.0-$label.$(date +%s).previous.pkg"
    fi

    ditto "$SOURCE_APP" "$staged_app"
    lipo "$SOURCE_APP/Contents/MacOS/IPALens" -thin "$architecture" \
        -output "$staged_app/Contents/MacOS/IPALens"
    lipo "$SOURCE_APP/Contents/XPCServices/IPALensContainerService.xpc/Contents/MacOS/IPALensContainerService" \
        -thin "$architecture" \
        -output "$service_path/Contents/MacOS/IPALensContainerService"

    codesign --force --options runtime --sign - "$service_path"
    codesign --force --options runtime \
        --entitlements "$PROJECT_ROOT/SupportingFiles/IPALens.entitlements" \
        --sign - "$staged_app"
    codesign --verify --deep --strict "$staged_app"
    test "$(lipo -archs "$staged_app/Contents/MacOS/IPALens")" = "$architecture"
    test "$(lipo -archs "$service_path/Contents/MacOS/IPALensContainerService")" = "$architecture"

    pkgbuild \
        --component "$staged_app" \
        --install-location /Applications \
        --identifier "com.eripum9.IPALens.$architecture.pkg" \
        --version 1.0.0 \
        --ownership recommended \
        "$package_path"
    pkgutil --payload-files "$package_path" | grep -q '^\./IPALens.app/Contents/MacOS/IPALens$'
    echo "$package_path"
}

build_installer arm64 Apple-Silicon
build_installer x86_64 Intel
