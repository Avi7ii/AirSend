#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/.." && pwd)"
BUILD_TYPE="${1:-debug}"
APK="$ROOT_DIR/app/build/outputs/apk/$BUILD_TYPE/app-$BUILD_TYPE.apk"
DAEMON="$ROOT_DIR/app/src/main/assets/airsend_daemon"
MODULE_SOURCE="$ROOT_DIR/root-module"
OUTPUT_DIR="$REPO_DIR/outputs"
STAGING="$ROOT_DIR/build/airsend-root-module"

version_name="$(sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' "$ROOT_DIR/app/build.gradle.kts" | head -n 1)"
version_code="$(sed -n 's/.*versionCode = \([0-9][0-9]*\).*/\1/p' "$ROOT_DIR/app/build.gradle.kts" | head -n 1)"
daemon_version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$ROOT_DIR/airsend_daemon/Cargo.toml" | head -n 1)"

[ -f "$APK" ] || { echo "Missing APK: $APK" >&2; exit 1; }
[ -f "$DAEMON" ] || { echo "Missing daemon asset: $DAEMON" >&2; exit 1; }
[ "$version_name" = "$daemon_version" ] || {
  echo "Version mismatch: app=$version_name daemon=$daemon_version" >&2
  exit 1
}

rm -rf "$STAGING"
mkdir -p "$STAGING/system/bin" "$STAGING/system/app/AirSend" "$OUTPUT_DIR"
cp "$MODULE_SOURCE/customize.sh" "$MODULE_SOURCE/service.sh" \
  "$MODULE_SOURCE/supervisor.sh" \
  "$MODULE_SOURCE/sepolicy.rule" "$STAGING/"
sed \
  -e "s/^version=.*/version=v$version_name/" \
  -e "s/^versionCode=.*/versionCode=$version_code/" \
  "$MODULE_SOURCE/module.prop" > "$STAGING/module.prop"
cp "$DAEMON" "$STAGING/system/bin/airsend_daemon"
cp "$MODULE_SOURCE/supervisor.sh" "$STAGING/system/bin/airsend_supervisor"
cp "$APK" "$STAGING/system/app/AirSend/AirSend.apk"
chmod 0755 "$STAGING/customize.sh" "$STAGING/service.sh" "$STAGING/supervisor.sh" \
  "$STAGING/system/bin/airsend_daemon" "$STAGING/system/bin/airsend_supervisor"
chmod 0644 "$STAGING/module.prop" "$STAGING/sepolicy.rule" \
  "$STAGING/system/app/AirSend/AirSend.apk"

(
  cd "$STAGING"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | \
    xargs -0 shasum -a 256 > SHA256SUMS
  zip -qr "$OUTPUT_DIR/AirSend-root-v$version_name.zip" .
)

echo "$OUTPUT_DIR/AirSend-root-v$version_name.zip"
