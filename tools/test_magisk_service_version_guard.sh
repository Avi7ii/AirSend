#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AIRSEND_SERVICE_TEST_MODE=1
export AIRSEND_TEST_MODDIR="$ROOT_DIR/magisk_module"

# shellcheck disable=SC1091
source "$ROOT_DIR/magisk_module/service.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  if [[ "$expected" != "$actual" ]]; then
    printf 'expected <%s>, got <%s>\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_eq "install" "$(decide_apk_sync missing 500)"
assert_eq "install" "$(decide_apk_sync 499 500)"
assert_eq "keep" "$(decide_apk_sync 500 500)"
assert_eq "keep" "$(decide_apk_sync 501 500)"
assert_eq "error" "$(decide_apk_sync 500 invalid)"

printf 'magisk service version guard tests passed\n'
