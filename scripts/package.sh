#!/usr/bin/env bash
# Build a distributable, ad-hoc-signed RezkaPlayer.dmg (Apple Silicon).
#
#   ./scripts/package.sh
#
# Produces build/RezkaPlayer.dmg containing a self-contained app (bundled frozen
# Python sidecar). Not notarized — first launch needs right-click → Open.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPNAME="RezkaPlayer"
BUILD="$ROOT/build"
DD="$BUILD/dd"
DMG="$BUILD/$APPNAME.dmg"

rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "==> 1/5  Freeze sidecar"
"$ROOT/scripts/build-sidecar.sh"

echo "==> 2/5  Build app (Release, arm64)"
cd "$ROOT/app"
xcodegen generate >/dev/null
xcodebuild -project "$APPNAME.xcodeproj" -scheme "$APPNAME" -configuration Release \
  -derivedDataPath "$DD" -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build >/dev/null
APP="$DD/Build/Products/Release/$APPNAME.app"
[ -d "$APP" ] || { echo "ERROR: app not found at $APP"; exit 1; }

echo "==> 3/5  Bundle sidecar into app"
RES="$APP/Contents/Resources/sidecar"
rm -rf "$RES"; mkdir -p "$RES"
cp -R "$ROOT/sidecar/dist/rezka-sidecar" "$RES/"

echo "==> 4/5  Ad-hoc sign (inside-out)"
# Sign nested Mach-O first, then seal the whole bundle.
find "$RES/rezka-sidecar/_internal" \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do codesign --force --sign - "$f" 2>/dev/null || true; done
codesign --force --sign - "$RES/rezka-sidecar/rezka-sidecar"

# Sparkle ships nested helpers (Updater.app, the Installer/Downloader XPC services and the
# Autoupdate tool) that must each be signed before the framework is sealed — `--deep` alone is
# unreliable for these, so sign them explicitly inside-out.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  V="$SPARKLE_FW/Versions/B"
  for nested in \
    "$V/XPCServices/Downloader.xpc" \
    "$V/XPCServices/Installer.xpc" \
    "$V/Updater.app" \
    "$V/Autoupdate"; do
    [ -e "$nested" ] && codesign --force --sign - "$nested"
  done
  codesign --force --sign - "$SPARKLE_FW"
fi

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature OK"

echo "==> 5/5  Build DMG"
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/scripts/INSTALL.txt" "$STAGE/INSTALL — read me first.txt"
hdiutil create -volname "$APPNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo
echo "✅ Done: $DMG"
du -h "$DMG" | cut -f1 | sed 's/^/   size: /'
