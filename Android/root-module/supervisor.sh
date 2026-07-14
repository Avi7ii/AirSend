#!/system/bin/sh

MODDIR=${AIRSEND_SUPERVISOR_MODDIR:-${0%/*}}
DAEMON_BIN="/system/bin/airsend_daemon"
STATE_DIR="/data/adb/airsend"
CONTROL_DIR="/data/local/tmp/airsend_supervisor"
LOCK_DIR="$CONTROL_DIR/.lock"
LOCK_PID="$LOCK_DIR/pid"
LOCK_BOOT_ID="$LOCK_DIR/boot_id"
LOG_PATH="/data/local/tmp/airsend_daemon_bootstrap.log"
STATE_PATH="$STATE_DIR/supervisor.state"

mkdir -p "$STATE_DIR" "$CONTROL_DIR"

current_boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"

existing_supervisor_is_alive() {
  existing_pid="$(cat "$LOCK_PID" 2>/dev/null || true)"
  case "$existing_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac

  existing_boot_id="$(cat "$LOCK_BOOT_ID" 2>/dev/null || true)"
  if [ -n "$current_boot_id" ] && [ "$existing_boot_id" != "$current_boot_id" ]; then
    return 1
  fi

  kill -0 "$existing_pid" 2>/dev/null || return 1
  existing_cmdline="$(tr '\000' ' ' < "/proc/$existing_pid/cmdline" 2>/dev/null || true)"
  case "$existing_cmdline" in
    *airsend_supervisor*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -d "$LOCK_DIR" ]; then
  existing_supervisor_is_alive && exit 0
  rm -rf "$LOCK_DIR" 2>/dev/null || exit 0
fi

mkdir "$LOCK_DIR" 2>/dev/null || exit 0
echo "$$" > "$LOCK_PID"
[ -z "$current_boot_id" ] || echo "$current_boot_id" > "$LOCK_BOOT_ID"

cleanup() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log_line() {
  echo "$(date): $1" >> "$LOG_PATH"
}

write_state() {
  printf 'status=%s\nreason=%s\ncrashCount=%s\n' "$1" "$2" "$3" > "$STATE_PATH"
}

stop_unmanaged_daemons() {
  for pid in $(pidof airsend_daemon 2>/dev/null); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for _ in $(seq 1 20); do
    pidof airsend_daemon >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  for pid in $(pidof airsend_daemon 2>/dev/null); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

child_pid=""

stop_child() {
  if [ -z "$child_pid" ]; then
    return 0
  fi
  kill -TERM "$child_pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$child_pid" 2>/dev/null || true
  child_pid=""
}

handle_stop() {
  stop_child
  exit 0
}

trap handle_stop INT TERM

stop_unmanaged_daemons

crash_count=0
window_start=0
backoff=1

while true; do
  if [ ! -x "$DAEMON_BIN" ]; then
    write_state "degraded" "daemon_missing" "$crash_count"
    log_line "AirSend daemon binary is missing: $DAEMON_BIN"
    sleep 30
    continue
  fi

  write_state "starting" "supervisor_launch" "$crash_count"
  "$DAEMON_BIN" >> "$LOG_PATH" 2>&1 &
  child_pid=$!
  write_state "running" "child_started" "$crash_count"
  finished_pid="$child_pid"
  wait "$finished_pid"
  exit_code=$?
  child_pid=""

  if [ "$exit_code" -eq 0 ]; then
    crash_count=0
    window_start=0
    backoff=1
    write_state "restarting" "child_requested_restart" "$crash_count"
    log_line "AirSend daemon requested a controlled restart."
    sleep 1
    continue
  fi

  now="$(date +%s)"
  case "$window_start" in
    0) window_start="$now"; crash_count=1 ;;
    *)
      if [ "$now" -ge $((window_start + 120)) ]; then
        window_start="$now"
        crash_count=1
      else
        crash_count=$((crash_count + 1))
      fi
      ;;
  esac

  if [ "$crash_count" -ge 5 ]; then
    write_state "circuit_open" "crash_loop_exit_$exit_code" "$crash_count"
    log_line "AirSend daemon crash loop; circuit open for 300s (exit=$exit_code count=$crash_count)."
    sleep 300
    crash_count=0
    window_start=0
    backoff=1
    continue
  fi

  write_state "backing_off" "child_exit_$exit_code" "$crash_count"
  log_line "AirSend daemon exited (exit=$exit_code); restarting in ${backoff}s (count=$crash_count)."
  sleep "$backoff"
  if [ "$backoff" -lt 30 ]; then
    backoff=$((backoff * 2))
    [ "$backoff" -gt 30 ] && backoff=30
  fi
done
