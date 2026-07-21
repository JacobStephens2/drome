# Drome Android

Native Kotlin/Compose phone and Wear OS clients over the shared Rust core. The implementation contract is [`../docs/ANDROID.md`](../docs/ANDROID.md).

## Local build

Prerequisites: Android Studio/JBR, API 36 SDK, NDK `28.2.13676358`, and the Rust targets `aarch64-linux-android` + `x86_64-linux-android`.

```sh
./core/build-android-lib.sh
cd android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
  ANDROID_HOME="$HOME/Library/Android/sdk" \
  ./gradlew test assembleDebug
```

The generated Kotlin binding is checked in; native `.so` files and Gradle output are ignored. Re-run the Rust build script after any exported core API change.

Phone and Wear deliberately use the same application ID and must be signed from the same Play App Signing lineage. Debug variants also share the same `.debug` suffix.

## Release checks

```sh
android/scripts/verify-native-alignment.sh android/app/build/outputs/apk/debug/app-debug.apk
android/scripts/verify-native-alignment.sh android/wear/build/outputs/apk/debug/wear-debug.apk
android/scripts/verify-native-alignment.sh android/app/build/outputs/bundle/release/app-release.aab
android/scripts/verify-native-alignment.sh android/wear/build/outputs/bundle/release/wear-release.aab
```

The check inspects every packaged native library, including JNA, and verifies 16 KB
ELF segment alignment. APKs additionally receive the 16 KB ZIP alignment check.
