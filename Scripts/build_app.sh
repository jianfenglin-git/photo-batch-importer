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

# --- Nest the login-item helper -------------------------------------------
# Contents/Library/LoginItems/ is the location SMAppService.loginItem requires;
# it will not find a helper anywhere else in the bundle.
HELPER_BIN="$(swift build $SWIFT_CONFIG_FLAG --show-bin-path)/PhotoImporterHelper"
HELPER_APP="$APP_DIR/Contents/Library/LoginItems/PhotoImporterHelper.app"
if [[ -f "$HELPER_BIN" ]]; then
    echo "› embedding login item"
    mkdir -p "$HELPER_APP/Contents/MacOS"
    cp "$HELPER_BIN" "$HELPER_APP/Contents/MacOS/PhotoImporterHelper"
    chmod +x "$HELPER_APP/Contents/MacOS/PhotoImporterHelper"
    cp Resources/HelperInfo.plist "$HELPER_APP/Contents/Info.plist"
fi

# --- Sign ------------------------------------------------------------------
# Without a signature the entitlements file is ignored and the app runs with
# whatever the OS defaults to — fine for dev, but we want parity with MAS.
#
# The identity matters more than it used to: SMAppService refuses to register a
# login item whose signature doesn't carry the same Team ID as the app doing
# the registering, and an ad-hoc (`-`) signature carries no team at all. So an
# ad-hoc dev build silently can't test the auto-open toggle. Prefer a real
# Development identity and say plainly when falling back.
ENTITLEMENTS="Resources/PhotoImporter.entitlements"
HELPER_ENTITLEMENTS="Resources/PhotoImporterHelper.entitlements"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
    echo "› no 'Apple Development' identity found — signing ad-hoc"
    echo "  (everything works except the auto-open login item, which needs a team)"
else
    echo "› codesign identity: $SIGN_IDENTITY"
fi

xattr -cr "$APP_DIR"

# Inside-out: a nested bundle must be signed before the bundle that contains
# it, or the outer signature seals a helper that is about to change.
if [[ -d "$HELPER_APP" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$HELPER_ENTITLEMENTS" \
        --options runtime \
        "$HELPER_APP" || echo "  (helper codesign failed — auto-open won't register)"
fi

if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        "$APP_DIR" || echo "  (codesign failed — app runs but entitlements aren't active)"
fi

echo "› done: $REPO_ROOT/$APP_DIR"
echo "  open \"$REPO_ROOT/$APP_DIR\""
