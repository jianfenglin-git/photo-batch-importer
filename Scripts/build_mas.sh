#!/usr/bin/env bash
# Build a Mac App Store submission: a sandboxed, signed, universal
# `Photo Importer.app` wrapped in a signed installer `.pkg` ready to upload
# to App Store Connect via Transporter.
#
# Prerequisites (one-time, see README "Mac App Store build"):
#   - "Apple Distribution: … (TEAMID)" identity in the keychain  (signs .app)
#   - "3rd Party Mac Developer Installer: … (TEAMID)" identity   (signs .pkg)
#   - Apple WWDR G3 intermediate cert installed                  (chain)
#   - A Mac App Store provisioning profile for the app's bundle id
#
# Usage:
#   Scripts/build_mas.sh
#
# Override autodetected values with env vars if needed:
#   APP_IDENTITY="Apple Distribution: Jianfeng Lin (MA5JSLK6AZ)"
#   PKG_IDENTITY="3rd Party Mac Developer Installer: Jianfeng Lin (MA5JSLK6AZ)"
#   PROFILE="certs/Photo_Importer.provisionprofile"
#
# Output:
#   build/Photo Importer.app   (sandboxed, signed)
#   build/Photo Importer.pkg   (installer-signed; upload this)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Photo Batch Importer"
APP_DIR="build/${APP_NAME}.app"
PKG_PATH="build/${APP_NAME}.pkg"
ENTITLEMENTS="Resources/PhotoImporter.mas.entitlements"
PROFILE="${PROFILE:-certs/Photo_Importer.provisionprofile}"
ICON_NAME="PhotoImporter"   # → Resources/PhotoImporter.icon (Icon Composer bundle)

# --- Resolve signing identities -------------------------------------------
# Autodetect from the keychain unless the caller pinned them via env vars.
if [[ -z "${APP_IDENTITY:-}" ]]; then
    APP_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Distribution: [^"]*"' | head -1 | tr -d '"')"
fi
if [[ -z "${PKG_IDENTITY:-}" ]]; then
    PKG_IDENTITY="$(security find-identity -v 2>/dev/null \
        | grep -o '"3rd Party Mac Developer Installer: [^"]*"' | head -1 | tr -d '"')"
fi

if [[ -z "$APP_IDENTITY" ]]; then
    echo "error: no 'Apple Distribution' identity found in keychain." >&2
    echo "       Import your distribution cert + WWDR G3 intermediate first." >&2
    exit 1
fi
if [[ -z "$PKG_IDENTITY" ]]; then
    echo "error: no '3rd Party Mac Developer Installer' identity found." >&2
    exit 1
fi
if [[ ! -f "$PROFILE" ]]; then
    echo "error: provisioning profile not found at: $PROFILE" >&2
    echo "       Set PROFILE=... or place it at certs/Photo_Importer.provisionprofile" >&2
    exit 1
fi

echo "› app identity: $APP_IDENTITY"
echo "› pkg identity: $PKG_IDENTITY"
echo "› profile:      $PROFILE"

# --- Build a release binary ------------------------------------------------
# A universal (arm64 + x86_64) build needs xcbuild, which ships only with the
# full Xcode. With Command Line Tools alone we fall back to a native-arch
# build — Apple accepts single-architecture Mac App Store apps. Set
# UNIVERSAL=0 to force native even when full Xcode is present.
ARCH_FLAGS=()
BUILD_KIND="native ($(uname -m))"
if [[ "${UNIVERSAL:-1}" == "1" ]] \
    && [[ -x "/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    BUILD_KIND="universal (arm64 + x86_64)"
fi

echo "› swift build -c release [$BUILD_KIND]"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN_PATH="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/PhotoImporter"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "error: executable not found at $BIN_PATH" >&2
    exit 1
fi

# --- Assemble the .app bundle ---------------------------------------------
echo "› assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# --- Compile the app icon from the Icon Composer .icon bundle --------------
# Resources/PhotoImporter.icon is an Icon Composer source (icon.json + art),
# NOT a finished icon. actool (full Xcode) renders it into Assets.car (the
# primary icon source on macOS 13+) plus a fallback .icns, with the proper
# rounded-rect macOS shape baked in (transparent corners). A flat full-bleed
# PNG/icns instead shows as a hard SQUARE in Dock/Launchpad — that was the bug
# this fixes. --app-icon must match the .icon file's basename.
#
# The dyld "_kFig… missing symbol" warnings from running Xcode 26's actool on
# macOS 15 are harmless (set to no-op) and don't affect output.
ICON_SRC="Resources/${ICON_NAME}.icon"
if [[ -d "$ICON_SRC" ]] && xcrun --find actool >/dev/null 2>&1; then
    echo "› actool: compiling $ICON_SRC"
    ICON_PARTIAL="build/icon-partial.plist"
    xcrun actool \
        --app-icon "$ICON_NAME" \
        --compile "$APP_DIR/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)" \
        --output-partial-info-plist "$ICON_PARTIAL" \
        --output-format human-readable-text \
        "$ICON_SRC" >/dev/null 2>&1
    if [[ ! -f "$APP_DIR/Contents/Resources/Assets.car" ]]; then
        echo "error: actool did not produce Assets.car — icon compile failed" >&2
        exit 1
    fi
else
    echo "error: $ICON_SRC not found or actool unavailable (needs full Xcode)." >&2
    exit 1
fi

# The Mac App Store requires the provisioning profile embedded in the bundle
# BEFORE signing, at this exact path. Copy via `cat` (stream the bytes) rather
# than `cp`: cp clones the source's extended attributes, and a browser-
# downloaded profile carries com.apple.quarantine (rejected, error 91109) plus
# com.apple.macl — and macl is reapplied by the OS and survives `xattr -c`.
# Streaming the contents yields a fresh file with no inherited attributes.
cat "$PROFILE" > "$APP_DIR/Contents/embedded.provisionprofile"

# --- Strip extended attributes BEFORE signing ------------------------------
# Files copied in from disk can carry xattrs the App Store rejects — most
# commonly com.apple.quarantine on a browser-downloaded provisioning profile
# (error 91109), plus com.apple.macl / provenance / kMDItemWhereFroms. Clear
# them recursively so the cleared state is what gets sealed into the signature.
echo "› clearing extended attributes"
xattr -cr "$APP_DIR"

# --- Sign the app ----------------------------------------------------------
# No --options runtime: hardened runtime is a Developer-ID/notarization
# concern, not a Mac App Store one. --timestamp is required for submission.
echo "› codesign app"
codesign --force --sign "$APP_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_DIR"

echo "› verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# --- Build the signed installer -------------------------------------------
# The App Store needs BOTH of these in the product archive, and getting one
# can break the other:
#   (a) the app component NON-relocatable — otherwise PackageInfo carries a
#       <relocate> block and, if LaunchServices already knows this bundle id at
#       another path (e.g. a local build-dir copy), the installer adopts that
#       copy instead of writing to /Applications: the install reports success
#       but the app is nowhere (this silently broke local + TestFlight installs).
#   (b) product-level metadata — <product id/version> and an os-version
#       requirement matching LSMinimumSystemVersion. `productbuild --package`
#       (the simple wrapper) omits these → App Store errors 90230 / 90264.
# So: pkgbuild makes a non-relocatable component pkg (a), then we synthesize a
# distribution, inject <product>, and `productbuild --distribution` to get (b).
echo "› building installer (non-relocatable, with product metadata)"
rm -f "$PKG_PATH"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")"
BUNDLE_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
SHORT_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_DIR/Contents/Info.plist")"

COMPONENT_PLIST="build/component.plist"
COMPONENT_PKG="build/component.pkg"
REQUIREMENTS="build/requirements.plist"
DIST="build/distribution.xml"
STAGE="build/stage"
rm -rf "$STAGE" "$COMPONENT_PKG" "$DIST" "$REQUIREMENTS"
mkdir -p "$STAGE"

# (a) Non-relocatable component pkg. ditto preserves the code signature.
ditto "$APP_DIR" "$STAGE/${APP_NAME}.app"
pkgbuild --analyze --root "$STAGE" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"
pkgbuild --root "$STAGE" \
    --component-plist "$COMPONENT_PLIST" \
    --identifier "$BUNDLE_ID" \
    --version "$BUNDLE_VER" \
    --install-location /Applications \
    "$COMPONENT_PKG"

# (b) Product metadata. A requirements plist injects the os-version block;
# synthesize a distribution, then add the <product id/version> element the
# App Store requires (synthesize alone omits it).
cat > "$REQUIREMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>os</key>
    <array><string>${MIN_OS}</string></array>
</dict>
</plist>
PLIST
productbuild --synthesize --product "$REQUIREMENTS" --package "$COMPONENT_PKG" "$DIST"
# Insert <product id/version> right after the opening installer-gui-script tag.
awk -v id="$BUNDLE_ID" -v ver="$SHORT_VER" \
    '/<installer-gui-script/{print; print "    <product id=\"" id "\" version=\"" ver "\"/>"; next} {print}' \
    "$DIST" > "$DIST.tmp" && mv "$DIST.tmp" "$DIST"

productbuild --distribution "$DIST" --package-path build \
    --sign "$PKG_IDENTITY" \
    "$PKG_PATH"
rm -rf "$STAGE" "$COMPONENT_PKG"

echo
echo "› done."
echo "  app: $REPO_ROOT/$APP_DIR"
echo "  pkg: $REPO_ROOT/$PKG_PATH"
echo
echo "Next: open Transporter, sign in, drag in the .pkg, and Deliver."
