#!/usr/bin/env bash
# Build both deliverables for a release:
#   build/Photo Batch Importer.pkg          → Transporter → TestFlight / App Store
#   build/local/Photo Batch Importer.app    → run directly, no TestFlight wait
#   build/local/Photo Batch Importer-<ver>-local.zip
#
# The local build is Development-signed and NOT sandboxed (see
# Resources/PhotoImporter.entitlements), so card access behaves like a dev
# build — everything else, including the UI, matches the pkg.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

Scripts/build_mas.sh "$@"

LOCAL_DIR="build/local"
LOCAL_APP="$LOCAL_DIR/Photo Batch Importer.app"
rm -rf "$LOCAL_DIR"
mkdir -p "$LOCAL_DIR"
APP_DIR="$LOCAL_APP" Scripts/build_app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
ZIP="$LOCAL_DIR/Photo Batch Importer-$VERSION-$BUILD-local.zip"
ditto -c -k --keepParent "$LOCAL_APP" "$ZIP"

echo
echo "› all done ($VERSION build $BUILD)"
echo "  TestFlight pkg: $REPO_ROOT/build/Photo Batch Importer.pkg"
echo "  local app:      $REPO_ROOT/$LOCAL_APP"
echo "  local zip:      $REPO_ROOT/$ZIP"
