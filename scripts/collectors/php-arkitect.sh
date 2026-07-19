#!/bin/sh
# Sentinel Shield collector — php-arkitect (normalized architecture contract).
# Thin entry point: the contract is implemented once in collectors/architecture.sh
# (same pattern as php-/js-coverage sharing collectors/coverage.sh).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$SCRIPT_DIR/architecture.sh" --tool-name "php-arkitect" --input "reports/raw/php-arkitect.json" "$@"
