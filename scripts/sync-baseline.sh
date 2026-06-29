#!/bin/sh
# Sentinel Shield — profile-driven baseline sync (v0.1.11).
# POSIX sh. Updates a consuming project from a newer Sentinel Shield release WITHOUT
# destroying local decisions. SAFE BY DEFAULT: --dry-run unless --apply; --force only
# touches MANAGED files; NEVER overwrites accepted-risks.json, phpstan-baseline.neon,
# project-owned (create-if-missing) files, or project code.
#
# Usage:
#   sh scripts/sync-baseline.sh --target <dir>                       # dry-run drift report
#   sh scripts/sync-baseline.sh --target <dir> --apply --force       # update managed files
#   sh scripts/sync-baseline.sh --target <dir> --profile laravel --apply --force
#
# Categories reported: created | updated | up-to-date | manual-review-needed |
#                      project-local-preserved
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

TARGET=""; APPLY=0; FORCE=0; PROFILE="laravel-react-docker"; EMIT_PLAN=""; NONINTERACTIVE=0

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: sync-baseline.sh --target <dir> [--profile <name>] [--apply] [--force]
                        [--emit-plan <path>] [--non-interactive]
  --target <dir>     Consuming project directory (required).
  --profile <name>   Profile manifest (default: laravel-react-docker).
  --apply            Write changes (default: dry-run drift report).
  --force            Update MANAGED files (overwrite-if-force / sync-managed-block) only.
  --emit-plan <path> Write the read-only tool resolution plan (JSON) to <path> while syncing.
  --non-interactive  Never prompt (accepted for CI parity; this sync does not prompt).
  -h, --help         Show help.
NEVER overwrites: accepted-risks.json, phpstan-baseline.neon, project-owned (create-if-missing)
files, or project code. Those are reported as project-local-preserved.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--apply) APPLY=1; shift ;;
		--force) FORCE=1; shift ;;
		--dry-run) APPLY=0; shift ;;
		--emit-plan) EMIT_PLAN="${2:?--emit-plan requires a value}"; shift 2 ;;
		--non-interactive) NONINTERACTIVE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
	esac
done

[ -n "$TARGET" ] || { echo "error: --target is required" >&2; usage; exit 2; }
[ -d "$TARGET/.sentinel-shield" ] || { echo "error: '$TARGET/.sentinel-shield' not found — run install-baseline.sh first." >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

MANIFEST=""
for cand in "profiles/$PROFILE/profile.manifest.json" "profiles/combinations/$PROFILE.manifest.json"; do
	[ -f "$ROOT/$cand" ] && { MANIFEST="$ROOT/$cand"; break; }
done
[ -n "$MANIFEST" ] || { echo "error: no manifest for profile '$PROFILE'" >&2; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { echo "error: manifest not valid JSON: $MANIFEST" >&2; exit 2; }

# --emit-plan: write the read-only resolver plan (JSON) via resolve-tool-plan.sh, which now
# resolves the COMPOSED effective profile (named OR combinations/<name>).
if [ -n "$EMIT_PLAN" ]; then
	if sh "$SCRIPT_DIR/resolve-tool-plan.sh" --profile "$PROFILE" --target "$TARGET" --format json > "$EMIT_PLAN" 2>/dev/null; then
		echo "Tool plan written: $EMIT_PLAN"
	else
		echo "warn: could not emit tool plan to '$EMIT_PLAN' (profile '$PROFILE' could not be resolved)." >&2
		rm -f "$EMIT_PLAN" 2>/dev/null || true
	fi
fi

[ "$APPLY" -eq 0 ] && echo "DRY-RUN drift report (no files written)." || echo "APPLY mode (managed files only; --force=$([ "$FORCE" -eq 1 ] && echo yes || echo no))."
echo "Profile: $PROFILE   Source: $ROOT   Target: $TARGET"
echo "------------------------------------------------------------"

PROTECT=" .sentinel-shield/accepted-risks.json phpstan-baseline.neon "
for p in $(jq -r '(.never_touch // [])[]' "$MANIFEST" 2>/dev/null); do PROTECT="$PROTECT$p "; done
is_protected() { case "$PROTECT" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

SUM=$(mktemp); : > "$SUM"; trap 'rm -f "$SUM"' EXIT INT TERM

sync_entry() { # <source> <target> <mode>
	_src="$ROOT/$1"; _tgt="$TARGET/$2"; _mode="$3"
	if is_protected "$2" || [ "$(basename "$2")" = "accepted-risks.json" ]; then
		echo "project-local-preserved (protected): $2"; echo preserved >> "$SUM"; return
	fi
	[ -e "$_src" ] || { echo "skip (missing in Sentinel Shield): $1"; echo skip >> "$SUM"; return; }
	if [ ! -e "$_tgt" ]; then
		if [ "$_mode" = "manual" ]; then echo "manual-review-needed (absent; copy if wanted): $2"; echo manual >> "$SUM"; return; fi
		if [ "$APPLY" -eq 1 ]; then mkdir -p "$(dirname "$_tgt")"; cp "$_src" "$_tgt"; echo "created (was missing): $2"; else echo "would create (missing): $2"; fi
		echo created >> "$SUM"; return
	fi
	if diff "$_src" "$_tgt" >/dev/null 2>&1; then echo "up-to-date: $2"; echo uptodate >> "$SUM"; return; fi
	# Differs:
	case "$_mode" in
		create-if-missing)
			echo "project-local-preserved (project owns it; NOT overwritten): $2"; echo preserved >> "$SUM" ;;
		overwrite-if-force|sync-managed-block)
			if [ "$APPLY" -eq 1 ] && [ "$FORCE" -eq 1 ]; then
				cp "$_src" "$_tgt"; echo "updated (managed): $2"; echo updated >> "$SUM"
			else
				echo "manual-review-needed (managed drift; --apply --force to update): $2"; echo manual >> "$SUM"
			fi ;;
		*) echo "manual-review-needed: $2"; echo manual >> "$SUM" ;;
	esac
}

ENTRIES=$(jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | "\(.source)\t\(.target)\t\(.mode)"' "$MANIFEST")
printf '%s\n' "$ENTRIES" | while IFS="$(printf '\t')" read -r s t m; do [ -n "$s" ] || continue; sync_entry "$s" "$t" "$m"; done

echo "------------------------------------------------------------"
echo "SUMMARY: created=$(grep -c '^created' "$SUM" 2>/dev/null || echo 0)  updated=$(grep -c '^updated' "$SUM" 2>/dev/null || echo 0)  up-to-date=$(grep -c '^uptodate' "$SUM" 2>/dev/null || echo 0)  manual-review-needed=$(grep -c '^manual' "$SUM" 2>/dev/null || echo 0)  project-local-preserved=$(grep -c '^preserved' "$SUM" 2>/dev/null || echo 0)  skipped=$(grep -c '^skip' "$SUM" 2>/dev/null || echo 0)"
if [ "$APPLY" -eq 0 ]; then
	echo "Dry-run. To update managed files after review: sh scripts/sync-baseline.sh --target '$TARGET' --apply --force"
fi
echo "accepted-risks.json / phpstan-baseline.neon / project-owned config were NOT modified."
