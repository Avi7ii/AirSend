#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR=""
SOURCE_DIR="${AIRSEND_RELEASE_ASSET_SOURCE:-$ROOT_DIR}"
MAGISK_ASSET="${AIRSEND_MAGISK_ASSET:-}"
CHECK_ONLY=0

usage() {
  cat >&2 <<'USAGE'
Usage: tools/prepare_release_assets.sh <release-assets-dir> [options]

Ensures every AirSend GitHub Release asset set includes both:
  - a macOS zip: AirSend*macOS*.zip
  - an Android/Magisk module zip: AirSend_Magisk*.zip

If the release directory has no Android/Magisk zip, the script copies the
latest AirSend_Magisk*.zip from the repository root or --source-dir. This
prevents Mac-only releases from replacing the release asset set with only a
macOS build.

Options:
  --source-dir <dir>      Directory to search for the previous/latest Magisk zip.
  --magisk-asset <file>   Explicit Magisk zip to copy when missing.
  --check-only            Only verify; do not copy a missing Magisk asset.
  -h, --help              Show this help.
USAGE
}

fail() {
  printf 'prepare_release_assets: ERROR: %s\n' "$1" >&2
  exit 1
}

mtime() {
  case "$(uname -s)" in
    Darwin|FreeBSD)
      stat -f '%m' "$1"
      ;;
    *)
      stat -c '%Y' "$1"
      ;;
  esac
}

collect_matches() {
  local dir="$1"
  local pattern="$2"
  find "$dir" -maxdepth 1 -type f -name "$pattern" -print0
}

latest_match() {
  local dir="$1"
  local pattern="$2"
  local latest=""
  local latest_mtime=-1
  local candidate
  local candidate_mtime

  while IFS= read -r -d '' candidate; do
    candidate_mtime="$(mtime "$candidate")"
    if [ "$candidate_mtime" -gt "$latest_mtime" ]; then
      latest="$candidate"
      latest_mtime="$candidate_mtime"
    fi
  done < <(collect_matches "$dir" "$pattern")

  printf '%s' "$latest"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-dir)
      [ "$#" -ge 2 ] || fail "--source-dir requires a directory"
      SOURCE_DIR="$2"
      shift 2
      ;;
    --magisk-asset)
      [ "$#" -ge 2 ] || fail "--magisk-asset requires a file"
      MAGISK_ASSET="$2"
      shift 2
      ;;
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      if [ -n "$RELEASE_DIR" ]; then
        fail "unexpected extra argument: $1"
      fi
      RELEASE_DIR="$1"
      shift
      ;;
  esac
done

[ -n "$RELEASE_DIR" ] || { usage; exit 2; }
[ -d "$RELEASE_DIR" ] || fail "release asset directory not found: $RELEASE_DIR"

MAC_ASSET="$(latest_match "$RELEASE_DIR" 'AirSend*macOS*.zip')"
if [ -z "$MAC_ASSET" ]; then
  fail "Missing macOS release asset in $RELEASE_DIR (expected AirSend*macOS*.zip)"
fi

MAGISK_IN_RELEASE="$(latest_match "$RELEASE_DIR" 'AirSend_Magisk*.zip')"
if [ -z "$MAGISK_IN_RELEASE" ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    fail "Missing Android/Magisk release asset in $RELEASE_DIR (expected AirSend_Magisk*.zip)"
  fi

  if [ -z "$MAGISK_ASSET" ]; then
    [ -d "$SOURCE_DIR" ] || fail "Magisk asset source directory not found: $SOURCE_DIR"
    MAGISK_ASSET="$(latest_match "$SOURCE_DIR" 'AirSend_Magisk*.zip')"
  fi

  [ -n "$MAGISK_ASSET" ] || fail "Missing Android/Magisk release asset; set AIRSEND_MAGISK_ASSET or place AirSend_Magisk*.zip in $SOURCE_DIR"
  [ -f "$MAGISK_ASSET" ] || fail "Magisk asset not found: $MAGISK_ASSET"

  MAGISK_IN_RELEASE="$RELEASE_DIR/$(basename "$MAGISK_ASSET")"
  if [ "$MAGISK_ASSET" != "$MAGISK_IN_RELEASE" ]; then
    cp -p "$MAGISK_ASSET" "$MAGISK_IN_RELEASE"
  fi
fi

[ -s "$MAGISK_IN_RELEASE" ] || fail "Android/Magisk release asset is empty: $MAGISK_IN_RELEASE"

printf 'Release assets ready:\n'
printf '  macOS:          %s\n' "$MAC_ASSET"
printf '  Android/Magisk: %s\n' "$MAGISK_IN_RELEASE"
