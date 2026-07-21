#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "usage: $0 <apk-or-aab>" >&2
  exit 2
fi

artifact="$1"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
ndk_version="${DROME_NDK_VERSION:-28.2.13676358}"
readelf="$sdk_root/ndk/$ndk_version/toolchains/llvm/prebuilt"
readelf="$(find "$readelf" -maxdepth 3 -name llvm-readelf -print -quit)"
if [[ -z "$readelf" ]]; then
  echo "llvm-readelf not found for NDK $ndk_version" >&2
  exit 1
fi

temp_dir="$(mktemp -d)"
trap 'rm -r "$temp_dir"' EXIT
libraries_file="$temp_dir/libraries.txt"
unzip -Z1 "$artifact" | grep -E '\.so$' > "$libraries_file" || true
if [[ ! -s "$libraries_file" ]]; then
  echo "no native libraries found in $artifact" >&2
  exit 1
fi

while IFS= read -r entry; do
  unzip -q "$artifact" "$entry" -d "$temp_dir"
  while read -r alignment; do
    value=$((alignment))
    if (( value < 16384 )); then
      echo "$entry has LOAD alignment $alignment (< 0x4000)" >&2
      exit 1
    fi
  done < <("$readelf" -lW "$temp_dir/$entry" | awk '$1 == "LOAD" { print $NF }')
  echo "16K ELF: $entry"
done < "$libraries_file"

if [[ "$artifact" == *.apk ]]; then
  zipalign="$(find "$sdk_root/build-tools" -maxdepth 2 -type f -name zipalign -print | sort -V | tail -1)"
  "$zipalign" -c -P 16 4 "$artifact"
  echo "16K ZIP: $artifact"
fi
