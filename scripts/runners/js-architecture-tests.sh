#!/bin/sh
# Sentinel Shield runner — custom JS/TS architecture tests (v2.1.0).
# Thin entry point over runners/architecture-tests.sh (one implementation of the custom-command
# contract). Command from $SENTINEL_SHIELD_JS_ARCH_TEST_CMD, else
# architecture.tools.architecture_tests.command in the architecture policy. Typical value:
#   npm run test:architecture
# No command -> unavailable; command fails without JSON -> execution-error (never a faked pass).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
set -- --output "reports/raw/js-architecture-tests.json" --producer js-architecture-tests \
       --env-var SENTINEL_SHIELD_JS_ARCH_TEST_CMD "$@"
exec sh "$SCRIPT_DIR/architecture-tests.sh" "$@"
