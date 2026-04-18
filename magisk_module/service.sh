#!/system/bin/sh

MODDIR=${0%/*}
PACKAGE_NAME="com.airsend"
APK_SOURCE="$MODDIR/system/app/AirSend/AirSend.apk"
DAEMON_BIN="$MODDIR/system/bin/airsend_daemon"
LOG_DIR="/data/adb/airsend/logs"
LOG_PATH="$LOG_DIR/airsend_daemon.log"
LOG_ROTATED_PATH="$LOG_DIR/airsend_daemon.log.1"
LEGACY_LOG_PATH="/data/local/tmp/airsend_daemon.log"
LOG_MAX_BYTES=4194304

prepare_runtime_dirs() {
  mkdir -p "$LOG_DIR"
  chmod 0755 "$LOG_DIR" 2>/dev/null || true
}

rotate_log_if_needed() {
  if [ ! -f "$LOG_PATH" ]; then
    return 0
  fi

  log_size="$(wc -c < "$LOG_PATH" 2>/dev/null || echo 0)"
  if [ "${log_size:-0}" -lt "$LOG_MAX_BYTES" ]; then
    return 0
  fi

  rm -f "$LOG_ROTATED_PATH"
  mv "$LOG_PATH" "$LOG_ROTATED_PATH"
}

log_line() {
  echo "$(date): $1" >> "$LOG_PATH"
}

get_active_package_path() {
  pm path "$PACKAGE_NAME" 2>/dev/null | sed -n 's/^package://p' | head -n 1
}

get_file_hash() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}' | head -n 1
}

wait_for_package_manager() {
  package_path=""
  attempt=""

  for attempt in $(seq 1 20); do
    package_path="$(get_active_package_path)"
    if [ -n "$package_path" ]; then
      echo "$package_path"
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
  current_hash=""
  payload_hash=""
  resolved_path=""

  if ! command -v pm >/dev/null 2>&1; then
    log_line "Package manager CLI unavailable; skipping APK sync."
    return 0
  fi

  if [ ! -f "$APK_SOURCE" ]; then
    log_line "Module APK payload missing: $APK_SOURCE"
    return 0
  fi

  payload_hash="$(get_file_hash "$APK_SOURCE")"
  current_path="$(wait_for_package_manager || true)"
  if [ -n "$current_path" ] && [ -f "$current_path" ]; then
    current_hash="$(get_file_hash "$current_path")"
  fi

  if [ -n "$payload_hash" ] && [ -n "$current_hash" ] && [ "$payload_hash" = "$current_hash" ]; then
    log_line "AirSend APK already matches module payload: $current_path"
    return 0
  fi

  if [ -n "$current_path" ]; then
    log_line "Installing AirSend APK update from module payload (current path: $current_path)"
  else
    log_line "AirSend APK missing from PackageManager; installing from module payload."
  fi

  if pm install -r -d "$APK_SOURCE" >> "$LOG_PATH" 2>&1; then
    if command -v cmd >/dev/null 2>&1; then
      cmd package wait-for-handler --timeout 20000 >> "$LOG_PATH" 2>&1 || true
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
  if pgrep -x airsend_daemon > /dev/null; then
    log_line "AirSend daemon is already running, skipping startup."
    return 0
  fi

  rm -f "$LEGACY_LOG_PATH"
  log_line "Starting AirSend daemon..."
  nohup "$DAEMON_BIN" >> "$LOG_PATH" 2>&1 &
  log_line "AirSend daemon started in background."
}

for i in $(seq 1 30); do
  [ -d "/data/adb" ] && break
  sleep 2
done

prepare_runtime_dirs
rotate_log_if_needed
start_daemon
ensure_payload_app_installed
