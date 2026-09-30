#!/bin/bash
# iOS step 4 (on macOS): build SlicerPoC for a real iPad, sign it with your Apple ID
# team (the free Personal Team is enough), install it and run the autotest on the device.
#
# Needs ios_02_core.sh (device slice of SlicerCore.xcframework).
# Logs: ios/logs/ios_04_device.log, ios/logs/ios_04_xcodebuild.log
#
# Usage:
#   ios/scripts/ios_04_device.sh --build-only   compile + link for iPad, no signing, no device
#                                               (works remotely: checks the device build)
#   ios/scripts/ios_04_device.sh                sign, install on the connected iPad, autotest
#   ios/scripts/ios_04_device.sh --no-test      sign and install only
#
# Optional environment:
#   TEAM=ABCDE12345         signing team (default: taken from your "Apple Development" certificate)
#   BUNDLE_ID=com.x.y       if com.wizwally.slicerpoc is refused (IDs are global on free teams)
#   DEVICE=<udid or name>   which iPad, if more than one is connected
#
# First time with a device:
#   1. Xcode > Settings > Accounts: add your Apple ID (creates the Personal Team),
#      then Manage Certificates > + > Apple Development.
#   2. Connect the iPad with the cable, unlock it, tap "Trust".
#   3. On the iPad: Settings > Privacy & Security > Developer Mode > On (it restarts).
#   4. Run this script. After the install, on the iPad: Settings > General >
#      VPN & Device Management > your Apple ID > Trust, then run it again.
# Free-team apps expire after 7 days: run the script again to renew.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPDIR="$ROOT/ios/app"
DERIVED="$ROOT/ios/build/app-device"
LOG="$ROOT/ios/logs/ios_04_device.log"
XLOG="$ROOT/ios/logs/ios_04_xcodebuild.log"
BUNDLE_ID="${BUNDLE_ID:-com.wizwally.slicerpoc}"
MODE="${1:-}"
mkdir -p "$(dirname "$LOG")"

[ -d "$ROOT/ios/build/SlicerCore.xcframework/ios-arm64" ] || {
    echo "Manca la versione iPad di SlicerCore: esegui ios/scripts/ios_02_core.sh"; exit 1; }
command -v xcodegen >/dev/null || brew install xcodegen

build() {   # build <destination> <extra xcodebuild settings...>
    local dest="$1"; shift
    xcodebuild -project SlicerPoC.xcodeproj -scheme SlicerPoC -configuration Release \
        -destination "$dest" -derivedDataPath "$DERIVED" \
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" "$@" build > "$XLOG" 2>&1 || true
    grep -E "error:|\*\* BUILD" "$XLOG" | head -40 || true
    grep -q "BUILD SUCCEEDED" "$XLOG" || { echo "Build fallita: dettagli in ios/logs/ios_04_xcodebuild.log"; exit 1; }
    APP="$DERIVED/Build/Products/Release-iphoneos/SlicerPoC.app"
    echo "App: $(du -sh "$APP" | cut -f1), eseguibile: $(du -sh "$APP/SlicerPoC" | cut -f1)"
}

{
echo "=== $(date) ${MODE:-install}"
cd "$APPDIR"
xcodegen generate

if [ "$MODE" = "--build-only" ]; then
    build "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO
    echo "OK: build per iPad compilata e linkata (non firmata, non installabile)"
    exit 0
fi

# Signing team: the OU of the "Apple Development" certificate is the team ID.
if [ -z "${TEAM:-}" ]; then
    TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^ *organizationalUnitName *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
fi
[ -n "$TEAM" ] || { echo "Nessun certificato Apple Development: in Xcode > Settings > Accounts aggiungi il tuo Apple ID,"
                    echo "poi Manage Certificates > + > Apple Development. Oppure passa TEAM=<team id>."; exit 1; }
echo "Team: $TEAM"

# Connected iPad (USB, or network once Xcode has paired it).
DEVJSON="${TMPDIR:-/tmp}/slicerpoc_devices.json"
xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1 || true
read -r UDID NAME DEVMODE < <(/usr/bin/python3 - "$DEVJSON" "${DEVICE:-}" <<'EOF'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
want = sys.argv[2]
for d in devices:
    hw, props = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") == "virtual":
        continue
    if want and want not in (hw.get("udid"), props.get("name"), d.get("identifier")):
        continue
    if conn.get("tunnelState") == "unavailable" and not want:
        continue
    print(hw.get("udid", ""), props.get("name", "?").replace(" ", "_"),
          props.get("developerModeStatus", "?"))
    break
else:
    print("", "", "")
EOF
)
[ -n "$UDID" ] || { echo "Nessun iPad collegato: collegalo col cavo, sbloccalo e conferma 'Autorizza'."
                    echo "Dispositivi visti da Xcode:"; xcrun devicectl list devices 2>&1 | tail -n +1; exit 1; }
echo "iPad: $NAME ($UDID), modalità sviluppatore: $DEVMODE"
[ "$DEVMODE" = "disabled" ] && { echo "Attiva la modalità sviluppatore: Impostazioni > Privacy e sicurezza > Modalità sviluppatore"; exit 1; }

build "id=$UDID" DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration

echo "=== installazione"
xcrun devicectl device install app --device "$UDID" "$APP"

[ "$MODE" = "--no-test" ] && exit 0

echo "=== autotest (sull'iPad, lascialo sbloccato)"
if ! xcrun devicectl device process launch --device "$UDID" --console --terminate-existing \
        "$BUNDLE_ID" -autotest 2>&1 | tee "${TMPDIR:-/tmp}/slicerpoc_autotest.txt" | grep "AUTOTEST"; then
    echo "Avvio non riuscito. Se l'errore parla di profilo non attendibile: sull'iPad"
    echo "Impostazioni > Generali > VPN e gestione dispositivi > il tuo Apple ID > Autorizza, poi rilancia."
    tail -5 "${TMPDIR:-/tmp}/slicerpoc_autotest.txt"
    exit 1
fi

# Offscreen renders made by the autotest, from the app's tmp folder on the iPad.
OUT="$ROOT/ios/logs/autotest-device"
mkdir -p "$OUT"
if xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" --source tmp --destination "$OUT" >/dev/null 2>&1; then
    echo "Immagini autotest: ios/logs/autotest-device/"
else
    echo "(immagini dell'autotest non copiate dall'iPad)"
fi
} 2>&1 | tee "$LOG"
