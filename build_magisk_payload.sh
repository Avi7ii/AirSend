#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$ROOT_DIR/Android"
DAEMON_DIR="$ANDROID_DIR/airsend_daemon"
MAGISK_DIR="$ROOT_DIR/magisk_module"
MODULE_VERSION="$(sed -n 's/^version=//p' "$MAGISK_DIR/module.prop" | head -n1)"
MODULE_VERSION_CODE="$(sed -n 's/^versionCode=//p' "$MAGISK_DIR/module.prop" | head -n1)"
if [[ -z "$MODULE_VERSION" ]]; then
  MODULE_VERSION="latest"
fi

DAEMON_TARGET_ABI="${DAEMON_TARGET_ABI:-arm64-v8a}"
APK_VARIANT="${APK_VARIANT:-debug}" # debug | release

DAEMON_DST="$MAGISK_DIR/system/bin/airsend_daemon"
APK_DST_DIR="$MAGISK_DIR/system/app/AirSend"
APK_DST="$APK_DST_DIR/AirSend.apk"
ZIP_OUTPUT="${ZIP_OUTPUT:-$ROOT_DIR/AirSend_Magisk_${MODULE_VERSION}.zip}"

log() {
  printf '[build-magisk] %s\n' "$1"
}

fail() {
  printf '[build-magisk] ERROR: %s\n' "$1" >&2
  exit 1
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

verify_same_hash() {
  local source="$1"
  local destination="$2"
  local source_hash
  local destination_hash
  source_hash="$(sha256_file "$source")"
  destination_hash="$(sha256_file "$destination")"
  [[ "$source_hash" == "$destination_hash" ]] ||
    fail "payload hash mismatch: $source ($source_hash) != $destination ($destination_hash)"
}

detect_android_home() {
  if [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME" ]]; then
    return
  fi

  local props="$ANDROID_DIR/local.properties"
  if [[ -f "$props" ]]; then
    local sdk_dir
    sdk_dir="$(sed -n 's/^sdk\.dir=//p' "$props" | head -n1)"
    if [[ -n "$sdk_dir" && -d "$sdk_dir" ]]; then
      export ANDROID_HOME="$sdk_dir"
      return
    fi
  fi

  if [[ -d "$HOME/Library/Android/sdk" ]]; then
    export ANDROID_HOME="$HOME/Library/Android/sdk"
  fi
}

detect_java_home() {
  if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
    return
  fi
  local android_studio_jbr="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  if [[ -x "$android_studio_jbr/bin/java" ]]; then
    export JAVA_HOME="$android_studio_jbr"
  fi
}

find_aapt2() {
  [[ -n "${ANDROID_HOME:-}" ]] || return 1
  find "$ANDROID_HOME/build-tools" -type f -name aapt2 -perm -111 2>/dev/null |
    sort -V |
    tail -n1
}

read_apk_version_code() {
  local apk="$1"
  local aapt2
  aapt2="$(find_aapt2 || true)"
  if [[ -n "$aapt2" ]]; then
    "$aapt2" dump badging "$apk" |
      sed -n "s/.*versionCode='\([0-9][0-9]*\)'.*/\1/p" |
      head -n1
    return
  fi

  local apkanalyzer="${ANDROID_HOME:-}/cmdline-tools/latest/bin/apkanalyzer"
  if [[ -x "$apkanalyzer" ]]; then
    "$apkanalyzer" manifest version-code "$apk" | tr -d '[:space:]'
    return
  fi
  fail "Neither aapt2 nor apkanalyzer is available to verify APK versionCode"
}

verify_version_sources() {
  local normalized_module_version="${MODULE_VERSION#v}"
  local cargo_version
  local android_version_name
  local android_version_code
  cargo_version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$DAEMON_DIR/Cargo.toml" | head -n1)"
  android_version_name="$(sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' "$ANDROID_DIR/app/build.gradle.kts" | head -n1)"
  android_version_code="$(sed -n 's/.*versionCode = \([0-9][0-9]*\).*/\1/p' "$ANDROID_DIR/app/build.gradle.kts" | head -n1)"

  [[ -n "$MODULE_VERSION_CODE" && "$MODULE_VERSION_CODE" =~ ^[0-9]+$ ]] ||
    fail "module.prop versionCode is missing or invalid"
  [[ "$cargo_version" == "$normalized_module_version" ]] ||
    fail "daemon version $cargo_version does not match module version $normalized_module_version"
  [[ "$android_version_name" == "$normalized_module_version" ]] ||
    fail "Android versionName $android_version_name does not match module version $normalized_module_version"
  [[ "$android_version_code" == "$MODULE_VERSION_CODE" ]] ||
    fail "Android versionCode $android_version_code does not match module versionCode $MODULE_VERSION_CODE"
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
  command -v unzip >/dev/null 2>&1 || fail "unzip not found"
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
  verify_same_hash "$daemon_src" "$DAEMON_DST"
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
  local apk_version_code
  apk_version_code="$(read_apk_version_code "$apk_src")"
  [[ "$apk_version_code" == "$MODULE_VERSION_CODE" ]] ||
    fail "built APK versionCode=$apk_version_code does not match module versionCode=$MODULE_VERSION_CODE"

  # Keep only one APK in the module app directory.
  mkdir -p "$APK_DST_DIR"
  find "$APK_DST_DIR" -maxdepth 1 -type f -name "*.apk" -delete
  replace_file_atomic "$apk_src" "$APK_DST" 0644
  verify_same_hash "$apk_src" "$APK_DST"
  log "APK replaced at: $APK_DST"
}

package_magisk_module() {
  log "Packaging Magisk module zip..."
  rm -f "$ZIP_OUTPUT"
  find "$MAGISK_DIR" \( -name '.DS_Store' -o -name '._*' \) -delete
  (
    cd "$MAGISK_DIR"
    COPYFILE_DISABLE=1 zip -qry "$ZIP_OUTPUT" . -x '*.DS_Store' '*/.DS_Store' '._*' '*/._*'
  )
  verify_zip_payload
  log "Magisk zip created: $ZIP_OUTPUT"
}

verify_zip_payload() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  unzip -qq "$ZIP_OUTPUT" -d "$temp_dir"
  [[ -f "$temp_dir/system/bin/airsend_daemon" ]] || fail "zip daemon payload missing"
  [[ -f "$temp_dir/system/app/AirSend/AirSend.apk" ]] || fail "zip APK payload missing"
  verify_same_hash "$DAEMON_DST" "$temp_dir/system/bin/airsend_daemon"
  verify_same_hash "$APK_DST" "$temp_dir/system/app/AirSend/AirSend.apk"
  rm -rf "$temp_dir"
  trap - RETURN
}

main() {
  detect_android_home
  detect_java_home
  ensure_prereqs
  detect_ndk_home
  verify_version_sources
  prepare_module_scripts
  build_daemon
  build_apk
  package_magisk_module
  log "Done. Magisk payload updated:"
  log "  - $DAEMON_DST"
  log "  - $APK_DST"
  log "  - $ZIP_OUTPUT"
}

if [[ "${AIRSEND_BUILD_TEST_MODE:-0}" != "1" ]]; then
  main "$@"
fi
