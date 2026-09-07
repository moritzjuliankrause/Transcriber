#!/bin/zsh
# Builds AnyRecord in release mode and assembles a double-clickable AnyRecord.app
# in ./dist. Works with Xcode or with the Command Line Tools alone.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" 2>&1 | tail -3

BIN=".build/$CONFIG/AnyRecord"
# SwiftPM resource bundles of dependencies (e.g. FluidAudio_FluidAudio.bundle)
APP="dist/AnyRecord.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AnyRecord"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamp build number (commit count) and git hash into the bundle's Info.plist.
if git rev-parse --git-dir >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :AnyRecordGitHash string $(git rev-parse --short HEAD)$( [ -n "$(git status --porcelain)" ] && echo '-dirty')" "$APP/Contents/Info.plist"
fi
for b in .build/$CONFIG/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Sign. A self-signed "AnyRecord Dev" identity gives a stable designated requirement so
# macOS keeps the microphone / system-audio grants across rebuilds. Ad-hoc signatures
# change with every build and reset the permissions each time.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning | grep -q '"AnyRecord Dev"'; then
  IDENTITY="AnyRecord Dev"
fi
codesign --force --sign "${IDENTITY:--}" --entitlements Resources/AnyRecord.entitlements "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

# `./scripts/bundle.sh release --install` also copies the app to /Applications and relaunches it.
if [[ "${2:-}" == "--install" ]]; then
  pkill -x AnyRecord || true
  sleep 1
  rm -rf /Applications/AnyRecord.app
  cp -R "$APP" /Applications/AnyRecord.app
  open /Applications/AnyRecord.app
  echo "Installed to /Applications and launched"
fi
