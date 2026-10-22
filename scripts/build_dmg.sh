#!/bin/bash
# Builds PlayCover.app for Apple Silicon and packages it as DMG + ZIP.
#
# Same flags the CI uses: signing disabled during the build, ad-hoc signature
# applied at the end (no paid Apple certificate needed), hdiutil for the DMG.
#
# Usage:
#   ./scripts/build_dmg.sh            # builds from the current checkout
#   ./scripts/build_dmg.sh --fresh    # clones the branch into a temp dir first
#
# Result: ./PlayCover.dmg and ./PlayCover.app.zip
set -euo pipefail

BRANCH="arena/91ef998b-playcover"
REPO="https://github.com/dexkaua/PlayCover.git"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" = "--fresh" ]; then
    ROOT="$(mktemp -d)/PlayCover"
    echo "==> Cloning $REPO ($BRANCH) into $ROOT"
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$ROOT"
fi

cd "$ROOT"
echo "==> Building in $ROOT"

if ! command -v carthage >/dev/null 2>&1; then
    echo "!! carthage not found. Install it with: brew install carthage"
    exit 1
fi

echo "==> Fetching PlayTools (Carthage)"
carthage bootstrap --use-xcframeworks --platform macOS \
    || carthage bootstrap --use-xcframeworks \
    || carthage update --use-xcframeworks

if [ ! -d Carthage/Build/PlayTools.xcframework ]; then
    echo "!! PlayTools.xcframework is missing - the build will skip it."
    echo "   (PlayCover still builds; only game keymapping support is lost.)"
fi

echo "==> Building PlayCover (arm64, Nightly, unsigned)"
rm -rf output
xcodebuild build \
    -project PlayCover.xcodeproj \
    -scheme PlayCover \
    -configuration Nightly \
    -arch arm64 \
    -derivedDataPath ./DerivedData \
    CONFIGURATION_BUILD_DIR="$ROOT/output" \
    CODE_SIGN_IDENTITY="-" \
    EXPANDED_CODE_SIGN_IDENTITY="-" \
    EXPANDED_CODE_SIGN_IDENTITY_NAME="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    FASTLANE=1

APP="$ROOT/output/PlayCover.app"
if [ ! -d "$APP" ]; then
    echo "!! Build finished but $APP does not exist"
    exit 1
fi

echo "==> Signing ad-hoc and clearing extended attributes"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

echo "==> Packaging ZIP"
rm -f "$ROOT/PlayCover.app.zip"
ditto -c -k --keepParent "$APP" "$ROOT/PlayCover.app.zip"

echo "==> Packaging DMG (hdiutil, no create-dmg)"
STAGE="$ROOT/dmg_stage"
rm -rf "$STAGE" "$ROOT/PlayCover.dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PlayCover" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/PlayCover.dmg"

echo
echo "Done:"
ls -lh "$ROOT/PlayCover.dmg" "$ROOT/PlayCover.app.zip"
echo
echo "First launch: right click > Open (the build is ad-hoc signed, not notarized)."
