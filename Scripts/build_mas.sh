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
# Full Xcode is NOT required. Without it:
#   - the pre-compiled icon in Resources/CompiledIcon is used, after verifying
#     it matches the icon source;
#   - the universal binary is built per-arch with --triple and merged by lipo,
#     rather than by xcbuild.
#
# Usage:
#   Scripts/build_mas.sh
#   Scripts/build_mas.sh --refresh-icon-cache   (full Xcode only; see below)
#
# Override autodetected values with env vars if needed:
#   APP_IDENTITY="Apple Distribution: Jianfeng Lin (MA5JSLK6AZ)"
#   PKG_IDENTITY="3rd Party Mac Developer Installer: Jianfeng Lin (MA5JSLK6AZ)"
#   PROFILE="certs/Photo_Importer.provisionprofile"
#   REFRESH_ICON_CACHE=1   same as --refresh-icon-cache
#
# Output:
#   build/Photo Importer.app   (sandboxed, signed)
#   build/Photo Importer.pkg   (installer-signed; upload this)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

for arg in "$@"; do
    case "$arg" in
        --refresh-icon-cache) REFRESH_ICON_CACHE=1 ;;
        *) echo "error: unknown argument: $arg" >&2; exit 1 ;;
    esac
done

APP_NAME="Photo Batch Importer"
APP_DIR="build/${APP_NAME}.app"
PKG_PATH="build/${APP_NAME}.pkg"
ENTITLEMENTS="Resources/PhotoImporter.mas.entitlements"
PROFILE="${PROFILE:-certs/Photo_Importer.provisionprofile}"
ICON_NAME="PhotoImporter"   # → Resources/PhotoImporter.icon (Icon Composer bundle)

# --- Resolve signing identities -------------------------------------------
# Autodetect from the keychain unless the caller pinned them via env vars.
# The trailing `|| true` matters: with `set -e` + `pipefail`, grep finding no
# match fails the whole substitution and kills the script *silently*, so the
# actionable "no identity found" message below would never print — which is
# exactly the case a fresh machine hits.
if [[ -z "${APP_IDENTITY:-}" ]]; then
    APP_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Distribution: [^"]*"' | head -1 | tr -d '"' || true)"
fi
if [[ -z "${PKG_IDENTITY:-}" ]]; then
    PKG_IDENTITY="$(security find-identity -v 2>/dev/null \
        | grep -o '"3rd Party Mac Developer Installer: [^"]*"' | head -1 | tr -d '"' || true)"
fi

if [[ -z "$APP_IDENTITY" || -z "$PKG_IDENTITY" ]]; then
    [[ -z "$APP_IDENTITY" ]] && echo "error: no 'Apple Distribution' identity in keychain." >&2
    [[ -z "$PKG_IDENTITY" ]] && echo "error: no '3rd Party Mac Developer Installer' identity in keychain." >&2
    echo >&2
    echo "An identity = certificate + PRIVATE KEY. The .cer files in certs/ are only" >&2
    echo "the public halves, so copying certs/ to a new machine is not enough." >&2
    echo "Check what the keychain actually has:" >&2
    echo "    security find-identity -v" >&2
    echo >&2
    echo "If it reports 0 identities:" >&2
    echo "  - import a .p12 (cert + key exported together), or" >&2
    echo "  - revoke + regenerate both certs from a new CSR at" >&2
    echo "    https://developer.apple.com/account/resources/certificates" >&2
    echo "    then re-create the provisioning profile (it embeds the dist cert)." >&2
    echo "Also install the WWDR G3 intermediate, or valid certs still show as 0:" >&2
    echo "    https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer" >&2
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
# Universal (arm64 + x86_64) without full Xcode: `swift build --arch a --arch b`
# needs xcbuild, but building each slice on its own with `--triple` and merging
# them with lipo produces an equivalent fat binary, and the Command Line Tools
# SDK carries x86_64 stubs (SDKSettings SupportedTargets.macosx.Archs lists
# x86_64 + arm64), so cross-compiling works. Set UNIVERSAL=0 for native only.
#
# The triples pin the same LSMinimumSystemVersion the app declares, so both
# slices agree on minos — a mismatch there is an App Store rejection.
MIN_OS_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
HOST_ARCH="$(uname -m)"

if [[ "${UNIVERSAL:-1}" != "1" ]]; then
    echo "› swift build -c release [native ($HOST_ARCH)]"
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)/PhotoImporter"
elif [[ -x "/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild" ]]; then
    # Full Xcode present: let SwiftPM build both slices in one invocation.
    echo "› swift build -c release [universal (arm64 + x86_64), via xcbuild]"
    swift build -c release --arch arm64 --arch x86_64
    BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/PhotoImporter"
else
    echo "› swift build -c release [universal (arm64 + x86_64), per-arch + lipo]"
    SLICES=()
    for arch in arm64 x86_64; do
        triple="${arch}-apple-macosx${MIN_OS_BUILD}"
        echo "  › $triple"
        swift build -c release --triple "$triple"
        slice="$(swift build -c release --triple "$triple" --show-bin-path)/PhotoImporter"
        if [[ ! -f "$slice" ]]; then
            echo "error: $arch slice not found at $slice" >&2
            exit 1
        fi
        SLICES+=("$slice")
    done
    BIN_PATH="build/PhotoImporter-universal"
    mkdir -p build
    rm -f "$BIN_PATH"
    lipo -create -output "$BIN_PATH" "${SLICES[@]}"
fi

if [[ ! -f "$BIN_PATH" ]]; then
    echo "error: executable not found at $BIN_PATH" >&2
    exit 1
fi
echo "› binary archs: $(lipo -archs "$BIN_PATH")"

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
#
# When actool is unavailable (Command Line Tools only), fall back to the
# pre-compiled artifacts in Resources/CompiledIcon — but only after confirming
# they were built from the icon source that's on disk right now. A stale
# Assets.car would ship the OLD artwork with a successful-looking build, which
# is a worse failure than not building at all.
ICON_SRC="Resources/${ICON_NAME}.icon"
ICON_CACHE="Resources/CompiledIcon"

if [[ ! -d "$ICON_SRC" ]]; then
    echo "error: icon source not found at $ICON_SRC" >&2
    exit 1
fi

# Digest of every file in the .icon bundle, ignoring .DS_Store (Finder rewrites
# it on mere folder views, which would otherwise invalidate a good cache).
icon_source_digest() {
    find "$ICON_SRC" -type f -not -name '.DS_Store' | sort \
        | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}'
}

if xcrun --find actool >/dev/null 2>&1; then
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
    # Refresh the checked-in cache so CLT-only machines can build this icon.
    # Both artifacts and the digest are written together so they can't drift.
    if [[ "${REFRESH_ICON_CACHE:-0}" == "1" ]]; then
        echo "› refreshing $ICON_CACHE from actool output"
        mkdir -p "$ICON_CACHE"
        cp "$APP_DIR/Contents/Resources/Assets.car" "$ICON_CACHE/Assets.car"
        if [[ -f "$APP_DIR/Contents/Resources/${ICON_NAME}.icns" ]]; then
            cp "$APP_DIR/Contents/Resources/${ICON_NAME}.icns" "$ICON_CACHE/${ICON_NAME}.icns"
        fi
        icon_source_digest > "$ICON_CACHE/source.sha256"
        xattr -cr "$ICON_CACHE"
    fi
elif [[ -f "$ICON_CACHE/Assets.car" && -f "$ICON_CACHE/source.sha256" ]]; then
    CACHED_DIGEST="$(tr -d '[:space:]' < "$ICON_CACHE/source.sha256")"
    ACTUAL_DIGEST="$(icon_source_digest)"
    if [[ "$CACHED_DIGEST" != "$ACTUAL_DIGEST" ]]; then
        echo "error: $ICON_CACHE is stale — $ICON_SRC has changed since it was compiled." >&2
        echo "       cached: $CACHED_DIGEST" >&2
        echo "       actual: $ACTUAL_DIGEST" >&2
        echo "       Using it would silently ship the old icon. Rebuild on a machine with" >&2
        echo "       full Xcode: REFRESH_ICON_CACHE=1 Scripts/build_mas.sh" >&2
        exit 1
    fi
    echo "› actool unavailable — using verified pre-compiled icon from $ICON_CACHE"
    cp "$ICON_CACHE/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
    if [[ -f "$ICON_CACHE/${ICON_NAME}.icns" ]]; then
        cp "$ICON_CACHE/${ICON_NAME}.icns" "$APP_DIR/Contents/Resources/${ICON_NAME}.icns"
    fi
else
    echo "error: actool unavailable (needs full Xcode) and no pre-compiled icon at" >&2
    echo "       $ICON_CACHE. See $ICON_CACHE/README.md." >&2
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
rm -rf "$STAGE" "$COMPONENT_PKG" build/PhotoImporter-universal

echo
echo "› done."
echo "  app: $REPO_ROOT/$APP_DIR"
echo "  pkg: $REPO_ROOT/$PKG_PATH"
echo
echo "Next: open Transporter, sign in, drag in the .pkg, and Deliver."
