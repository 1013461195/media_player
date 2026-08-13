#!/usr/bin/env bash

# Build a debug APK in Docker and install it on every authorised host ADB device.
# The Docker image, rather than host SDK paths, must provide Linux Flutter, Android
# SDK and NDK. Set FLUTTER_DOCKER_IMAGE if the default image is not suitable.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$PROJECT_DIR/android"
APK_PATH="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
ANDROID_DOCKER_IMAGE="${FLUTTER_DOCKER_IMAGE:-ghcr.io/cirruslabs/flutter:3.44.0}"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-28.2.13676358}"
GRADLE_BUILD_RETRIES="${GRADLE_BUILD_RETRIES:-3}"

fail() {
  echo "错误：$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "未找到 Docker。请先安装并启动 Docker Desktop。"
[[ -x "$ANDROID_DIR/gradlew" ]] || fail "未找到可执行的 Gradle Wrapper：$ANDROID_DIR/gradlew"

ANDROID_SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[[ -n "$ANDROID_SDK_DIR" && -d "$ANDROID_SDK_DIR" ]] || fail "请设置 ANDROID_HOME（或 ANDROID_SDK_ROOT）为有效的 Android SDK 目录，以便安装 APK。"
ADB_BIN="$ANDROID_SDK_DIR/platform-tools/adb"
[[ -x "$ADB_BIN" ]] || fail "未找到 adb：$ADB_BIN。请安装 Android SDK Platform-Tools。"

# The container uses Linux SDK binaries. Do not bind-mount host FLUTTER_HOME,
# ANDROID_HOME or ANDROID_NDK_HOME, which may target a different operating system.
mkdir -p "$PROJECT_DIR/.gradle"

DOCKER_RUN=(
  docker run --rm
  --user "$(id -u):$(id -g)"
  --volume "$PROJECT_DIR:/workspace"
  --workdir /workspace
  --env GRADLE_USER_HOME=/workspace/.gradle
  --env ANDROID_NDK_VERSION
  --env GRADLE_BUILD_RETRIES
)

for proxy_name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
  proxy_value="${!proxy_name-}"
  [[ -n "$proxy_value" ]] && DOCKER_RUN+=(--env "$proxy_name")
done

echo "正在使用 Docker 镜像打包 Debug APK：$ANDROID_DOCKER_IMAGE"
"${DOCKER_RUN[@]}" "$ANDROID_DOCKER_IMAGE" bash -lc '
  set -euo pipefail
  sdk_dir="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [[ -n "$sdk_dir" && -d "$sdk_dir" ]] || { echo "错误：Docker 镜像未设置有效的 ANDROID_HOME/ANDROID_SDK_ROOT。" >&2; exit 1; }
  command -v flutter >/dev/null || { echo "错误：Docker 镜像未包含 Flutter。请设置 FLUTTER_DOCKER_IMAGE。" >&2; exit 1; }
  ndk_dir="$sdk_dir/ndk/$ANDROID_NDK_VERSION"
  [[ -f "$ndk_dir/source.properties" ]] || { echo "错误：Docker 镜像未包含 NDK $ANDROID_NDK_VERSION。请使用包含此 NDK 的 FLUTTER_DOCKER_IMAGE。" >&2; exit 1; }
  local_properties="/workspace/android/local.properties"
  backup="$(mktemp)"
  [[ -f "$local_properties" ]] && cp "$local_properties" "$backup"
  restore_properties() { if [[ -s "$backup" ]]; then cp "$backup" "$local_properties"; else rm -f "$local_properties"; fi; rm -f "$backup"; }
  trap restore_properties EXIT
  { [[ -f "$local_properties" ]] && grep -vE "^(sdk\\.dir|flutter\\.sdk|ndk\\.dir)=" "$local_properties" || true; printf "sdk.dir=%s\\nflutter.sdk=%s\\n" "$sdk_dir" "$(dirname "$(dirname "$(command -v flutter)")")"; } > "$local_properties.tmp"
  mv "$local_properties.tmp" "$local_properties"
  flutter pub get
  cd /workspace/android
  for ((attempt = 1; attempt <= GRADLE_BUILD_RETRIES; attempt++)); do
    build_log="$(mktemp)"
    if (( attempt > 1 )); then
      echo "网络依赖下载失败，正在重试（$attempt/$GRADLE_BUILD_RETRIES）..."
      set +e
      ./gradlew --no-daemon --refresh-dependencies assembleDebug 2>&1 | tee "$build_log"
      status="${PIPESTATUS[0]}"
      set -e
    else
      set +e
      ./gradlew --no-daemon assembleDebug 2>&1 | tee "$build_log"
      status="${PIPESTATUS[0]}"
      set -e
    fi
    if [[ "$status" -eq 0 ]]; then rm -f "$build_log"; exit 0; fi
    if ! grep -qE "Could not download|Premature end of Content-Length|Connection reset|Read timed out" "$build_log"; then rm -f "$build_log"; exit "$status"; fi
    rm -f "$build_log"
    (( attempt < GRADLE_BUILD_RETRIES )) || exit "$status"
    sleep "$attempt"
  done
'

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
