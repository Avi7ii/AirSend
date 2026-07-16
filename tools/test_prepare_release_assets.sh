#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/tools/prepare_release_assets.sh"

fail() {
  printf 'test_prepare_release_assets: %s\n' "$1" >&2
  exit 1
}

write_fake_zip() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf 'fake zip payload for %s\n' "$(basename "$path")" > "$path"
}

TMP_DIR="$(mktemp -d /tmp/airsend-release-assets-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

RELEASE_DIR="$TMP_DIR/release"
SOURCE_DIR="$TMP_DIR/source"
mkdir -p "$RELEASE_DIR" "$SOURCE_DIR"

write_fake_zip "$RELEASE_DIR/AirSend-v9.9.9-macOS.zip"
write_fake_zip "$SOURCE_DIR/AirSend_Magisk_v5.0.0.zip"

AIRSEND_RELEASE_ASSET_SOURCE="$SOURCE_DIR" "$SCRIPT" "$RELEASE_DIR" >/tmp/airsend-release-assets-ok.log
test -s "$RELEASE_DIR/AirSend_Magisk_v5.0.0.zip" || fail "expected latest Magisk asset to be copied"
grep -q "Release assets ready" /tmp/airsend-release-assets-ok.log || fail "expected success summary"

NO_MAC_DIR="$TMP_DIR/no-mac"
mkdir -p "$NO_MAC_DIR"
if AIRSEND_RELEASE_ASSET_SOURCE="$SOURCE_DIR" "$SCRIPT" "$NO_MAC_DIR" 2>"$TMP_DIR/no-mac.err"; then
  fail "expected missing macOS asset to fail"
fi
grep -q "Missing macOS release asset" "$TMP_DIR/no-mac.err" || fail "expected missing macOS asset error"

NO_MAGISK_DIR="$TMP_DIR/no-magisk"
EMPTY_SOURCE="$TMP_DIR/empty-source"
mkdir -p "$NO_MAGISK_DIR" "$EMPTY_SOURCE"
write_fake_zip "$NO_MAGISK_DIR/AirSend-v9.9.9-macOS.zip"
if AIRSEND_RELEASE_ASSET_SOURCE="$EMPTY_SOURCE" "$SCRIPT" "$NO_MAGISK_DIR" 2>"$TMP_DIR/no-magisk.err"; then
  fail "expected missing Magisk asset source to fail"
fi
grep -q "Missing Android/Magisk release asset" "$TMP_DIR/no-magisk.err" || fail "expected missing Magisk asset error"

printf 'test_prepare_release_assets passed\n'
