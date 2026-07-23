#!/bin/sh
# Sentinel Shield runner — PHPStan with the Symfony extension -> reports/raw/phpstan-symfony.json.
#
# The phpstan/phpstan-symfony extension is enabled in the PROJECT's phpstan.neon
# (includes: vendor/phpstan/phpstan-symfony/extension.neon). This runner therefore
# just delegates to the generic phpstan.sh, writing to the phpstan-symfony report so
# the symfony profile can require/track it independently. Same honest-absent contract.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT="reports/raw/phpstan-symfony.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: phpstan-symfony.sh [--output <path>]\n'; exit 0 ;;
		*) echo "[sentinel-shield] phpstan-symfony: unknown argument: $1" >&2; exit 2 ;;
	esac
done
exec sh "$SCRIPT_DIR/phpstan.sh" --output "$OUTPUT"
