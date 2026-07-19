#!/bin/sh
# Sentinel Shield prod test — collector severity mapping (audit PR B).
#
# Every check here targets a mapping that produced a WRONG GATE VERDICT on real scanner
# output. Two failure directions are covered, because both are defects:
#
#   UNDER-blocking — a real finding lands in a bucket that does not gate, or vanishes:
#     osv-scanner collapsed CRITICAL into high; codeql could never emit a critical;
#     composer-audit dropped advisories with no severity; trufflehog dropped unverified
#     secrets; trivy ignored misconfigurations and secrets entirely.
#
#   OVER-blocking — a clean run fails, or a non-security finding blocks a security gate:
#     php-style/php-syntax counted SCANNED FILES rather than violations, so a clean sweep
#     failed permanently with a count that scaled with repo size; eslint mapped lint
#     warnings to medium_vulnerabilities and double-counted security errors; semgrep
#     mapped INFO to a blocking bucket, contradicting docs/severity-policy.md.
#
# Each collector also gets a malformed/unknown-shape probe: a mapping fix is worthless if
# the collector silently reads garbage as clean.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss267)
trap 'rm -rf -- "$WORK"' EXIT INT TERM
COLL="$ROOT/scripts/collectors"

# m <collector> <json> <jq-projection> — run a collector over inline JSON and project a field.
m() {
	printf '%s' "$2" > "$WORK/in.json"
	sh "$COLL/$1" --input "$WORK/in.json" 2>/dev/null | jq -r "$3"
}
# sev <collector> <json> — "critical:high:medium" from the emitted summary.
sev() { m "$1" "$2" '"\(.summary.critical_vulnerabilities):\(.summary.high_vulnerabilities):\(.summary.medium_vulnerabilities)"'; }

# --- php-style: violations, not scanned files --------------------------------
PHPCS_CLEAN='{"totals":{"errors":0,"warnings":0},"files":{"a.php":{"errors":0,"warnings":0},"b.php":{"errors":0,"warnings":0}}}'
check "php-style: clean sweep over 2 files is 0 violations" \
	"$(m php-style.sh "$PHPCS_CLEAN" '.summary.style_violations')" "0"
check "php-style: clean sweep PASSES (was a permanent strict failure)" \
	"$(m php-style.sh "$PHPCS_CLEAN" '.status')" "pass"
check "php-style: totals.errors + totals.warnings are the count" \
	"$(m php-style.sh '{"totals":{"errors":3,"warnings":2},"files":{"a.php":{"errors":3,"warnings":2}}}' '.summary.style_violations')" "5"
check "php-style: per-file counts when totals are absent" \
	"$(m php-style.sh '{"files":{"a.php":{"errors":3,"warnings":1}}}' '.summary.style_violations')" "4"
# `.files` also appears as an ARRAY of per-file records (the shape the engine's own
# mode-readiness fixture uses). Still per-FINDING: a record with no violations counts 0.
check "php-style: files-as-array counts violations, not files" \
	"$(m php-style.sh '{"files":[{"violations":["x","y"]},{"violations":["z"]}]}' '.summary.style_violations')" "3"
check "php-style: files-as-array with no violations is clean" \
	"$(m php-style.sh '{"files":[{"name":"a.php","violations":[]},{"name":"b.php","violations":[]}]}' '.summary.style_violations')" "0"
# PHP-CS-Fixer lists ONLY files that needed fixing, so each entry IS a finding — the
# opposite of the phpcs object, which lists every scanned file. Conflating the two is what
# made a clean phpcs sweep report one violation per file.
check "php-style: php-cs-fixer entries count as findings" \
	"$(m php-style.sh '{"files":[{"name":"a.php","appliedFixers":["braces"]},{"name":"b.php","appliedFixers":["single_quote"]}]}' '.summary.style_violations')" "2"

# --- php-syntax: .files is the LINTED set, not the failing set ---------------
check "php-syntax: 2 files linted clean is 0 errors" \
	"$(m php-syntax.sh '{"files":{"a.php":{},"b.php":{}}}' '.summary.php_syntax_errors')" "0"
check "php-syntax: clean lint PASSES (was blocking from baseline)" \
	"$(m php-syntax.sh '{"files":{"a.php":{},"b.php":{}}}' '.status')" "pass"
check "php-syntax: explicit error count is honoured" \
	"$(m php-syntax.sh '{"errors":2}' '.summary.php_syntax_errors')" "2"
check "php-syntax: an array of error records is counted" \
	"$(m php-syntax.sh '[{"file":"a.php"},{"file":"b.php"},{"file":"c.php"}]' '.summary.php_syntax_errors')" "3"

# --- osv-scanner: preserve severity ------------------------------------------
check "osv: a CRITICAL CVE is critical, not high" \
	"$(sev osv-scanner.sh '{"results":[{"packages":[{"vulnerabilities":[{"database_specific":{"severity":"CRITICAL"}}]}]}]}')" "1:0:0"
check "osv: HIGH and MODERATE land in their own buckets" \
	"$(sev osv-scanner.sh '{"results":[{"packages":[{"vulnerabilities":[{"database_specific":{"severity":"HIGH"}},{"database_specific":{"severity":"MODERATE"}}]}]}]}')" "0:1:1"
check "osv: an unclassifiable vulnerability is counted, not dropped" \
	"$(sev osv-scanner.sh '{"results":[{"packages":[{"vulnerabilities":[{"id":"X"}]}]}]}')" "0:0:1"
check "osv: clean report passes" "$(m osv-scanner.sh '{"results":[]}' '.status')" "pass"

# --- codeql: rule-level severity, and criticals are reachable ----------------
check "codeql: rule defaultConfiguration.level=error -> high (was medium)" \
	"$(sev codeql.sh '{"runs":[{"tool":{"driver":{"rules":[{"id":"r1","defaultConfiguration":{"level":"error"}}]}},"results":[{"ruleId":"r1"}]}]}')" "0:1:0"
check "codeql: security-severity 9.8 -> critical (was unreachable)" \
	"$(sev codeql.sh '{"runs":[{"tool":{"driver":{"rules":[{"id":"r1","properties":{"security-severity":"9.8"}}]}},"results":[{"ruleId":"r1"}]}]}')" "1:0:0"
check "codeql: security-severity 7.5 -> high" \
	"$(sev codeql.sh '{"runs":[{"tool":{"driver":{"rules":[{"id":"r1","properties":{"security-severity":"7.5"}}]}},"results":[{"ruleId":"r1"}]}]}')" "0:1:0"
check "codeql: per-result level still wins when present" \
	"$(sev codeql.sh '{"runs":[{"tool":{"driver":{"rules":[]}},"results":[{"ruleId":"r9","level":"error"}]}]}')" "0:1:0"

# --- eslint: channel separation, no double counting --------------------------
# 2 security errors (severity 2, security/ rule) inside errorCount:2, plus 3 lint warnings.
ESLINT='[{"errorCount":2,"warningCount":3,"messages":[{"severity":2,"ruleId":"security/detect-eval"},{"severity":2,"ruleId":"security/detect-eval"},{"severity":1,"ruleId":"no-unused-vars"}]}]'
check "eslint: lint warnings do NOT become medium_vulnerabilities" \
	"$(m eslint.sh "$ESLINT" '.summary.medium_vulnerabilities // 0')" "0"
check "eslint: security findings stay in high_vulnerabilities" \
	"$(m eslint.sh "$ESLINT" '.summary.high_vulnerabilities')" "2"
check "eslint: security errors are not ALSO counted as type_errors" \
	"$(m eslint.sh "$ESLINT" '.summary.type_errors')" "0"
check "eslint: plain lint errors remain type_errors" \
	"$(m eslint.sh '[{"errorCount":5,"warningCount":0,"messages":[{"severity":2,"ruleId":"no-undef"}]}]' '.summary.type_errors')" "5"

# --- semgrep: INFO never blocks; ERROR is not automatically critical ---------
check "semgrep: an INFO-only run does not fail the gate" \
	"$(m semgrep.sh '{"results":[{"extra":{"severity":"INFO"}}]}' '.status')" "warn"
check "semgrep: INFO contributes no gating count" \
	"$(sev semgrep.sh '{"results":[{"extra":{"severity":"INFO"}}]}')" "0:0:0"
check "semgrep: ERROR -> high (was critical, blocking from baseline)" \
	"$(sev semgrep.sh '{"results":[{"extra":{"severity":"ERROR"}}]}')" "0:1:0"
check "semgrep: only an explicit CRITICAL is critical" \
	"$(sev semgrep.sh '{"results":[{"extra":{"severity":"CRITICAL"}}]}')" "1:0:0"
# summary.* is additionalProperties:false — internal metadata must not leak into it.
check "semgrep: no internal _ keys leak into summary" \
	"$(m semgrep.sh '{"results":[{"extra":{"severity":"INFO"}}]}' '.summary | keys | map(select(startswith("_"))) | length')" "0"

# --- composer-audit: a severity-less advisory is still a vulnerability -------
check "composer-audit: advisory with NO severity is counted (was 0)" \
	"$(sev composer-audit.sh '{"advisories":{"pkg/a":[{"advisoryId":"X","cve":"CVE-1"}]}}')" "0:0:1"
check "composer-audit: labelled severities still bucket correctly" \
	"$(sev composer-audit.sh '{"advisories":{"p":[{"severity":"critical"},{"severity":"high"}]}}')" "1:1:0"
check "composer-audit: clean report passes" \
	"$(m composer-audit.sh '{"advisories":{}}' '.status')" "pass"

# --- trufflehog: unverified secrets are still secrets ------------------------
check "trufflehog: an UNVERIFIED secret is counted (was dropped)" \
	"$(m trufflehog.sh '[{"Verified":false}]' '.summary.secrets')" "1"
check "trufflehog: unverified findings fail the gate" \
	"$(m trufflehog.sh '[{"Verified":false}]' '.status')" "fail"
check "trufflehog: verified + unverified are both counted" \
	"$(m trufflehog.sh '[{"Verified":true},{"Verified":false}]' '.summary.secrets')" "2"
check "trufflehog: verified/unverified split is reported for triage" \
	"$(m trufflehog.sh '[{"Verified":true},{"Verified":false}]' '"\(.tool_report.verified):\(.tool_report.unverified)"')" "1:1"
check "trufflehog: clean report passes" "$(m trufflehog.sh '[]' '.status')" "pass"

# --- trivy: misconfigurations and secrets are their own channels -------------
check "trivy: Misconfigurations map to iac_violations (were ignored)" \
	"$(m trivy.sh '{"Results":[{"Misconfigurations":[{"Status":"FAIL"},{"Status":"FAIL"}]}]}' '.summary.iac_violations')" "2"
check "trivy: Secrets map to secrets (were ignored)" \
	"$(m trivy.sh '{"Results":[{"Secrets":[{"RuleID":"aws"}]}]}' '.summary.secrets')" "1"
check "trivy: a PASSing misconfiguration is not a violation" \
	"$(m trivy.sh '{"Results":[{"Misconfigurations":[{"Status":"PASS"}]}]}' '.summary.iac_violations')" "0"
check "trivy: misconfigurations are NOT counted as vulnerabilities" \
	"$(sev trivy.sh '{"Results":[{"Misconfigurations":[{"Status":"FAIL"}]}]}')" "0:0:0"
check "trivy: vulnerability mapping is unchanged" \
	"$(sev trivy.sh '{"Results":[{"Vulnerabilities":[{"Severity":"CRITICAL"}]}]}')" "1:0:0"

# --- checkov: multi-framework array output -----------------------------------
check "checkov: multi-framework ARRAY output is summed (was a crash)" \
	"$(m checkov.sh '[{"summary":{"failed":2}},{"summary":{"failed":3}}]' '.summary.iac_violations')" "5"
check "checkov: single-object output still works" \
	"$(m checkov.sh '{"summary":{"failed":4}}' '.summary.iac_violations')" "4"
check "checkov: clean array passes" \
	"$(m checkov.sh '[{"summary":{"failed":0}}]' '.status')" "pass"
# The array shape used to raise a jq type error and exit non-zero, failing the whole build.
printf '%s' '[{"summary":{"failed":1}}]' > "$WORK/in.json"
sh "$COLL/checkov.sh" --input "$WORK/in.json" >/dev/null 2>&1 && _rc=0 || _rc=$?
check "checkov: array output exits 0, not a build-breaking error" "$_rc" "0"

# --- malformed input ----------------------------------------------------------
# SCOPE NOTE, deliberately explicit: making an UNRECOGNIZED-BUT-VALID-JSON document fail
# closed belongs to the fail-closed-evidence work (ss_shape_or_fail), not to this PR. That
# helper does not exist on master, so asserting it here would either fail or force this
# branch to depend on the other — and the two must be mergeable in either order.
#
# After both land, gitleaks/trivy/semgrep/npm-audit/grype/osv-scanner/composer-audit/
# codeql/dependency-check/tests are shape-guarded. php-style, php-syntax, trufflehog and
# checkov still are NOT — an unrecognized document reads as a clean 0 for those four.
# Recorded here so it is not mistaken for covered ground.
#
# What IS asserted here: invalid JSON remains a hard error for a collector this PR edits.
printf 'not json {' > "$WORK/bad.json"
sh "$COLL/php-style.sh" --input "$WORK/bad.json" >/dev/null 2>&1 && _rc=0 || _rc=$?
check "invalid JSON still exits 2" "$_rc" "2"

# --- summary ------------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
	printf '\n267-collector-severity-mapping: ALL CHECKS PASSED\n'
else
	printf '\n267-collector-severity-mapping: FAILURES PRESENT\n'
fi
exit "$FAILED"
