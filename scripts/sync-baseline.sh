#!/bin/sh
# Sentinel Shield — sync an already-installed baseline in a consuming project.
# POSIX sh. SAFE STUB: this version is non-destructive. It reports drift between
# the baseline source and the project's .sentinel-shield/ copy but does NOT modify
# files. Apply changes deliberately with install-baseline.sh --apply --force after
# review.
set -eu

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
	echo "Usage: sync-baseline.sh <project-dir>" >&2
	exit 1
fi
if [ ! -d "$TARGET/.sentinel-shield" ]; then
	echo "error: '$TARGET/.sentinel-shield' not found. Run install-baseline.sh first." >&2
	exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEST="$TARGET/.sentinel-shield"

echo "Sentinel Shield sync (report-only)"
echo "Source: $ROOT"
echo "Dest:   $DEST"
echo "----"

# Report files that differ or are missing. Non-destructive.
ITEMS="SECURITY-STANDARD.md RELEASE-GATES.md docs profiles policies semgrep templates scripts"

DRIFT=0
for item in $ITEMS; do
	src="$ROOT/$item"
	dst="$DEST/$item"
	if [ ! -e "$dst" ]; then
		echo "MISSING in project: $item"
		DRIFT=1
	elif ! diff -r "$src" "$dst" >/dev/null 2>&1; then
		echo "DRIFT (differs from baseline): $item"
		DRIFT=1
	else
		echo "up to date: $item"
	fi
done

echo "----"
if [ "$DRIFT" -eq 0 ]; then
	echo "No drift detected."
else
	echo "Drift detected. To update after review, run:"
	echo "  sh scripts/install-baseline.sh --target '$TARGET' --apply --force"
fi

# TODO (future): selective merge, backup-before-overwrite, changelog of updated
# files, and a --apply mode with per-file confirmation. Kept non-destructive for v1.
