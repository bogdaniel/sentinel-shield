#!/bin/sh
# Sentinel Shield runner — PHPStan with the Doctrine extension -> reports/raw/phpstan-doctrine.json.
#
# The phpstan/phpstan-doctrine extension is enabled in the PROJECT's phpstan.neon.
# Delegates to the generic phpstan.sh (writing to the phpstan-doctrine report).
# Only meaningful when Doctrine is present (the profile marks it not-applicable
# otherwise); same honest-absent contract.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT="reports/raw/phpstan-doctrine.json"
[ "${1:-}" = "--output" ] && OUTPUT="${2:?--output requires a value}"
exec sh "$SCRIPT_DIR/phpstan.sh" --output "$OUTPUT"
