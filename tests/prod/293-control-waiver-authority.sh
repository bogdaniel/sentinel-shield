#!/bin/sh
# Sentinel Shield prod test — control-waiver identity and time bounds (#225, #226).
#
# #225  A waiver was a boolean fact about a TOOL KEY: cw_valid_keys printed every
#       unexpired record's tool and cw_is_waived did a membership test. Several records
#       with different owners, approvers, dates and tracking issues collapsed into one
#       waived state, no record had an identity, and no output could say which approval
#       authorised the control being waived.
#
# #226  Validation proved created_at/expires_at were real dates in the right order and
#       nothing else: a record dated next year applied the moment its expiry followed,
#       and a 2099 expiry made a "temporary" waiver permanent.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

# shellcheck source=scripts/lib/control-waivers.sh
. "$ROOT/scripts/lib/control-waivers.sh"

# A FIXED validation date: every structural case below is deterministic forever, not
# "valid until someone runs the suite next year".
T=2026-06-15

# wf <file> <json-array-of-records> — write a v2 waiver file.
wf() { printf '{"version":"2","waivers":%s}\n' "$2" > "$1"; }
# rec <id> <tool> <created> <expires> [extra-json] — one record.
rec() {
	_x="${5:-}"; [ -n "$_x" ] || _x='{}'
	jq -nc --arg id "$1" --arg t "$2" --arg c "$3" --arg e "$4" --argjson x "$_x" '
		{id:$id, tool:$t, justification:"prod-test", owner:"alice", approved_by:"bob",
		 created_at:$c, expires_at:$e, tracking_issue:"SEC-1"} + $x'
}
# v <file> — validate at the fixed date, echoing the exit code.
v() { _c=0; cw_validate_file "$1" "" "$T" >"$WORK/log" 2>&1 || _c=$?; printf '%s' "$_c"; }
# ds <days-offset> — a UTC date relative to today (GNU date, then BSD date).
ds() { date -u -d "$1 days" +%Y-%m-%d 2>/dev/null || date -u -v"$1"d +%Y-%m-%d; }

# ---------------------------------------------------------------------------
# 1. #225 — a waiver has ONE identity.
# ---------------------------------------------------------------------------
wf "$WORK/ok.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-07-01)]"
check "a well-formed v2 waiver validates" "$(v "$WORK/ok.json")" 0
check "  the applied record carries its identity" \
	"$(cw_applied_records "$WORK/ok.json" "$T" | cut -f1)" "WVR-1"
check "  and its owner, approver, dates and tracking reference" \
	"$(cw_applied_records "$WORK/ok.json" "$T" | cut -f3,4,5,6,7 | tr '\t' ',')" \
	"alice,bob,2026-06-01,2026-07-01,SEC-1"
check "  cw_valid_keys still yields the tool key" "$(cw_valid_keys "$WORK/ok.json" "$T")" "phpstan"
contains "  cw_describe names the approval" "$(cw_describe "$(cw_applied_records "$WORK/ok.json" "$T")" phpstan)" "waiver=WVR-1"

# A v1 file has no identity at all: refused, with the migration named.
printf '{"version":"1","waivers":[{"tool":"phpstan","justification":"x","owner":"a","approved_by":"b","created_at":"2026-06-01","expires_at":"2026-07-01","tracking_issue":"S"}]}\n' > "$WORK/v1.json"
check "a v1 file (no waiver ids) is refused" "$(v "$WORK/v1.json")" 2
contains "  the refusal explains the migration" "$(cat "$WORK/log")" "giving every record a unique 'id'"

for _case in \
	'missing-id|[{"tool":"phpstan","justification":"x","owner":"a","approved_by":"b","created_at":"2026-06-01","expires_at":"2026-07-01","tracking_issue":"S"}]' \
	; do
	_n=${_case%%|*}; _j=${_case#*|}
	wf "$WORK/$_n.json" "$_j"
	check "a record without an id is refused" "$(v "$WORK/$_n.json")" 2
done

wf "$WORK/badid.json" "[$(rec 'a b' phpstan 2026-06-01 2026-07-01)]"
check "an id that is not a safe token is refused" "$(v "$WORK/badid.json")" 2
wf "$WORK/shortid.json" "[$(rec 'ab' phpstan 2026-06-01 2026-07-01)]"
check "a too-short id is refused" "$(v "$WORK/shortid.json")" 2

wf "$WORK/dupid.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-07-01), $(rec WVR-1 semgrep 2026-06-01 2026-07-01)]"
check "duplicate waiver ids are refused" "$(v "$WORK/dupid.json")" 2
contains "  the refusal names the duplicate" "$(cat "$WORK/log")" "duplicate waiver id"

# ---------------------------------------------------------------------------
# 2. #225 — two approvals cannot silently cover one tool.
# ---------------------------------------------------------------------------
wf "$WORK/dup-tool.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-07-01), $(rec WVR-2 phpstan 2026-06-10 2026-07-10)]"
check "two overlapping active waivers for one tool are refused" "$(v "$WORK/dup-tool.json")" 2
contains "  the refusal names both records and the tool" "$(cat "$WORK/log")" "WVR-1 and WVR-2 both waive phpstan"
contains "  and points at supersession as the fix" "$(cat "$WORK/log")" "supersede one of them"

# Reordering the array must not change the verdict.
wf "$WORK/dup-rev.json" "[$(rec WVR-2 phpstan 2026-06-10 2026-07-10), $(rec WVR-1 phpstan 2026-06-01 2026-07-01)]"
check "the same conflict is refused with the records reordered" "$(v "$WORK/dup-rev.json")" 2

# Non-overlapping windows for one tool are a legitimate history.
wf "$WORK/history.json" "[$(rec WVR-1 phpstan 2026-01-01 2026-02-01), $(rec WVR-2 phpstan 2026-06-01 2026-07-01)]"
check "non-overlapping windows for one tool validate" "$(v "$WORK/history.json")" 0
check "  only the record covering today applies" \
	"$(cw_applied_records "$WORK/history.json" "$T" | cut -f1)" "WVR-2"

# Explicit supersession resolves an overlap to exactly one authoritative record.
wf "$WORK/supersede.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-07-01), $(rec WVR-2 phpstan 2026-06-10 2026-07-10 '{"supersedes":"WVR-1"}')]"
check "an overlap resolved by supersession validates" "$(v "$WORK/supersede.json")" 0
check "  exactly one record applies" "$(cw_applied_records "$WORK/supersede.json" "$T" | wc -l | tr -d ' ')" 1
check "  and it is the superseding one" "$(cw_applied_records "$WORK/supersede.json" "$T" | cut -f1)" "WVR-2"
check "  the tool is waived exactly once" "$(cw_valid_keys "$WORK/supersede.json" "$T" | wc -l | tr -d ' ')" 1

# A superseded record is shadowed even when its own window still covers today.
wf "$WORK/shadow.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-07-01), $(rec WVR-2 phpstan 2026-06-10 2026-06-12 '{"supersedes":"WVR-1"}')]"
check "a superseded record does not reactivate when its replacement expires" \
	"$(cw_applied_records "$WORK/shadow.json" "$T" | wc -l | tr -d ' ')" 0
check "  so the tool is NOT waived" "$(cw_valid_keys "$WORK/shadow.json" "$T")" ""

# Broken supersession relations.
wf "$WORK/sup-unknown.json" "[$(rec WVR-2 phpstan 2026-06-10 2026-07-10 '{"supersedes":"WVR-0"}')]"
check "supersedes an unknown id -> refused" "$(v "$WORK/sup-unknown.json")" 2
wf "$WORK/sup-self.json" "[$(rec WVR-2 phpstan 2026-06-10 2026-07-10 '{"supersedes":"WVR-2"}')]"
check "supersedes itself -> refused" "$(v "$WORK/sup-self.json")" 2
wf "$WORK/sup-other.json" "[$(rec WVR-1 semgrep 2026-06-01 2026-07-01), $(rec WVR-2 phpstan 2026-06-10 2026-07-10 '{"supersedes":"WVR-1"}')]"
check "supersedes a record for a DIFFERENT tool -> refused" "$(v "$WORK/sup-other.json")" 2
wf "$WORK/sup-twice.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-07-01), $(rec WVR-2 phpstan 2026-06-10 2026-07-10 '{"supersedes":"WVR-1"}'), $(rec WVR-3 phpstan 2026-06-11 2026-07-11 '{"supersedes":"WVR-1"}')]"
check "two records superseding the same id -> refused (ambiguous)" "$(v "$WORK/sup-twice.json")" 2
wf "$WORK/sup-older.json" "[$(rec WVR-1 phpstan 2026-06-10 2026-07-10), $(rec WVR-2 phpstan 2026-06-01 2026-07-01 '{"supersedes":"WVR-1"}')]"
check "a replacement OLDER than what it replaces -> refused" "$(v "$WORK/sup-older.json")" 2
contains "  the refusal explains the ordering rule" "$(cat "$WORK/log")" "must be newer than what it replaces"
# A supersession cycle is unrepresentable under strict ordering.
wf "$WORK/sup-cycle.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-07-01 '{"supersedes":"WVR-2"}'), $(rec WVR-2 phpstan 2026-06-10 2026-07-10 '{"supersedes":"WVR-1"}')]"
check "a supersession cycle -> refused" "$(v "$WORK/sup-cycle.json")" 2

# ---------------------------------------------------------------------------
# 3. #226 — the validity window is bounded.
# ---------------------------------------------------------------------------
wf "$WORK/forever.json" "[$(rec WVR-1 phpstan 2026-06-01 2099-01-01)]"
check "a decade-long waiver is refused" "$(v "$WORK/forever.json")" 2
contains "  the refusal states the maximum" "$(cat "$WORK/log")" "over the 90-day maximum"

# Exact boundary: 90 days is allowed, 91 is not.
wf "$WORK/d90.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-08-30)]"
check "a window of exactly the maximum (90d) validates" "$(v "$WORK/d90.json")" 0
wf "$WORK/d91.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-08-31)]"
check "one day over the maximum (91d) is refused" "$(v "$WORK/d91.json")" 2

# A tightened ceiling (regulated) refuses a window the default accepts.
wf "$WORK/d60.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-07-31)]"
check "a 60-day window validates under the default ceiling" "$(v "$WORK/d60.json")" 0
_c=0; ( CW_MAX_WAIVER_DAYS="$CW_MAX_WAIVER_DAYS_REGULATED"; cw_validate_file "$WORK/d60.json" "" "$T" ) >/dev/null 2>&1 || _c=$?
check "  and is refused under the regulated ceiling (30d)" "$_c" 2

# A loosened environment cannot exceed the hard ceiling.
wf "$WORK/d400.json" "[$(rec WVR-1 phpstan 2026-06-01 2027-07-31)]"
_c=0; ( CW_MAX_WAIVER_DAYS=99999; cw_validate_file "$WORK/d400.json" "" "$T" ) >/dev/null 2>&1 || _c=$?
check "an environment-loosened ceiling cannot exceed the hard limit" "$_c" 2
_c=0; ( CW_MAX_WAIVER_DAYS='not-a-number'; cw_validate_file "$WORK/d400.json" "" "$T" ) >/dev/null 2>&1 || _c=$?
check "a non-numeric ceiling falls back to the hard limit" "$_c" 2

# Creation time.
wf "$WORK/future.json" "[$(rec WVR-1 phpstan 2026-08-01 2026-09-01)]"
check "a future-dated record is refused" "$(v "$WORK/future.json")" 2
contains "  the refusal says it cannot be pre-positioned" "$(cat "$WORK/log")" "cannot be pre-positioned"
wf "$WORK/skew.json" "[$(rec WVR-1 phpstan 2026-06-16 2026-07-16)]"
check "one day ahead is tolerated as clock skew" "$(v "$WORK/skew.json")" 0
wf "$WORK/skew2.json" "[$(rec WVR-1 phpstan 2026-06-17 2026-07-17)]"
check "two days ahead is not skew, it is pre-positioning" "$(v "$WORK/skew2.json")" 2
check "  a record that is valid but not yet effective does not apply" \
	"$(cw_applied_records "$WORK/skew.json" "$T" | wc -l | tr -d ' ')" 0

# Leap-day handling in the duration arithmetic (2028 is a leap year, 2100 is not).
wf "$WORK/leap.json" "[$(rec WVR-1 phpstan 2024-02-01 2024-02-29)]"
check "a leap-day window validates" "$(v "$WORK/leap.json")" 0
wf "$WORK/leapbad.json" "[$(rec WVR-1 phpstan 2026-02-01 2026-02-29)]"
check "a non-leap 29 February is still an invalid date" "$(v "$WORK/leapbad.json")" 2

# Expiry, ordering and self-approval remain enforced.
wf "$WORK/expired.json" "[$(rec WVR-1 phpstan 2026-01-01 2026-02-01)]"
check "an expired record still validates" "$(v "$WORK/expired.json")" 0
check "  but does not apply" "$(cw_applied_records "$WORK/expired.json" "$T" | wc -l | tr -d ' ')" 0
wf "$WORK/backwards.json" "[$(rec WVR-1 phpstan 2026-06-10 2026-06-01)]"
check "created_at after expires_at is refused" "$(v "$WORK/backwards.json")" 2
wf "$WORK/self.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-07-01 '{"approved_by":"alice"}')]"
check "self-approval is still refused" "$(v "$WORK/self.json")" 2

# Control characters cannot smuggle a field boundary into the record projection.
wf "$WORK/ctrl.json" "[$(rec WVR-1 phpstan 2026-06-01 2026-07-01 '{"owner":"ali\tce"}')]"
check "control characters in a record field are refused" "$(v "$WORK/ctrl.json")" 2

# ---------------------------------------------------------------------------
# 4. The clock itself is a trust boundary.
# ---------------------------------------------------------------------------
_c=0; cw__resolve_today "not-a-date" >/dev/null 2>&1 || _c=$?
check "an untrusted 'today' is refused rather than defaulted" "$_c" 2
_c=0; cw_validate_file "$WORK/ok.json" "" "9999-99-99" >/dev/null 2>&1 || _c=$?
check "validation refuses an impossible evaluation date" "$_c" 2
_c=0; cw_applied_records "$WORK/ok.json" "9999-99-99" >/dev/null 2>&1 || _c=$?
check "so does the applied-record query" "$_c" 2

# ---------------------------------------------------------------------------
# 5. End to end: the enforcement report names the approval it acted on.
# ---------------------------------------------------------------------------
D="$WORK/e2e"; mkdir -p "$D"
sh "$ROOT/scripts/resolve-gates.sh" --mode baseline --output-dir "$D" --format all >/dev/null 2>&1
jq '.tools = {"phpstan":{"tool":"phpstan","policy":"required","status":"unavailable","gate_enforced":true}}' \
	"$ROOT/templates/security-summary.example.json" > "$D/s.json"
wf "$D/cw.json" "[$(rec WVR-E2E-1 phpstan "$(ds -10)" "$(ds +20)")]"
_c=0
sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$D/sentinel-shield-gates.env" --summary "$D/s.json" \
	--control-waivers "$D/cw.json" --output-dir "$D" --format all >"$D/enf.log" 2>&1 || _c=$?
check "a valid waiver downgrades the required-tool failure" "$_c" 0
check "  the JSON report names the waiver" \
	"$(jq -r '.tool_policy.waived[0].waiver_id' "$D/sentinel-shield-enforcement.json")" "WVR-E2E-1"
check "  with the approval trail attached" \
	"$(jq -r '.tool_policy.waived[0] | [.owner,.approved_by,.tracking_issue] | join(",")' "$D/sentinel-shield-enforcement.json")" \
	"alice,bob,SEC-1"
contains "  the markdown row names the waiver" "$(cat "$D/sentinel-shield-enforcement.md")" "waiver WVR-E2E-1"
contains "  the console warning names the waiver" "$(cat "$D/enf.log")" "waiver=WVR-E2E-1"

# A superseded waiver does not downgrade anything, even inside its own window.
wf "$D/cw-shadow.json" "[$(rec WVR-OLD phpstan "$(ds -10)" "$(ds +20)"), $(rec WVR-NEW phpstan "$(ds -5)" "$(ds -1)" '{"supersedes":"WVR-OLD"}')]"
_c=0
sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$D/sentinel-shield-gates.env" --summary "$D/s.json" \
	--control-waivers "$D/cw-shadow.json" --output-dir "$D" --format json >"$D/enf2.log" 2>&1 || _c=$?
check "a superseded waiver does NOT downgrade the control" "$_c" 1
check "  the tool is reported as a required-tool failure" \
	"$(jq -r '[.tool_policy.required_tool_failures[]?.tool] | index("phpstan") != null' "$D/sentinel-shield-enforcement.json")" "true"

# A conflicting waiver file is a configuration failure, not a silent waiver.
wf "$D/cw-conflict.json" "[$(rec WVR-A phpstan "$(ds -10)" "$(ds +20)"), $(rec WVR-B phpstan "$(ds -5)" "$(ds +25)")]"
_c=0
sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$D/sentinel-shield-gates.env" --summary "$D/s.json" \
	--control-waivers "$D/cw-conflict.json" --output-dir "$D" --format json >"$D/enf3.log" 2>&1 || _c=$?
check "a conflicting waiver file fails the run as configuration" "$_c" 2

# Regulated mode applies the tighter ceiling end to end.
D2="$WORK/e2e-reg"; mkdir -p "$D2"
sh "$ROOT/scripts/resolve-gates.sh" --mode regulated --output-dir "$D2" --format all >/dev/null 2>&1
# regulated refuses a summary in which NO tool produced evidence, so the fixture pairs the
# unavailable required tool with one that ran: the case under test is the waiver window.
jq '.tools = {"tests":{"tool":"tests","policy":"required","status":"pass","gate_enforced":true},
	"phpstan":{"tool":"phpstan","policy":"required","status":"unavailable","gate_enforced":true}}' \
	"$ROOT/templates/security-summary.example.json" > "$D2/s.json"
wf "$D2/cw.json" "[$(rec WVR-LONG phpstan "$(ds -10)" "$(ds +70)")]"
_c=0
sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$D2/sentinel-shield-gates.env" --summary "$D2/s.json" \
	--control-waivers "$D2/cw.json" --output-dir "$D2" --format json >"$D2/enf.log" 2>&1 || _c=$?
check "regulated refuses an 80-day waiver window" "$_c" 2
contains "  naming the regulated maximum" "$(cat "$D2/enf.log")" "30-day maximum"

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '293-control-waiver-authority: ALL CHECKS PASSED\n'
	exit 0
fi
printf '293-control-waiver-authority: FAILURES PRESENT\n'
exit 1
