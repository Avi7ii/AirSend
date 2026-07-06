#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MAC_DIR/.." && pwd)"

ARCHIVE_DIR="${1:-}"
if [ -z "$ARCHIVE_DIR" ]; then
    echo "Usage: $0 <directory-containing-release-zips>" >&2
    echo "Set AIRSEND_DOWNLOAD_URL_PREFIX to the GitHub release asset URL prefix." >&2
    exit 2
fi

if [ ! -d "$ARCHIVE_DIR" ]; then
    echo "Release archive directory not found: $ARCHIVE_DIR" >&2
    exit 2
fi

TMP_ARCHIVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/airsend-appcast.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ARCHIVE_DIR"
}
trap cleanup EXIT

shopt -s nullglob
MAC_ARCHIVES=("$ARCHIVE_DIR"/AirSend*macOS*.zip)
shopt -u nullglob

if [ "${#MAC_ARCHIVES[@]}" -eq 0 ]; then
    echo "No macOS release zip found in $ARCHIVE_DIR (expected AirSend*macOS*.zip)" >&2
    exit 2
fi

for archive in "${MAC_ARCHIVES[@]}"; do
    cp -p "$archive" "$TMP_ARCHIVE_DIR/"
    base="$(basename "$archive" .zip)"
    for ext in html md txt; do
        notes="$ARCHIVE_DIR/$base.$ext"
        if [ -f "$notes" ]; then
            cp -p "$notes" "$TMP_ARCHIVE_DIR/"
        fi
    done
done

GENERATE_APPCAST="$MAC_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [ ! -x "$GENERATE_APPCAST" ]; then
    echo "Sparkle generate_appcast not found; resolving SwiftPM dependencies..." >&2
    (cd "$MAC_DIR" && swift build >/dev/null)
fi

if [ ! -x "$GENERATE_APPCAST" ]; then
    echo "Sparkle generate_appcast still missing: $GENERATE_APPCAST" >&2
    exit 1
fi

APPCAST_PATH="${AIRSEND_APPCAST_PATH:-$REPO_ROOT/appcast.xml}"
DOWNLOAD_URL_PREFIX="${AIRSEND_DOWNLOAD_URL_PREFIX:-}"
SPARKLE_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-AirSend}"

ARGS=(
    --account "$SPARKLE_ACCOUNT"
    --embed-release-notes
    --link "https://github.com/Avi7ii/AirSend"
    -o "$APPCAST_PATH"
)

if [ -n "$DOWNLOAD_URL_PREFIX" ]; then
    case "$DOWNLOAD_URL_PREFIX" in
        */) ;;
        *) DOWNLOAD_URL_PREFIX="$DOWNLOAD_URL_PREFIX/" ;;
    esac
    ARGS+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
fi

"$GENERATE_APPCAST" "${ARGS[@]}" "$TMP_ARCHIVE_DIR"
echo "Updated appcast: $APPCAST_PATH"
