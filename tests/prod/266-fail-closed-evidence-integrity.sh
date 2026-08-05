#!/bin/sh
# Sentinel Shield prod test — fail-closed evidence integrity (v2.0.2 security hotfix).
#
# THE INVARIANT THIS SUITE DEFENDS:
#   Absent, malformed, partial, skipped, unrecognized, negative or non-integer evidence
#   must FAIL CLOSED. "The scanner did not run" and "the scanner output could not be
#   parsed" must never read as "we are clean".
#
# Every check here FAILS against the pre-hotfix code. The headline case — an empty
# reports/raw/ passing `regulated`, the highest-assurance mode the engine offers — was
# reproduced end-to-end before the fix.
#
# Scope honesty: this proves the ENGINE's fail-closed behavior over fixtures. It is not
# consumer proof, and it does not claim the collector severity mappings are correct — those
# are separate, still-open audit findings (see docs/fail-closed-evidence.md).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
# check_ne <label> <actual> <forbidden> — assert a value is NOT the forbidden one.
check_ne() { if [ "$2" != "$3" ]; then pass "$1"; else fail "$1 (got the forbidden value '$3')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss266)
trap 'rm -rf -- "$WORK"' EXIT INT TERM

BUILD="$ROOT/scripts/build-security-summary.sh"
RESOLVE="$ROOT/scripts/resolve-gates.sh"
ENFORCE="$ROOT/scripts/enforce-gates.sh"
COLL="$ROOT/scripts/collectors"

# gate <summary> <mode> — resolve gates for <mode>, enforce, echo the exit code.
gate() {
	sh "$RESOLVE" --mode "$2" --output-dir "$WORK/g" --format env >/dev/null 2>&1
	sh "$ENFORCE" --gates-env "$WORK/g/sentinel-shield-gates.env" --summary "$1" \
		--output-dir "$WORK/g" --format json >/dev/null 2>&1 && printf 0 || printf '%s' "$?"
}
# cstat <collector> <json> — run a collector over inline JSON, echo "status:key=value...".
cstat() {
	printf '%s' "$2" > "$WORK/in.json"
	sh "$COLL/$1" --input "$WORK/in.json" 2>/dev/null | jq -r '.status'
}

# --- (1) empty reports/raw must not pass regulated ---------------------------
# THE headline defect. The builder invokes every collector even when its raw report is
# absent; each returns `unavailable` with a fully ZEROED summary and the merge sums those
# zeros into a pristine document. sbom + release-evidence are staged so those two gates
# cannot be what fails — the ONLY thing under test is "no scanner ran".
E="$WORK/empty"; mkdir -p "$E/raw" "$E/rep"
sh "$BUILD" --raw-dir "$E/raw" --output "$E/rep/s.json" --project-name t >/dev/null 2>&1
# Evidence is VALIDATED now (#237), so staging empty files no longer stages evidence —
# write a real SPDX document and a real attestation, otherwise the two gates under
# exclusion would be exactly what fails.
jq -n '{spdxVersion:"SPDX-2.3", SPDXID:"SPDXRef-DOCUMENT", name:"prod-test",
	creationInfo:{created:"2026-01-01T00:00:00Z", creators:["Tool: prod-test-1.0"]},
	packages:[{name:"pkg", SPDXID:"SPDXRef-pkg"}]}' > "$E/rep/sbom.spdx.json"
printf '# Release evidence\n\nProduced by the 266 fixture.\nScope: engine self-test.\n' \
	> "$E/rep/release-evidence.md"
# Valid CONTENT is no longer sufficient in an enforcing mode: an artifact nothing binds to
# this run is unattributed, and unattributed content is not evidence. Write the producer
# manifest a real handoff would produce, so the artifacts are attributed as well as valid.
_msha() { ss_sha256_file "$1" 2>/dev/null || printf ''; }
. "$ROOT/scripts/lib/sentinel-shield-common.sh" 2>/dev/null || true
jq -n --arg s "$(_msha "$E/rep/sbom.spdx.json")" --arg r "$(_msha "$E/rep/release-evidence.md")" \
	'{version:"1", files:[{path:"sbom.spdx.json", sha256:$s},
	                      {path:"release-evidence.md", sha256:$r}]}' \
	> "$E/rep/sentinel-shield-artifact-manifest.json"
sh "$BUILD" --raw-dir "$E/raw" --output "$E/rep/s.json" --project-name t >/dev/null 2>&1
check_ne "zero scanners: regulated does NOT pass"        "$(gate "$E/rep/s.json" regulated)" "0"
check_ne "zero scanners: strict does NOT pass"           "$(gate "$E/rep/s.json" strict)" "0"
# report-only/baseline are visibility/migration modes and never claimed evidence
# completeness; tightening them would be a breaking change, not a security fix.
check    "zero scanners: baseline unchanged (migration mode)"    "$(gate "$E/rep/s.json" baseline)" "0"
check    "zero scanners: report-only unchanged"                  "$(gate "$E/rep/s.json" report-only)" "0"

# A summary carrying REAL evidence must still pass regulated — the guard must not simply
# refuse everything.
cp "$E/rep/s.json" "$WORK/evid.json"
# A real regulated run is built with --profile, so it carries the tool-policy overlay the
# evidence gates need. The fixture is built without one (it is about scanner evidence, not
# applicability), so add the overlay's neutral values — otherwise the enforcer refuses it for
# the unrelated reason that evidence gates cannot be judged without the overlay.
jq '.tools.gitleaks = {"status":"pass","findings":0}
	| .summary += {required_tool_failures:0, tool_configuration_failures:0, tool_execution_failures:0,
		missing_coverage_evidence:false, missing_test_evidence:false, empty_test_suite:false,
		missing_architecture_evidence:false, missing_test_change_evidence:false,
		missing_behavior_specification:false, missing_acceptance_evidence:false}' \
	"$WORK/evid.json" > "$WORK/evid2.json"
check "a summary WITH evidence still passes regulated" "$(gate "$WORK/evid2.json" regulated)" "0"

# A hand-built summary with NO producers cannot certify an assurance mode. This was the
# documented residual gap ("a caller who hand-writes \"tools\": {} still bypasses this"):
# omission is not an external-evidence contract, so an empty — or absent — tools object is
# now refused exactly like an all-unavailable one.
jq '.tools = {}' "$WORK/evid.json" > "$WORK/notools.json"
check "hand-built summary with empty .tools is REFUSED in regulated" "$(gate "$WORK/notools.json" regulated)" "2"
check "hand-built summary with empty .tools is REFUSED in strict" "$(gate "$WORK/notools.json" strict)" "2"
jq 'del(.tools)' "$WORK/evid.json" > "$WORK/notoolskey.json"
check "a summary with NO tools key at all is REFUSED in regulated" "$(gate "$WORK/notoolskey.json" regulated)" "2"
# ...and report-only/baseline are unchanged: they are visibility/migration modes.
check "empty .tools still enforces in report-only (visibility mode)" "$(gate "$WORK/notools.json" report-only)" "0"

# --- (2) malformed / unrecognized scanner output -----------------------------
# A valid-JSON document whose SHAPE the collector does not understand is untrusted
# evidence. These previously returned status=pass with zeroed counts, so a scanner
# version bump that renamed a top-level key silently erased every finding.
check_ne "gitleaks: unrecognized shape is not a clean pass" \
	"$(cstat gitleaks.sh '{"results":[{"a":1},{"b":2}]}')" "pass"
check    "gitleaks: unrecognized shape -> execution-error" \
	"$(cstat gitleaks.sh '{"results":[{"a":1}]}')" "execution-error"
check    "gitleaks: native clean array still passes"     "$(cstat gitleaks.sh '[]')" "pass"
check    "gitleaks: native findings array still fails"   "$(cstat gitleaks.sh '[{"a":1}]')" "fail"
check    "semgrep: unrecognized shape -> execution-error" \
	"$(cstat semgrep.sh '{"findings":[{"extra":{"severity":"ERROR"}}]}')" "execution-error"
check    "semgrep: native clean still passes"            "$(cstat semgrep.sh '{"results":[]}')" "pass"
check    "trivy: unrecognized shape -> execution-error" \
	"$(cstat trivy.sh '{"Findings":[{"Severity":"CRITICAL"}]}')" "execution-error"
check    "trivy: native clean still passes"              "$(cstat trivy.sh '{"Results":[]}')" "pass"
check    "composer-audit: unrecognized shape -> execution-error" \
	"$(cstat composer-audit.sh '{"packages":[]}')" "execution-error"
check    "codeql: unrecognized shape -> execution-error" \
	"$(cstat codeql.sh '{"findings":[]}')" "execution-error"
check    "tests: empty {} is not a clean test report" \
	"$(cstat tests.sh '{}')" "execution-error"
check    "tests: a real report still passes"             "$(cstat tests.sh '{"tests":9,"failures":0}')" "pass"

# Invalid JSON remains a hard exit 2 (pre-existing contract, re-asserted).
printf 'not json {' > "$WORK/bad.json"
sh "$COLL/gitleaks.sh" --input "$WORK/bad.json" >/dev/null 2>&1 && _rc=0 || _rc=$?
check "invalid JSON still exits 2" "$_rc" "2"

# --- (3) count validation ----------------------------------------------------
# Counts are SUMMED across collectors, so a negative one cancels another scanner's real
# findings. Floats/strings were coerced to a clean 0 by the enforcer.
check "npm-audit: negative count -> execution-error" \
	"$(cstat npm-audit.sh '{"metadata":{"vulnerabilities":{"critical":-99,"high":0,"moderate":0}}}')" "execution-error"
check "npm-audit: float count -> execution-error" \
	"$(cstat npm-audit.sh '{"metadata":{"vulnerabilities":{"critical":1.5,"high":0,"moderate":0}}}')" "execution-error"
check "npm-audit: valid counts still map" \
	"$(cstat npm-audit.sh '{"metadata":{"vulnerabilities":{"critical":2,"high":1,"moderate":0}}}')" "fail"

# A negative count must not be able to cancel a real finding through the merge.
N="$WORK/neg"; mkdir -p "$N/raw"
printf '%s' '{"Results":[{"Vulnerabilities":[{"Severity":"CRITICAL"},{"Severity":"CRITICAL"}]}]}' > "$N/raw/trivy.json"
printf '%s' '{"metadata":{"vulnerabilities":{"critical":-99,"high":0,"moderate":0}}}' > "$N/raw/npm-audit.json"
sh "$BUILD" --raw-dir "$N/raw" --output "$N/s.json" --project-name t >/dev/null 2>&1
_crit=$(jq -r '.summary.critical_vulnerabilities' "$N/s.json")
if [ "$_crit" -ge 2 ] 2>/dev/null; then
	pass "a negative count cannot cancel real findings (critical=$_crit)"
else
	fail "a negative count cancelled real findings (critical=$_crit, expected >= 2)"
fi

# The enforcer itself must reject malformed counts rather than reading them as 0.
S="$WORK/enf"; mkdir -p "$S"
cp "$WORK/evid2.json" "$S/base.json"
jq '.summary.iac_violations = 3.5'      "$S/base.json" > "$S/float.json"
jq '.summary.dast_findings = -5'        "$S/base.json" > "$S/negative.json"
jq '.summary.iac_violations = "nan"'    "$S/base.json" > "$S/string.json"
check "enforcer: float count fails closed"    "$(gate "$S/float.json" regulated)" "2"
check "enforcer: negative count fails closed" "$(gate "$S/negative.json" regulated)" "2"
check "enforcer: string count fails closed"   "$(gate "$S/string.json" regulated)" "2"
# An ABSENT key is back-compat ONLY while the gate is disabled, and only for a summary that
# declares no gate contract. Reading it as 0 for an ENABLED gate is how a v1/v2.0 summary was
# replayed under a newer, stricter gate set.
jq 'del(.summary.iac_violations)' "$S/base.json" > "$S/absent.json"
check "enforcer: an absent ENABLED-gate key is refused in regulated" "$(gate "$S/absent.json" regulated)" "2"
check "enforcer: an absent ENABLED-gate key is refused in strict" "$(gate "$S/absent.json" strict)" "2"
# ...and the visibility modes keep the documented tolerance so a migration is not bricked.
check "enforcer: an absent key still reads as 0 in baseline (legacy tolerance)" "$(gate "$S/absent.json" baseline)" "0"
# A summary that DECLARES the current contract gets no tolerance anywhere: the omission is a
# build defect rather than an older evidence contract.
# high_vulnerabilities is enabled from baseline upward, so this isolates "declared contract
# must be complete" from "which gates a mode enables".
jq '.gate_contract_version = "2.2" | del(.summary.high_vulnerabilities)' "$S/base.json" > "$S/absent-declared.json"
check "enforcer: a DECLARED contract must be complete (baseline too)" "$(gate "$S/absent-declared.json" baseline)" "2"

# --- (4) gate-flag parsing ---------------------------------------------------
# A flag that cannot be read is a configuration error, never a disabled gate.
sh "$RESOLVE" --mode regulated --output-dir "$WORK/g" --format env >/dev/null 2>&1
GENV="$WORK/g/sentinel-shield-gates.env"
jq '.summary.secrets = 5' "$S/base.json" > "$S/secrets.json"
# "TRUE" is a canonical spelling: the gate must be ENFORCED (and therefore fail on 5
# secrets), not silently skipped as it was when compared literally against "true".
sed 's/^SENTINEL_SHIELD_FAIL_ON_SECRETS=.*/SENTINEL_SHIELD_FAIL_ON_SECRETS=TRUE/' "$GENV" > "$WORK/g/upper.env"
sh "$ENFORCE" --gates-env "$WORK/g/upper.env" --summary "$S/secrets.json" \
	--output-dir "$WORK/g" --format json >/dev/null 2>&1 && _rc=0 || _rc=$?
check_ne "FAIL_ON_SECRETS=TRUE does not silently skip the gate" "$_rc" "0"
if [ -f "$WORK/g/sentinel-shield-enforcement.json" ]; then
	check "FAIL_ON_SECRETS=TRUE actually FAILS on 5 secrets" \
		"$(jq -r '[.failed_gates[]?] | index("secrets") | if . == null then "no" else "yes" end' "$WORK/g/sentinel-shield-enforcement.json")" "yes"
fi
# A non-boolean value is a configuration error.
sed 's/^SENTINEL_SHIELD_FAIL_ON_SECRETS=.*/SENTINEL_SHIELD_FAIL_ON_SECRETS=maybe/' "$GENV" > "$WORK/g/bogus.env"
sh "$ENFORCE" --gates-env "$WORK/g/bogus.env" --summary "$S/secrets.json" \
	--output-dir "$WORK/g" --format json >/dev/null 2>&1 && _rc=0 || _rc=$?
check "a non-boolean gate flag fails closed (exit 2)" "$_rc" "2"
# A truncated/tampered gates.env with the flags stripped must not pass silently.
grep -v '^SENTINEL_SHIELD_FAIL_ON_' "$GENV" > "$WORK/g/stripped.env"
sh "$ENFORCE" --gates-env "$WORK/g/stripped.env" --summary "$S/secrets.json" \
	--output-dir "$WORK/g" --format json >/dev/null 2>&1 && _rc=0 || _rc=$?
check "a gates.env with no FAIL_ON_ flags fails closed" "$_rc" "2"

# --- (5) one-of groups require evidence, not a file ---------------------------
O="$WORK/oneof"; mkdir -p "$O/raw" "$O/tgt"
# oneof_status — build with the laravel profile and echo the php-tests group status.
oneof_status() {
	sh "$BUILD" --raw-dir "$O/raw" --output "$O/s.json" --profile laravel --target "$O/tgt" >/dev/null 2>&1
	jq -r '.one_of_groups["php-tests"].status // "absent"' "$O/s.json"
}
printf '{}' > "$O/raw/tests.json"
check "one-of: an empty {} report does NOT satisfy a required group" "$(oneof_status)" "unsatisfied"
printf '%s' '{"tests":12,"failures":0,"errors":0}' > "$O/raw/tests.json"
check "one-of: real passing test evidence satisfies the group"       "$(oneof_status)" "satisfied"
printf '%s' '{"tests":12,"failures":3,"errors":0}' > "$O/raw/tests.json"
check "one-of: a FAILING suite still satisfies it (the suite RAN)"   "$(oneof_status)" "satisfied"
printf '%s' '{"status":"unavailable"}' > "$O/raw/tests.json"
check "one-of: an honest 'unavailable' does not satisfy it"          "$(oneof_status)" "unsatisfied"

# --- (6) expired exceptions propagate ----------------------------------------
# A collector-reported expiry was overwritten by the exceptions.json count on the way into
# the summary, silently discarding the finding.
X="$WORK/exc"; mkdir -p "$X/raw"
printf '%s' '{"tool":"test-change-evidence","status":"findings","production_change_without_test_change":0,"expired_waivers":0}' > "$X/raw/probe.json"
# Exception evidence is a RECORD set now (#242): three expired records, not a forged 3.
jq -n '{version:"1", exceptions: [ range(3) | {
		id: ("EX-\(.)"), type: "vulnerability", scope: "repo", owner: "plat",
		approved_by: "sec", created_at: "2000-01-01", expires_at: "2000-02-01",
		reason: "self-test", source: "manual" } ]}' > "$X/exceptions.json"
mkdir -p "$X/out"; cp "$X/exceptions.json" "$X/out/exceptions.json"
sh "$BUILD" --raw-dir "$X/raw" --output "$X/out/s.json" --project-name t >/dev/null 2>&1
check "expired exceptions from the exceptions file survive the merge" \
	"$(jq -r '.summary.expired_exceptions' "$X/out/s.json")" "3"
# expired_exceptions blocks in EVERY mode, including report-only.
check_ne "expired exceptions block even in report-only" "$(gate "$X/out/s.json" report-only)" "0"

# --- (7) architecture runner: no project-controlled execution ----------------
# The scanned repository's own policy file supplied a shell string that the runner passed
# straight to `sh -c` — arbitrary code execution in the gate runner, granted to anyone who
# can open a pull request.
A="$WORK/arch"; mkdir -p "$A/.sentinel-shield"
PROOF="$WORK/rce-proof.txt"
cat > "$A/.sentinel-shield/architecture-policy.yaml" <<EOF
architecture:
  enabled: true
  tools:
    architecture_tests:
      enabled: true
      command: "echo pwned > $PROOF; true"
EOF
rm -f "$PROOF"
( cd "$A" && sh "$ROOT/scripts/runners/architecture-tests.sh" --output "$A/out.json" ) >/dev/null 2>&1 || true
if [ -f "$PROOF" ]; then
	fail "the scanned project's YAML command was EXECUTED by the gate runner"
else
	pass "a project-supplied architecture command is refused, not executed"
fi
check "refusal is recorded as execution-error, not a pass" \
	"$(jq -r '.status' "$A/out.json" 2>/dev/null)" "execution-error"

# An exit code is not architecture evidence: `true` must not manufacture a clean report.
( cd "$A" && sh "$ROOT/scripts/runners/architecture-tests.sh" --output "$A/rc.json" --command 'true' ) >/dev/null 2>&1 || true
check_ne "an exit-0 command with no JSON does NOT manufacture a clean pass" \
	"$(jq -r '.status' "$A/rc.json" 2>/dev/null)" "pass"

# --- (8) JSON redaction -------------------------------------------------------
# The generic catch-all rule's value class excluded the double-quote character, so in JSON
# — where the byte after `": "` IS a quote — it could never match. JSON is the format the
# summary, the raw reports and the event journal are all persisted in.
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$ROOT/scripts/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/redaction.sh
. "$ROOT/scripts/lib/redaction.sh"
# redacted <text> — pipe through the redactor.
redacted() { printf '%s\n' "$1" | rd_redact_stream 2>/dev/null; }
# has_secret <text> <needle> — "leaked" when the needle survives redaction.
has_secret() { case "$(redacted "$1")" in *"$2"*) printf 'leaked' ;; *) printf 'redacted' ;; esac; }

check "JSON: GITHUB_TOKEN value is redacted" \
	"$(has_secret '{"GITHUB_TOKEN": "ghp_examplesecretvalue1234"}' 'ghp_examplesecretvalue1234')" "redacted"
check "JSON: camelCase apiKey value is redacted" \
	"$(has_secret '{"apiKey": "AbCdEf1234567890XyZw"}' 'AbCdEf1234567890XyZw')" "redacted"
check "JSON: underscore _SECRET value is redacted" \
	"$(has_secret '{"SOME_SECRET": "s3cr3tvalue0987654321"}' 's3cr3tvalue0987654321')" "redacted"
check "JSON: nested npm_token value is redacted" \
	"$(has_secret '{"a":{"npm_token":"npm_abcdef1234567"},"b":2}' 'npm_abcdef1234567')" "redacted"
check "JSON: lowercase password value is redacted" \
	"$(has_secret '{"password":"hunter2hunter2xyz"}' 'hunter2hunter2xyz')" "redacted"
# Over-redaction corrupts real evidence, which is its own integrity failure.
check "no over-redaction: \"monkey\" is not treated as a key" \
	"$(has_secret '{"monkey": "banana"}' 'banana')" "leaked"
check "no over-redaction: \"keyboard_layout\" is not a secret" \
	"$(has_secret '{"keyboard_layout": "qwerty"}' 'qwerty')" "leaked"
check "no over-redaction: \"tokenizer\" is not a secret" \
	"$(has_secret '{"tokenizer": "bpe"}' 'bpe')" "leaked"

# --- summary ------------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
	printf '\n266-fail-closed-evidence-integrity: ALL CHECKS PASSED\n'
else
	printf '\n266-fail-closed-evidence-integrity: FAILURES PRESENT\n'
fi
exit "$FAILED"
