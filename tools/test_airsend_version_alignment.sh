#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'AirSend version alignment: ERROR: %s\n' "$1" >&2
  exit 1
}

plist_string() {
  local key="$1"
  sed -n "/<key>${key}<\/key>/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;q;}" \
    "$ROOT_DIR/AirSend-macOS/Info.plist"
}

gradle_string() {
  local key="$1"
  sed -n "s/.*${key} = \"\([^\"]*\)\".*/\1/p" \
    "$ROOT_DIR/Android/app/build.gradle.kts" | head -n 1
}

gradle_integer() {
  local key="$1"
  sed -n "s/.*${key} = \([0-9][0-9]*\).*/\1/p" \
    "$ROOT_DIR/Android/app/build.gradle.kts" | head -n 1
}

cargo_version() {
  sed -n 's/^version = "\([^"]*\)"/\1/p' \
    "$ROOT_DIR/Android/airsend_daemon/Cargo.toml" | head -n 1
}

module_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

json_string() {
  local file="$1"
  local key="$2"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -n 1
}

json_integer() {
  local file="$1"
  local key="$2"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$file" | head -n 1
}

mac_version="$(plist_string CFBundleShortVersionString)"
mac_build="$(plist_string CFBundleVersion)"
android_version="$(gradle_string versionName)"
android_code="$(gradle_integer versionCode)"
daemon_version="$(cargo_version)"
module_update_url="https://raw.githubusercontent.com/Avi7ii/AirSend/main/update.json"

IFS=. read -r major minor patch <<< "$mac_version"
[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]$ && "$patch" =~ ^[0-9]$ ]] ||
  fail "unsupported semantic version: $mac_version"
expected_code=$((major * 100 + minor * 10 + patch))

[[ "$mac_version" == "$android_version" ]] ||
  fail "macOS $mac_version != Android $android_version"
[[ "$mac_version" == "$daemon_version" ]] ||
  fail "macOS $mac_version != daemon $daemon_version"
[[ "$mac_build" == "$android_code" ]] ||
  fail "macOS build $mac_build != Android versionCode $android_code"
[[ "$mac_build" == "$expected_code" ]] ||
  fail "build/code $mac_build != semantic version code $expected_code"

for module_prop in \
  "$ROOT_DIR/Android/root-module/module.prop" \
  "$ROOT_DIR/magisk_module/module.prop"
do
  module_version="$(module_value "$module_prop" version)"
  module_code="$(module_value "$module_prop" versionCode)"
  [[ "$module_version" == "v$mac_version" ]] ||
    fail "$module_prop has version $module_version"
  [[ "$module_code" == "$mac_build" ]] ||
    fail "$module_prop has versionCode $module_code"
  [[ "$(module_value "$module_prop" updateJson)" == "$module_update_url" ]] ||
    fail "$module_prop does not use the AirSend module update feed"
done

update_json="$ROOT_DIR/update.json"
update_version="$(json_string "$update_json" version)"
update_code="$(json_integer "$update_json" versionCode)"
update_zip_url="$(json_string "$update_json" zipUrl)"
update_changelog="$(json_string "$update_json" changelog)"
expected_zip_url="https://github.com/Avi7ii/AirSend/releases/download/v${mac_version}/AirSend_Magisk_v${mac_version}.zip"
expected_changelog="https://raw.githubusercontent.com/Avi7ii/AirSend/main/release_notes_v${mac_version}.md"

[[ "$update_version" == "v$mac_version" ]] ||
  fail "update.json has version $update_version"
[[ "$update_code" == "$mac_build" ]] ||
  fail "update.json has versionCode $update_code"
[[ "$update_zip_url" == "$expected_zip_url" ]] ||
  fail "update.json has zipUrl $update_zip_url"
[[ "$update_changelog" == "$expected_changelog" ]] ||
  fail "update.json has changelog $update_changelog"

app_daemon="$ROOT_DIR/Android/app/src/main/assets/airsend_daemon"
module_daemon="$ROOT_DIR/magisk_module/system/bin/airsend_daemon"
cmp -s "$app_daemon" "$module_daemon" ||
  fail "Android app and Magisk daemon binaries differ"
strings "$app_daemon" | grep -F "daemonVersion${mac_version}" >/dev/null ||
  fail "daemon binary does not advertise $mac_version"

printf 'AirSend versions aligned: %s (%s)\n' "$mac_version" "$mac_build"
