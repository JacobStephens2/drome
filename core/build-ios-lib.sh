#!/bin/bash
#
# build-ios-lib.sh — build the drome-core static library for the iOS simulator
# and regenerate the UniFFI Swift bindings.
#
#   core/build-ios-lib.sh            # debug (default)
#   core/build-ios-lib.sh --release
#
# Outputs (repo-relative):
#   ios/DromeShared/Generated/drome_core.swift
#   ios/DromeShared/Generated/drome_coreFFI.h
#   ios/DromeShared/Generated/drome_coreFFI.modulemap
#   ios/Frameworks/libdrome_core.a          (aarch64-apple-ios-sim)
#
# Santa notes (see CLAUDE.md): plain cargo with the default target dir works —
# this repo's core/target/(debug|release)/ is allowlisted. The bindgen binary
# is always run as a debug `cargo run`, so it executes from core/target/debug/.
# Do NOT set CARGO_TARGET_DIR outside the repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PROFILE=debug
for arg in "$@"; do
    case "$arg" in
        --release) PROFILE=release ;;
        -h|--help)
            sed -n '2,17p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "error: unknown argument '$arg' (only --release is accepted)" >&2
            exit 2
            ;;
    esac
done

TARGET="aarch64-apple-ios-sim"
GENERATED_DIR="$REPO_ROOT/ios/DromeShared/Generated"
FRAMEWORKS_DIR="$REPO_ROOT/ios/Frameworks"
STATICLIB="$SCRIPT_DIR/target/$TARGET/$PROFILE/libdrome_core.a"

if ! rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
    echo "error: rust target $TARGET is not installed (rustup target add $TARGET)" >&2
    exit 1
fi

# Pin the min iOS version for cc-compiled objects (bundled sqlite3.o) to the
# app's deployment floor, so the linker doesn't warn about mismatched versions.
export IPHONEOS_DEPLOYMENT_TARGET=17.0

echo "==> cargo build --lib --target $TARGET ($PROFILE)"
if [ "$PROFILE" = "release" ]; then
    (cd "$SCRIPT_DIR" && cargo build --lib --target "$TARGET" --release)
else
    (cd "$SCRIPT_DIR" && cargo build --lib --target "$TARGET")
fi

if [ ! -f "$STATICLIB" ]; then
    echo "error: expected staticlib missing: $STATICLIB" >&2
    exit 1
fi

echo "==> generating Swift bindings into ios/DromeShared/Generated/"
mkdir -p "$GENERATED_DIR"
# cargo run builds the bindgen bin in debug and executes it from
# core/target/debug/ (a Santa-allowlisted path). Renames/config come from
# core/uniffi.toml, discovered automatically in library mode.
(cd "$SCRIPT_DIR" && cargo run --features cli --bin uniffi-bindgen -- \
    generate --library "$STATICLIB" --language swift --out-dir "$GENERATED_DIR")

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

echo "==> copying staticlib to ios/Frameworks/libdrome_core.a"
mkdir -p "$FRAMEWORKS_DIR"
cp -f "$STATICLIB" "$FRAMEWORKS_DIR/libdrome_core.a"

echo "==> done"
echo "    $GENERATED_DIR/drome_core.swift"
echo "    $GENERATED_DIR/drome_coreFFI.h"
echo "    $GENERATED_DIR/drome_coreFFI.modulemap"
echo "    $FRAMEWORKS_DIR/libdrome_core.a ($TARGET, $PROFILE)"
