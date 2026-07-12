#!/system/bin/sh

MODDIR=${AIRSEND_TEST_MODDIR:-${0%/*}}
PACKAGE_NAME="com.airsend"
APK_SOURCE="$MODDIR/system/app/AirSend/AirSend.apk"
DAEMON_BIN="/system/bin/airsend_daemon"
SERVICE_LOG_PATH="/data/local/tmp/airsend_service.log"
BOOTSTRAP_LOG_PATH="/data/local/tmp/airsend_daemon_bootstrap.log"
MODULE_PROP="$MODDIR/module.prop"
MAX_SERVICE_LOG_BYTES=262144

log_line() {
  echo "$(date): $1" >> "$SERVICE_LOG_PATH"
}

get_active_package_path() {
  pm path "$PACKAGE_NAME" 2>/dev/null | sed -n 's/^package://p' | head -n 1
}

get_module_version_code() {
  sed -n 's/^versionCode=\([0-9][0-9]*\)$/\1/p' "$MODULE_PROP" 2>/dev/null | head -n 1
}

get_installed_version_code() {
  dumpsys package "$PACKAGE_NAME" 2>/dev/null |
    sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' |
    head -n 1
}

decide_apk_sync() {
  installed_version="$1"
  payload_version="$2"

  case "$payload_version" in
    ''|*[!0-9]*) echo "error"; return 0 ;;
  esac
  case "$installed_version" in
    missing|'') echo "install"; return 0 ;;
    *[!0-9]*) echo "error"; return 0 ;;
  esac

  if [ "$installed_version" -lt "$payload_version" ]; then
    echo "install"
  else
    echo "keep"
  fi
}

wait_for_package_manager() {
  attempt=""

  for attempt in $(seq 1 20); do
    if pm list packages >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_for_package_registration() {
  package_path=""
  attempt=""

  for attempt in $(seq 1 10); do
    package_path="$(get_active_package_path)"
    if [ -n "$package_path" ]; then
      echo "$package_path"
      return 0
    fi
    sleep 1
  done

  return 1
}

ensure_payload_app_installed() {
  current_path=""
  current_version=""
  payload_version=""
  decision=""
  resolved_path=""

  if ! command -v pm >/dev/null 2>&1; then
    log_line "Package manager CLI unavailable; skipping APK sync."
    return 0
  fi

  if [ ! -f "$APK_SOURCE" ]; then
    log_line "Module APK payload missing: $APK_SOURCE"
    return 0
  fi

  if ! wait_for_package_manager; then
    log_line "Package manager did not become ready; skipping APK sync."
    return 0
  fi

  payload_version="$(get_module_version_code)"
  if [ -z "$payload_version" ]; then
    log_line "Module versionCode is missing or invalid; refusing APK sync."
    return 0
  fi

  current_path="$(get_active_package_path)"
  current_version="$(get_installed_version_code)"
  if [ -z "$current_version" ]; then
    current_version="missing"
  fi
  decision="$(decide_apk_sync "$current_version" "$payload_version")"
  if [ "$decision" = "keep" ]; then
    log_line "Keeping installed AirSend APK versionCode=$current_version (module payload=$payload_version)."
    return 0
  fi
  if [ "$decision" != "install" ]; then
    log_line "Invalid APK version state installed=$current_version payload=$payload_version; refusing sync."
    return 0
  fi

  if [ "$current_version" = "missing" ]; then
    log_line "AirSend APK is missing; installing module payload versionCode=$payload_version."
  else
    log_line "Updating AirSend APK versionCode=$current_version -> $payload_version from module payload."
  fi

  if pm install -r "$APK_SOURCE" >> "$SERVICE_LOG_PATH" 2>&1; then
    if command -v cmd >/dev/null 2>&1; then
      cmd package wait-for-handler --timeout 20000 >> "$SERVICE_LOG_PATH" 2>&1 || true
    fi

    resolved_path="$(wait_for_package_registration || true)"
    if [ -n "$resolved_path" ]; then
      log_line "AirSend APK installed successfully: $resolved_path"
      log_line "Reboot once more so LSPosed/system_server reloads the new module code."
    else
      log_line "Install succeeded, but active package path is still unavailable."
    fi
  else
    log_line "Failed to install AirSend APK from module payload."
  fi
}

start_daemon() {
  if pgrep -f "$DAEMON_BIN" > /dev/null; then
    log_line "AirSend daemon is already running, skipping startup."
    return 0
  fi

  log_line "Starting AirSend daemon..."
  rotate_small_log "$BOOTSTRAP_LOG_PATH"
  nohup "$DAEMON_BIN" >> "$BOOTSTRAP_LOG_PATH" 2>&1 &
  log_line "AirSend daemon started in background."
}

rotate_small_log() {
  path="$1"
  if [ -f "$path" ]; then
    size="$(wc -c < "$path" 2>/dev/null || echo 0)"
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac
    if [ "$size" -ge "$MAX_SERVICE_LOG_BYTES" ]; then
      mv -f "$path" "$path.1" 2>/dev/null || true
    fi
  fi
}

if [ "${AIRSEND_SERVICE_TEST_MODE:-0}" != "1" ]; then
  for i in $(seq 1 30); do
    [ -d "/data/local/tmp" ] && break
    sleep 2
  done

  rotate_small_log "$SERVICE_LOG_PATH"
  start_daemon
  ensure_payload_app_installed
fi
