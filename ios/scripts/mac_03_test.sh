#!/bin/bash
# Step 3 (macOS): slice the test models with bbs-core-slice and, if installed,
# with the official BambuStudio.app CLI, then compare the two G-code files.
#
# Usage: ios/scripts/mac_03_test.sh [model.stl ...]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$(find "$ROOT/build-core/arm64" -name bbs-core-slice -type f | head -1)"
APP_CLI="/Applications/BambuStudio.app/Contents/MacOS/BambuStudio"
OUT="$ROOT/ios/test/out"
DATA="$OUT/data"
PROFILES="$OUT/profiles"

PRINTER="Bambu Lab P1S 0.4 nozzle"
PROCESS="0.20mm Standard @BBL X1C"
FILAMENT="Bambu PLA Basic @BBL P1S 0.4 nozzle"

[ -x "$CORE" ] || { echo "bbs-core-slice non trovato: esegui prima ios/scripts/mac_02_core.sh"; exit 1; }
mkdir -p "$OUT" "$DATA"

MODELS=("$@")
if [ ${#MODELS[@]} -eq 0 ]; then
    [ -f "$ROOT/ios/test/models/cube20.stl" ] || python3 "$ROOT/ios/tools/make_test_models.py"
    MODELS=("$ROOT"/ios/test/models/*.stl)
fi

# Flattened profiles, used only by the official CLI (our core reads the vendor bundle directly).
python3 "$ROOT/ios/tools/flatten_profile.py" --vendor-dir "$ROOT/resources/profiles/BBL" \
    --machine "$PRINTER" --process "$PROCESS" --filament "$FILAMENT" --out "$PROFILES" >/dev/null

for M in "${MODELS[@]}"; do
    NAME="$(basename "${M%.*}")"
    echo "=== $NAME"

    echo "--- core"
    "$CORE" --resources "$ROOT/resources" --data "$DATA" \
        --printer "$PRINTER" --process "$PROCESS" --filament "$FILAMENT" \
        --threads 3 --out "$OUT/$NAME.core.gcode" "$M" 2> "$OUT/$NAME.core.log"
    tail -n 3 "$OUT/$NAME.core.log"

    if [ -x "$APP_CLI" ]; then
        echo "--- BambuStudio.app (riferimento)"
        REF="$OUT/ref_$NAME"
        rm -rf "$REF"; mkdir -p "$REF"
        # Options per the BambuStudio CLI help; to be verified on the installed version.
        "$APP_CLI" --slice 0 \
            --load-settings "$PROFILES/machine.json;$PROFILES/process.json" \
            --load-filaments "$PROFILES/filament_0.json" \
            --outputdir "$REF" --export-3mf "$NAME.3mf" "$M" > "$REF/cli.log" 2>&1 \
            || echo "CLI ufficiale fallita, vedi $REF/cli.log"
        if [ -f "$REF/$NAME.3mf" ]; then
            (cd "$REF" && unzip -o -q "$NAME.3mf" 'Metadata/plate_1.gcode' && cp Metadata/plate_1.gcode "$OUT/$NAME.ref.gcode")
        fi
        [ -f "$OUT/$NAME.ref.gcode" ] && python3 "$ROOT/ios/tools/compare_gcode.py" "$OUT/$NAME.ref.gcode" "$OUT/$NAME.core.gcode"
    else
        echo "(BambuStudio.app non installato: salto il confronto)"
    fi
done
echo
echo "Risultati in $OUT"
