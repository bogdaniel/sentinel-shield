#!/bin/sh
# Sentinel Shield prod test — finding-scoped accepted risks beyond unsafe_docker (issue #89).
#
# Governance said finding-scoped suppression was the safe default and broad `scope: gate`
# suppression was discouraged — but finding scope existed ONLY for unsafe_docker. To accept a
# single medium vulnerability an adopter had to suppress the WHOLE gate, and that record then
# also covered every unrelated medium finding that appeared later. The schema reserved
# `components` and `fingerprints` without enforcing them, so the product implied a capability
# it did not have.
#
# Everything here runs offline against fabricated raw scanner reports: no scanner is invoked
# and no assertion is satisfied by a skip.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
NORM="$ROOT/scripts/normalize-findings.sh"
ENFORCE="$ROOT/scripts/enforce-gates.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$NORM" ] || { fail "missing scripts/normalize-findings.sh"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# Fixture: two medium findings in different packages, from two scanners.
# ---------------------------------------------------------------------------
mkfix() { # mkfix <name> -> dir
	_d="$WORK/$1"; mkdir -p "$_d/reports/raw"
	cat > "$_d/reports/raw/grype.json" <<'JSON'
{"matches":[
 {"vulnerability":{"id":"GHSA-lodash","severity":"Medium"},"artifact":{"name":"lodash","version":"4.17.20","locations":[{"path":"package-lock.json"}]}},
 {"vulnerability":{"id":"CVE-2024-HIGH","severity":"High"},"artifact":{"name":"other","version":"1.0.0","locations":[{"path":"package-lock.json"}]}}
]}
JSON
	cat > "$_d/reports/raw/trivy-fs.json" <<'JSON'
{"Results":[{"Target":"composer.lock","Vulnerabilities":[
 {"VulnerabilityID":"CVE-2024-SYMFONY","PkgName":"symfony/http-kernel","InstalledVersion":"5.4.1","Severity":"MEDIUM"}
]}]}
JSON
	jq '.summary.medium_vulnerabilities = 2' "$ROOT/templates/security-summary.example.json" > "$_d/reports/security-summary.json"
	sh "$ROOT/scripts/resolve-gates.sh" --mode strict --output-dir "$_d/reports" --format env >/dev/null 2>&1
	printf '%s' "$_d"
}

# enforce <dir> <accepted-risks-file> — echo the enforcer's exit code.
enforce() {
	_c=0
	sh "$ENFORCE" --summary "$1/reports/security-summary.json" \
		--gates-env "$1/reports/sentinel-shield-gates.env" \
		--accepted-risks "$2" --raw-dir "$1/reports/raw" \
		--output-dir "$1/reports" --format all >"$1/enforce.log" 2>&1 || _c=$?
	printf '%s' "$_c"
}
acct() { jq -r ".accepted_risks.medium_vulnerabilities.$2" "$1/reports/sentinel-shield-enforcement.json"; }

# risk <file> <extra-json> — write an approved, unexpired, owner-bound record.
risk() {
	jq -n --argjson extra "$2" '{version:"1", risks:[
		({ id:"AR-1", gate:"medium_vulnerabilities", scope:"finding",
		   owner:"sec@example.com", reason:"reviewed; compensating control",
		   expires_at:"2099-01-01", status:"approved" } + $extra) ]}' > "$1"
}

# ---------------------------------------------------------------------------
# 1. The normalizer emits a stable, versioned identity per finding.
# ---------------------------------------------------------------------------
D=$(mkfix norm)
_f=$(sh "$NORM" --gate medium_vulnerabilities --raw-dir "$D/reports/raw")
check "normalizer emits exactly the MEDIUM findings" "$(printf '%s' "$_f" | jq 'length')" 2
check "high-severity findings are not in the medium identity set" "$(printf '%s' "$_f" | jq '[.[] | select(.severity != "medium")] | length')" 0
check "fingerprints carry the algorithm version" "$(printf '%s' "$_f" | jq '[.[] | select(.fingerprint | startswith("ss-fp/1|"))] | length')" 2
check "identities are unique" "$(printf '%s' "$_f" | jq '[.[].fingerprint] | unique | length')" 2
_f2=$(sh "$NORM" --gate medium_vulnerabilities --raw-dir "$D/reports/raw")
check "the normalizer is deterministic across runs" "$(printf '%s' "$_f2" | jq -c .)" "$(printf '%s' "$_f" | jq -c .)"
check "an unsupported gate is rejected" "$(_c=0; sh "$NORM" --gate secrets >/dev/null 2>&1 || _c=$?; printf '%s' "$_c")" 2
check "an unknown argument is rejected" "$(_c=0; sh "$NORM" --wat >/dev/null 2>&1 || _c=$?; printf '%s' "$_c")" 2

# ---------------------------------------------------------------------------
# 2. THE ISSUE: one medium vulnerability can be accepted without accepting the others.
# ---------------------------------------------------------------------------
D=$(mkfix one)
risk "$D/ar.json" '{"components":["lodash"]}'
check "accepting ONE component leaves the other medium finding failing" "$(enforce "$D" "$D/ar.json")" 1
check "  accepted count" "$(acct "$D" accepted)" 1
check "  unaccepted count" "$(acct "$D" unaccepted)" 1
check "  raw count is preserved (never zeroed)" "$(acct "$D" total)" 2
check "  scope is reported as finding" "$(acct "$D" scope)" "finding"
check "  the fingerprint algorithm is reported" "$(acct "$D" fingerprint_algorithm)" "ss-fp/1"

D=$(mkfix both)
risk "$D/ar.json" '{"components":["lodash","symfony/http-kernel"]}'
check "accepting BOTH components passes the gate" "$(enforce "$D" "$D/ar.json")" 0
check "  both are accounted as accepted" "$(acct "$D" accepted)" 2

# ---------------------------------------------------------------------------
# 3. Matching dimensions: fingerprint, advisory id, file — and their negatives.
# ---------------------------------------------------------------------------
D=$(mkfix fp)
risk "$D/ar.json" '{"fingerprints":["ss-fp/1|grype|GHSA-lodash|lodash|4.17.20|package-lock.json","ss-fp/1|trivy-fs|CVE-2024-SYMFONY|symfony/http-kernel|5.4.1|composer.lock"]}'
check "exact fingerprints accept exactly those findings" "$(enforce "$D" "$D/ar.json")" 0

D=$(mkfix fp-stale)
risk "$D/ar.json" '{"fingerprints":["ss-fp/1|grype|GHSA-lodash|lodash|4.17.19|package-lock.json"]}'
check "a STALE fingerprint (package version bumped) no longer matches" "$(enforce "$D" "$D/ar.json")" 1
check "  nothing was accepted by the stale record" "$(acct "$D" accepted)" 0

D=$(mkfix rule)
risk "$D/ar.json" '{"components":["lodash"],"rule_ids":["GHSA-lodash"]}'
check "component + advisory id matches the intended finding" "$(enforce "$D" "$D/ar.json")" 1
check "  exactly one accepted" "$(acct "$D" accepted)" 1

D=$(mkfix rule-wrong)
risk "$D/ar.json" '{"components":["lodash"],"rule_ids":["GHSA-DIFFERENT"]}'
check "a DIFFERENT advisory for the same package is NOT accepted" "$(enforce "$D" "$D/ar.json")" 1
check "  nothing accepted" "$(acct "$D" accepted)" 0

D=$(mkfix dup-advisory)
# The same advisory id in another ecosystem must not be swept in by a component record.
risk "$D/ar.json" '{"rule_ids":["CVE-2024-SYMFONY"],"components":["symfony/http-kernel"]}'
check "a duplicate advisory across ecosystems only matches its own component" "$(enforce "$D" "$D/ar.json")" 1
check "  exactly one accepted" "$(acct "$D" accepted)" 1

D=$(mkfix file)
risk "$D/ar.json" '{"files":["composer.lock"]}'
check "a file-scoped record matches only findings in that file" "$(enforce "$D" "$D/ar.json")" 1
check "  exactly one accepted" "$(acct "$D" accepted)" 1

D=$(mkfix renamed)
risk "$D/ar.json" '{"components":["lodash"],"files":["moved/package-lock.json"]}'
check "a renamed/moved path no longer matches (basename+suffix only)" "$(enforce "$D" "$D/ar.json")" 1
check "  nothing accepted for the moved path" "$(acct "$D" accepted)" 0

# ---------------------------------------------------------------------------
# 4. Governance: invalid, expired, pending, ambiguous and never-suppressible.
# ---------------------------------------------------------------------------
D=$(mkfix expired)
jq -n '{version:"1", risks:[{id:"AR-1", gate:"medium_vulnerabilities", scope:"finding", components:["lodash","symfony/http-kernel"], owner:"o", reason:"r", expires_at:"2000-01-01", status:"approved"}]}' > "$D/ar.json"
check "an EXPIRED record suppresses nothing" "$(enforce "$D" "$D/ar.json")" 1
check "  it is counted as expired" "$(jq -r '.accepted_risks.expired_ignored' "$D/reports/sentinel-shield-enforcement.json")" 1

D=$(mkfix pending)
jq -n '{version:"1", risks:[{id:"AR-1", gate:"medium_vulnerabilities", scope:"finding", components:["lodash","symfony/http-kernel"], owner:"o", reason:"r", expires_at:"2099-01-01", status:"pending"}]}' > "$D/ar.json"
check "a PENDING record suppresses nothing" "$(enforce "$D" "$D/ar.json")" 1

D=$(mkfix noowner)
jq -n '{version:"1", risks:[{id:"AR-1", gate:"medium_vulnerabilities", scope:"finding", components:["lodash","symfony/http-kernel"], owner:"", reason:"r", expires_at:"2099-01-01", status:"approved"}]}' > "$D/ar.json"
check "an ownerless record suppresses nothing" "$(enforce "$D" "$D/ar.json")" 1

D=$(mkfix ambiguous)
jq -n '{version:"1", risks:[{id:"AR-1", gate:"medium_vulnerabilities", scope:"finding", owner:"o", reason:"r", expires_at:"2099-01-01", status:"approved"}]}' > "$D/ar.json"
check "an AMBIGUOUS finding-scoped record (no matching field) suppresses nothing" "$(enforce "$D" "$D/ar.json")" 1
check "  it is reported as legacy/unscoped" "$(jq -r '.accepted_risks.legacy_unscoped_ignored' "$D/reports/sentinel-shield-enforcement.json")" 1

D=$(mkfix neversup)
jq '.summary.secrets = 1' "$D/reports/security-summary.json" > "$D/s.json" && mv "$D/s.json" "$D/reports/security-summary.json"
jq -n '{version:"1", risks:[{id:"AR-S", gate:"secrets", scope:"gate", owner:"o", reason:"r", expires_at:"2099-01-01", status:"approved"},
                            {id:"AR-1", gate:"medium_vulnerabilities", scope:"finding", components:["lodash","symfony/http-kernel"], owner:"o", reason:"r", expires_at:"2099-01-01", status:"approved"}]}' > "$D/ar.json"
check "a NEVER-suppressible gate (secrets) still fails despite a record" "$(enforce "$D" "$D/ar.json")" 1
grep -q 'secrets' "$D/reports/sentinel-shield-enforcement.md" && pass "the secrets failure is reported" || fail "the secrets failure is not reported"

# ---------------------------------------------------------------------------
# 5. Fail-closed on evidence the enforcer cannot identify.
# ---------------------------------------------------------------------------
D=$(mkfix unreadable)
printf 'not-json{' > "$D/reports/raw/grype.json"
risk "$D/ar.json" '{"components":["lodash","symfony/http-kernel"]}'
check "an INVALID raw report cannot become a clean pass" "$(enforce "$D" "$D/ar.json")" 1
check "  the unidentifiable finding is counted as unaccepted" "$(acct "$D" unaccepted)" 1

D=$(mkfix missingraw)
rm -f "$D/reports/raw/grype.json" "$D/reports/raw/trivy-fs.json"
risk "$D/ar.json" '{"components":["lodash","symfony/http-kernel"]}'
check "MISSING raw reports cannot become a clean pass" "$(enforce "$D" "$D/ar.json")" 1
check "  every counted finding is unaccepted" "$(acct "$D" unaccepted)" 2

D=$(mkfix undercount)
# The summary counts MORE findings than the raw reports can identify (e.g. a scanner that
# reports only aggregate counts). The shortfall must be unaccepted.
jq '.summary.medium_vulnerabilities = 5' "$D/reports/security-summary.json" > "$D/s.json" && mv "$D/s.json" "$D/reports/security-summary.json"
risk "$D/ar.json" '{"components":["lodash","symfony/http-kernel"]}'
check "unidentifiable EXTRA findings fail closed" "$(enforce "$D" "$D/ar.json")" 1
check "  the shortfall is unaccepted" "$(acct "$D" unaccepted)" 3

# ---------------------------------------------------------------------------
# 6. Backward compatibility: broad scope:gate still works, and is surfaced as broad.
# ---------------------------------------------------------------------------
D=$(mkfix broad)
jq -n '{version:"1", risks:[{id:"AR-B", gate:"medium_vulnerabilities", scope:"gate", owner:"o", reason:"legacy broad record", expires_at:"2099-01-01", status:"approved"}]}' > "$D/ar.json"
check "an existing broad scope:gate record still suppresses" "$(enforce "$D" "$D/ar.json")" 0
check "  it is reported as broad, not as finding-scoped" "$(acct "$D" scope)" "gate"
grep -q 'BROAD' "$D/reports/sentinel-shield-enforcement.md" && pass "broad suppression is surfaced in the Markdown output" || fail "broad suppression is not surfaced in the Markdown output"
grep -qi 'broad' "$D/enforce.log" && pass "broad suppression is warned about at run time" || fail "broad suppression produces no warning"

D=$(mkfix norecord)
jq -n '{version:"1", risks:[]}' > "$D/ar.json"
check "with no record at all the gate simply fails on its count" "$(enforce "$D" "$D/ar.json")" 1
check "  and nothing is reported accepted" "$(acct "$D" accepted)" 0

# ---------------------------------------------------------------------------
# 7. The unsafe_docker contract is unchanged (no regression from generalizing).
# ---------------------------------------------------------------------------
D=$(mkfix docker)
jq '.summary.unsafe_docker = 1 | .summary.medium_vulnerabilities = 0' "$D/reports/security-summary.json" > "$D/s.json" && mv "$D/s.json" "$D/reports/security-summary.json"
printf '[{"code":"DL3018","level":"warning","file":"Dockerfile","line":3,"message":"pin versions"}]' > "$D/reports/raw/hadolint.json"
printf '[]' > "$D/reports/raw/docker-base-digest.json"
jq -n '{version:"1", risks:[{id:"AR-D", gate:"unsafe_docker", scope:"finding", rule_id:"DL3018", files:["Dockerfile"], owner:"o", reason:"r", expires_at:"2099-01-01", status:"approved"}]}' > "$D/ar.json"
check "unsafe_docker finding scope still accepts a matched finding" "$(enforce "$D" "$D/ar.json")" 0
jq -n '{version:"1", risks:[{id:"AR-D", gate:"unsafe_docker", scope:"finding", rule_id:"DL3008", files:["Dockerfile"], owner:"o", reason:"r", expires_at:"2099-01-01", status:"approved"}]}' > "$D/ar2.json"
check "unsafe_docker finding scope still rejects a different rule" "$(enforce "$D" "$D/ar2.json")" 1

# ---------------------------------------------------------------------------
# 8. Schema and shipped template agree with the implementation.
# ---------------------------------------------------------------------------
for _f in components fingerprints; do
	if jq -e --arg f "$_f" '.. | objects | select(has($f)) | .[$f].description | test("RESERVED")' schemas/accepted-risks.schema.json >/dev/null 2>&1; then
		fail "the schema still describes '$_f' as RESERVED while the enforcer implements it"
	else
		pass "the schema describes '$_f' as implemented"
	fi
done
jq -e '[.risks[] | select(.gate == "medium_vulnerabilities" and (.scope // "finding") == "finding")] | length >= 2' templates/accepted-risks.example.json >/dev/null 2>&1 \
	&& pass "the shipped example demonstrates finding-scoped medium records" \
	|| fail "the shipped example has no finding-scoped medium_vulnerabilities record"
jq -e '[.risks[] | select(.status != "pending")] | length == 0' templates/accepted-risks.example.json >/dev/null 2>&1 \
	&& pass "every example record is pending (an example never suppresses)" \
	|| fail "a shipped example record is not pending and could suppress"

# --- CodeRabbit round 2: an EMPTY dimension constrains nothing ----------------
# The eligibility filter used `has(…)`, which accepts a record whose every dimension is
# PRESENT BUT EMPTY, while the matcher treats an empty array as a wildcard. Such a record
# matched every finding while still reporting as the quiet `scope: finding` — the "one
# accepted risk silently covers everything" failure this model exists to prevent, reached
# through an empty array.
for _gate in unsafe_docker medium_vulnerabilities; do
	D="$WORK/empty-$_gate"; mkdir -p "$D/reports/raw"
	jq -n --arg g "$_gate" '{version:"1.1", risks:[{id:"oops", gate:$g, scope:"finding",
		rule_id:"", rule_ids:[], files:[], components:[], fingerprints:[],
		owner:"o", reason:"r", expires_at:"2099-01-01", status:"approved"}]}' > "$D/ar.json"
	jq --arg g "$_gate" '.tools = {"tests":{"status":"pass"}} | .summary[$g] = 2' \
		"$ROOT/templates/security-summary.example.json" > "$D/s.json"
	# medium_vulnerabilities is not enabled in baseline; strict enables both gates so the
	# suppression path is actually reached.
	sh "$ROOT/scripts/resolve-gates.sh" --mode strict --output-dir "$D" --format env >/dev/null 2>&1
	_c=0
	sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$D/sentinel-shield-gates.env" \
		--summary "$D/s.json" --accepted-risks "$D/ar.json" --output-dir "$D" --format json \
		>"$D/log" 2>&1 || _c=$?
	if [ "$_c" -eq 0 ]; then
		fail "$_gate: an all-empty finding-scope record SUPPRESSED the gate (wildcard through an empty array)"
	else
		pass "$_gate: an all-empty finding-scope record does not suppress anything"
	fi
	if grep -q 'ambiguous' "$D/log"; then
		pass "  and it is reported as ambiguous rather than silently applied"
	else
		fail "  but it was not reported as ambiguous: $(tail -2 "$D/log")"
	fi
	# A record that DOES constrain still works — the fix must not disable finding scope.
	jq -n --arg g "$_gate" '{version:"1.1", risks:[{id:"real", gate:$g, scope:"finding",
		rule_ids:["DL3018"], files:[], components:[], fingerprints:[],
		owner:"o", reason:"r", expires_at:"2099-01-01", status:"approved"}]}' > "$D/ar2.json"
	sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$D/sentinel-shield-gates.env" \
		--summary "$D/s.json" --accepted-risks "$D/ar2.json" --output-dir "$D" --format json \
		>"$D/log2" 2>&1 || true
	if grep -q 'ambiguous' "$D/log2"; then
		fail "  a record constrained by rule_ids alone is wrongly reported as ambiguous"
	else
		pass "  a record constrained by rule_ids alone is still finding-scoped"
	fi
done

# ---------------------------------------------------------------------------
# A finding with NO path must not destroy the accounting.
# ---------------------------------------------------------------------------
# Package-level advisories legitimately carry no file. The record's paths were normalized but
# the FINDING's was not, so `null | endswith(...)` aborted the whole jq program: the gate then
# reported "could not compute finding-scope accounting" and DISCARDED the matches that had
# already resolved. A finding with no path simply cannot satisfy a path-scoped record.
D=$(mkfix nopath)
jq 'del(.matches[0].artifact.locations)' "$D/reports/raw/grype.json" > "$D/g.tmp" \
	&& mv "$D/g.tmp" "$D/reports/raw/grype.json"
check "  the fixture really does produce a finding with no path" \
	"$(sh "$NORM" --gate medium_vulnerabilities --raw-dir "$D/reports/raw" | jq '[.[] | select(.file == "")] | length')" 1
risk "$D/ar.json" '{"files":["composer.lock"], "components":["symfony/http-kernel"]}'
check "a path-less finding does not abort the accounting" "$(enforce "$D" "$D/ar.json")" 1
check "  the path-scoped record still matched the finding that HAS that path" "$(acct "$D" accepted)" 1
check "  and the path-less finding is reported as unaccepted" "$(acct "$D" unaccepted)" 1
if grep -q 'could not compute finding-scope accounting' "$D/enforce.log"; then
	fail "  the accounting was thrown away for a perfectly normal finding shape"
else
	pass "  the accounting was computed, not discarded"
fi

# ---------------------------------------------------------------------------
# With NO finding-scope record the gate is an ordinary count gate — and the published
# accounting has to say so. It used to publish accepted:0/unaccepted:0 for a non-zero
# total, which reads as "nothing unaccepted" on a FAILED gate.
# ---------------------------------------------------------------------------
D=$(mkfix nofs)
# A record for a DIFFERENT gate: medium_vulnerabilities has no finding-scope record at all.
jq -n '{version:"1", risks:[
	{ id:"AR-OTHER", gate:"unsafe_docker", scope:"finding", rule_ids:["DL3018"],
	  owner:"o", reason:"r", expires_at:"2099-01-01", status:"approved" }]}' > "$D/ar.json"
check "with no finding-scope record the gate still fails" "$(enforce "$D" "$D/ar.json")" 1
check "  and the whole count is published as unaccepted" "$(acct "$D" unaccepted)" 2
check "  with nothing claimed as accepted" "$(acct "$D" accepted)" 0

# ---------------------------------------------------------------------------
# Multiple values within a dimension are ANY-match, and dimensions cross-gate (ALL must
# match). Asserted with every dimension carrying more than one value.
# ---------------------------------------------------------------------------
D=$(mkfix anymatch)
risk "$D/ar.json" '{"components":["lodash","not-installed"],
	"rule_ids":["GHSA-lodash","GHSA-absent"],
	"files":["package-lock.json","never.lock"]}'
check "any-match within each dimension accepts the finding that satisfies all three" "$(enforce "$D" "$D/ar.json")" 1
check "  exactly the matching finding is accepted" "$(acct "$D" accepted)" 1
check "  the other finding is untouched" "$(acct "$D" unaccepted)" 1
# One dimension that matches NOTHING must veto the record: dimensions are cross-gating.
D=$(mkfix crossgate)
risk "$D/ar.json" '{"components":["lodash","not-installed"],
	"rule_ids":["GHSA-lodash","GHSA-absent"],
	"files":["never.lock","also-never.lock"]}'
check "a dimension that matches nothing vetoes the record" "$(enforce "$D" "$D/ar.json")" 1
check "  nothing is accepted" "$(acct "$D" accepted)" 0

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '286-finding-scoped-suppression: ALL CHECKS PASSED\n'
	exit 0
fi
printf '286-finding-scoped-suppression: FAILURES PRESENT\n'
exit 1
