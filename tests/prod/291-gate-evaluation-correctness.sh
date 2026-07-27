#!/bin/sh
# Sentinel Shield prod test — gate-evaluation correctness (#229, #230, #231, #232, #233).
#
# Five ways the evaluators turned untrusted or contradictory evidence into a pass:
#
#   #229  eval_bool_gate triggered only on the literal string "true". Every other value —
#         a number, a string, an array, an object, a read error, or an ABSENT key for an
#         ENABLED gate — became `false` and PASSED, clearing missing-evidence controls.
#   #230  eval_expired_gate skipped a malformed `exceptions.expired` silently and never
#         required the detailed object to agree with the summary counter.
#   #231  required-tool policy recognised four failure statuses; every other status —
#         empty, unknown, `skipped`, `warn`, `fail`, or from a future schema — fell through
#         without a failure, and `gate_enforced:false` on a required entry skipped the tool
#         entirely, so the summary PRODUCER could switch off enforcement.
#   #232  unsafe_docker reconciled only the summary-undercount direction. More raw findings
#         than the summary counted could make `accepted` exceed `total` with `unaccepted`
#         zero, and duplicate raw findings inflated `accepted`.
#   #233  Docker accepted-risk paths matched by basename and by suffix, so a waiver for
#         `Dockerfile` covered every Dockerfile in the repository.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
ENFORCE="$ROOT/scripts/enforce-gates.sh"
RESOLVE="$ROOT/scripts/resolve-gates.sh"
EXAMPLE="$ROOT/templates/security-summary.example.json"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

# base <mutation> — a complete, current-contract, evidence-bearing summary with one mutation.
base() {
	jq '.tools = {"tests":{"status":"pass","policy":"required","gate_enforced":true}}' "$EXAMPLE" |
		jq "$1" > "$WORK/s.json"
	printf '%s' "$WORK/s.json"
}
# enf <summary> <mode> [accepted-risks] — echo the enforcer's exit code.
enf() {
	_d="$WORK/e"; rm -rf "$_d"; mkdir -p "$_d"
	sh "$RESOLVE" --mode "$2" --output-dir "$_d" --format all >/dev/null 2>&1
	_c=0
	sh "$ENFORCE" --gates-env "$_d/sentinel-shield-gates.env" --summary "$1" \
		${3:+--accepted-risks "$3"} --raw-dir "$WORK/raw" \
		--hadolint-raw "$WORK/raw/hadolint.json" --docker-base-digest-raw "$WORK/raw/docker-base-digest.json" \
		--output-dir "$_d" --format all >"$_d/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}

# ---------------------------------------------------------------------------
# 0. Control.
# ---------------------------------------------------------------------------
check "control: a complete clean summary passes strict" "$(enf "$(base '.')" strict)" 0

# ---------------------------------------------------------------------------
# 1. #229 — boolean evidence gates.
# ---------------------------------------------------------------------------
for _v in '1' '0' '"true"' '"yes"' '[]' '{}' 'null'; do
	_s=$(base ".summary.missing_coverage_evidence = $_v")
	_rc=$(enf "$_s" strict)
	case "$_v" in
		'null') check "an ABSENT enabled evidence flag is refused in strict ($_v)" "$_rc" 2 ;;
		*) check "a malformed evidence flag ($_v) fails closed" "$_rc" 2 ;;
	esac
done
check "a real true evidence flag still FAILS the gate (not exit 2)" "$(enf "$(base '.summary.missing_coverage_evidence = true')" strict)" 1
check "a real false evidence flag still passes" "$(enf "$(base '.summary.missing_coverage_evidence = false')" strict)" 0
# The same rule for every boolean family member.
for _k in missing_test_evidence empty_test_suite missing_architecture_evidence missing_test_change_evidence; do
	check "$_k: a malformed value fails closed" "$(enf "$(base ".summary.$_k = 7")" regulated)" 2
done
# A DISABLED gate keeps back-compat for an absent key.
check "an absent key for a DISABLED gate is still fine" "$(enf "$(base 'del(.summary.mutation_score_violations)')" baseline)" 0

# ---------------------------------------------------------------------------
# 2. #230 — expired-exception evidence must be readable and must agree.
# ---------------------------------------------------------------------------
check "a malformed exceptions.expired fails closed" \
	"$(enf "$(base '.exceptions.expired = "many"')" baseline)" 2
check "a negative exceptions.expired fails closed" \
	"$(enf "$(base '.exceptions.expired = -1')" baseline)" 2
check "summary says 0 while the detail says 2 -> contradiction" \
	"$(enf "$(base '.exceptions.expired = 2 | .summary.expired_exceptions = 0')" baseline)" 2
check "summary says 2 while the detail says 0 -> contradiction" \
	"$(enf "$(base '.exceptions.expired = 0 | .summary.expired_exceptions = 2')" baseline)" 2
check "agreeing non-zero counts FAIL the gate (a real finding, not a config error)" \
	"$(enf "$(base '.exceptions.expired = 2 | .summary.expired_exceptions = 2')" baseline)" 1
check "agreeing zero counts pass" \
	"$(enf "$(base '.exceptions.expired = 0 | .summary.expired_exceptions = 0')" baseline)" 0
check "no detailed exceptions object at all is still accepted" \
	"$(enf "$(base 'del(.exceptions)')" baseline)" 0

# ---------------------------------------------------------------------------
# 3. #231 — required-tool statuses.
# ---------------------------------------------------------------------------
# Statuses INSIDE the schema enum reach required-tool policy and are a gate failure (exit 1).
for _st in '"skipped"' '"warn"' '"fail"'; do
	_s=$(base ".tools.tests.status = $_st")
	check "a required tool with in-enum status $_st is a required-tool failure" "$(enf "$_s" baseline)" 1
done
# Statuses OUTSIDE the enum are a malformed summary and are refused earlier still (exit 2) by
# the now-mandatory structural validation — stricter than the required-tool path, and asserted
# so a future refactor cannot downgrade them into a silent fall-through again.
for _st in '""' '"from-the-future"' '"PASS"'; do
	_s=$(base ".tools.tests.status = $_st")
	check "a required tool with out-of-enum status $_st is refused as malformed" "$(enf "$_s" baseline)" 2
done
check "a required tool with status pass is fine" "$(enf "$(base '.tools.tests.status = "pass"')" baseline)" 0
check "a required tool with status findings is judged by the count gates, not here" \
	"$(enf "$(base '.tools.tests.status = "findings"')" baseline)" 0
# gate_enforced:false must be explained, not merely asserted by the producer.
check "an UNEXPLAINED gate_enforced:false on a required tool fails" \
	"$(enf "$(base '.tools.tests.gate_enforced = false')" baseline)" 1
check "gate_enforced:false with status not-applicable is accepted" \
	"$(enf "$(base '.tools.tests.gate_enforced = false | .tools.tests.status = "not-applicable"')" baseline)" 0
# A declared stage is NOT on its own a scope statement: accepting any non-empty `.stage` let
# a hand-built summary mark arbitrary required tools non-enforced. The per-tool
# `stage_selected: false` the builder derives from the effective-profile execution matrix is
# what proves this tool is out of scope at this stage.
check "a declared stage ALONE does not excuse gate_enforced:false" \
	"$(enf "$(base '.stage = "pr" | .tools.tests.gate_enforced = false')" baseline)" 1
check "gate_enforced:false IS accepted with the derived stage_selected:false marker" \
	"$(enf "$(base '.stage = "pr" | .tools.tests.gate_enforced = false | .tools.tests.stage_selected = false')" baseline)" 0
check "…and stage_selected:true still fails (the tool IS selected at this stage)" \
	"$(enf "$(base '.stage = "pr" | .tools.tests.gate_enforced = false | .tools.tests.stage_selected = true')" baseline)" 1
# `disabled` is a required-control FAILURE state, not an exemption: a producer could
# otherwise switch off its own required control with two fields.
check "required + status disabled + gate_enforced:false FAILS without a waiver" \
	"$(enf "$(base '.tools.tests.status = "disabled" | .tools.tests.gate_enforced = false')" baseline)" 1
# not-applicable must be substantiated by the tool-policy overlay.
check "not-applicable without the tool-policy overlay is unsubstantiated" \
	"$(enf "$(base '.tools.tests.status = "not-applicable" | del(.summary.required_tool_failures)')" baseline)" 1

# ---------------------------------------------------------------------------
# 4. #232 / #233 — unsafe_docker reconciliation and path matching.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/raw"
printf '[]' > "$WORK/raw/docker-base-digest.json"
risk() { # risk <files-json>
	jq -n --argjson f "$1" '{version:"1", risks:[{id:"AR-D", gate:"unsafe_docker", scope:"finding",
		rule_id:"DL3018", files:$f, owner:"o", reason:"r", expires_at:"2099-01-01", status:"approved"}]}' \
		> "$WORK/ar.json"
	printf '%s' "$WORK/ar.json"
}

# #233: a waiver for `Dockerfile` must NOT cover docker/prod/Dockerfile.
cat > "$WORK/raw/hadolint.json" <<'JSON'
[{"code":"DL3018","level":"warning","file":"docker/prod/Dockerfile","line":3,"message":"pin"}]
JSON
_s=$(base '.summary.unsafe_docker = 1')
check "a basename waiver no longer covers a different Dockerfile" "$(enf "$_s" baseline "$(risk '["Dockerfile"]')")" 1
check "a suffix waiver no longer covers a deeper path" "$(enf "$_s" baseline "$(risk '["prod/Dockerfile"]')")" 1
check "the EXACT repository-rooted path still matches" "$(enf "$_s" baseline "$(risk '["docker/prod/Dockerfile"]')")" 0
check "a leading ./ on the record still matches" "$(enf "$_s" baseline "$(risk '["./docker/prod/Dockerfile"]')")" 0

# #232: more raw findings than the summary counts is a contradiction, not an acceptance.
cat > "$WORK/raw/hadolint.json" <<'JSON'
[{"code":"DL3018","level":"warning","file":"a/Dockerfile","line":1,"message":"pin"},
 {"code":"DL3018","level":"warning","file":"b/Dockerfile","line":1,"message":"pin"},
 {"code":"DL3018","level":"warning","file":"c/Dockerfile","line":1,"message":"pin"}]
JSON
_s=$(base '.summary.unsafe_docker = 1')
_rc=$(enf "$_s" baseline "$(risk '["a/Dockerfile","b/Dockerfile","c/Dockerfile"]')")
check "raw findings exceeding the summary total is refused, not accepted" "$_rc" 2
grep -q 'contradicts its own evidence' "$WORK/e/log" && pass "  the contradiction is named" || fail "  contradiction not reported"

# Duplicate raw findings must not inflate the accepted count.
# A DUPLICATE is the identical finding repeated (same rule, file AND line). Two findings for the
# same rule at different lines are two real findings and must stay counted separately.
cat > "$WORK/raw/hadolint.json" <<'JSON'
[{"code":"DL3018","level":"warning","file":"a/Dockerfile","line":1,"message":"pin"},
 {"code":"DL3018","level":"warning","file":"a/Dockerfile","line":1,"message":"pin"}]
JSON
_s=$(base '.summary.unsafe_docker = 1')
check "an identical repeated finding collapses to one accounted finding" "$(enf "$_s" baseline "$(risk '["a/Dockerfile"]')")" 0
_acc=$(jq -r '.accepted_risks.unsafe_docker.accepted' "$WORK/e/sentinel-shield-enforcement.json")
_tot=$(jq -r '.accepted_risks.unsafe_docker.total' "$WORK/e/sentinel-shield-enforcement.json")
if [ "$_acc" -le "$_tot" ]; then pass "  accepted ($_acc) never exceeds the reported total ($_tot)"
else fail "  accepted ($_acc) exceeds the total ($_tot)"; fi

cat > "$WORK/raw/hadolint.json" <<'JSON'
[{"code":"DL3018","level":"warning","file":"a/Dockerfile","line":1,"message":"pin"},
 {"code":"DL3018","level":"warning","file":"a/Dockerfile","line":9,"message":"pin"}]
JSON
_s=$(base '.summary.unsafe_docker = 2')
check "two findings at different LINES are not duplicates" "$(enf "$_s" baseline "$(risk '["a/Dockerfile"]')")" 0
_acc=$(jq -r '.accepted_risks.unsafe_docker.accepted' "$WORK/e/sentinel-shield-enforcement.json")
check "  both are accounted and accepted" "$_acc" 2

# The undercount direction still fails closed (unchanged behaviour).
cat > "$WORK/raw/hadolint.json" <<'JSON'
[{"code":"DL3018","level":"warning","file":"a/Dockerfile","line":1,"message":"pin"}]
JSON
_s=$(base '.summary.unsafe_docker = 3')
check "a summary counting MORE than the raw sources still fails closed" \
	"$(enf "$_s" baseline "$(risk '["a/Dockerfile"]')")" 1

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '291-gate-evaluation-correctness: ALL CHECKS PASSED\n'
	exit 0
fi
printf '291-gate-evaluation-correctness: FAILURES PRESENT\n'
exit 1
