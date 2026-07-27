#!/bin/sh
# Sentinel Shield prod test — governance input + report output integrity (#223, #228).
#
#   #223  The accepted-risks file was only checked for "is it JSON?" and then matched with
#         ad-hoc jq filters, several followed by `|| true`. Impossible-but-orderable dates
#         (9999-99-99 never expires), duplicate or missing IDs, non-array/typed fields,
#         unsafe or traversing paths, unknown scopes/statuses and conflicting broad+finding
#         records all passed through, and a jq error over a malformed record produced an
#         EMPTY suppression set rather than a configuration failure — hiding corruption.
#
#   #228  Both report writers redirected straight to their final path. The JSON destination
#         was truncated before generation finished and validated only after it had already
#         replaced the previous report; the Markdown was never validated; a symlinked
#         destination redirected the write; and a failure between the two formats left a
#         JSON and a Markdown describing different runs.
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
mkdir -p "$WORK/out"
sh "$RESOLVE" --mode baseline --output-dir "$WORK/out" --format all >/dev/null 2>&1
jq '.tools = {"tests":{"status":"pass","policy":"required","gate_enforced":true}} | .summary.unsafe_docker = 1' \
	"$EXAMPLE" > "$WORK/s.json"

# enf [extra args] — run the enforcer against the fixture, echo its exit code.
enf() {
	_c=0
	sh "$ENFORCE" --gates-env "$WORK/out/sentinel-shield-gates.env" --summary "$WORK/s.json" \
		--output-dir "$WORK/out" "$@" >"$WORK/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}
# risk <json> — write an accepted-risks file and echo its path.
risk() { printf '%s' "$1" > "$WORK/ar.json"; printf '%s' "$WORK/ar.json"; }
R='{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}'

# ---------------------------------------------------------------------------
# 1. #223 — accepted-risk records are validated as executable policy.
# ---------------------------------------------------------------------------
# Build the JSON in a variable first: escaped quotes inside a nested command substitution are
# not portably parsed the same way by every shell.
_ctrl_json='{"version":"1","risks":['"$R"']}'
_ctrl_file=$(risk "$_ctrl_json")
check "control: a valid broad record suppresses the gate" "$(enf --accepted-risks "$_ctrl_file" --format json)" 0

# invalid <label> <risks-json>
invalid() {
	_ij='{"version":"1","risks":'"$2"'}'
	_if=$(risk "$_ij")
	check "$1" "$(enf --accepted-risks "$_if" --format json)" 2
}
invalid "an impossible expiry date (9999-99-99) is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"9999-99-99","status":"approved"}]'
invalid "a month-13 expiry date is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"2099-13-01","status":"approved"}]'
invalid "a non-date expiry is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"soon","status":"approved"}]'
invalid "a malformed review_at is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"2099-01-01","review_at":"2099-02-30x","status":"approved"}]'
invalid "a missing id is rejected" \
	'[{"gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'
invalid "duplicate ids are rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"},{"id":"a","gate":"medium_vulnerabilities","scope":"gate","owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'
invalid "a missing gate is rejected" \
	'[{"id":"a","scope":"gate","owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'
invalid "an unknown status is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"2099-01-01","status":"maybe"}]'
invalid "an unknown scope is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"everything","owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'
invalid "files as a string instead of an array is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"finding","files":"Dockerfile","owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'
invalid "rule_ids containing a non-string is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"finding","rule_ids":[7],"owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'
invalid "components as an object is rejected" \
	'[{"id":"a","gate":"medium_vulnerabilities","scope":"finding","components":{"x":1},"owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'
invalid "a traversing file pattern is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"finding","files":["../../etc/passwd"],"owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'
invalid "an absolute file pattern is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"finding","files":["/etc/passwd"],"owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'
invalid "a glob/wildcard file pattern is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"finding","files":["docker/*/Dockerfile"],"owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'
invalid "a record that is not an object is rejected" \
	'["just-a-string"]'
invalid "an active broad record conflicting with an active finding record is rejected" \
	'[{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"},{"id":"b","gate":"unsafe_docker","scope":"finding","rule_id":"DL3018","owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]'

# The failure names the offending record, so an operator can find it.
enf --accepted-risks "$(risk '{"version":"1","risks":[{"id":"the-bad-one","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"9999-99-99","status":"approved"}]}')" --format json >/dev/null 2>&1 || true
grep -q 'the-bad-one' "$WORK/log" && pass "the rejection names the offending record id" || fail "the rejection does not name the record"
grep -q 'INVALID' "$WORK/log" && pass "the file is reported as invalid, not silently ignored" || fail "invalid governance input was not reported"

# Valid variations must still be accepted (the validator must not reject legitimate policy).
check "a pending record is valid input (and suppresses nothing)" \
	"$(enf --accepted-risks "$(risk '{"version":"1","risks":[{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"2099-01-01","status":"pending"}]}')" --format json)" 1
check "an expired record is valid input (and suppresses nothing)" \
	"$(enf --accepted-risks "$(risk '{"version":"1","risks":[{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"2000-01-01","status":"approved"}]}')" --format json)" 1
check "a leap day (2024-02-29) is a real date" \
	"$(enf --accepted-risks "$(risk '{"version":"1","risks":[{"id":"a","gate":"unsafe_docker","scope":"gate","owner":"o","reason":"r","expires_at":"2024-02-29","status":"approved"}]}')" --format json)" 1
check "a nested repository path is accepted" \
	"$(enf --accepted-risks "$(risk '{"version":"1","risks":[{"id":"a","gate":"unsafe_docker","scope":"finding","rule_id":"DL3018","files":["docker/8.3/Dockerfile"],"owner":"o","reason":"r","expires_at":"2099-01-01","status":"approved"}]}')" --format json)" 1
check "an empty risks array is valid" \
	"$(enf --accepted-risks "$(risk '{"version":"1","risks":[]}')" --format json)" 1
check "no accepted-risks file at all is valid" "$(enf --accepted-risks "$WORK/absent.json" --format json)" 1
# The SHIPPED template must satisfy its own validator.
check "the shipped accepted-risks example is valid input" \
	"$(enf --accepted-risks "$ROOT/templates/accepted-risks.example.json" --format json)" 1

# ---------------------------------------------------------------------------
# 2. #228 — the report set is published atomically, validated, and paired.
# ---------------------------------------------------------------------------
rm -f "$WORK/out/sentinel-shield-enforcement.json" "$WORK/out/sentinel-shield-enforcement.md"
check "a normal run publishes both formats" "$(enf --format all)" 1
check "  the JSON exists" "$([ -f "$WORK/out/sentinel-shield-enforcement.json" ] && echo yes || echo no)" "yes"
check "  the Markdown exists" "$([ -f "$WORK/out/sentinel-shield-enforcement.md" ] && echo yes || echo no)" "yes"
check "  the JSON is valid" "$(jq -e . "$WORK/out/sentinel-shield-enforcement.json" >/dev/null 2>&1 && echo yes || echo no)" "yes"
check "  no staging directory is left behind" \
	"$(find "$WORK/out" -maxdepth 1 -name '.sentinel-shield-report.*' | wc -l | tr -d ' ')" 0
# The two formats must describe the SAME run.
_jr=$(jq -r '.result' "$WORK/out/sentinel-shield-enforcement.json")
_mr=$(grep -m1 '^## Overall result: ' "$WORK/out/sentinel-shield-enforcement.md" | sed 's/^## Overall result: //' | tr '[:upper:]' '[:lower:]')
check "  JSON and Markdown agree on the verdict" "$_mr" "$_jr"

# A symlinked destination must not be written through.
ln -sf "$WORK/outside.json" "$WORK/out/sentinel-shield-enforcement.json"
check "a symlinked JSON destination is refused" "$(enf --format json)" 2
check "  nothing was written through the symlink" "$([ -e "$WORK/outside.json" ] && echo written || echo clean)" "clean"
rm -f "$WORK/out/sentinel-shield-enforcement.json"

ln -sf "$WORK/outside.md" "$WORK/out/sentinel-shield-enforcement.md"
check "a symlinked Markdown destination is refused" "$(enf --format markdown)" 2
check "  nothing was written through the symlink" "$([ -e "$WORK/outside.md" ] && echo written || echo clean)" "clean"
rm -f "$WORK/out/sentinel-shield-enforcement.md"

mkdir -p "$WORK/out/sentinel-shield-enforcement.json"
check "a directory in place of the JSON report is refused" "$(enf --format json)" 2
rmdir "$WORK/out/sentinel-shield-enforcement.json"

# A previous, valid report survives a refused publication.
enf --format all >/dev/null 2>&1 || true
cp "$WORK/out/sentinel-shield-enforcement.json" "$WORK/previous.json"
ln -sf "$WORK/outside2.md" "$WORK/out/sentinel-shield-enforcement.md"
enf --format all >/dev/null 2>&1 || true
check "a refused Markdown publication leaves the previous JSON intact" \
	"$(cmp -s "$WORK/previous.json" "$WORK/out/sentinel-shield-enforcement.json" && echo same || echo changed)" "same"
rm -f "$WORK/out/sentinel-shield-enforcement.md"

# Single-format runs publish only what they were asked for.
rm -f "$WORK/out/sentinel-shield-enforcement.json" "$WORK/out/sentinel-shield-enforcement.md"
enf --format json >/dev/null 2>&1 || true
check "--format json publishes only the JSON" \
	"$([ -f "$WORK/out/sentinel-shield-enforcement.json" ] && [ ! -f "$WORK/out/sentinel-shield-enforcement.md" ] && echo yes || echo no)" "yes"

# --- second-reviewer round: shape-of-a-date is not a date ---------------------
# The jq `realdate` check only bounded month 1-12 and day 1-31, so 2026-02-31, 2026-04-31 and
# non-leap 2025-02-29 all validated — and each sorts as unexpired, i.e. an accepted risk that
# never expires. The canonical calendar validator is reused now.
for _bad in 2026-02-31 2026-04-31 2025-02-29 2026-06-31 2026-11-31; do
	jq -n --arg e "$_bad" '{version:"1.1", risks:[{id:"R1", gate:"unsafe_docker", scope:"gate",
		owner:"o", reason:"r", expires_at:$e, status:"approved"}]}' > "$WORK/ar-bad.json"
	check "an impossible calendar date ($_bad) is refused" "$(enf --accepted-risks "$WORK/ar-bad.json" --format json)" 2
done
# Real AND unexpired: an expired record legitimately fails the gate (exit 1), which would
# not tell us anything about date VALIDATION.
for _ok in 2028-02-29 2026-12-31 2099-04-30; do
	jq -n --arg e "$_ok" '{version:"1.1", risks:[{id:"R1", gate:"unsafe_docker", scope:"gate",
		owner:"o", reason:"r", expires_at:$e, status:"approved"}]}' > "$WORK/ar-ok.json"
	check "a real calendar date ($_ok) is accepted" "$(enf --accepted-risks "$WORK/ar-ok.json" --format json)" 0
done
# review_at gets the same treatment.
jq -n '{version:"1.1", risks:[{id:"R1", gate:"unsafe_docker", scope:"gate", owner:"o",
	reason:"r", expires_at:"2099-01-01", review_at:"2026-02-31", status:"approved"}]}' > "$WORK/ar-rev.json"
check "an impossible review_at is refused" "$(enf --accepted-risks "$WORK/ar-rev.json" --format json)" 2

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '292-governance-io-integrity: ALL CHECKS PASSED\n'
	exit 0
fi
printf '292-governance-io-integrity: FAILURES PRESENT\n'
exit 1
