#!/bin/sh
# Sentinel Shield — run available Node quality tools.
# POSIX sh. Skips missing tools with a warning. Uses npx for locally-installed bins.
set -eu

TARGET="${1:-.}"
cd "$TARGET"

OVERALL=0

have() { command -v "$1" >/dev/null 2>&1; }

# run_npx <label> <package> <bin> <args...>
# Skips unless <package> resolves locally. Runs <bin> (the package's binary, which
# is not always the package name — e.g. the "typescript" package ships "tsc").
run_npx() {
	label="$1"
	pkg="$2"
	bin="$3"
	shift 3
	if [ -d "node_modules/$pkg" ] || [ -f "node_modules/.bin/$bin" ]; then
		echo ">> $label"
		if npx --no-install "$bin" "$@"; then
			echo "   $label: ok"
		else
			echo "   $label: FAILED" >&2
			OVERALL=1
		fi
	else
		echo ">> $label: $pkg not installed locally, skipping"
	fi
}

if [ ! -f package.json ]; then
	echo "warning: no package.json in '$TARGET'; this may not be a Node project." >&2
fi

if ! have npx; then
	echo "error: npx not found; install Node.js 22+." >&2
	exit 1
fi

run_npx "TypeScript typecheck" typescript tsc --noEmit
run_npx "ESLint"               eslint eslint .
run_npx "Knip (unused)"        knip knip

echo "----"
if [ "$OVERALL" -eq 0 ]; then
	echo "Node quality: all present tools passed."
else
	echo "Node quality: one or more tools reported issues." >&2
fi
exit "$OVERALL"
