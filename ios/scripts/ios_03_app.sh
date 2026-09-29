#!/bin/bash
# iOS step 3 (on macOS): generate the PoC Xcode project, build it for the iPad
# Simulator, run the automatic slicing test and print the results.
#
# Needs ios_02_core.sh (SlicerCore.xcframework with the simulator slice).
# Log: ios/logs/ios_03_app.log
# Usage: ios/scripts/ios_03_app.sh            (build + autotest on the Simulator)
#        ios/scripts/ios_03_app.sh --open     (also leave the app open in the Simulator)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPDIR="$ROOT/ios/app"
DERIVED="$ROOT/ios/build/app"
LOG="$ROOT/ios/logs/ios_03_app.log"
BUNDLE_ID="com.wizwally.slicerpoc"
mkdir -p "$(dirname "$LOG")"

[ -d "$ROOT/ios/build/SlicerCore.xcframework/ios-arm64-simulator" ] || {
    echo "Manca la versione simulatore di SlicerCore: esegui PLATFORM=iphonesimulator ios/scripts/ios_02_core.sh"; exit 1; }
command -v xcodegen >/dev/null || brew install xcodegen

{
echo "=== $(date)"
cd "$APPDIR"
xcodegen generate

# Prefer an iPad Pro 11-inch (M4) simulator, otherwise any iPad.
UDID=$(xcrun simctl list devices available | grep -m1 "iPad Pro 11-inch (M4)" | grep -oE '[0-9A-F-]{36}' || true)
[ -n "$UDID" ] || UDID=$(xcrun simctl list devices available | grep -m1 "iPad" | grep -oE '[0-9A-F-]{36}' || true)
[ -n "$UDID" ] || { echo "Nessun simulatore iPad: installa il runtime con  xcodebuild -downloadPlatform iOS"; exit 1; }
echo "Simulatore: $(xcrun simctl list devices | grep "$UDID")"

xcodebuild -project SlicerPoC.xcodeproj -scheme SlicerPoC -configuration Release \
    -destination "id=$UDID" -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build > "$ROOT/ios/logs/ios_03_xcodebuild.log" 2>&1 || true
grep -E "error:|\*\* BUILD" "$ROOT/ios/logs/ios_03_xcodebuild.log" | head -40 || true

APP="$DERIVED/Build/Products/Release-iphonesimulator/SlicerPoC.app"
grep -q "BUILD SUCCEEDED" "$ROOT/ios/logs/ios_03_xcodebuild.log" || { echo "Build fallita: dettagli in ios/logs/ios_03_xcodebuild.log"; exit 1; }
echo "App: $(du -sh "$APP" | cut -f1), eseguibile: $(du -sh "$APP/SlicerPoC" | cut -f1)"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
# Install from a fresh copy in $TMPDIR: installing straight from the project
# folder failed with "Missing bundle ID" (file access from the Simulator service).
echo "Bundle ID nel pacchetto: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>&1)"
TMPAPP="${TMPDIR:-/tmp}/SlicerPoC.app"
rm -rf "$TMPAPP"
ditto "$APP" "$TMPAPP"
xcrun simctl install "$UDID" "$TMPAPP"
echo "=== autotest"
xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID" -autotest | grep "AUTOTEST" || true

# Offscreen renders of the 3D view made by the autotest (model / layer preview).
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)
if [ -n "$DATA" ] && ls "$DATA"/tmp/autotest_*.png >/dev/null 2>&1; then
    mkdir -p "$ROOT/ios/logs/autotest"
    cp "$DATA"/tmp/autotest_*.png "$ROOT/ios/logs/autotest/"
    echo "Immagini autotest: ios/logs/autotest/"
fi

if [ "${1:-}" = "--open" ]; then
    open -a Simulator
    xcrun simctl launch "$UDID" "$BUNDLE_ID"
fi
} 2>&1 | tee "$LOG"
