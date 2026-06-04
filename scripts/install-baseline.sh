#!/bin/sh
# Sentinel Shield — install/copy baseline files into a consuming project.
# POSIX sh. SAFE BY DEFAULT:
#   - dry-run unless --apply is given
#   - never overwrites an existing file unless --force is also given
#
# Usage:
#   sh scripts/install-baseline.sh --target /path/to/project            # dry-run
#   sh scripts/install-baseline.sh --target /path/to/project --apply    # copy
#   sh scripts/install-baseline.sh --target /path/to/project --apply --force
set -eu

TARGET=""
APPLY=0
FORCE=0

usage() {
	cat <<'EOF'
Usage: install-baseline.sh --target <dir> [--apply] [--force]

  --target <dir>  Destination project directory (required).
  --apply         Actually copy files (default is dry-run).
  --force         Overwrite existing files (only with --apply).
  -h, --help      Show this help.

Copies baseline configs into <dir>/.sentinel-shield/ and reports what it would do.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="${2:-}"; shift 2 ;;
		--apply)  APPLY=1; shift ;;
		--force)  FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
	esac
done

if [ -z "$TARGET" ]; then
	echo "error: --target is required" >&2
	usage
	exit 1
fi
if [ ! -d "$TARGET" ]; then
	echo "error: target '$TARGET' is not a directory" >&2
	exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEST="$TARGET/.sentinel-shield"

if [ "$APPLY" -eq 0 ]; then
	echo "DRY-RUN (no files will be written). Re-run with --apply to copy."
fi
echo "Source: $ROOT"
echo "Dest:   $DEST"
echo "----"

# Baseline files/dirs to install into the project's .sentinel-shield/ directory.
# `scripts` is included so the gate resolver and shared library are vendored and the
# release-gate workflow can find them at .sentinel-shield/scripts/resolve-gates.sh.
ITEMS="SECURITY-STANDARD.md RELEASE-GATES.md docs profiles policies semgrep templates scripts"

# copy_path <relative-source> <absolute-destination>
copy_path() {
	src="$ROOT/$1"
	dst="$2"
	label="$1 -> $dst"
	if [ ! -e "$src" ]; then
		echo "skip (missing in baseline): $1"
		return
	fi
	if [ -e "$dst" ] && [ "$FORCE" -eq 0 ]; then
		echo "exists, NOT overwriting (use --force): $dst"
		return
	fi
	if [ "$APPLY" -eq 0 ]; then
		echo "would copy: $label"
		return
	fi
	mkdir -p "$(dirname "$dst")"
	cp -R "$src" "$dst"
	echo "copied: $label"
}

for item in $ITEMS; do
	copy_path "$item" "$DEST/$item"
done

# Propose the consuming-project profile at the canonical location. This is the file
# the gate resolver reads. It is never overwritten without --force, so an existing
# project profile is safe.
echo "----"
echo "Project profile:"
copy_path "templates/profile.yaml" "$DEST/profile.yaml"

echo "----"
if [ "$APPLY" -eq 0 ]; then
	echo "Dry-run complete. Review the plan above, then re-run with --apply."
	echo "After applying, edit $TARGET/.sentinel-shield/profile.yaml and run:"
	echo "  sh $TARGET/.sentinel-shield/scripts/resolve-gates.sh --output-dir reports"
else
	echo "Install complete."
	echo "Next:"
	echo "  1. Edit $TARGET/.sentinel-shield/profile.yaml (mode + project metadata)."
	echo "  2. Run the resolver to verify gates:"
	echo "     sh $TARGET/.sentinel-shield/scripts/resolve-gates.sh --output-dir reports"
	echo "  3. Copy github/workflows/* into $TARGET/.github/workflows/ as needed."
fi
