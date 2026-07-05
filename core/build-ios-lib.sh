#!/bin/bash
#
# build-ios-lib.sh — build the drome-core static library for the iOS simulator
# AND device, and regenerate the UniFFI Swift bindings.
#
#   core/build-ios-lib.sh            # debug (default)
#   core/build-ios-lib.sh --release
#
# Outputs (repo-relative):
#   ios/DromeShared/Generated/drome_core.swift
#   ios/DromeShared/Generated/drome_coreFFI.h
#   ios/DromeShared/Generated/drome_coreFFI.modulemap
#   ios/Frameworks/sim/libdrome_core.a       (aarch64-apple-ios-sim)
#   ios/Frameworks/device/libdrome_core.a    (aarch64-apple-ios)
#
# The Xcode project selects the right slot per SDK via conditional
# LIBRARY_SEARCH_PATHS ([sdk=iphonesimulator*] -> sim/, [sdk=iphoneos*] -> device/).
#
# Santa notes (see CLAUDE.md): plain cargo with the default target dir works —
# this repo's core/target/(debug|release)/ is allowlisted. The bindgen binary
# is always run as a debug `cargo run`, so it executes from core/target/debug/.
# Do NOT set CARGO_TARGET_DIR outside the repo. The device .a is never executed
# on this Mac (build scripts run from core/target/, also allowlisted).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PROFILE=debug
for arg in "$@"; do
    case "$arg" in
        --release) PROFILE=release ;;
        -h|--help)
            sed -n '2,19p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "error: unknown argument '$arg' (only --release is accepted)" >&2
            exit 2
            ;;
    esac
done

SIM_TARGET="aarch64-apple-ios-sim"
DEVICE_TARGET="aarch64-apple-ios"
GENERATED_DIR="$REPO_ROOT/ios/DromeShared/Generated"
FRAMEWORKS_DIR="$REPO_ROOT/ios/Frameworks"

for t in "$SIM_TARGET" "$DEVICE_TARGET"; do
    if ! rustup target list --installed 2>/dev/null | grep -qx "$t"; then
        echo "error: rust target $t is not installed (rustup target add $t)" >&2
        exit 1
    fi
done

# Pin the min iOS version for cc-compiled objects (bundled sqlite3.o) to the
# app's deployment floor, so the linker doesn't warn about mismatched versions.
export IPHONEOS_DEPLOYMENT_TARGET=17.0

for t in "$SIM_TARGET" "$DEVICE_TARGET"; do
    echo "==> cargo build --lib --target $t ($PROFILE)"
    if [ "$PROFILE" = "release" ]; then
        (cd "$SCRIPT_DIR" && cargo build --lib --target "$t" --release)
    else
        (cd "$SCRIPT_DIR" && cargo build --lib --target "$t")
    fi
    if [ ! -f "$SCRIPT_DIR/target/$t/$PROFILE/libdrome_core.a" ]; then
        echo "error: expected staticlib missing: target/$t/$PROFILE/libdrome_core.a" >&2
        exit 1
    fi
done

SIM_LIB="$SCRIPT_DIR/target/$SIM_TARGET/$PROFILE/libdrome_core.a"
DEVICE_LIB="$SCRIPT_DIR/target/$DEVICE_TARGET/$PROFILE/libdrome_core.a"

echo "==> generating Swift bindings into ios/DromeShared/Generated/"
mkdir -p "$GENERATED_DIR"
# cargo run builds the bindgen bin in debug and executes it from
# core/target/debug/ (a Santa-allowlisted path). Renames/config come from
# core/uniffi.toml, discovered automatically in library mode. Bindings are
# identical for both platforms; generate once from the sim lib.
(cd "$SCRIPT_DIR" && cargo run --features cli --bin uniffi-bindgen -- \
    generate --library "$SIM_LIB" --language swift --out-dir "$GENERATED_DIR")

for f in drome_core.swift drome_coreFFI.h drome_coreFFI.modulemap; do
    if [ ! -f "$GENERATED_DIR/$f" ]; then
        echo "error: bindgen did not produce $GENERATED_DIR/$f" >&2
        exit 1
    fi
done

# Work around a uniffi 0.32.0 rename bug: the DromeStore constructor's error
# converter keeps the un-renamed type name (FfiConverterTypeDromeError_lift,
# undefined) while everything else uses FfiConverterTypeUniDromeError_lift.
# Deterministic textual fix; drop when uniffi fixes constructor throw renames.
if grep -q "FfiConverterTypeDromeError_lift" "$GENERATED_DIR/drome_core.swift"; then
    sed -i '' 's/FfiConverterTypeDromeError_lift/FfiConverterTypeUniDromeError_lift/g' \
        "$GENERATED_DIR/drome_core.swift"
    echo "    (applied uniffi 0.32.0 constructor-error rename fix)"
fi

# The generated Swift must be collision-free against Models.swift (see
# core/uniffi.toml). If the rename config ever stops being applied, fail here
# instead of at Xcode compile time.
if grep -qE 'public (struct|enum) (Challenge|DayState|WaterState|ChugCheck|LogResult)\b' \
        "$GENERATED_DIR/drome_core.swift"; then
    echo "error: generated Swift contains un-renamed types that collide with Models.swift" >&2
    echo "       (is core/uniffi.toml's [bindings.swift.rename] table intact?)" >&2
    exit 1
fi

echo "==> copying staticlibs to ios/Frameworks/{sim,device}/"
mkdir -p "$FRAMEWORKS_DIR/sim" "$FRAMEWORKS_DIR/device"
cp -f "$SIM_LIB" "$FRAMEWORKS_DIR/sim/libdrome_core.a"
cp -f "$DEVICE_LIB" "$FRAMEWORKS_DIR/device/libdrome_core.a"
# Remove the legacy single-slot lib so a stale copy can't shadow the split ones.
rm -f "$FRAMEWORKS_DIR/libdrome_core.a"

echo "==> done"
echo "    $GENERATED_DIR/drome_core.swift"
echo "    $FRAMEWORKS_DIR/sim/libdrome_core.a ($SIM_TARGET, $PROFILE)"
echo "    $FRAMEWORKS_DIR/device/libdrome_core.a ($DEVICE_TARGET, $PROFILE)"
