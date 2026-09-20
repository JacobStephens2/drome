#!/bin/bash
#
# Build drome-core for Android phone/emulator ABIs and regenerate UniFFI Kotlin.
#
#   core/build-android-lib.sh            # debug (default)
#   core/build-android-lib.sh --release
#
# The script deliberately uses the NDK toolchain directly rather than cargo-ndk:
# every cargo-built executable stays in this repo's Santa-allowlisted target dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-28.2.13676358}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION}}"
ANDROID_MIN_SDK=26
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

if [ ! -d "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt" ]; then
    echo "error: Android NDK not found at $ANDROID_NDK_ROOT" >&2
    exit 1
fi

PREBUILT_ROOT="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt"
PREBUILT_DIR="$(find "$PREBUILT_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [ -z "$PREBUILT_DIR" ]; then
    echo "error: no NDK host toolchain found under $PREBUILT_ROOT" >&2
    exit 1
fi
TOOLCHAIN_BIN="$PREBUILT_DIR/bin"

ARM_TARGET="aarch64-linux-android"
X64_TARGET="x86_64-linux-android"
ARM_CLANG="$TOOLCHAIN_BIN/aarch64-linux-android${ANDROID_MIN_SDK}-clang"
X64_CLANG="$TOOLCHAIN_BIN/x86_64-linux-android${ANDROID_MIN_SDK}-clang"
LLVM_AR="$TOOLCHAIN_BIN/llvm-ar"

for executable in "$ARM_CLANG" "$X64_CLANG" "$LLVM_AR"; do
    if [ ! -x "$executable" ]; then
        echo "error: required NDK tool is missing or not executable: $executable" >&2
        exit 1
    fi
done
for target in "$ARM_TARGET" "$X64_TARGET"; do
    if ! rustup target list --installed 2>/dev/null | grep -qx "$target"; then
        echo "error: Rust target $target is not installed (rustup target add $target)" >&2
        exit 1
    fi
done

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$ARM_CLANG"
export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$X64_CLANG"
export CC_aarch64_linux_android="$ARM_CLANG"
export CC_x86_64_linux_android="$X64_CLANG"
export AR_aarch64_linux_android="$LLVM_AR"
export AR_x86_64_linux_android="$LLVM_AR"

for target in "$ARM_TARGET" "$X64_TARGET"; do
    echo "==> cargo build --lib --target $target ($PROFILE)"
    if [ "$PROFILE" = release ]; then
        (cd "$REPO_ROOT" && cargo build -p drome-core --lib --target "$target" --release)
    else
        (cd "$REPO_ROOT" && cargo build -p drome-core --lib --target "$target")
    fi
done

KOTLIN_ROOT="$REPO_ROOT/android/core/src/main/kotlin"
GENERATED_FILE="$KOTLIN_ROOT/day/drome/core/generated/drome_core.kt"
JNI_ROOT="$REPO_ROOT/android/core/src/main/jniLibs"
ARM_LIB="$SCRIPT_DIR/target/$ARM_TARGET/$PROFILE/libdrome_core.so"
X64_LIB="$SCRIPT_DIR/target/$X64_TARGET/$PROFILE/libdrome_core.so"

for library in "$ARM_LIB" "$X64_LIB"; do
    if [ ! -f "$library" ]; then
        echo "error: expected Android library is missing: $library" >&2
        exit 1
    fi
done

echo "==> generating Kotlin bindings"
mkdir -p "$KOTLIN_ROOT"
(cd "$REPO_ROOT" && cargo run -p drome-core --features cli --bin uniffi-bindgen -- \
    generate --library "$ARM_LIB" --language kotlin --no-format --out-dir "$KOTLIN_ROOT")

if [ ! -f "$GENERATED_FILE" ]; then
    echo "error: UniFFI did not generate $GENERATED_FILE" >&2
    exit 1
fi

echo "==> copying native libraries"
mkdir -p "$JNI_ROOT/arm64-v8a" "$JNI_ROOT/x86_64"
cp -f "$ARM_LIB" "$JNI_ROOT/arm64-v8a/libdrome_core.so"
cp -f "$X64_LIB" "$JNI_ROOT/x86_64/libdrome_core.so"

echo "==> done"
echo "    $GENERATED_FILE"
echo "    $JNI_ROOT/arm64-v8a/libdrome_core.so"
echo "    $JNI_ROOT/x86_64/libdrome_core.so"
