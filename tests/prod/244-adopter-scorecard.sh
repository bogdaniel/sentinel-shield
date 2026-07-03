#!/bin/sh
# tests/prod/244-adopter-scorecard.sh — deterministic tests for the external-adopter
# usability scorecard generator (scripts/report-adopter-usability.sh) and its schemas
# (schemas/adopter-scorecard.schema.json, schemas/adopter-session.schema.json).
#
# NETWORK-FREE + DETERMINISTIC. It builds synthetic adopter-session fixtures (never runs
# the engine) and asserts the generator's verdict, its schema conformance, its fail-closed
# behaviour, and its redaction guarantees:
#
#   POSITIVE          healthy sessions -> result=pass, all 8 blocking criteria pass, exit 0.
#   NEGATIVE          one fixture per criterion trips exactly that criterion -> result=fail, exit 1.
#   FAILURE-INJECTION empty/malformed/non-conformant evidence -> FAIL CLOSED (exit 3, no scorecard).
#   SCHEMA            emitted scorecard conforms to adopter-scorecard.schema.json (jq-structural);
#                     every failed criterion carries a non-empty reproduction command.
#   REDACTION         a session carrying an absolute path never leaks it into the scorecard.
#
# Self-contained: creates its own mktemp fixtures and cleans up. Auto-discovered by
# `sh scripts/self-test.sh production-readiness`. jq is a hard dependency.
# Prints "PASS: x" / "FAIL: x"; exits nonzero if any assertion fails.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
GEN="$ROOT/scripts/report-adopter-usability.sh"
SC_SCHEMA="$ROOT/schemas/adopter-scorecard.schema.json"
SESS_SCHEMA="$ROOT/schemas/adopter-session.schema.json"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n' >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# mk_session <dir> <name> <json> — write a *.session.json fixture.
mk_session() { mkdir -p "$1"; printf '%s\n' "$3" > "$1/$2.session.json"; }

# A healthy baseline session (all criteria satisfied). Callers tweak via jq.
HEALTHY='{
  "schema_version":"1","harness":"adopter-scenarios","scenario":"clean-linux",
  "platform":"Linux","started_at":"2026-07-04T00:00:00Z","finished_at":"2026-07-04T00:00:04Z",
  "documented_environment":["PATH","HOME","TMPDIR"],"injected_inputs":[],"unexpected_prompt":false,
  "budget_seconds":60,
  "recovery":{"required":true,"performed":true,"restored":true,"method":"re-run install --apply --force"},
  "steps":[
    {"step":"install","command":"sh scripts/install-baseline.sh --target <target> --apply","exit_code":0,"elapsed_seconds":3,"status":"ok","message":"installed","generated_files":["<target>/.sentinel-shield/installation.json"]},
    {"step":"inject-failure","command":"detect drift","exit_code":1,"elapsed_seconds":1,"status":"fail","message":"managed file drifted","next_action":"re-run install --apply --force","generated_files":[]},
    {"step":"recover","command":"sh scripts/install-baseline.sh --target <target> --apply --force","exit_code":0,"elapsed_seconds":2,"status":"ok","message":"restored byte-for-byte","generated_files":[]}
  ],
  "result":"pass"
}'

# sc_validate <scorecard.json> — jq-structural conformance to adopter-scorecard.schema.json.
sc_validate() {
	jq -e '
		(.schema_version=="1")
		and (.generator=="report-adopter-usability")
		and (.generated_at|type=="string" and (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
		and (.sessions_evaluated|type=="number" and (.>=1))
		and (.scenarios|type=="array" and (length>=1))
		and (.scenarios|all((.scenario|type=="string" and (length>0)) and (.result|IN("pass","fail")) and (.steps_total|type=="number") and (.budget_seconds|type=="number")))
		and (.criteria|type=="array" and (length==8))
		and (.criteria|all(
			(.id|IN("undocumented-prerequisites","unexplained-failures","unrecoverable-mutations","errors-have-next-actions","bounded-durations","files-attributable","recovery-restores-state","no-secrets-no-abs-paths"))
			and (.blocking==true)
			and (.status|IN("pass","fail"))
			and (.offenders|type=="array")
			and (.reproduction|type=="string" and (length>0))
		))
		and (.totals|(.scenarios|type=="number") and (.criteria_passed|type=="number") and (.criteria_failed|type=="number"))
		and (.result|IN("pass","fail"))
	' "$1" >/dev/null 2>&1
}

# run_gen <dir> <extra-args...> : run the generator; sets globals RG_RC + SCOUT.
# NOT called in a subshell, so the globals propagate to assertions.
SCOUT=""
RG_RC=0
run_gen() {
	_d="$1"; shift
	SCOUT="$_d/scorecard.json"
	rm -f "$SCOUT"
	RG_RC=0
	sh "$GEN" --sessions-dir "$_d" --json-out "$SCOUT" "$@" >/dev/null 2>"$_d/gen.err" || RG_RC=$?
}

# --- schemas are valid JSON --------------------------------------------------
if jq -e . "$SC_SCHEMA" >/dev/null 2>&1; then pass "adopter-scorecard.schema.json is valid JSON"; else fail "adopter-scorecard.schema.json is not valid JSON"; fi
if jq -e . "$SESS_SCHEMA" >/dev/null 2>&1; then pass "adopter-session.schema.json is valid JSON"; else fail "adopter-session.schema.json is not valid JSON"; fi

# --- POSITIVE: two healthy sessions -> pass ----------------------------------
P="$WORK/pos"
mk_session "$P" clean-linux "$HEALTHY"
mk_session "$P" other "$(printf '%s' "$HEALTHY" | jq '.scenario="read-only-project"')"
run_gen "$P" --skipped "uninstall=no engine uninstall command is published"
assert_eq "positive: generator exit 0" "$RG_RC" "0"
if [ -s "$SCOUT" ]; then
	assert_eq "positive: scorecard result=pass" "$(jq -r '.result' "$SCOUT")" "pass"
	assert_eq "positive: 8 criteria all pass" "$(jq '[.criteria[]|select(.status=="pass")]|length' "$SCOUT")" "8"
	assert_eq "positive: sessions_evaluated=2" "$(jq -r '.sessions_evaluated' "$SCOUT")" "2"
	assert_eq "positive: skipped scenario recorded" "$(jq -r '.skipped_scenarios[0].scenario' "$SCOUT")" "uninstall"
	if sc_validate "$SCOUT"; then pass "positive: scorecard conforms to adopter-scorecard.schema.json"; else fail "positive: scorecard non-conformant"; fi
else
	fail "positive: no scorecard emitted"
fi

# --- NEGATIVE: one fixture per criterion -------------------------------------
# neg_case <criterion-id> <session-json>
neg_case() {
	_id="$1"; _js="$2"; _d="$WORK/neg-$_id"
	mk_session "$_d" fixture "$_js"
	run_gen "$_d"
	assert_eq "negative[$_id]: generator exit 1" "$RG_RC" "1"
	if [ -s "$SCOUT" ]; then
		assert_eq "negative[$_id]: result=fail" "$(jq -r '.result' "$SCOUT")" "fail"
		assert_eq "negative[$_id]: criterion '$_id' failed" "$(jq -r --arg id "$_id" '.criteria[]|select(.id==$id)|.status' "$SCOUT")" "fail"
		_rep=$(jq -r --arg id "$_id" '.criteria[]|select(.id==$id)|.reproduction' "$SCOUT")
		if [ -n "$_rep" ] && [ "$_rep" != "null" ]; then pass "negative[$_id]: failed criterion carries a reproduction command"; else fail "negative[$_id]: missing reproduction command"; fi
	else
		fail "negative[$_id]: no scorecard emitted (should still emit a fail scorecard)"
	fi
}

neg_case "undocumented-prerequisites" "$(printf '%s' "$HEALTHY" | jq '.unexpected_prompt=true')"
neg_case "unexplained-failures"       "$(printf '%s' "$HEALTHY" | jq '(.steps[]|select(.step=="inject-failure")).message=""')"
neg_case "errors-have-next-actions"   "$(printf '%s' "$HEALTHY" | jq 'del((.steps[]|select(.step=="inject-failure")).next_action)')"
neg_case "unrecoverable-mutations"    "$(printf '%s' "$HEALTHY" | jq '.recovery.restored=false')"
neg_case "recovery-restores-state"    "$(printf '%s' "$HEALTHY" | jq '.recovery={"required":false,"performed":true,"restored":false}')"
neg_case "bounded-durations"          "$(printf '%s' "$HEALTHY" | jq '(.steps[]|select(.step=="install")).elapsed_seconds=9999')"
neg_case "files-attributable"         "$(printf '%s' "$HEALTHY" | jq '(.steps[]|select(.step=="install")).generated_files=["relative/or/absent/root"]')"

# no-secrets-no-abs-paths: a message carrying an absolute local path.
neg_case "no-secrets-no-abs-paths"    "$(printf '%s' "$HEALTHY" | jq '(.steps[]|select(.step=="recover")).message="wrote /Users/victim/project/out"')"

# --- REDACTION: the leaked path must NOT appear in the emitted scorecard -----
_d="$WORK/redact"
mk_session "$_d" fixture "$(printf '%s' "$HEALTHY" | jq '(.steps[]|select(.step=="recover")).message="wrote /Users/victim/project/out"')"
run_gen "$_d"
if [ -s "$SCOUT" ]; then
	if grep -q "/Users/victim" "$SCOUT"; then fail "redaction: scorecard leaked the absolute path"; else pass "redaction: absolute path never appears in the scorecard"; fi
else
	fail "redaction: expected a fail scorecard to be emitted"
fi

# --- FAILURE-INJECTION: fail-closed on bad evidence --------------------------
E="$WORK/empty"; mkdir -p "$E"
run_gen "$E"; assert_eq "fail-closed: empty evidence dir -> exit 3" "$RG_RC" "3"
if [ -s "$SCOUT" ]; then fail "fail-closed: empty dir must NOT emit a scorecard"; else pass "fail-closed: empty dir emits no scorecard"; fi

M="$WORK/malformed"; mk_session "$M" bad '{ this is not valid json'
run_gen "$M"; assert_eq "fail-closed: malformed session -> exit 3" "$RG_RC" "3"

N="$WORK/nonconformant"
mk_session "$N" bad "$(printf '%s' "$HEALTHY" | jq 'del(.result)')"
run_gen "$N"; assert_eq "fail-closed: non-conformant session (missing .result) -> exit 3" "$RG_RC" "3"

Nb="$WORK/badharness"
mk_session "$Nb" bad "$(printf '%s' "$HEALTHY" | jq '.harness="totally-unknown"')"
run_gen "$Nb"; assert_eq "fail-closed: unknown harness -> exit 3" "$RG_RC" "3"

# --- INVOCATION: no evidence supplied at all ---------------------------------
_rc=0; sh "$GEN" >/dev/null 2>&1 || _rc=$?
assert_eq "fail-closed: no --sessions-dir/--session -> exit 3" "$_rc" "3"

# --- INVOCATION: bad budget --------------------------------------------------
_rc=0; sh "$GEN" --sessions-dir "$P" --budget-seconds "-5" >/dev/null 2>&1 || _rc=$?
assert_eq "invalid invocation: negative budget -> exit 2" "$_rc" "2"

printf '\n244-adopter-scorecard: %d failure(s)\n' "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
printf 'All adopter-scorecard assertions passed.\n'
exit 0
