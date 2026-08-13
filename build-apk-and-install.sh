#!/usr/bin/env bash

# Build a debug APK and install it on every authorised ADB device.
# Required environment variables:
#   FLUTTER_HOME (or FLUTTER_ROOT), ANDROID_HOME (or ANDROID_SDK_ROOT),
#   ANDROID_NDK_HOME (or ANDROID_NDK_ROOT), and JAVA_HOME (or ANDROID_JDK_HOME).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$PROJECT_DIR/android"
APK_PATH="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
LOCAL_PROPERTIES="$ANDROID_DIR/local.properties"
GRADLE_BUILD_RETRIES="${GRADLE_BUILD_RETRIES:-3}"

fail() {
  echo "错误：$*" >&2
  exit 1
}

require_directory() {
  local variable_name="$1"
  local directory="$2"
  [[ -n "$directory" && -d "$directory" ]] || fail "请设置 $variable_name 为有效目录。"
}

FLUTTER_SDK="${FLUTTER_HOME:-${FLUTTER_ROOT:-}}"
require_directory "FLUTTER_HOME（或 FLUTTER_ROOT）" "$FLUTTER_SDK"
[[ -x "$FLUTTER_SDK/bin/flutter" ]] || fail "FLUTTER_HOME 必须指向 Flutter SDK 根目录（未找到 bin/flutter）。"

ANDROID_SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
require_directory "ANDROID_HOME（或 ANDROID_SDK_ROOT）" "$ANDROID_SDK_DIR"

ANDROID_NDK_DIR="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
require_directory "ANDROID_NDK_HOME（或 ANDROID_NDK_ROOT）" "$ANDROID_NDK_DIR"
[[ -f "$ANDROID_NDK_DIR/source.properties" ]] || fail "ANDROID_NDK_HOME 必须指向 NDK 版本目录（未找到 source.properties）。"
NDK_VERSION="$(awk -F '=' '/^Pkg\.Revision[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$ANDROID_NDK_DIR/source.properties")"
[[ -n "$NDK_VERSION" && -f "$ANDROID_SDK_DIR/ndk/$NDK_VERSION/source.properties" ]] || fail "Android SDK 中未安装 NDK ${NDK_VERSION:-未知}。请将 ANDROID_NDK_HOME 指向 $ANDROID_SDK_DIR/ndk/<版本>。"

BUILD_JDK_HOME="${ANDROID_JDK_HOME:-${JAVA_HOME:-}}"
require_directory "ANDROID_JDK_HOME（或 JAVA_HOME）" "$BUILD_JDK_HOME"
[[ -x "$BUILD_JDK_HOME/bin/java" ]] || fail "JAVA_HOME 必须指向 JDK 17 根目录（未找到 bin/java）。"

JDK_MAJOR_VERSION="$("$BUILD_JDK_HOME/bin/java" -version 2>&1 | awk -F '[".]' '/version/ { print $2; exit }')"
[[ "$JDK_MAJOR_VERSION" == "17" ]] || fail "当前 JDK 为 ${JDK_MAJOR_VERSION:-未知}；此项目需要 JDK 17。"

[[ -x "$ANDROID_DIR/gradlew" ]] || fail "未找到可执行的 Gradle Wrapper：$ANDROID_DIR/gradlew"
ADB_BIN="$ANDROID_SDK_DIR/platform-tools/adb"
[[ -x "$ADB_BIN" ]] || fail "未找到 adb：$ADB_BIN。请安装 Android SDK Platform-Tools。"

export JAVA_HOME="$BUILD_JDK_HOME"
export ANDROID_HOME="$ANDROID_SDK_DIR"
export ANDROID_SDK_ROOT="$ANDROID_SDK_DIR"
export ANDROID_NDK_HOME="$ANDROID_NDK_DIR"
export ANDROID_NDK_ROOT="$ANDROID_NDK_DIR"
export PATH="$FLUTTER_SDK/bin:$JAVA_HOME/bin:$ANDROID_SDK_DIR/platform-tools:$PATH"

# local.properties is intentionally ignored by Git. Keep unrelated local settings,
# but refresh the paths consumed by Flutter's Gradle settings on every build. The
# NDK is selected from the Android SDK by the project's declared ndkVersion; it
# must not be written as ndk.dir because that property is deprecated by AGP.
update_local_properties() {
  local temporary_file
  temporary_file="$(mktemp "$ANDROID_DIR/local.properties.XXXXXX")"
  if [[ -f "$LOCAL_PROPERTIES" ]]; then
    awk '!/^(sdk\.dir|flutter\.sdk|ndk\.dir)=/' "$LOCAL_PROPERTIES" > "$temporary_file"
  fi
  {
    printf 'sdk.dir=%s\n' "$ANDROID_SDK_DIR"
    printf 'flutter.sdk=%s\n' "$FLUTTER_SDK"
  } >> "$temporary_file"
  mv "$temporary_file" "$LOCAL_PROPERTIES"
}

update_local_properties

run_gradle_build() {
  local attempt build_log status
  for ((attempt = 1; attempt <= GRADLE_BUILD_RETRIES; attempt++)); do
    build_log="$(mktemp)"
    if (( attempt > 1 )); then
      echo "网络依赖下载失败，正在重试（$attempt/$GRADLE_BUILD_RETRIES）..."
      set +e
      ./gradlew --refresh-dependencies assembleDebug 2>&1 | tee "$build_log"
      status="${PIPESTATUS[0]}"
      set -e
    else
      set +e
      ./gradlew assembleDebug 2>&1 | tee "$build_log"
      status="${PIPESTATUS[0]}"
      set -e
    fi

    if [[ "$status" -eq 0 ]]; then
      rm -f "$build_log"
      return 0
    fi
    if ! grep -qE 'Could not download|Premature end of Content-Length|Connection reset|Read timed out' "$build_log"; then
      rm -f "$build_log"
      return "$status"
    fi
    rm -f "$build_log"
    (( attempt < GRADLE_BUILD_RETRIES )) || return "$status"
    sleep "$attempt"
  done
}

echo "正在获取 Flutter 依赖..."
cd "$PROJECT_DIR"
flutter pub get

echo "正在打包 Debug APK..."
cd "$ANDROID_DIR"
run_gradle_build

[[ -f "$APK_PATH" ]] || fail "未找到生成的 APK：$APK_PATH"

DEVICE_IDS=()
while IFS= read -r device_id; do
  [[ -n "$device_id" ]] && DEVICE_IDS+=("$device_id")
done < <("$ADB_BIN" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
if [[ ${#DEVICE_IDS[@]} -eq 0 ]]; then
  echo "APK 已生成：$APK_PATH"
  echo "未检测到已授权的 ADB 设备，跳过安装。"
  exit 0
fi

for device_id in "${DEVICE_IDS[@]}"; do
  echo "正在安装到设备：$device_id"
  "$ADB_BIN" -s "$device_id" install -r "$APK_PATH"
done

echo "APK 已生成并安装完成：$APK_PATH"
