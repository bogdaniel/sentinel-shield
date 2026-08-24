#!/bin/sh
# Sentinel Shield — e2e scanner evidence generator/checker (fixture tooling, NOT a production
# evidence publisher).
#
# ce_bind requires provenance for every report, in production and in fixtures alike. Exempting
# fixtures would put a bypass inside the exact binding that stops forged evidence -- the property
# #135, #136, #137 and #184 all rest on. So the fixtures carry REAL provenance, generated here.
#
# The manifest declares only intentional semantics: whose project, which producer, what kind of
# scan, what the collector should conclude. Every mechanically derived fact -- the digest above all
# -- is computed from the committed report, never typed by hand.
#
#   --generate   refresh sidecars (explicit, atomic)
#   --check      write nothing; fail on missing, stale or non-reproducible sidecars
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SS_LIB_DIR="$ROOT/scripts/lib"
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SS_LIB_DIR/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$SS_LIB_DIR/normalized-evidence.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"
# shellcheck source=scripts/lib/filesystem-safety.sh
. "$SS_LIB_DIR/filesystem-safety.sh"

MANIFEST="$ROOT/config/e2e-evidence-manifest.json"
MODE="--check"
[ $# -le 1 ] || { echo "usage: generate-e2e-evidence.sh [--generate|--check]" >&2; exit 2; }
case "${1:---check}" in --generate) MODE="--generate" ;; --check) MODE="--check" ;; *) echo "usage: generate-e2e-evidence.sh [--generate|--check]" >&2; exit 2 ;; esac
command_exists jq || { log_error "jq is required"; exit 2; }
[ -f "$MANIFEST" ] || { log_error "missing $MANIFEST"; exit 2; }

ROWS=$(jq -r '.rows | length' "$MANIFEST")
[ "$ROWS" -gt 0 ] || { log_error "manifest declares zero rows"; exit 1; }
_dupes=$(jq -r '[.rows[].report] | group_by(.) | map(select(length>1)|.[0]) | join(" ")' "$MANIFEST")
[ -z "$_dupes" ] || { log_error "duplicate manifest rows: $_dupes"; exit 1; }

# ATOMIC: render every sidecar into a private workspace, validate the COMPLETE set, and publish
# only when all rows succeed. A partially regenerated fixture set is worse than none.
WORK=$(fs_mktemp_dir "$ROOT/reports" 2>/dev/null) || WORK=$(mktemp -d)
trap 'rm -rf "$WORK" 2>/dev/null || :' EXIT INT TERM

FAILED=0; CHECKED=0
jq -r '.rows[] | [.tool,.report,.subject,.target_mode,.completion] | @tsv' "$MANIFEST" > "$WORK/rows"
while IFS="$(printf '\t')" read -r TOOL REPORT SUBJECT MODE_T COMPLETION; do
	[ -n "$TOOL" ] || continue
	CHECKED=$((CHECKED + 1))
	_abs="$ROOT/$REPORT"
	if [ ! -f "$_abs" ]; then log_error "$TOOL: missing report $REPORT"; FAILED=$((FAILED+1)); continue; fi
	# THE REAL PRODUCTION VALIDATOR, not a fixture-specific one: a fixture that production would
	# reject must not be blessed by its own generator.
	case "$TOOL" in
	syft)        sc_syft_validate "$_abs"  || { log_error "$TOOL $REPORT: ${SC_REASON:-invalid}"; FAILED=$((FAILED+1)); continue; } ;;
	trivy-fs)    sc_trivy_validate "$_abs" || { log_error "$TOOL $REPORT: ${SC_REASON:-invalid}"; FAILED=$((FAILED+1)); continue; } ;;
	grype)       sc_grype_validate "$_abs" || { log_error "$TOOL $REPORT: ${SC_REASON:-invalid}"; FAILED=$((FAILED+1)); continue; } ;;
	osv-scanner) sc_osv_validate "$_abs"   || { log_error "$TOOL $REPORT: ${SC_REASON:-invalid}"; FAILED=$((FAILED+1)); continue; } ;;
	*) log_error "unknown producer '$TOOL' in manifest"; FAILED=$((FAILED+1)); continue ;;
	esac
	_digest=$(ne_sha256 "$_abs") || { log_error "$TOOL: cannot digest $REPORT"; FAILED=$((FAILED+1)); continue; }
	_side="$WORK/$(printf '%s' "$REPORT" | tr '/' '_').provenance.json"
	jq -n --arg t "$TOOL" --arg d "$_digest" --arg s "$COMPLETION" --arg sub "$SUBJECT" --arg m "$MODE_T" \
		'{contract:"sentinel-shield/scanner-transaction@1", tool:$t,
		  completion:{state:$s, detail:"generated e2e fixture evidence", exit:"0"},
		  report:{sha256:$d},
		  scanner:{version:"fixture", executor:"fixture", platform:"fixture"},
		  target:{identity:$sub, mode:$m},
		  source:{commit:""}, diagnostics:""}' > "$_side" || { FAILED=$((FAILED+1)); continue; }
	_committed="${_abs%.json}.provenance.json"
	if [ "$MODE" = "--check" ]; then
		if [ ! -f "$_committed" ]; then log_error "$TOOL $REPORT: sidecar missing (run --generate)"; FAILED=$((FAILED+1)); continue; fi
		cmp -s "$_side" "$_committed" || { log_error "$TOOL $REPORT: sidecar is stale or not reproducible"; FAILED=$((FAILED+1)); }
	fi
done < "$WORK/rows"

[ "$CHECKED" -eq "$ROWS" ] || { log_error "only $CHECKED of $ROWS manifest rows were processed"; exit 1; }
if [ "$FAILED" -ne 0 ]; then log_error "e2e evidence: $FAILED of $ROWS row(s) failed"; exit 1; fi

if [ "$MODE" = "--generate" ]; then
	# Publish only now, with every row already validated.
	jq -r '.rows[].report' "$MANIFEST" | while IFS= read -r REPORT; do
		cp -f "$WORK/$(printf '%s' "$REPORT" | tr '/' '_').provenance.json" "$ROOT/${REPORT%.json}.provenance.json"
	done
	log_info "e2e evidence: generated $ROWS sidecar(s)"
else
	log_info "e2e evidence: $ROWS sidecar(s) current and reproducible"
fi
exit 0
