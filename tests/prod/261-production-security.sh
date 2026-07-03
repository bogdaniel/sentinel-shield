#!/bin/sh
# tests/prod/261-production-security.sh — deterministic tests for the production security
# acceptance + incident-response gate: the canonical policy (config/production-security-policy.json),
# its schema (schemas/production-security-policy.schema.json), the library
# (scripts/lib/security-policy.sh), the normalizer (scripts/normalize-security-summary.sh),
# the enforcer (scripts/enforce-security-policy.sh) and the acceptance-report contract
# (schemas/security-acceptance.schema.json).
#
# NETWORK-FREE + DETERMINISTIC. Every scenario builds a synthetic normalized summary and/or
# accepted-risks file in a scratch dir; waiver expiry uses fixed far-future (2999) / past
# (2000) dates so the SAME assertions hold on any day. It proves the documented exit contract
# and STABLE diagnostics:
#
#   POSITIVE          (0) clean, fully-covered, fresh env -> exit 0 accepted;
#                     (13) a valid, owned, approved, issue-linked, narrowly-scoped risk
#                     acceptance -> exit 0; (14) a documented emergency release -> exit 0
#                     accepted-emergency.
#   NEGATIVE          (1) critical vuln; (2) high w/ fix; (3) high w/o fix; (4) expired
#                     waiver; (6) waiver for the wrong scanner; (7) stale database;
#                     (8) scanner success w/ zero parsed targets; (9) scanner crash;
#                     (11) secret finding; (12) unexplained target-coverage reduction
#                     -> exit 1 with a stable reason token in the acceptance report.
#   FAILURE-INJECTION (5) waiver missing owner; (10) malformed report; malformed / missing /
#                     non-conformant policy -> exit 2 (fail closed).
#   SCHEMA            all schemas + the policy are valid JSON; policy conforms (jq-structural);
#                     every emitted acceptance report conforms to its schema.
#
# Self-contained; jq is a hard dependency. Prints "PASS: x" / "FAIL: x"; exits nonzero if any
# assertion fails.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
POLICY="$ROOT/config/production-security-policy.json"
POLICY_SCHEMA="$ROOT/schemas/production-security-policy.schema.json"
SUMMARY_SCHEMA="$ROOT/schemas/security-summary.schema.json"
ACCEPT_SCHEMA="$ROOT/schemas/security-acceptance.schema.json"
RISKS_SCHEMA="$ROOT/schemas/accepted-risks.schema.json"
ENFORCE="$ROOT/scripts/enforce-security-policy.sh"
NORMALIZE="$ROOT/scripts/normalize-security-summary.sh"
LIB="$ROOT/scripts/lib/security-policy.sh"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n' >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# assert_reason <label> <report> <token> — pass iff a violation with reason <token> exists.
assert_reason() {
	if jq -e --arg r "$3" 'any(.violations[]; .reason == $r)' "$2" >/dev/null 2>&1; then pass "$1"
	else fail "$1 (no violation reason=$3 in report)"; fi
}
# assert_conforms <label> <report> — pass iff the acceptance report conforms to its schema.
# The common + security-policy libs are sourced below, so call the validator directly.
assert_conforms() {
	if [ -s "$2" ] && sp_validate_acceptance "$2" >/dev/null 2>&1; then pass "$1"
	else fail "$1 (acceptance report not conformant)"; fi
}

EMPTY_RISKS="$WORK/risks-empty.json"; printf '{"version":"1","risks":[]}\n' > "$EMPTY_RISKS"

# mk_clean_summary <path> — a fully-covered, fresh, finding-free normalized summary that
# yields exit 0. Individual scenarios jq-patch a single field off this baseline.
mk_clean_summary() {
	cat > "$1" <<'JSON'
{
  "version": "1.0",
  "generated_at": "2026-07-04T00:00:00Z",
  "targets": { "expected": 10, "scanned": 10, "coverage_ratio": 1.0 },
  "scanners": [
    { "name": "semgrep", "category": "source_vulnerabilities", "applicable": true, "status": "success", "version": "1.165.0", "database": { "timestamp": null, "age_days": null }, "targets_scanned": 10, "raw_report_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000" },
    { "name": "gitleaks", "category": "leaked_secrets", "applicable": true, "status": "success", "version": "8.18.0", "database": { "age_days": null }, "targets_scanned": 10, "raw_report_digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111" },
    { "name": "osv-scanner", "category": "dependency_vulnerabilities", "applicable": true, "status": "success", "version": "2.3.8", "database": { "age_days": 2 }, "targets_scanned": 5, "raw_report_digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222" },
    { "name": "grype", "category": "dependency_vulnerabilities", "applicable": true, "status": "success", "version": "0.74.0", "database": { "age_days": 1 }, "targets_scanned": 5, "raw_report_digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333" },
    { "name": "trivy", "category": "container_findings", "applicable": true, "status": "success", "version": "0.50.0", "database": { "age_days": 3 }, "targets_scanned": 2, "raw_report_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444" },
    { "name": "actionlint", "category": "workflow_vulnerabilities", "applicable": true, "status": "success", "version": "1.6.0", "database": { "age_days": null }, "targets_scanned": 12, "raw_report_digest": "sha256:5555555555555555555555555555555555555555555555555555555555555555" }
  ],
  "findings": []
}
JSON
}

# run_enforce <summary> <risks> [baseline] — set RC + REP (acceptance report path).
REP=""
RC=0
run_enforce() {
	REP="$WORK/acceptance.json"
	RC=0
	if [ -n "${3:-}" ]; then
		sh "$ENFORCE" --policy "$POLICY" --summary "$1" --accepted-risks "$2" --baseline "$3" --output "$REP" >/dev/null 2>&1 || RC=$?
	else
		sh "$ENFORCE" --policy "$POLICY" --summary "$1" --accepted-risks "$2" --output "$REP" >/dev/null 2>&1 || RC=$?
	fi
}

# --- SCHEMA / policy structural conformance ----------------------------------
for _s in "$POLICY_SCHEMA" "$SUMMARY_SCHEMA" "$ACCEPT_SCHEMA" "$RISKS_SCHEMA"; do
	if jq -e . "$_s" >/dev/null 2>&1; then pass "schema is valid JSON: $(basename "$_s")"; else fail "schema is not valid JSON: $(basename "$_s")"; fi
done
if jq -e . "$POLICY" >/dev/null 2>&1; then pass "production-security-policy is valid JSON"; else fail "policy is not valid JSON"; fi

# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$ROOT/scripts/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/security-policy.sh
. "$LIB"
if sp_validate_policy "$POLICY" >/dev/null 2>&1; then pass "policy conforms to production-security-policy.schema.json (sp_validate_policy)"; else fail "policy does not conform (sp_validate_policy)"; fi

# library unit checks: lifetime + digest + date.
assert_eq "sp_lifetime_days 2999-01-01..2999-02-01 == 31" "$(sp_lifetime_days 2999-01-01 2999-02-01)" "31"
if sp_digest_ok "sha256:$(printf '%064d' 0)"; then pass "sp_digest_ok accepts sha256:<64hex>"; else fail "sp_digest_ok rejected a valid digest"; fi
if sp_digest_ok "sha256:nothex"; then fail "sp_digest_ok accepted a non-hex digest"; else pass "sp_digest_ok rejects a non-hex digest"; fi

# ============================================================================
# (0) POSITIVE: clean, fully-covered, fresh env -> exit 0 accepted
# ============================================================================
mk_clean_summary "$WORK/clean.json"
run_enforce "$WORK/clean.json" "$EMPTY_RISKS"
assert_eq "(0) clean env -> exit 0" "$RC" "0"
assert_eq "(0) decision accepted" "$(jq -r '.decision' "$REP")" "accepted"
assert_conforms "(0) acceptance report conforms to schema" "$REP"

# ============================================================================
# (1) critical vuln, no waiver -> exit 1
# ============================================================================
jq '.findings=[{"id":"CVE-CRIT","scanner":"osv-scanner","category":"dependency_vulnerabilities","severity":"critical","fix_available":true,"reference":"CVE-CRIT"}]' "$WORK/clean.json" > "$WORK/s1.json"
run_enforce "$WORK/s1.json" "$EMPTY_RISKS"
assert_eq "(1) critical vuln -> exit 1" "$RC" "1"
assert_reason "(1) critical vuln blocking finding recorded" "$REP" "BLOCKING_FINDING"

# ============================================================================
# (2) high WITH fix, no waiver -> exit 1
# ============================================================================
jq '.findings=[{"id":"CVE-HF","scanner":"grype","category":"dependency_vulnerabilities","severity":"high","fix_available":true,"reference":"CVE-HF"}]' "$WORK/clean.json" > "$WORK/s2.json"
run_enforce "$WORK/s2.json" "$EMPTY_RISKS"
assert_eq "(2) high with fix -> exit 1" "$RC" "1"
assert_eq "(2) blocking finding counted" "$(jq -r '.findings.blocking' "$REP")" "1"

# ============================================================================
# (3) high WITHOUT fix, no waiver -> exit 1
# ============================================================================
jq '.findings=[{"id":"CVE-HN","scanner":"grype","category":"dependency_vulnerabilities","severity":"high","fix_available":false,"reference":"CVE-HN"}]' "$WORK/clean.json" > "$WORK/s3.json"
run_enforce "$WORK/s3.json" "$EMPTY_RISKS"
assert_eq "(3) high without fix -> exit 1" "$RC" "1"

# ============================================================================
# (4) EXPIRED waiver -> does not apply -> exit 1
# ============================================================================
cat > "$WORK/r4.json" <<'JSON'
{"version":"1","risks":[{"id":"R4","gate":"high_vulnerabilities","owner":"alice","approved_by":"bob","issue":"https://tracker/4","scanner":"grype","category":"dependency_vulnerabilities","finding_id":"CVE-HN","severity":"high","reason":"upstream fix pending","created_at":"2000-01-01","expires_at":"2000-02-01","status":"approved","scope":"finding"}]}
JSON
run_enforce "$WORK/s3.json" "$WORK/r4.json"
assert_eq "(4) expired waiver -> exit 1" "$RC" "1"
assert_eq "(4) no waiver applied" "$(jq -r '.findings.waived' "$REP")" "0"

# ============================================================================
# (5) waiver MISSING OWNER -> fail closed exit 2
# ============================================================================
cat > "$WORK/r5.json" <<'JSON'
{"version":"1","risks":[{"id":"R5","gate":"high_vulnerabilities","approved_by":"bob","issue":"https://tracker/5","scanner":"grype","category":"dependency_vulnerabilities","finding_id":"CVE-HN","severity":"high","reason":"x","created_at":"2999-01-01","expires_at":"2999-02-01","status":"approved","scope":"finding"}]}
JSON
run_enforce "$WORK/s3.json" "$WORK/r5.json"
assert_eq "(5) waiver missing owner -> exit 2 (fail closed)" "$RC" "2"

# ============================================================================
# (6) waiver for the WRONG SCANNER -> does not match -> exit 1
# ============================================================================
cat > "$WORK/r6.json" <<'JSON'
{"version":"1","risks":[{"id":"R6","gate":"high_vulnerabilities","owner":"alice","approved_by":"bob","issue":"https://tracker/6","scanner":"osv-scanner","category":"dependency_vulnerabilities","finding_id":"CVE-HN","severity":"high","reason":"x","created_at":"2999-01-01","expires_at":"2999-02-01","status":"approved","scope":"finding"}]}
JSON
run_enforce "$WORK/s3.json" "$WORK/r6.json"
assert_eq "(6) waiver for wrong scanner -> exit 1" "$RC" "1"
assert_eq "(6) no waiver applied (scanner mismatch)" "$(jq -r '.findings.waived' "$REP")" "0"

# ============================================================================
# (7) STALE database -> exit 1
# ============================================================================
jq '(.scanners[]|select(.name=="osv-scanner").database.age_days)=30' "$WORK/clean.json" > "$WORK/s7.json"
run_enforce "$WORK/s7.json" "$EMPTY_RISKS"
assert_eq "(7) stale database -> exit 1" "$RC" "1"
assert_reason "(7) stale database reason SCANNER_DB_STALE" "$REP" "SCANNER_DB_STALE"

# ============================================================================
# (8) scanner success with ZERO parsed targets -> exit 1
# ============================================================================
jq '(.scanners[]|select(.name=="osv-scanner").targets_scanned)=0' "$WORK/clean.json" > "$WORK/s8.json"
run_enforce "$WORK/s8.json" "$EMPTY_RISKS"
assert_eq "(8) zero parsed targets -> exit 1" "$RC" "1"
assert_reason "(8) zero targets reason SCANNER_ZERO_TARGETS" "$REP" "SCANNER_ZERO_TARGETS"

# ============================================================================
# (9) scanner CRASH -> exit 1
# ============================================================================
jq '(.scanners[]|select(.name=="trivy").status)="error"' "$WORK/clean.json" > "$WORK/s9.json"
run_enforce "$WORK/s9.json" "$EMPTY_RISKS"
assert_eq "(9) scanner crash -> exit 1" "$RC" "1"
assert_reason "(9) scanner crash reason SCANNER_FAILURE" "$REP" "SCANNER_FAILURE"

# ============================================================================
# (10) MALFORMED report -> fail closed exit 2
# ============================================================================
printf '{ this is not valid json\n' > "$WORK/s10.json"
run_enforce "$WORK/s10.json" "$EMPTY_RISKS"
assert_eq "(10) malformed report -> exit 2 (fail closed)" "$RC" "2"

# ============================================================================
# (11) SECRET finding -> never waivable -> exit 1
# ============================================================================
jq '.findings=[{"id":"SECRET-1","scanner":"gitleaks","category":"leaked_secrets","severity":"low"}]' "$WORK/clean.json" > "$WORK/s11.json"
# even a (structurally valid) waiver must not suppress a secret
cat > "$WORK/r11.json" <<'JSON'
{"version":"1","risks":[{"id":"R11","gate":"high_vulnerabilities","owner":"alice","approved_by":"bob","issue":"https://tracker/11","scanner":"gitleaks","category":"leaked_secrets","finding_id":"SECRET-1","severity":"low","reason":"nope","created_at":"2999-01-01","expires_at":"2999-02-01","status":"approved","scope":"finding"}]}
JSON
run_enforce "$WORK/s11.json" "$WORK/r11.json"
assert_eq "(11) secret finding -> exit 1" "$RC" "1"
assert_reason "(11) secret finding reason SECRET_LEAK_BLOCKING" "$REP" "SECRET_LEAK_BLOCKING"
assert_eq "(11) secret never waived" "$(jq -r '.findings.waived' "$REP")" "0"

# ============================================================================
# (12) unexplained TARGET-COVERAGE reduction vs baseline -> exit 1
# ============================================================================
cat > "$WORK/baseline.json" <<'JSON'
{ "targets": { "expected": 10, "scanned": 10, "coverage_ratio": 1.0 }, "findings": { "total": 0 } }
JSON
jq '.targets={"expected":5,"scanned":5,"coverage_ratio":1.0}' "$WORK/clean.json" > "$WORK/s12.json"
run_enforce "$WORK/s12.json" "$EMPTY_RISKS" "$WORK/baseline.json"
assert_eq "(12) coverage reduction -> exit 1" "$RC" "1"
assert_reason "(12) coverage reduction reason SECURITY_REGRESSION" "$REP" "SECURITY_REGRESSION"
assert_eq "(12) coverage_regression flag set" "$(jq -r '.regression.coverage_regression' "$REP")" "true"
# baseline present but coverage steady -> no regression
run_enforce "$WORK/clean.json" "$EMPTY_RISKS" "$WORK/baseline.json"
assert_eq "(12b) steady coverage vs baseline -> exit 0" "$RC" "0"

# ============================================================================
# (13) VALID narrowly-scoped risk acceptance -> exit 0
# ============================================================================
cat > "$WORK/r13.json" <<'JSON'
{"version":"1","risks":[{"id":"R13","gate":"high_vulnerabilities","owner":"alice","approved_by":"bob","issue":"https://tracker/13","scanner":"grype","category":"dependency_vulnerabilities","finding_id":"CVE-HN","severity":"high","reason":"no upstream fix; compensating control in place","created_at":"2999-01-01","expires_at":"2999-02-01","status":"approved","scope":"finding"}]}
JSON
run_enforce "$WORK/s3.json" "$WORK/r13.json"
assert_eq "(13) valid narrow risk acceptance -> exit 0" "$RC" "0"
assert_eq "(13) exactly one waiver applied" "$(jq -r '.findings.waived' "$REP")" "1"
assert_eq "(13) decision accepted" "$(jq -r '.decision' "$REP")" "accepted"

# ============================================================================
# (14) EMERGENCY release policy path -> exit 0 accepted-emergency
# ============================================================================
cat > "$WORK/r14.json" <<'JSON'
{"version":"1","risks":[{"id":"E14","gate":"critical_vulnerabilities","owner":"alice","approved_by":"bob","issue":"https://tracker/14","scanner":"osv-scanner","category":"dependency_vulnerabilities","finding_id":"CVE-CRIT","severity":"critical","reason":"active incident; ship mitigation now","created_at":"2999-01-01","expires_at":"2999-01-03","status":"approved","scope":"finding","emergency":true,"incident":"INC-2026-014"}]}
JSON
run_enforce "$WORK/s1.json" "$WORK/r14.json"
assert_eq "(14) emergency release -> exit 0" "$RC" "0"
assert_eq "(14) decision accepted-emergency" "$(jq -r '.decision' "$REP")" "accepted-emergency"

# ============================================================================
# FAILURE-INJECTION: policy problems fail closed (exit 2)
# ============================================================================
RC=0; sh "$ENFORCE" --policy "$WORK/nope.json" --summary "$WORK/clean.json" --accepted-risks "$EMPTY_RISKS" --output "$WORK/x.json" >/dev/null 2>&1 || RC=$?
assert_eq "fail-closed: missing policy -> exit 2" "$RC" "2"
printf '{ broken\n' > "$WORK/malpol.json"
RC=0; sh "$ENFORCE" --policy "$WORK/malpol.json" --summary "$WORK/clean.json" --accepted-risks "$EMPTY_RISKS" --output "$WORK/x.json" >/dev/null 2>&1 || RC=$?
assert_eq "fail-closed: malformed policy -> exit 2" "$RC" "2"
jq 'del(.required_scanners)' "$POLICY" > "$WORK/nonconf.json"
RC=0; sh "$ENFORCE" --policy "$WORK/nonconf.json" --summary "$WORK/clean.json" --accepted-risks "$EMPTY_RISKS" --output "$WORK/x.json" >/dev/null 2>&1 || RC=$?
assert_eq "fail-closed: non-conformant policy (no required_scanners) -> exit 2" "$RC" "2"

# waiver whose lifetime exceeds the policy maximum -> fail closed
cat > "$WORK/rlong.json" <<'JSON'
{"version":"1","risks":[{"id":"RL","gate":"high_vulnerabilities","owner":"alice","approved_by":"bob","issue":"https://tracker/l","scanner":"grype","category":"dependency_vulnerabilities","finding_id":"CVE-HN","severity":"high","reason":"x","created_at":"2999-01-01","expires_at":"2999-12-31","status":"approved","scope":"finding"}]}
JSON
run_enforce "$WORK/s3.json" "$WORK/rlong.json"
assert_eq "fail-closed: waiver lifetime over policy max -> exit 2" "$RC" "2"

# blanket (scope=scanner) suppression -> prohibited -> fail closed
cat > "$WORK/rblanket.json" <<'JSON'
{"version":"1","risks":[{"id":"RB","gate":"high_vulnerabilities","owner":"alice","approved_by":"bob","issue":"https://tracker/b","scanner":"grype","category":"dependency_vulnerabilities","finding_id":"CVE-HN","severity":"high","reason":"x","created_at":"2999-01-01","expires_at":"2999-02-01","status":"approved","scope":"scanner"}]}
JSON
run_enforce "$WORK/s3.json" "$WORK/rblanket.json"
assert_eq "fail-closed: blanket scanner suppression prohibited -> exit 2" "$RC" "2"

# ============================================================================
# NORMALIZER: raw digest + freshness + malformed-report fail-closed
# ============================================================================
mkdir -p "$WORK/raw"
printf '{"results":[]}\n' > "$WORK/raw/osv.json"
cat > "$WORK/manifest.json" <<JSON
{
  "targets": { "expected": 3, "scanned": 3 },
  "scanners": [
    { "name": "osv-scanner", "category": "dependency_vulnerabilities", "applicable": true, "status": "success", "version": "2.3.8", "raw_report": "$WORK/raw/osv.json", "targets_scanned": 3,
      "findings": [ { "id": "CVE-N", "scanner": "osv-scanner", "category": "dependency_vulnerabilities", "severity": "high", "fix_available": true, "reference": "CVE-N" } ] }
  ]
}
JSON
NRC=0; sh "$NORMALIZE" --manifest "$WORK/manifest.json" --output "$WORK/norm.json" >/dev/null 2>&1 || NRC=$?
assert_eq "normalize: valid manifest -> exit 0" "$NRC" "0"
if [ "$NRC" -eq 0 ]; then
	assert_eq "normalize: raw report digest computed" "$(jq -r '.scanners[0].raw_report_digest | startswith("sha256:")' "$WORK/norm.json")" "true"
	assert_eq "normalize: finding carried through" "$(jq -r '.findings | length' "$WORK/norm.json")" "1"
	assert_eq "normalize: high count derived" "$(jq -r '.summary.high_vulnerabilities' "$WORK/norm.json")" "1"
fi
printf '{ broken\n' > "$WORK/raw/bad.json"
jq --arg p "$WORK/raw/bad.json" '.scanners[0].raw_report=$p' "$WORK/manifest.json" > "$WORK/manifest-bad.json"
NRC=0; sh "$NORMALIZE" --manifest "$WORK/manifest-bad.json" --output "$WORK/normbad.json" >/dev/null 2>&1 || NRC=$?
assert_eq "normalize: malformed raw report -> exit 2 (fail closed)" "$NRC" "2"

printf '\n261-production-security: %d failure(s)\n' "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
printf 'All production-security assertions passed.\n'
exit 0
