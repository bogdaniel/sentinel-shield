#!/bin/sh
# tests/prod/160-maturity.sh — WS16 production-grade maturity report.
#
# Asserts scripts/maturity-report.sh DISTINGUISHES the ten maturity states and, above all,
# reports `live_validated` HONESTLY — driven ONLY by REAL evidence (a backed
# evidence/releases/*.json consumer_run), never by the static product `maturity` label.
#
#   (a) With NO real evidence (shipped honest-but-empty files, or empty consumer_runs[]) the
#       report marks live-validated = false/no for the repo and EVERY tool.
#   (b) The report enumerates the distinct states:
#       installed / configured / executed-locally / executed-in-CI / gate-enforced / live-validated.
#   (c) Fixture-only / unbacked evidence (no real workflow_run_id, not success, artifacts
#       unverified) is NOT shown as live; only a genuinely backed run flips it on.
#
# Self-contained, no network. Run via: sh tests/prod/160-maturity.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/maturity-report.sh"

FAILED=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is a documented prerequisite but is absent\n' >&2; exit 2; }
[ -f "$SCRIPT" ] || { bad "maturity-report.sh exists"; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssmaturity)
trap 'rm -rf "$WORK"' EXIT INT TERM

# write_evidence <path> <workflow_run_id> <result> <artifacts_verified>
# A single laravel consumer_run; the three args decide whether it is REAL/backing.
write_evidence() {
	cat > "$1" <<EOF
{
  "version": "9.0.0", "stage": "ga", "engine_commit": "deadbeef",
  "consumer_runs": [
    {"stack":"laravel","repository":"o/r","commit":"c0ffee","profile":"laravel",
     "tool_mode":"bootstrap-tools","workflow_run_id":"$2","result":"$3","artifacts_verified":$4}
  ],
  "required_evidence": {
    "laravel": true, "symfony": false, "php_library": false, "node_react": false,
    "combined_profile": false, "bootstrap_apply": false,
    "rollback_npm": false, "rollback_pnpm": false, "rollback_yarn": false
  }
}
EOF
}

# ---------------------------------------------------------------------------
# (a) SMOKE: the default evidence dir resolves and emits valid JSON (exit 0). That dir MAY carry
# real committed evidence, so it is NOT used for negative 'no real evidence' assertions — those run
# against a temporary EMPTY fixture dir below (deterministic regardless of what is committed).
# ---------------------------------------------------------------------------
JSON_DEFAULT=$(sh "$SCRIPT" --format json 2>/dev/null) || { bad "(a) default-run produced JSON"; }
if [ -n "${JSON_DEFAULT:-}" ]; then
	printf '%s' "$JSON_DEFAULT" | jq -e . >/dev/null 2>&1 \
		&& ok "(a) default-run JSON is valid" || bad "(a) default-run JSON is valid"
fi

# Empty consumer_runs[] via --evidence-dir => no real evidence: live_validated false/no for the repo
# and EVERY tool, and the product 'live-validated' label is NOT conflated with live_validated.
mkdir -p "$WORK/empty"
write_evidence "$WORK/empty/e.json" "" "skipped" "false"
JSON_EMPTY=$(sh "$SCRIPT" --format json --evidence-dir "$WORK/empty" 2>/dev/null)
_e=$(printf '%s' "$JSON_EMPTY" | jq -r '.live_validated')
[ "$_e" = "false" ] && ok "(a) empty/unbacked evidence-dir => live_validated=false" \
	|| bad "(a) empty evidence-dir live_validated expected false, got '$_e'"
_yescount=$(printf '%s' "$JSON_EMPTY" | jq '[.tools[]|select(.live_validated=="yes")]|length')
[ "$_yescount" = "0" ] && ok "(a) no tool is live_validated=yes without real evidence" \
	|| bad "(a) $_yescount tool(s) wrongly marked live_validated=yes"
# Deptrac's PRODUCT maturity is "live-validated" yet must NOT be live_validated without evidence.
_dm=$(printf '%s' "$JSON_EMPTY" | jq -r '.tools[]|select(.tool=="Deptrac").maturity')
_dl=$(printf '%s' "$JSON_EMPTY" | jq -r '.tools[]|select(.tool=="Deptrac").live_validated')
if [ "$_dm" = "live-validated" ] && [ "$_dl" = "no" ]; then
	ok "(a) product 'live-validated' label is NOT conflated with live_validated (Deptrac)"
else bad "(a) Deptrac maturity='$_dm' live_validated='$_dl' (expected live-validated / no)"; fi

# ---------------------------------------------------------------------------
# (b) The report enumerates the distinct maturity states (JSON keys + MD columns).
# ---------------------------------------------------------------------------
for _k in installed configured executed_local executed_ci gate_enforced live_validated \
          evidence_run_id last_evidence_date product_support profile_policy; do
	if printf '%s' "$JSON_DEFAULT" | jq -e --arg k "$_k" '.tools[0]|has($k)' >/dev/null 2>&1; then
		ok "(b) JSON tool carries distinct state: $_k"
	else bad "(b) JSON tool missing state key: $_k"; fi
done
MD=$(sh "$SCRIPT" --format md 2>/dev/null)
for _col in 'Installed' 'Configured' 'Executed (local)' 'Executed (CI)' 'Gate enforced' 'Live validated' 'Evidence run ID' 'Last evidence date'; do
	if printf '%s\n' "$MD" | grep -qF "$_col"; then ok "(b) MD column present: $_col"
	else bad "(b) MD column missing: $_col"; fi
done
# The MD table header must still start with '| Tool ' (kept stable for downstream parsers).
[ "$(printf '%s\n' "$MD" | grep -c '^| Tool ')" = "1" ] \
	&& ok "(b) MD still emits a single '| Tool' header row" || bad "(b) MD '| Tool' header row not unique"

# ---------------------------------------------------------------------------
# (c) Fixture-only / unbacked evidence is NOT live; a genuinely backed run IS.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/fixture"
# Unbacked: empty workflow_run_id, failure, artifacts not verified.
write_evidence "$WORK/fixture/f.json" "" "failure" "false"
J_FIX=$(sh "$SCRIPT" --format json --evidence-dir "$WORK/fixture" 2>/dev/null)
_f=$(printf '%s' "$J_FIX" | jq -r '.live_validated')
_frid=$(printf '%s' "$J_FIX" | jq -r '.evidence_run_id')
if [ "$_f" = "false" ] && [ "$_frid" = "—" ]; then
	ok "(c) unbacked/fixture-only evidence is NOT shown as live"
else bad "(c) fixture-only evidence leaked as live (live=$_f run_id=$_frid)"; fi

# A run that is success+artifacts but has NO workflow_run_id is still NOT real.
write_evidence "$WORK/fixture/f.json" "" "success" "true"
_n=$(sh "$SCRIPT" --format json --evidence-dir "$WORK/fixture" 2>/dev/null | jq -r '.live_validated')
[ "$_n" = "false" ] && ok "(c) success without a real workflow_run_id is NOT live" \
	|| bad "(c) missing workflow_run_id wrongly counted as live (got $_n)"

# Genuinely backed run: real id + success + verified -> live=true, and a product
# 'live-validated' tool becomes live while a 'ci-validated (evidence-fixture)' tool does not.
mkdir -p "$WORK/real"
write_evidence "$WORK/real/r.json" "gh-run-555" "success" "true"
J_REAL=$(sh "$SCRIPT" --format json --evidence-dir "$WORK/real" 2>/dev/null)
_r=$(printf '%s' "$J_REAL" | jq -r '.live_validated')
_rid=$(printf '%s' "$J_REAL" | jq -r '.evidence_run_id')
if [ "$_r" = "true" ] && [ "$_rid" = "gh-run-555" ]; then
	ok "(c) a genuinely backed consumer_run flips live_validated=true with the real run ID"
else bad "(c) backed run failed to validate (live=$_r run_id=$_rid)"; fi
_dl=$(printf '%s' "$J_REAL" | jq -r '.tools[]|select(.tool=="Deptrac").live_validated')
_cl=$(printf '%s' "$J_REAL" | jq -r '.tools[]|select(.tool=="Checkov").live_validated')
[ "$_dl" = "yes" ] && ok "(c) product live-validated tool (Deptrac) goes live with real evidence" \
	|| bad "(c) Deptrac not live with real evidence (got $_dl)"
[ "$_cl" = "no" ] && ok "(c) fixture-tier tool (Checkov) stays NOT live even with real evidence" \
	|| bad "(c) Checkov wrongly live (got $_cl)"

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
