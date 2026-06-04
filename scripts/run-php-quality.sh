#!/bin/sh
# Sentinel Shield — run available PHP quality tools.
# POSIX sh. Skips tools that are not installed (prints a warning). Never crashes
# because a tool is missing; reports a non-zero exit only if a present tool fails.
set -eu

TARGET="${1:-.}"
cd "$TARGET"

OVERALL=0

# run_if <binary-path> <label> <args...>
run_if() {
	bin="$1"
	label="$2"
	shift 2
	if [ -x "$bin" ]; then
		echo ">> $label"
		if "$bin" "$@"; then
			echo "   $label: ok"
		else
			echo "   $label: FAILED" >&2
			OVERALL=1
		fi
	else
		echo ">> $label: not installed, skipping (expected at $bin)"
	fi
}

if [ ! -f composer.json ]; then
	echo "warning: no composer.json in '$TARGET'; this may not be a PHP project." >&2
fi

run_if vendor/bin/phpstan       "PHPStan"            analyse --no-progress --memory-limit=1G
run_if vendor/bin/psalm         "Psalm"              --no-cache --no-progress
run_if vendor/bin/pint          "Pint (style)"       --test
run_if vendor/bin/php-cs-fixer  "PHP-CS-Fixer"       fix --dry-run --diff
run_if vendor/bin/deptrac       "Deptrac (arch)"     analyse --config-file=deptrac.yaml --no-progress
run_if vendor/bin/rector        "Rector (dry-run)"   process --dry-run

echo "----"
if [ "$OVERALL" -eq 0 ]; then
	echo "PHP quality: all present tools passed."
else
	echo "PHP quality: one or more tools reported issues." >&2
fi
exit "$OVERALL"
