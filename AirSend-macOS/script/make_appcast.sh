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
    ARGS+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
fi

"$GENERATE_APPCAST" "${ARGS[@]}" "$ARCHIVE_DIR"
echo "Updated appcast: $APPCAST_PATH"
