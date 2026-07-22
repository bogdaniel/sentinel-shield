#!/bin/sh
# Sentinel Shield prod test — gate/collector correctness (audit PR F).
#
# Each assertion pins a defect that produced a WRONG GATE VERDICT or silently discarded
# evidence. Every one of them fails against the pre-fix engine.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss269)
trap 'rm -rf -- "$WORK"' EXIT INT TERM
COLL="$ROOT/scripts/collectors"

# c <collector> <json> — run a collector over inline JSON, echo its status.
c() { printf '%s' "$2" > "$WORK/i.json"; sh "$COLL/$1" --input "$WORK/i.json" 2>/dev/null | jq -r '.status'; }

# --- malformed GATING counts are never coerced to a clean 0 ------------------
# docs/raw-report-contract.md states this rule; these collectors did the opposite, so a
# corrupted or truncated report reported PASS.
for _c in coverage mutation complexity duplication diff-coverage; do
	check "$_c: a negative .violations fails closed"   "$(c "$_c.sh" '{"violations":-5}')"  "execution-error"
	check "$_c: a fractional .violations fails closed" "$(c "$_c.sh" '{"violations":1.5}')" "execution-error"
	check "$_c: a string .violations fails closed"     "$(c "$_c.sh" '{"violations":"x"}')" "execution-error"
	check "$_c: a valid .violations still counts"      "$(c "$_c.sh" '{"violations":2}')"   "findings"
	check "$_c: an ABSENT .violations is legitimately 0" "$(c "$_c.sh" '{}')"               "pass"
done
check "debug-code: negative count fails closed" "$(c debug-code.sh '{"debug_code_violations":-1}')" "execution-error"
check "debug-code: valid count still counts"    "$(c debug-code.sh '{"debug_code_violations":3}')"  "findings"

# --- dead-code must not FABRICATE a count from a different field ------------
# {"violations":"abc","dead_code_count":7} reported 7 violations — a number the report never
# asserted, produced by falling back to an unrelated field when the gating count was malformed.
check "dead-code: malformed .violations does not fall back to dead_code_count" \
	"$(c dead-code.sh '{"violations":"abc","dead_code_count":7}')" "execution-error"
check "dead-code: negative .violations fails closed" "$(c dead-code.sh '{"violations":-3}')" "execution-error"
check "dead-code: .dead_code_count is still used when .violations is ABSENT" \
	"$(c dead-code.sh '{"dead_code_count":2}')" "findings"
# When .violations is absent, dead_code_count IS the gating count, so it must fail closed on
# malformed input too — coercing "abc"/-1/1.5 to 0 read as a clean pass (the same fail-open
# the .violations checks above prevent). An ABSENT count is still a legitimate 0.
check "dead-code: malformed .dead_code_count fails closed (no clean-pass coercion)" \
	"$(c dead-code.sh '{"dead_code_count":"abc"}')" "execution-error"
check "dead-code: negative .dead_code_count fails closed" \
	"$(c dead-code.sh '{"dead_code_count":-1}')" "execution-error"
check "dead-code: absent count is a legitimate pass (0)" \
	"$(c dead-code.sh '{}')" "pass"

# --- --strict-summary must accept the schema's own status values ------------
# The enforcer allowed 5 values; the schema (and every v1.10+ collector) emits 10. So the
# STRICTEST validation flag could not be run against a HEALTHY summary.
_schema=$(jq -r '.properties.tools.additionalProperties.properties.status.enum | sort | join(",")' \
	"$ROOT/schemas/security-summary.schema.json")
for _st in findings not-configured not-applicable execution-error disabled; do
	printf '{"version":"1.0","generated_at":"2026-07-20T00:00:00Z","source":{},"evidence":{"sbom":{"present":true},"release_evidence":{"present":true}},"summary":{"secrets":0,"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0,"architecture_violations":0,"type_errors":0,"test_failures":0,"unsafe_docker":0,"unsafe_github_actions":0,"missing_sbom":false,"missing_release_evidence":false,"expired_exceptions":0},"tools":{"coverage":{"status":"%s"}}}\n' "$_st" > "$WORK/sum.json"
	sh "$ROOT/scripts/resolve-gates.sh" --mode strict --output-dir "$WORK" --format env >/dev/null 2>&1
	sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$WORK/sentinel-shield-gates.env" \
		--summary "$WORK/sum.json" --output-dir "$WORK" --format json --strict-summary >/dev/null 2>&1 && _rc=0 || _rc=$?
	check "--strict-summary accepts the schema status '$_st'" "$([ "$_rc" = "2" ] && echo rejected || echo accepted)" "accepted"
done

# --- zap-full is produced by the DAST template and must be collected --------
_zap=$(awk -F'|' '/^zap-full\|/{print $2; exit}' "$ROOT/scripts/build-security-summary.sh")
check "zap-full has a TOOL_TABLE row" "${_zap:-missing}" "zap-full.json"

# --- symfony style output must reach the summary ----------------------------
# symfony declares php-cs-fixer; the builder only knew php-style, so its style findings were
# silently dropped and a project with violations reported style_violations=0.
_S="$WORK/sym"; mkdir -p "$_S/raw" "$_S/tgt"
printf '{"files":[{"name":"a.php"},{"name":"b.php"}]}' > "$_S/raw/php-cs-fixer.json"
sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_S/raw" --output "$_S/s.json" \
	--profile symfony --target "$_S/tgt" >/dev/null 2>&1
check "symfony php-cs-fixer output reaches summary.style_violations" \
	"$(jq -r '.summary.style_violations' "$_S/s.json" 2>/dev/null)" "2"

# Both style keys emit php_style, so a profile declaring BOTH would double-count the SUM.
_both=""
for _m in "$ROOT"/profiles/*/profile.manifest.json "$ROOT"/profiles/combinations/*.json; do
	_n=$(jq -r '[(.tools // {}) | keys[] | select(. == "php-style" or . == "php-cs-fixer")] | length' "$_m" 2>/dev/null || echo 0)
	[ "${_n:-0}" -gt 1 ] && _both="$_both$(basename "$(dirname "$_m")") "
done
check "no profile declares BOTH php-style and php-cs-fixer (would double-count)" "${_both:-none}" "none"

# --- the two recompute_applicable copies must agree on the default arm ------
# One printed 'no' (not applicable) and the other 'unknown' (cannot decide), so an
# unrecognized applies_when meant different things to the two halves of the acceptance gate —
# while a comment claimed they were kept identical.
_mfd=$(awk '/^recompute_applicable\(\)/,/^}/' "$ROOT/scripts/build-scanner-manifest.sh" | grep -cE "\*\) *printf 'unknown'" || true)
_enf=$(awk '/^recompute_applicable\(\)/,/^}/' "$ROOT/scripts/enforce-security-policy.sh" | grep -cE "\*\) *printf 'unknown'" || true)
case "$_mfd" in ''|*[!0-9]*) _mfd=0 ;; esac
case "$_enf" in ''|*[!0-9]*) _enf=0 ;; esac
check "both recompute_applicable copies default to 'unknown'" \
	"$([ "$_mfd" -ge 1 ] && [ "$_enf" -ge 1 ] && echo agree || echo diverge)" "agree"

# --- resolved gates and evaluated gates must reconcile ----------------------
# The removed GATE_KEYS list claimed to be the inventory while omitting 25 of ~41 gates.
# The real invariant: every flag the resolver emits is evaluated, and vice-versa.
sh "$ROOT/scripts/resolve-gates.sh" --mode regulated --output-dir "$WORK/g" --format env >/dev/null 2>&1
_resolved=$(grep '^SENTINEL_SHIELD_FAIL_ON_' "$WORK/g/sentinel-shield-gates.env" | sed 's/^SENTINEL_SHIELD_FAIL_ON_//; s/=.*//' | tr 'A-Z' 'a-z' | sort)
_n=$(printf '%s\n' "$_resolved" | grep -c . || true)
case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
if [ "$_n" -ge 40 ]; then
	pass "resolver emits a full gate set ($_n flags)"
else
	fail "resolver emits only $_n flags — expected the full set (>=40)"
fi
check "the dead GATE_KEYS inventory is gone" \
	"$(grep -c '^GATE_KEYS=' "$ROOT/scripts/enforce-gates.sh" || true)" "0"

if [ "$FAILED" -eq 0 ]; then
	printf '\n269-gate-correctness: ALL CHECKS PASSED\n'
else
	printf '\n269-gate-correctness: FAILURES PRESENT\n'
fi
exit "$FAILED"
