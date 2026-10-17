#!/usr/bin/env bash
#
# Builds MacDuoNext.app from the SwiftPM package, then packages it.
#
#   ./scripts/build-release.sh              universal app + DMG + ZIP in dist/
#   ./scripts/build-release.sh --run        native build, sign, and relaunch the app
#   ./scripts/build-release.sh --no-test    skip the unit tests
#
# Signing: ad-hoc by default. Set MACDUONEXT_SIGN_IDENTITY to a
# "Developer ID Application: ..." identity to sign for distribution, and
# NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID to notarize the DMG.
# macOS asks for Screen Recording and Camera again after every ad-hoc rebuild.
#
# Environment:
#   MACDUONEXT_BUILD_NUMBER   CFBundleVersion (default 1)

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MacDuoNext"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${MACDUONEXT_BUILD_NUMBER:-1}"
SIGN_IDENTITY="${MACDUONEXT_SIGN_IDENTITY:--}"
DIST="dist"
BUNDLE="$DIST/${APP_NAME}.app"

RUN_APP=false
RUN_TESTS=true
UNIVERSAL=true
for argument in "$@"; do
  case "$argument" in
    --run) RUN_APP=true; UNIVERSAL=false ;;
    --no-test) RUN_TESTS=false ;;
    *) echo "Unknown argument: $argument" >&2; exit 1 ;;
  esac
done

BUILD_ARGS=(-c release)
if "$UNIVERSAL"; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

if "$RUN_TESTS"; then
  swift test
fi

swift build "${BUILD_ARGS[@]}" --product MacDuoNextApp
swift build "${BUILD_ARGS[@]}" --product macduonext-lidprobe
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_PATH/MacDuoNextApp" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BIN_PATH/macduonext-lidprobe" "$BUNDLE/Contents/MacOS/macduonext-lidprobe"
# SettingsLanguage looks for the resource bundle in Contents/Resources.
cp -R "$BIN_PATH/MacDuoNext_MacDuoNextApp.bundle" "$BUNDLE/Contents/Resources/"
sed -e "s/__MACDUONEXT_VERSION__/$VERSION/" -e "s/__MACDUONEXT_BUILD__/$BUILD_NUMBER/" \
  Resources/App-Info.plist > "$BUNDLE/Contents/Info.plist"
plutil -lint "$BUNDLE/Contents/Info.plist"
cp LICENSE NOTICE.md "$BUNDLE/Contents/Resources/"

# The icon is generated from the 1024 px master in docs/assets.
if [ -f docs/assets/icon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" docs/assets/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" docs/assets/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

TIMESTAMP=--timestamp
if [[ "$SIGN_IDENTITY" == - ]]; then
  TIMESTAMP=--timestamp=none
fi
codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" \
  "$BUNDLE/Contents/MacOS/macduonext-lidprobe"
codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" \
  --entitlements Resources/MacDuoNext.entitlements "$BUNDLE"
codesign --verify --strict --verbose=1 "$BUNDLE"
echo "built $BUNDLE ($VERSION, build $BUILD_NUMBER)"

if "$RUN_APP"; then
  pkill -f -x "$PWD/$BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  sleep 0.5
  open "$BUNDLE"
  echo "launched"
  exit 0
fi

if "$UNIVERSAL"; then
  lipo "$BUNDLE/Contents/MacOS/$APP_NAME" -verify_arch arm64 x86_64
fi

# Disk image: the app and a link to Applications.
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$BUNDLE" "$STAGING/${APP_NAME}.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DMG" >/dev/null
if [[ "$SIGN_IDENTITY" != - ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [[ "$SIGN_IDENTITY" != - && -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$BUNDLE"
fi

ZIP="$DIST/${APP_NAME}-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"
echo "packaged $DMG and $ZIP"
