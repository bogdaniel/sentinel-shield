#!/bin/sh
# Sentinel Shield runner — custom PHP architecture tests (v2.1.0).
# Thin entry point over runners/architecture-tests.sh (one implementation of the custom-command
# contract). Command from $SENTINEL_SHIELD_PHP_ARCH_TEST_CMD, else $SENTINEL_SHIELD_ARCH_TEST_CMD,
# else architecture.tools.architecture_tests.command. Typical value:
#   vendor/bin/pest --group=arch    |    vendor/bin/phpunit --testsuite=architecture
# No command -> unavailable (never a faked pass).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CMD="${SENTINEL_SHIELD_PHP_ARCH_TEST_CMD:-${SENTINEL_SHIELD_ARCH_TEST_CMD:-}}"
set -- --output "reports/raw/php-architecture-tests.json" --producer php-architecture-tests "$@"
[ -n "$CMD" ] && set -- "$@" --command "$CMD"
exec sh "$SCRIPT_DIR/architecture-tests.sh" "$@"
