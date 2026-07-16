#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIRSEND_SERVICE_TEST_MODE=1
. "$SCRIPT_DIR/service.sh"

[ "$(decide_apk_sync missing 500)" = "install" ]
[ "$(decide_apk_sync 499 500)" = "install" ]
[ "$(decide_apk_sync 500 500)" = "keep" ]
[ "$(decide_apk_sync 501 500)" = "keep" ]
[ "$(decide_apk_sync invalid 500)" = "error" ]
[ "$(decide_apk_sync 500 invalid)" = "error" ]

echo "service.sh version policy tests passed"
