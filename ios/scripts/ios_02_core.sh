#!/bin/bash
# iOS step 2 (on macOS): build libslic3r + ios/core for iPadOS arm64 and package
# everything (our code + all dependencies) as ios/build/SlicerCore.xcframework,
# ready to be added to the Xcode app project.
#
# Needs ios_01_deps.sh completed.   Log: ios/logs/ios_02_core.log
# Usage: ios/scripts/ios_02_core.sh          (configure + build + package)
#        ios/scripts/ios_02_core.sh -b       (build + package, no reconfigure)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPS="$ROOT/ios/build/deps/BambuStudio_deps/usr/local"
BUILD="$ROOT/ios/build/core"
OUT="$ROOT/ios/build"
LOG="$ROOT/ios/logs/ios_02_core.log"
IOS_MIN="17.0"
mkdir -p "$BUILD" "$(dirname "$LOG")"

[ -d "$DEPS/lib" ] || { echo "Dipendenze iOS non trovate: esegui prima ios/scripts/ios_01_deps.sh"; exit 1; }

GEN="Unix Makefiles"
command -v ninja >/dev/null && GEN="Ninja"

{
echo "=== $(date)"
cd "$BUILD"
if [ "${1:-}" != "-b" ]; then
    cmake "$ROOT" -G "$GEN" -Wno-dev \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_SYSTEM_PROCESSOR=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$DEPS" \
        -DCMAKE_FIND_ROOT_PATH="$DEPS" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
        -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew \
        -DCMAKE_MACOSX_BUNDLE=OFF \
        -DSLIC3R_CORE_ONLY=ON \
        -DSLIC3R_STATIC=ON \
        -DBBL_RELEASE_TO_PUBLIC=1 \
        -DBBL_INTERNAL_TESTING=0
fi
cmake --build . --target slicer_core slicer_core_gui_shims

echo "=== packaging"
PKG="$OUT/pkg"
rm -rf "$PKG" "$OUT/SlicerCore.xcframework"
mkdir -p "$PKG/include"

# Our static libraries and the shim objects, plus every dependency archive.
LIBS=$(find "$BUILD" -name '*.a' -not -path '*/CMakeFiles/*')
SHIMS=$(find "$BUILD" -path '*slicer_core_gui_shims*' -name '*.o')
DEPLIBS=$(find "$DEPS/lib" -maxdepth 1 -name '*.a' -not -name '*d.a')
libtool -static -no_warning_for_no_symbols -o "$PKG/libSlicerCore.a" $LIBS $SHIMS $DEPLIBS

cp "$ROOT/ios/core/SlicerCore.hpp" "$PKG/include/"
xcodebuild -create-xcframework -library "$PKG/libSlicerCore.a" -headers "$PKG/include" \
    -output "$OUT/SlicerCore.xcframework"

echo "OK: $OUT/SlicerCore.xcframework ($(du -sh "$PKG/libSlicerCore.a" | cut -f1))"
} 2>&1 | tee "$LOG"
