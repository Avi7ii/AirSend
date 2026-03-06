#!/system/bin/sh

PACKAGE_NAME="com.airsend"
APK_SOURCE="${MODPATH:-}/system/app/AirSend/AirSend.apk"

ui_print_safe() {
  if command -v ui_print >/dev/null 2>&1; then
    ui_print "$1"
  else
    echo "$1"
  fi
}

get_active_package_path() {
  pm path "$PACKAGE_NAME" 2>/dev/null | sed -n 's/^package://p' | head -n 1
}

get_file_hash() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}' | head -n 1
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

install_payload_app() {
  active_path=""
  active_hash=""
  payload_hash=""
  resolved_path=""

  if ! command -v pm >/dev/null 2>&1; then
    ui_print_safe "- Package manager CLI unavailable; skipping AirSend APK install"
    return 0
  fi

  if [ -z "${MODPATH:-}" ] || [ ! -f "$APK_SOURCE" ]; then
    ui_print_safe "- Module APK payload is unavailable during install; boot self-check will retry"
    return 0
  fi

  active_path="$(get_active_package_path)"
  payload_hash="$(get_file_hash "$APK_SOURCE")"
  if [ -n "$active_path" ] && [ -f "$active_path" ]; then
    active_hash="$(get_file_hash "$active_path")"
  fi

  if [ -n "$payload_hash" ] && [ -n "$active_hash" ] && [ "$payload_hash" = "$active_hash" ]; then
    ui_print_safe "- AirSend APK already matches the module payload"
    return 0
  fi

  if [ -n "$active_path" ]; then
    ui_print_safe "- Updating AirSend APK from module payload"
  else
    ui_print_safe "- Installing AirSend APK from module payload"
  fi

  if pm install -r -d "$APK_SOURCE" >/dev/null 2>&1; then
    if command -v cmd >/dev/null 2>&1; then
      cmd package wait-for-handler --timeout 20000 >/dev/null 2>&1 || true
    fi

    resolved_path="$(wait_for_package_registration || true)"
    if [ -n "$resolved_path" ]; then
      ui_print_safe "- Active path is now $resolved_path"
    else
      ui_print_safe "! Install succeeded, but the active path is still unavailable"
    fi
  else
    ui_print_safe "! Failed to install AirSend APK from the module payload; boot self-check will retry"
  fi
}

if [ "${BOOTMODE:-false}" = "true" ]; then
  ui_print_safe "- Syncing AirSend APK from the module payload"
  install_payload_app
  ui_print_safe "- Reboot after install so LSPosed/system_server loads the packaged APK"
else
  ui_print_safe "- Recovery install detected; APK sync will run on first boot"
fi
