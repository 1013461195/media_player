#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_MODE="release"
readonly APK_PATH="${SCRIPT_DIR}/build/app/outputs/flutter-apk/app-${BUILD_MODE}.apk"
readonly DEFAULT_FLUTTER_IMAGE="ghrc-registry.rainbowsea.com.cn:2096/gmeligio/flutter-android:3.44.9"
readonly FLUTTER_IMAGE="${FLUTTER_DOCKER_IMAGE:-${DEFAULT_FLUTTER_IMAGE}}"

log() {
  printf '[android-build] %s\n' "$*"
}

fail() {
  printf '[android-build] 错误: %s\n' "$*" >&2
  exit 1
}

find_docker() {
  if [[ -n "${DOCKER_BIN:-}" && -x "${DOCKER_BIN}" ]]; then
    printf '%s\n' "${DOCKER_BIN}"
  elif command -v docker >/dev/null 2>&1; then
    command -v docker
  else
    return 1
  fi
}

find_adb() {
  if [[ -n "${ADB_BIN:-}" && -x "${ADB_BIN}" ]]; then
    printf '%s\n' "${ADB_BIN}"
  elif command -v adb >/dev/null 2>&1; then
    command -v adb
  elif [[ -n "${ANDROID_SDK_ROOT:-}" && -x "${ANDROID_SDK_ROOT}/platform-tools/adb" ]]; then
    printf '%s\n' "${ANDROID_SDK_ROOT}/platform-tools/adb"
  elif [[ -n "${ANDROID_HOME:-}" && -x "${ANDROID_HOME}/platform-tools/adb" ]]; then
    printf '%s\n' "${ANDROID_HOME}/platform-tools/adb"
  else
    return 1
  fi
}

main() {
  local docker_bin
  docker_bin="$(find_docker)" || fail "未找到 Docker。请先安装 Docker Desktop/Colima，或设置 DOCKER_BIN=/完整路径/docker。"

  if ! "${docker_bin}" info >/dev/null 2>&1; then
    fail "无法连接 Docker 后台，请先启动 Docker Desktop 或 Colima。"
  fi

  cd "${SCRIPT_DIR}"
  log "使用 Docker 镜像 ${FLUTTER_IMAGE} 构建 Android release APK..."
  "${docker_bin}" run --rm --pull=missing \
    --volume "${SCRIPT_DIR}:/app" \
    --workdir /app \
    "${FLUTTER_IMAGE}" \
    flutter build apk --release

  [[ -f "${APK_PATH}" ]] || fail "构建命令已结束，但未找到 APK：${APK_PATH}"
  log "构建完成：${APK_PATH}"

  local adb_bin
  if ! adb_bin="$(find_adb)"; then
    log "未找到 adb，跳过自动安装。请将 adb 加入 PATH，或设置 ADB_BIN=/完整路径/adb。"
    return 0
  fi

  local adb_output
  if ! adb_output="$("${adb_bin}" devices -l 2>&1)"; then
    log "adb 当前不可用，跳过自动安装："
    printf '%s\n' "${adb_output}"
    return 0
  fi

  local -a devices=()
  local serial state remainder
  while read -r serial state remainder; do
    [[ "${state:-}" == "device" ]] && devices+=("${serial}")
  done < <(printf '%s\n' "${adb_output}" | awk 'NR > 1 && NF >= 2 { print $1, $2 }')

  if (( ${#devices[@]} == 0 )); then
    log "未检测到已授权且在线的 ADB 设备，跳过自动安装。"
    if printf '%s\n' "${adb_output}" | awk 'NR > 1 && ($2 == "unauthorized" || $2 == "offline") { found=1 } END { exit !found }'; then
      log "提示：检测到了未授权或离线设备，请确认设备上的 USB 调试授权。"
    fi
    return 0
  fi

  local install_failed=0
  for serial in "${devices[@]}"; do
    log "正在安装到设备 ${serial}..."
    if "${adb_bin}" -s "${serial}" install -r "${APK_PATH}"; then
      log "设备 ${serial} 安装成功。"
    else
      log "设备 ${serial} 安装失败。"
      install_failed=1
    fi
  done

  (( install_failed == 0 )) || fail "APK 已构建，但至少有一台设备安装失败。"
  log "全部完成。"
}

main "$@"
