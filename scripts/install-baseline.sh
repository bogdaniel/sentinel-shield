#!/bin/sh
# Sentinel Shield — profile-driven baseline installer (v0.1.11).
# POSIX sh. SAFE BY DEFAULT: dry-run unless --apply; never overwrites a managed file
# without --force; NEVER creates/overwrites project-local risk decisions
# (.sentinel-shield/accepted-risks.json, phpstan-baseline.neon, ...).
#
# Reads a profile manifest (profiles/<name>/profile.manifest.json or
# profiles/combinations/<name>.manifest.json) and installs its files/workflows/docs into
# a consuming project. The consuming project does NOT copy workflow logic by hand.
#
# Usage:
#   sh scripts/install-baseline.sh --target <dir>                         # dry-run, default profile
#   sh scripts/install-baseline.sh --target <dir> --apply
#   sh scripts/install-baseline.sh --target <dir> --profile laravel --mode baseline --apply
#   sh scripts/install-baseline.sh --target <dir> --apply --force         # overwrite managed files
#
# Defaults: --profile laravel-react-docker  --mode report-only
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

TARGET=""; APPLY=0; FORCE=0; PROFILE="laravel-react-docker"; MODE="report-only"

usage() {
	cat <<'EOF'
Usage: install-baseline.sh --target <dir> [--profile <name>] [--mode <mode>] [--apply] [--force]
  --target <dir>   Consuming project directory (required).
  --profile <name> Profile manifest (default: laravel-react-docker). Also: laravel|react|node|docker.
  --mode <mode>    report-only|baseline|strict|regulated (default: report-only) — written into profile.yaml.
  --apply          Actually write files (default: dry-run).
  --force          Overwrite MANAGED files (overwrite-if-force mode); never touches project-local files.
  -h, --help       Show help.
Manifest file modes: create-if-missing | overwrite-if-force | sync-managed-block | manual.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
		--apply) APPLY=1; shift ;;
		--force) FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
	esac
done

[ -n "$TARGET" ] || { echo "error: --target is required" >&2; usage; exit 2; }
[ -d "$TARGET" ] || { echo "error: target '$TARGET' is not a directory" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
case "$MODE" in report-only|baseline|strict|regulated) ;; *) echo "error: invalid --mode '$MODE'" >&2; exit 2 ;; esac

# Resolve the manifest path from the profile name.
MANIFEST=""
for cand in "profiles/$PROFILE/profile.manifest.json" "profiles/combinations/$PROFILE.manifest.json"; do
	[ -f "$ROOT/$cand" ] && { MANIFEST="$ROOT/$cand"; break; }
done
[ -n "$MANIFEST" ] || { echo "error: no manifest for profile '$PROFILE' (looked in profiles/$PROFILE/ and profiles/combinations/)" >&2; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { echo "error: manifest is not valid JSON: $MANIFEST" >&2; exit 2; }

[ "$APPLY" -eq 0 ] && echo "DRY-RUN (no files written). Re-run with --apply." || echo "APPLY mode."
echo "Profile:  $PROFILE   ($MANIFEST)"
echo "Mode:     $MODE"
echo "Source:   $ROOT"
echo "Target:   $TARGET"
echo "Force:    $([ "$FORCE" -eq 1 ] && echo yes || echo no)"
echo "------------------------------------------------------------"

# Protected (never created/overwritten) — manifest never_touch + hard defaults.
PROTECT=" .sentinel-shield/accepted-risks.json phpstan-baseline.neon "
for p in $(jq -r '(.never_touch // [])[]' "$MANIFEST" 2>/dev/null); do PROTECT="$PROTECT$p "; done

is_protected() { case "$PROTECT" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Results accumulate in a temp file (the entry loop runs in a subshell via the pipe).
SUM=$(mktemp); : > "$SUM"; trap 'rm -f "$SUM"' EXIT INT TERM

do_entry() { # do_entry <source> <target> <mode>
	_src="$ROOT/$1"; _tgt="$TARGET/$2"; _mode="$3"
	if is_protected "$2" || [ "$(basename "$2")" = "accepted-risks.json" ]; then
		echo "PROTECTED (project-local, never written): $2"; echo protect >> "$SUM"; return
	fi
	if [ ! -e "$_src" ]; then echo "skip (missing in Sentinel Shield): $1"; echo skip >> "$SUM"; return; fi
	case "$_mode" in
		manual) echo "MANUAL (copy yourself if wanted): $1 -> $2"; echo manual >> "$SUM"; return ;;
		create-if-missing)
			if [ -e "$_tgt" ]; then echo "skip (exists, project-owned): $2"; echo skip >> "$SUM"; return; fi ;;
		overwrite-if-force|sync-managed-block)
			if [ -e "$_tgt" ] && [ "$FORCE" -eq 0 ]; then
				echo "skip (managed, exists; use --force to update): $2"; echo managed >> "$SUM"; return
			fi ;;
		*) echo "skip (unknown mode '$_mode'): $2"; echo skip >> "$SUM"; return ;;
	esac
	if [ "$APPLY" -eq 0 ]; then echo "would write [$_mode]: $1 -> $2"; echo created >> "$SUM"; return; fi
	mkdir -p "$(dirname "$_tgt")"
	cp "$_src" "$_tgt"
	if [ "$(basename "$2")" = "profile.yaml" ]; then
		awk -v m="$MODE" 'BEGIN{d=0} /^  mode: / && !d {sub(/^  mode: .*/, "  mode: " m); d=1} {print}' "$_tgt" > "$_tgt.tmp" && mv "$_tgt.tmp" "$_tgt"
	fi
	echo "wrote [$_mode]: $2"; echo created >> "$SUM"
}

# Process files + workflows + docs. Use a here-doc feed so do_entry runs in THIS shell
# (the $SUM counters persist).
ENTRIES=$(jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | "\(.source)\t\(.target)\t\(.mode)"' "$MANIFEST")
OLDIFS=$IFS
printf '%s\n' "$ENTRIES" | while IFS="$(printf '\t')" read -r s t m; do
	[ -n "$s" ] || continue
	do_entry "$s" "$t" "$m"
done
IFS=$OLDIFS

echo "------------------------------------------------------------"
echo "Required upstream scripts (live in Sentinel Shield; the workflow calls them via SENTINEL_SHIELD_PATH):"
jq -r '(.required_scripts // [])[] | "  - " + .' "$MANIFEST"
echo "Recommended raw reports the pipeline produces: $(jq -r '(.recommended_raw_reports // []) | join(", ")' "$MANIFEST")"
echo "------------------------------------------------------------"
echo "SUMMARY: created/would-create=$(grep -c '^created' "$SUM" 2>/dev/null || echo 0)  managed-skipped=$(grep -c '^managed' "$SUM" 2>/dev/null || echo 0)  skipped=$(grep -c '^skip' "$SUM" 2>/dev/null || echo 0)  manual=$(grep -c '^manual' "$SUM" 2>/dev/null || echo 0)  protected=$(grep -c '^protect' "$SUM" 2>/dev/null || echo 0)"
echo "Project-local files NEVER touched: accepted-risks.json, phpstan-baseline.neon (+ manifest never_touch)."
if [ "$APPLY" -eq 0 ]; then
	echo "Dry-run complete. Re-run with --apply to write; add --force to update managed files (workflow)."
else
	echo "Install complete. Next:"
	echo "  1. Review .sentinel-shield/profile.yaml (mode=$MODE) + project metadata."
	echo "  2. Set SENTINEL_SHIELD_REPOSITORY + a pinned SENTINEL_SHIELD_REF in .github/workflows/sentinel-shield.yml."
	echo "  3. Copy .sentinel-shield/accepted-risks.example.json -> accepted-risks.json ONLY when accepting a risk (owner-approved)."
	echo "  4. Run the pipeline (push/PR or workflow_dispatch)."
fi
