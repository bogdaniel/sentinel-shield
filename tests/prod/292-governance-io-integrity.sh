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
# `regulated` requires an INDEPENDENT source-attestation record (a summary cannot attest to
# itself, and cannot bind its own digest). The helper builds one bound to the summary being
# enforced; the enforcer still checks it in full.
# shellcheck source=tests/lib/attestation.sh
. "$ROOT/tests/lib/attestation.sh"

RESOLVE="$ROOT/scripts/resolve-gates.sh"
EXAMPLE="$ROOT/templates/security-summary.example.json"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }

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
	sh "$ENFORCE" --gates-env "$WORK/out/sentinel-shield-gates.env" --summary "$WORK/s.json" $(ss_att "$WORK/s.json") \
		--output-dir "$WORK/out" "$@" >"$WORK/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}
# risk <json> — write an accepted-risks file and echo its path.
# Accepted risks are now TIME-BOXED (90 days by default), so a fixture cannot use a
# decade-long window unless that is what it is testing. risk() stamps every APPROVED record
# that does not set its own authorisation date with approved_at = today, and rewrites a
# far-future expiry to a compliant one — the assertions here are about shape, paths and
# dates, not about the window, which has its own section below.
# shellcheck source=scripts/lib/control-waivers.sh
. "$ROOT/scripts/lib/control-waivers.sh"
AR_TODAY=$(date -u +%Y-%m-%d)
AR_SOON=$(date -u -d '+30 days' +%Y-%m-%d 2>/dev/null || date -u -v+30d +%Y-%m-%d)
risk() {
	printf '%s' "$1" | jq --arg today "$AR_TODAY" --arg soon "$AR_SOON" '
		(.risks // []) |= map(
			# Only stamp an authorisation date on a record whose expiry is still ahead:
			# stamping an ALREADY-EXPIRED fixture with the current date would make the
			# expiry precede the approval, a contradiction the enforcer rightly refuses —
			# and these cases are about expiry and dates, not about the window.
			if (.status // "") == "approved" and ((.expires_at // "") >= $today) then
				(if has("approved_at") or has("created_at") then . else . + {approved_at: $today} end)
				| (if (.expires_at // "") == "2099-01-01" then .expires_at = $soon else . end)
			else . end)
		# v2 closes every object and requires created_at (plus approved_at when approved), so
		# a fixture that DECLARES v2 gets those fields; a legacy fixture is left alone because
		# it is exercising the deprecation path.
		| (if (.version // "") == "2" then
			(.risks // []) |= map(
				(if has("created_at") then . else . + {created_at: (.approved_at // $today)} end)
				| (if (.status // "") == "approved" and (has("approved_at") | not)
				   then . + {approved_at: $today} else . end))
		   else . end)' > "$WORK/ar.json" 2>/dev/null || printf '%s' "$1" > "$WORK/ar.json"
	printf '%s' "$WORK/ar.json"
}
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
	jq -n --arg e "$_bad" '{version:"1.1", risks:[{id:"AR-1", gate:"unsafe_docker", scope:"gate",
		owner:"o", reason:"r", expires_at:$e, status:"approved"}]}' > "$WORK/ar-bad.json"
	check "an impossible calendar date ($_bad) is refused" "$(enf --accepted-risks "$WORK/ar-bad.json" --format json)" 2
done
# Real AND unexpired: an expired record legitimately fails the gate (exit 1), which would
# not tell us anything about date VALIDATION.
# Real AND inside the governed window: the authorisation date moves with the expiry so this
# section tests the CALENDAR, not the 90-day policy (which has its own section below).
for _ok in 2028-02-29 2026-12-31 2099-04-30; do
	jq -n --arg e "$_ok" --arg t "$AR_TODAY" '{version:"1.1", risks:[{id:"AR-1",
		gate:"unsafe_docker", scope:"gate", owner:"o", reason:"r",
		approved_at:$t, expires_at:$e, status:"approved"}]}' > "$WORK/ar-ok.json"
	# A far-future expiry is refused by the WINDOW policy, so use one inside it while still
	# proving the date itself parses.
	# >90 days from today is refused by the window policy; anything closer is accepted.
	_exp=0
	if [ "$(cw__days "$_ok")" -gt "$(( $(cw__days "$AR_TODAY") + 90 ))" ]; then _exp=2; fi
	check "a real calendar date ($_ok) parses; window policy decides the verdict" \
		"$(enf --accepted-risks "$WORK/ar-ok.json" --format json)" "$_exp"
	if [ "$_exp" -eq 2 ]; then
		grep -q 'over the .*-day maximum' "$WORK/log" 2>/dev/null \
			&& pass "  refused for the WINDOW, not the date" \
			|| fail "  refused for something other than the window"
	fi
done
# review_at gets the same treatment.
jq -n '{version:"1.1", risks:[{id:"AR-1", gate:"unsafe_docker", scope:"gate", owner:"o",
	reason:"r", expires_at:"2099-01-01", review_at:"2026-02-31", status:"approved"}]}' > "$WORK/ar-rev.json"
check "an impossible review_at is refused" "$(enf --accepted-risks "$WORK/ar-rev.json" --format json)" 2

# --- Decision 4: accepted risks are time-boxed (90 / 30 / 365) ----------------
# `expires_at: 9999-12-31` was a permanent suppression wearing a date. The window is now
# governed with the same policy as control waivers, measured from approved_at (when the
# exception was authorised) or created_at.
armk() {  # armk <approved_at> <expires_at> [status]
	jq -n --arg a "$1" --arg e "$2" --arg s "${3:-approved}" \
		'{version:"2", risks:[{id:"AR-1", gate:"unsafe_docker", scope:"gate", owner:"o",
			reason:"r", created_at:$a, approved_at:$a, expires_at:$e, status:$s}]}' > "$WORK/ar-win.json"
	printf '%s' "$WORK/ar-win.json"
}
arrun() {  # arrun <mode> [env-assignment]
	sh "$RESOLVE" --mode "$1" --output-dir "$WORK/w" --format all >/dev/null 2>&1
	_c=0
	# shellcheck disable=SC2046  # ss_att emits a controlled two-token flag or nothing
	env ${2:+"$2"} sh "$ENFORCE" --gates-env "$WORK/w/sentinel-shield-gates.env" \
		--summary "$WORK/win-summary.json" $(ss_att "$WORK/win-summary.json") \
		--accepted-risks "$WORK/ar-win.json" \
		--output-dir "$WORK/w" --format json >"$WORK/w/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}
mkdir -p "$WORK/w"
# regulated requires a VERIFIED platform attestation (#278); the window policy is what these
# cases are about, so the fixture carries the attestation a real attested run would have.
jq '.tools = {"tests":{"status":"pass"}}
	| .source.trust = "github-actions-attested"
	| .attestation = {verified:true, issuer:"https://token.actions.githubusercontent.com",
		repository:(.source.repository // "example-org/example-repo"),
		commit:(.source.commit // "0123456789abcdef0123456789abcdef01234567"),
		workflow:"sentinel-shield", workflow_sha:"1111111111111111111111111111111111111111",
		run_id:"1", run_attempt:"1",
		artifact_digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000"}' "$ROOT/templates/security-summary.example.json" > "$WORK/win-summary.json"

armk 2026-05-01 2026-07-30 >/dev/null; check "exactly 90 days is accepted in baseline" "$(arrun baseline)" 0
armk 2026-05-01 2026-07-31 >/dev/null; check "91 days is refused in baseline" "$(arrun baseline)" 2
contains "  naming the maximum" "$(cat "$WORK/w/log")" "over the 90-day maximum"
armk 2026-05-01 2026-07-30 >/dev/null; check "exactly 90 days is accepted in strict" "$(arrun strict)" 0
armk 2026-05-01 2026-07-31 >/dev/null; check "91 days is refused in strict" "$(arrun strict)" 2
armk 2026-07-01 2026-07-31 >/dev/null; check "exactly 30 days is accepted in regulated" "$(arrun regulated)" 0
armk 2026-07-01 2026-08-01 >/dev/null; check "31 days is refused in regulated" "$(arrun regulated)" 2
contains "  naming the regulated maximum" "$(cat "$WORK/w/log")" "over the 30-day maximum"
# 365 is the ABSOLUTE ceiling — never reachable through configuration, because configuration
# may only tighten below the 90-day policy maximum.
armk 2026-01-01 2026-12-31 >/dev/null
check "365 days is refused even with a configured maximum" "$(arrun baseline SS_MAX_ACCEPTED_RISK_DAYS=365)" 2
check "366 days is refused" "$(arrun baseline SS_MAX_ACCEPTED_RISK_DAYS=90)" 2

# Invalid policy configuration FAILS CLOSED — never clamped, never defaulted.
armk 2026-07-01 2026-07-15 >/dev/null
for _bad in oops 0 -5 1.5 366 999 '' '  ' 99999999999999999999; do
	check "SS_MAX_ACCEPTED_RISK_DAYS='$_bad' is a configuration error" "$(arrun baseline "SS_MAX_ACCEPTED_RISK_DAYS=$_bad")" 2
done
check "an UNSET maximum uses the 90-day default" "$(arrun baseline)" 0
check "a tightening value is honoured" "$(arrun baseline SS_MAX_ACCEPTED_RISK_DAYS=30)" 0
armk 2026-07-01 2026-08-15 >/dev/null
check "  and actually tightens (45 days refused at max=30)" "$(arrun baseline SS_MAX_ACCEPTED_RISK_DAYS=30)" 2

# The window is measured from approved_at; a future authorisation is pre-positioning.
armk 2099-01-01 2099-02-01 >/dev/null
check "a future approved_at is refused" "$(arrun baseline)" 2
contains "  naming the field" "$(cat "$WORK/w/log")" "approved_at"
# Leap-year arithmetic is exact.
armk 2024-01-01 2024-03-31 >/dev/null
check "a leap-year window of exactly 90 days is accepted" "$(arrun baseline)" 0
armk 2024-01-01 2024-04-01 >/dev/null
check "  and 91 days is refused" "$(arrun baseline)" 2
# Only APPROVED records are bounded — a pending record suppresses nothing.
armk 2026-01-01 2099-01-01 pending >/dev/null
check "a PENDING record is not bounded (it suppresses nothing)" "$(arrun baseline)" 0

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '292-governance-io-integrity: ALL CHECKS PASSED\n'
	exit 0
fi
printf '292-governance-io-integrity: FAILURES PRESENT\n'
exit 1
