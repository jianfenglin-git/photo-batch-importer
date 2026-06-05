#!/usr/bin/env bash
# Build a release Mach-O and wrap it into `Photo Importer.app`.
#
# Usage:
#   Scripts/build_app.sh                 # release build
#   Scripts/build_app.sh --debug         # debug build (faster, for iteration)
#
# Output:
#   build/Photo Importer.app

set -euo pipefail

CONFIG="release"
SWIFT_CONFIG_FLAG="-c release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="debug"
    SWIFT_CONFIG_FLAG="-c debug"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "› swift build $SWIFT_CONFIG_FLAG"
swift build $SWIFT_CONFIG_FLAG

BIN_PATH="$(swift build $SWIFT_CONFIG_FLAG --show-bin-path)/PhotoImporter"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "build: executable not found at $BIN_PATH" >&2
    exit 1
fi

APP_DIR="build/Photo Batch Importer.app"
echo "› assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Photo Batch Importer"
chmod +x "$APP_DIR/Contents/MacOS/Photo Batch Importer"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# Compile the app icon from the Icon Composer .icon bundle (see build_mas.sh
# for the full rationale). actool renders the proper rounded-rect macOS icon
# into Assets.car; falls back to copying a prebuilt AppIcon.icns if actool
# isn't available (CLT-only). The dyld "_kFig… missing" warnings are harmless.
if [[ -d "Resources/PhotoImporter.icon" ]] && xcrun --find actool >/dev/null 2>&1; then
    echo "› actool: compiling Resources/PhotoImporter.icon"
    xcrun actool --app-icon PhotoImporter \
        --compile "$APP_DIR/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)" \
        --output-partial-info-plist build/icon-partial.plist \
        --output-format human-readable-text \
        Resources/PhotoImporter.icon >/dev/null 2>&1
elif [[ -f Resources/AppIcon.icns ]]; then
    echo "› (actool unavailable) copying prebuilt AppIcon.icns"
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc code sign with the sandbox / iCloud-KV entitlements. Without a
# signature the entitlements file is ignored and the app runs unsandboxed —
# fine for dev, but we want parity with the MAS environment.
ENTITLEMENTS="Resources/PhotoImporter.entitlements"
if [[ -f "$ENTITLEMENTS" ]]; then
    echo "› codesign --entitlements $ENTITLEMENTS"
    codesign --force --sign - \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        "$APP_DIR" 2>/dev/null || {
        echo "  (codesign failed — app will run but entitlements won't be active)"
    }
fi

echo "› done: $REPO_ROOT/$APP_DIR"
echo "  open \"$REPO_ROOT/$APP_DIR\""
