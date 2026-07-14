#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIRSEND_SERVICE_TEST_MODE=1
. "$SCRIPT_DIR/service.sh"

[ "$(decide_apk_sync missing 351)" = "install" ]
[ "$(decide_apk_sync 350 351)" = "install" ]
[ "$(decide_apk_sync 351 351)" = "keep" ]
[ "$(decide_apk_sync 352 351)" = "keep" ]
[ "$(decide_apk_sync invalid 351)" = "error" ]
[ "$(decide_apk_sync 351 invalid)" = "error" ]

echo "service.sh version policy tests passed"
