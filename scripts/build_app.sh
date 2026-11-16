#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")}"
source "$ROOT_DIR/scripts/release_metadata.sh"
# CI supplies an increasing run number; local packages default to the current UTC epoch.
sleepskip_release_metadata "$VERSION" "${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(date -u +%s)}}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/SleepSkip.app"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/SleepSkip-${VERSION}-macOS-universal.dmg"
ZIP_PATH="$DIST_DIR/SleepSkip-${VERSION}-macOS-universal.zip"

echo "==> Building SleepSkip ($VERSION / universal arm64+x86_64) in release mode..."
cd "$ROOT_DIR"

swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SleepSkip"
if [ ! -x "$BIN_PATH" ]; then
  echo "Error: Release binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling SleepSkip.app bundle..."
rm -rf "$APP_DIR" "$DMG_STAGING" "$DMG_PATH" "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/SleepSkip"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SLEEPSKIP_MARKETING_VERSION" "$APP_DIR/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SLEEPSKIP_BUILD_NUMBER" "$APP_DIR/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :SleepSkipReleaseVersion string $VERSION" "$APP_DIR/Contents/Info.plist" >/dev/null

echo "==> Generating AppIcon.icns..."
swift "$ROOT_DIR/scripts/generate_icon.swift" "$APP_DIR/Contents/Resources/AppIcon.icns"

if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
  echo "==> Code signing bundle with Developer ID..."
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP_DIR"
else
  echo "==> Code signing bundle (ad-hoc)..."
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "==> Creating ZIP archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

if [ -n "${DEVELOPER_ID_APPLICATION:-}" ] && [ -n "${APPLE_NOTARY_PROFILE:-}" ]; then
  echo "==> Submitting for Apple notarization..."
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
fi

echo "==> Creating DMG installer..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "SleepSkip $VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGING"

echo "==> Binary architectures:"
lipo -info "$APP_DIR/Contents/MacOS/SleepSkip"
echo "==> Build complete:"
ls -lh "$APP_DIR/Contents/MacOS/SleepSkip" "$ZIP_PATH" "$DMG_PATH"
