#!/bin/sh
# Sentinel Shield prod test — evidence and exception validation (#237, #242).
#
# #237  `present` meant `test -f`. Touching `reports/sbom.spdx.json` and
#       `reports/release-evidence.md` cleared two non-suppressible missing-evidence gates;
#       an empty, malformed, symlinked or unrelated file was indistinguishable from
#       verified evidence; and a previous run's artifacts authorised the current commit.
#
# #242  `reports/exceptions.json` was two unauthenticated integers. `{}` asserted clean
#       governance, a forged `expired: 0` hid every expired exception, and no count could
#       be audited, deduplicated or attributed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
BUILD="$ROOT/scripts/build-security-summary.sh"
MANIFEST="$ROOT/scripts/build-evidence-manifest.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

COMMIT_A=1111111111111111111111111111111111111111
COMMIT_B=2222222222222222222222222222222222222222

# fresh <name> — an isolated reports dir with an empty raw dir; echoes the dir.
fresh() { _d="$WORK/$1"; rm -rf "$_d"; mkdir -p "$_d/raw"; printf '%s' "$_d"; }
# good_sbom <dir>, good_release <dir> — evidence that SHOULD be accepted.
good_sbom() {
	jq -n '{spdxVersion:"SPDX-2.3", SPDXID:"SPDXRef-DOCUMENT", name:"prod-test",
		creationInfo:{created:"2026-01-01T00:00:00Z", creators:["Tool: prod-test-1.0"]},
		packages:[{name:"pkg", SPDXID:"SPDXRef-pkg"}]}' > "$1/sbom.spdx.json"
}
good_release() {
	printf '# Release evidence\n\nProduced by the 295 fixture.\nScope: engine self-test.\n' > "$1/release-evidence.md"
}
# build <dir> [args...] — run the builder, echoing its exit code.
build() { _d="$1"; shift; _c=0; sh "$BUILD" --raw-dir "$_d/raw" --output "$_d/s.json" "$@" >"$_d/log" 2>&1 || _c=$?; printf '%s' "$_c"; }
# ev <dir> <sbom|release_evidence> <field> — read an evidence field from the summary.
ev() { jq -r --arg k "$2" --arg f "$3" '.evidence[$k] | if $f == "present" then .present else .verification[$f] end' "$1/s.json"; }

# ---------------------------------------------------------------------------
# 1. #237 — presence is a verified state, not a filename.
# ---------------------------------------------------------------------------
D=$(fresh good); good_sbom "$D"; good_release "$D"
check "valid evidence builds" "$(build "$D")" 0
check "  the SBOM is present" "$(ev "$D" sbom present)" "true"
check "  the release evidence is present" "$(ev "$D" release_evidence present)" "true"
check "  missing_sbom is the inverse" "$(jq -r '.summary.missing_sbom' "$D/s.json")" "false"
check "  the verification records a checksum" \
	"$(jq -r '(.evidence.sbom.verification.sha256 // "") | test("^[0-9a-f]{64}$")' "$D/s.json")" "true"
check "  and says the content was validated but unattributed" "$(ev "$D" sbom reason)" "verified-content-unattributed"

# The headline defect: two touched filenames must not clear two gates.
D=$(fresh touched); : > "$D/sbom.spdx.json"; : > "$D/release-evidence.md"
check "touch-only evidence builds" "$(build "$D")" 0
check "  an empty SBOM is NOT present" "$(ev "$D" sbom present)" "false"
check "    and says why" "$(ev "$D" sbom reason)" "empty"
check "  an empty release file is NOT present" "$(ev "$D" release_evidence present)" "false"
check "  missing_sbom is set" "$(jq -r '.summary.missing_sbom' "$D/s.json")" "true"
check "  missing_release_evidence is set" "$(jq -r '.summary.missing_release_evidence' "$D/s.json")" "true"

# Content classes that must never count as evidence.
for _case in 'empty-object|{}|not-spdx' 'malformed|not json at all|malformed-json' 'no-packages|{"spdxVersion":"SPDX-2.3","SPDXID":"SPDXRef-DOCUMENT","name":"x","creationInfo":{"created":"2026-01-01T00:00:00Z","creators":["Tool: t"]},"packages":[]}|no-packages' 'no-producer|{"spdxVersion":"SPDX-2.3","SPDXID":"SPDXRef-DOCUMENT","name":"x","creationInfo":{"created":"2026-01-01T00:00:00Z","creators":[]},"packages":[{"name":"p","SPDXID":"SPDXRef-p"}]}|no-producer' 'not-a-document|{"spdxVersion":"SPDX-2.3","SPDXID":"SPDXRef-Package","name":"x","creationInfo":{"created":"2026-01-01T00:00:00Z","creators":["Tool: t"]},"packages":[{"name":"p","SPDXID":"SPDXRef-p"}]}|not-spdx-document' 'incomplete-package|{"spdxVersion":"SPDX-2.3","SPDXID":"SPDXRef-DOCUMENT","name":"x","creationInfo":{"created":"2026-01-01T00:00:00Z","creators":["Tool: t"]},"packages":[{"name":""}]}|incomplete-packages'; do
	_n=${_case%%|*}; _rest=${_case#*|}; _body=${_rest%|*}; _why=${_rest##*|}
	D=$(fresh "sbom-$_n"); printf '%s' "$_body" > "$D/sbom.spdx.json"; good_release "$D"
	build "$D" >/dev/null
	check "an SBOM that is $_n is not evidence" "$(ev "$D" sbom present)" "false"
	check "  rejected as $_why" "$(ev "$D" sbom reason)" "$_why"
done

# A symlinked artifact is refused rather than followed.
D=$(fresh symlink); good_sbom "$WORK"; ln -s "$WORK/sbom.spdx.json" "$D/sbom.spdx.json"; good_release "$D"
build "$D" >/dev/null
check "a symlinked SBOM is not evidence" "$(ev "$D" sbom present)" "false"
check "  rejected as a symlink" "$(ev "$D" sbom reason)" "symlink"

# A title with nothing under it is a touched filename, not an attestation.
D=$(fresh thin); good_sbom "$D"; printf '# Release evidence\n' > "$D/release-evidence.md"
build "$D" >/dev/null
check "a heading-only release file is not evidence" "$(ev "$D" release_evidence present)" "false"
check "  rejected as no-content" "$(ev "$D" release_evidence reason)" "no-content"
D=$(fresh noheading); good_sbom "$D"; printf 'some text\nmore text\nand more\n' > "$D/release-evidence.md"
build "$D" >/dev/null
check "release evidence with no heading is not evidence" "$(ev "$D" release_evidence reason)" "no-heading"

# ---------------------------------------------------------------------------
# 2. #237 — provenance binds the artifact to THIS run.
# ---------------------------------------------------------------------------
D=$(fresh bound); good_sbom "$D"; good_release "$D"
sh "$MANIFEST" --dir "$D" --repository acme/shield --run-id 42 --commit "$COMMIT_A" >/dev/null 2>&1 \
	|| fail "could not build the producer manifest"
check "manifest-bound evidence builds" "$(build "$D" --commit "$COMMIT_A")" 0
check "  the SBOM is verified against the manifest" "$(ev "$D" sbom provenance)" "verified"
check "  and present" "$(ev "$D" sbom present)" "true"

# Replay: the same artifacts, attested for a DIFFERENT commit.
check "replayed evidence builds" "$(build "$D" --commit "$COMMIT_B")" 0
check "  evidence attested for another commit is refused" "$(ev "$D" sbom provenance)" "commit-mismatch"
check "  so it is not present" "$(ev "$D" sbom present)" "false"
check "  and the missing-evidence gate is set" "$(jq -r '.summary.missing_sbom' "$D/s.json")" "true"

# Tamper: the manifest is for this commit, but the file changed after it was recorded.
D=$(fresh tamper); good_sbom "$D"; good_release "$D"
sh "$MANIFEST" --dir "$D" --repository acme/shield --run-id 42 --commit "$COMMIT_A" >/dev/null 2>&1
jq '.name = "tampered"' "$D/sbom.spdx.json" > "$D/t.json" && mv "$D/t.json" "$D/sbom.spdx.json"
build "$D" --commit "$COMMIT_A" >/dev/null
check "an artifact modified after the manifest was written is refused" "$(ev "$D" sbom provenance)" "digest-mismatch"
check "  and is not present" "$(ev "$D" sbom present)" "false"

# An unattributed artifact is accepted by default and refused under the strict flag.
D=$(fresh unattributed); good_sbom "$D"; good_release "$D"
build "$D" --commit "$COMMIT_A" >/dev/null
check "unattributed evidence is present by default" "$(ev "$D" sbom present)" "true"
check "  with the provenance stated as unbound" "$(ev "$D" sbom provenance)" "unbound"
build "$D" --commit "$COMMIT_A" --require-evidence-provenance >/dev/null
check "--require-evidence-provenance refuses unattributed evidence" "$(ev "$D" sbom present)" "false"
check "  naming it unattributed" "$(ev "$D" sbom reason)" "unattributed"

# ---------------------------------------------------------------------------
# 3. #242 — exception counts are derived from validated records.
# ---------------------------------------------------------------------------
# rec <id> <created> <expires> [extra] — one exception record.
rec() {
	_x="${4:-}"; [ -n "$_x" ] || _x='{}'
	jq -nc --arg id "$1" --arg c "$2" --arg e "$3" --argjson x "$_x" '
		{id:$id, type:"vulnerability", scope:"repo", owner:"plat", approved_by:"sec",
		 created_at:$c, expires_at:$e, reason:"prod-test", source:"manual"} + $x'
}
xf() { printf '{"version":"1","exceptions":%s}\n' "$2" > "$1/exceptions.json"; }

D=$(fresh exc-ok); good_sbom "$D"; good_release "$D"
xf "$D" "[$(rec EX-1 2000-01-01 2000-02-01), $(rec EX-2 2026-01-01 2099-01-01 '{"source":"accepted-risk"}')]"
check "a valid record set builds" "$(build "$D")" 0
check "  the expired count is DERIVED from the records" "$(jq -r '.exceptions.expired' "$D/s.json")" 1
check "  the active count is DERIVED from the records" "$(jq -r '.exceptions.active' "$D/s.json")" 1
check "  the records travel with the counts" "$(jq -r '.exceptions.records | length' "$D/s.json")" 2
check "  each record carries its derived status" \
	"$(jq -r '[.exceptions.records[] | .status] | sort | join(",")' "$D/s.json")" "active,expired"
check "  the per-source split is recorded" \
	"$(jq -c '.exceptions.by_source' "$D/s.json")" '{"accepted-risk":1,"manual":1}'
check "  and the expired-exception gate sees them" "$(jq -r '.summary.expired_exceptions' "$D/s.json")" 1

# A forged zero cannot hide an expired exception.
D=$(fresh exc-forged); good_sbom "$D"; good_release "$D"
printf '{"version":"1","active":0,"expired":0,"exceptions":[%s]}\n' "$(rec EX-1 2000-01-01 2000-02-01)" > "$D/exceptions.json"
check "a declared aggregate that contradicts the records fails the build" "$(build "$D")" 2
grep -q 'does not match the evidence' "$D/log" && pass "  the failure says the aggregate does not match" || fail "  the failure does not explain the mismatch"

# Count-only governance is no longer evidence.
for _body in '{}' '{"active":0,"expired":0}' '{"active":2,"expired":0}'; do
	D=$(fresh exc-countonly); good_sbom "$D"; good_release "$D"
	printf '%s' "$_body" > "$D/exceptions.json"
	check "a count-only exceptions file ($_body) fails closed" "$(build "$D")" 2
done
grep -q 'versioned record set' "$D/log" && pass "  the failure names the migration" || fail "  the failure does not name the migration"

# An ABSENT file is still the honest 'no exceptions' default.
D=$(fresh exc-absent); good_sbom "$D"; good_release "$D"
check "an absent exceptions file still builds" "$(build "$D")" 0
check "  with zero counts and no records" \
	"$(jq -c '[.exceptions.active, .exceptions.expired, (.exceptions.records|length)]' "$D/s.json")" "[0,0,0]"

# Record-level defects, each fail-closed.
for _case in \
	'dup|['"$(rec EX-1 2000-01-01 2099-01-01)"', '"$(rec EX-1 2000-01-01 2099-01-01)"']|duplicate id' \
	'baddate|['"$(rec EX-1 2000-01-01 2026-02-31)"']|not a real calendar date' \
	'impossible|['"$(rec EX-1 2000-01-01 9999-99-99)"']|not a real calendar date' \
	'backwards|['"$(rec EX-1 2026-06-01 2026-01-01)"']|created_at is after expires_at' \
	'self|['"$(rec EX-1 2000-01-01 2099-01-01 '{"approved_by":"plat"}')"']|self-approval' \
	'source|['"$(rec EX-1 2000-01-01 2099-01-01 '{"source":"whatever"}')"']|unknown source' \
	'status|['"$(rec EX-1 2000-01-01 2000-02-01 '{"status":"active"}')"']|contradicts its dates' \
	'badid|['"$(rec 'a b' 2000-01-01 2099-01-01)"']|not a stable token' \
	; do
	_n=${_case%%|*}; _rest=${_case#*|}; _arr=${_rest%|*}; _why=${_rest##*|}
	D=$(fresh "exc-$_n"); good_sbom "$D"; good_release "$D"
	xf "$D" "$_arr"
	check "an exception record with a $_n defect fails closed" "$(build "$D")" 2
	if grep -q "$_why" "$D/log"; then pass "  reported as: $_why"; else fail "  not reported as '$_why': $(tail -2 "$D/log")"; fi
done

# A missing required field is refused.
D=$(fresh exc-missing); good_sbom "$D"; good_release "$D"
printf '{"version":"1","exceptions":[{"id":"EX-1","type":"v","scope":"repo"}]}\n' > "$D/exceptions.json"
check "an exception record missing owner/approval/dates fails closed" "$(build "$D")" 2
# An unsupported version is refused.
D=$(fresh exc-version); good_sbom "$D"; good_release "$D"
printf '{"version":"2","exceptions":[]}\n' > "$D/exceptions.json"
check "an unsupported exceptions version fails closed" "$(build "$D")" 2
# A symlinked exceptions file is refused.
D=$(fresh exc-symlink); good_sbom "$D"; good_release "$D"
printf '{"version":"1","exceptions":[]}\n' > "$WORK/exc-outside.json"
ln -s "$WORK/exc-outside.json" "$D/exceptions.json"
check "a symlinked exceptions file fails closed" "$(build "$D")" 2

# The shipped schema describes what the builder enforces.
check "the exceptions schema is shipped" "$([ -f "$ROOT/schemas/exceptions.schema.json" ] && echo yes || echo no)" "yes"
check "  and requires records, not counts" \
	"$(jq -r '[.required[]] | index("exceptions") != null' "$ROOT/schemas/exceptions.schema.json")" "true"

# ---------------------------------------------------------------------------
# Unattributed content is not evidence in an enforcing mode.
# ---------------------------------------------------------------------------
# The builder can only decide that bytes parse. Whether anything BINDS them to this run is a
# policy question, and it used to depend on the caller remembering an optional flag: a summary
# built without --require-evidence-provenance presented unbound content as `present: true` and
# `status: "verified"`. Assurance must not rest on a producer-side argument.
UN="$WORK/unbound"; mkdir -p "$UN/reports/raw"
# A real (clean) scanner report, so the enforcing modes reach the EVIDENCE gates instead of
# refusing the summary earlier for containing no scanner evidence at all.
printf '[]' > "$UN/reports/raw/gitleaks.json"
jq -n '{spdxVersion:"SPDX-2.3", SPDXID:"SPDXRef-DOCUMENT", name:"x",
	creationInfo:{created:"2026-01-01T00:00:00Z", creators:["Tool: t-1.0"]},
	packages:[{name:"p", SPDXID:"SPDXRef-p"}]}' > "$UN/reports/sbom.spdx.json"
printf '# Release evidence\n\nline two\nline three\n' > "$UN/reports/release-evidence.md"
sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$UN/reports/raw" \
	--output "$UN/reports/security-summary.json" --project-name t >/dev/null 2>&1
# The summary is built without --profile, so it carries no tool-policy overlay and the
# assurance modes refuse it before any gate is judged. This case is about the EVIDENCE
# decision, so stamp a clean, neutral overlay and a source binding.
jq '.summary += {required_tool_failures:0, tool_configuration_failures:0,
		tool_execution_failures:0, missing_coverage_evidence:false,
		missing_test_evidence:false, empty_test_suite:false,
		missing_architecture_evidence:false, missing_test_change_evidence:false,
		missing_behavior_specification:false, missing_acceptance_evidence:false}
	| .source.repository = "example-org/example-repo"
	| .source.commit = "0123456789abcdef0123456789abcdef01234567"' \
	"$UN/reports/security-summary.json" > "$UN/reports/s.tmp" \
	&& mv "$UN/reports/s.tmp" "$UN/reports/security-summary.json"
check "valid content with no producer manifest is reported as unbound" \
	"$(jq -r '.evidence.sbom.verification.provenance' "$UN/reports/security-summary.json")" "unbound"
check "  and is NOT called verified" \
	"$(jq -r '.evidence.sbom.verification.status' "$UN/reports/security-summary.json")" "content-verified-unattributed"
_enf() { # _enf <mode> -> exit code
	_o="$UN/$1"; mkdir -p "$_o"
	sh "$ROOT/scripts/resolve-gates.sh" --mode "$1" --output-dir "$_o" --format env >/dev/null 2>&1
	_c=0
	sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$_o/sentinel-shield-gates.env" \
		--summary "$UN/reports/security-summary.json" --output-dir "$_o" --format json \
		>"$_o/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}
check "report-only tolerates unattributed content" "$(_enf report-only)" 0
# baseline does not ENABLE the evidence gates (documented mode matrix), so it cannot block on
# them — but it must still classify the artifact as not-evidence rather than silently counting
# it. strict/regulated are where the gate is on and the refusal has to bite.
_bc=$(_enf baseline)
if grep -q 'nothing binds it to this run' "$UN/baseline/log" 2>/dev/null; then
	pass "baseline classifies unattributed content as not-evidence (gate itself is off there)"
else
	fail "baseline treated unattributed content as evidence without comment"
fi
_sc=$(_enf strict)
if [ "$_sc" = "0" ]; then
	fail "strict accepted unattributed content as evidence"
else
	pass "strict refuses unattributed content as evidence (exit $_sc)"
fi
if grep -q 'nothing binds it to this run' "$UN/strict/log" 2>/dev/null; then
	pass "  and says why"
else
	fail "  but does not explain the refusal"
fi
_gate=$(jq -r '[.evaluated_gates[]|select(.key=="missing_sbom")][0].result' "$UN/strict/sentinel-shield-enforcement.json" 2>/dev/null)
check "  the SBOM evidence gate is the one that fails" "$_gate" "fail"


printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '295-evidence-and-exception-validation: ALL CHECKS PASSED\n'
	exit 0
fi
printf '295-evidence-and-exception-validation: FAILURES PRESENT\n'
exit 1
