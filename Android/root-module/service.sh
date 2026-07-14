#!/system/bin/sh

MODDIR=${AIRSEND_TEST_MODDIR:-${0%/*}}
PACKAGE_NAME="com.airsend"
APK_SOURCE="$MODDIR/system/app/AirSend/AirSend.apk"
DAEMON_BIN="/system/bin/airsend_daemon"
SERVICE_LOG_PATH="/data/local/tmp/airsend_service.log"
BOOTSTRAP_LOG_PATH="/data/local/tmp/airsend_daemon_bootstrap.log"
SUPERVISOR_PATH="$MODDIR/supervisor.sh"
MODULE_PROP="$MODDIR/module.prop"
MAX_SERVICE_LOG_BYTES=262144

log_line() {
  echo "$(date): $1" >> "$SERVICE_LOG_PATH"
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
  for _ in $(seq 1 20); do
    pm list packages >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

ensure_payload_app_installed() {
  [ -f "$APK_SOURCE" ] || { log_line "Module APK payload missing: $APK_SOURCE"; return 0; }
  wait_for_package_manager || { log_line "Package manager did not become ready"; return 0; }

  payload_version="$(get_module_version_code)"
  installed_version="$(get_installed_version_code)"
  [ -n "$installed_version" ] || installed_version="missing"
  decision="$(decide_apk_sync "$installed_version" "$payload_version")"

  if [ "$decision" = "keep" ]; then
    log_line "Keeping installed APK versionCode=$installed_version (module=$payload_version)."
    return 0
  fi
  if [ "$decision" != "install" ]; then
    log_line "Invalid APK version state; refusing payload sync."
    return 0
  fi

  if pm install -r "$APK_SOURCE" >> "$SERVICE_LOG_PATH" 2>&1; then
    log_line "Installed AirSend APK payload versionCode=$payload_version."
    log_line "Reboot once more so system_server can load the updated LSPosed module."
  else
    log_line "Failed to install AirSend APK payload."
  fi
}

start_daemon() {
  if [ ! -x "$SUPERVISOR_PATH" ]; then
    log_line "AirSend supervisor is missing: $SUPERVISOR_PATH"
    return 0
  fi
  rotate_small_log "$BOOTSTRAP_LOG_PATH"
  AIRSEND_SUPERVISOR_MODDIR="$MODDIR" nohup "$SUPERVISOR_PATH" \
    >> "$BOOTSTRAP_LOG_PATH" 2>&1 &
  log_line "AirSend daemon supervisor started."
}

if [ "${AIRSEND_SERVICE_TEST_MODE:-0}" != "1" ]; then
  for _ in $(seq 1 30); do
    [ -d "/data/local/tmp" ] && break
    sleep 2
  done
  rotate_small_log "$SERVICE_LOG_PATH"
  start_daemon
  ensure_payload_app_installed
fi
