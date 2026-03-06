#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$ROOT_DIR/Android"
DAEMON_DIR="$ANDROID_DIR/airsend_daemon"
MAGISK_DIR="$ROOT_DIR/magisk_module"

DAEMON_TARGET_ABI="${DAEMON_TARGET_ABI:-arm64-v8a}"
APK_VARIANT="${APK_VARIANT:-debug}" # debug | release

DAEMON_DST="$MAGISK_DIR/system/bin/airsend_daemon"
APK_DST_DIR="$MAGISK_DIR/system/app/AirSend"
APK_DST="$APK_DST_DIR/AirSend.apk"
ZIP_OUTPUT="${ZIP_OUTPUT:-$ROOT_DIR/AirSend_Magisk_latest.zip}"

log() {
  printf '[build-magisk] %s\n' "$1"
}

fail() {
  printf '[build-magisk] ERROR: %s\n' "$1" >&2
  exit 1
}

prepare_module_scripts() {
  local script

  for script in "$MAGISK_DIR"/service.sh "$MAGISK_DIR"/customize.sh "$MAGISK_DIR"/post-fs-data.sh; do
    [[ -f "$script" ]] || continue
    chmod 0755 "$script"
  done
}

cleanup_renamed_duplicates() {
  local target="$1"
  local dir
  local base
  dir="$(dirname "$target")"
  base="$(basename "$target")"
  [[ -d "$dir" ]] || return 0

  # Remove Finder-style duplicates like "airsend_daemon 2" or "AirSend 3.apk".
  find "$dir" -maxdepth 1 -type f -name "$base *" -delete
}

replace_file_atomic() {
  local src="$1"
  local dst="$2"
  local mode="$3"
  local dir
  local tmp

  dir="$(dirname "$dst")"
  mkdir -p "$dir"

  cleanup_renamed_duplicates "$dst"

  tmp="$dir/.tmp.$(basename "$dst").$$"
  install -m "$mode" "$src" "$tmp"
  mv -f "$tmp" "$dst"
  chmod "$mode" "$dst"
}

ensure_prereqs() {
  command -v cargo >/dev/null 2>&1 || fail "cargo not found"
  command -v install >/dev/null 2>&1 || fail "install not found"
  command -v zip >/dev/null 2>&1 || fail "zip not found"
  [[ -x "$ANDROID_DIR/gradlew" ]] || fail "Android/gradlew is missing or not executable"
  cargo ndk --help >/dev/null 2>&1 || fail "cargo-ndk is required (install via: cargo install cargo-ndk)"
}

detect_ndk_home() {
  if [[ -n "${ANDROID_NDK_HOME:-}" && -d "${ANDROID_NDK_HOME:-}" ]]; then
    return
  fi

  local sdk_dir=""
  local props="$ANDROID_DIR/local.properties"
  if [[ -f "$props" ]]; then
    sdk_dir="$(grep -E '^sdk\.dir=' "$props" | head -n1 | cut -d'=' -f2- || true)"
  fi

  if [[ -z "$sdk_dir" && -n "${ANDROID_HOME:-}" ]]; then
    sdk_dir="$ANDROID_HOME"
  fi

  if [[ -z "$sdk_dir" ]]; then
    return
  fi

  local ndk_root="$sdk_dir/ndk"
  if [[ ! -d "$ndk_root" ]]; then
    return
  fi

  local latest_ndk
  latest_ndk="$(ls -1 "$ndk_root" | sort -V | tail -n1)"
  if [[ -n "$latest_ndk" && -d "$ndk_root/$latest_ndk" ]]; then
    export ANDROID_NDK_HOME="$ndk_root/$latest_ndk"
    log "Using ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
  fi
}

build_daemon() {
  log "Building daemon (ABI=$DAEMON_TARGET_ABI)..."
  (
    cd "$DAEMON_DIR"
    cargo ndk -t "$DAEMON_TARGET_ABI" build --release
  )

  local daemon_src="$DAEMON_DIR/target/aarch64-linux-android/release/airsend_daemon"
  [[ -f "$daemon_src" ]] || fail "daemon output not found: $daemon_src"

  replace_file_atomic "$daemon_src" "$DAEMON_DST" 0755
  log "Daemon replaced at: $DAEMON_DST"
}

resolve_apk_task() {
  local variant
  variant="$(printf '%s' "$APK_VARIANT" | tr '[:upper:]' '[:lower:]')"
  case "$variant" in
    debug)
      echo ":app:assembleDebug|$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
      ;;
    release)
      echo ":app:assembleRelease|$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk;$ANDROID_DIR/app/build/outputs/apk/release/app-release-unsigned.apk"
      ;;
    *)
      fail "Unsupported APK_VARIANT: $APK_VARIANT (use debug or release)"
      ;;
  esac
}

build_apk() {
  local task_and_candidates
  task_and_candidates="$(resolve_apk_task)"
  local gradle_task="${task_and_candidates%%|*}"
  local candidates="${task_and_candidates#*|}"

  log "Building APK ($gradle_task)..."
  (
    cd "$ANDROID_DIR"
    ./gradlew "$gradle_task"
  )

  local apk_src=""
  IFS=';' read -r -a apk_candidates <<< "$candidates"
  for candidate in "${apk_candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      apk_src="$candidate"
      break
    fi
  done

  [[ -n "$apk_src" ]] || fail "APK output not found after task $gradle_task"

  # Keep only one APK in the module app directory.
  mkdir -p "$APK_DST_DIR"
  find "$APK_DST_DIR" -maxdepth 1 -type f -name "*.apk" -delete
  replace_file_atomic "$apk_src" "$APK_DST" 0644
  log "APK replaced at: $APK_DST"
}

package_magisk_module() {
  log "Packaging Magisk module zip..."
  rm -f "$ZIP_OUTPUT"
  (
    cd "$MAGISK_DIR"
    zip -qry "$ZIP_OUTPUT" .
  )
  log "Magisk zip created: $ZIP_OUTPUT"
}

main() {
  ensure_prereqs
  detect_ndk_home
  prepare_module_scripts
  build_daemon
  build_apk
  package_magisk_module
  log "Done. Magisk payload updated:"
  log "  - $DAEMON_DST"
  log "  - $APK_DST"
  log "  - $ZIP_OUTPUT"
}

main "$@"
