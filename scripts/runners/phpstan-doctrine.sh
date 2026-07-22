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
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: phpstan-doctrine.sh [--output <path>]\n'; exit 0 ;;
		*) echo "[sentinel-shield] phpstan-doctrine: unknown argument: $1" >&2; exit 2 ;;
	esac
done
exec sh "$SCRIPT_DIR/phpstan.sh" --output "$OUTPUT"
