#!/bin/sh
# Sentinel Shield prod test — profile tool integrity.
#
# Pins the invariant that a profile recommendation means something executable, and pins the
# specific holes that were open before this suite existed:
#
#   - pint / larastan / php-cs-fixer / phpstan-symfony (all `missing_behavior: fail`) plus
#     rector and syft wrote raw reports that NO TOOL_TABLE row collected. Their presence
#     was gated; their CONTENTS were unreachable. A larastan.json with 47 errors and a
#     pint.json listing violations produced an all-zero summary.
#   - grype-fs (8 profiles) and trivy-image (2) were recommended with no TOOL_TABLE row,
#     no .tools entry, no runner, no collector and no workflow step.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

AUDIT="scripts/audits/profile-tool-integrity.sh"
[ -f "$AUDIT" ] || { fail "missing $AUDIT"; exit 1; }

# --- the audit must pass on the repo as shipped ------------------------------
if sh "$AUDIT" >/dev/null 2>&1; then
	pass "profile-tool-integrity audit passes on this revision"
else
	sh "$AUDIT" 2>&1 | grep '^FAIL' | sed 's/^/    /'
	fail "profile-tool-integrity audit reports unresolved tool keys"
fi

# --- the audit must FAIL CLOSED, not merely print ----------------------------
# The first draft ran its checks inside `cmd | while read`, a subshell, so FAILED=1 was
# discarded and it exited 0 while printing FAIL lines. Prove the exit status is real.
# This probe MUTATES a tracked manifest, so restoration is trapped: a kill between the
# write and the restore would otherwise leave the working tree dirty with a fake tool key.
_bak=$(mktemp)
_victim="profiles/laravel/profile.manifest.json"
cp "$_victim" "$_bak"
trap 'cp "$_bak" "$_victim" 2>/dev/null || true; rm -f -- "$_bak"' EXIT INT TERM
jq '.recommended_scheduled_tools += ["ss-nonexistent-probe-tool"]' "$_bak" > "$_victim"
if sh "$AUDIT" >/dev/null 2>&1; then
	fail "audit EXITED 0 with an unresolvable tool key — it reports but does not fail closed"
else
	pass "audit exits non-zero on an unresolvable tool key (fails closed)"
fi
cp "$_bak" "$_victim"
rm -f -- "$_bak"
trap - EXIT INT TERM

# --- every declared report must be collected ---------------------------------
# Recompute independently of the audit so a bug in the audit cannot hide the hole.
_tbl=$(sed -n "/^TOOL_TABLE='/,/'\$/p" scripts/build-security-summary.sh | sed "s/^TOOL_TABLE='//; s/'\$//")
_raw=$(printf '%s\n' "$_tbl" | awk -F'|' 'NF>=4 && $2!=""{print $2}' | sort -u)
_orphans=0
for f in profiles/*/profile.manifest.json profiles/combinations/*.manifest.json; do
	[ -f "$f" ] || continue
	for rep in $(jq -r '(.tools // {}) | to_entries[] | select(.value.report) | .value.report' "$f" 2>/dev/null); do
		base=${rep##*/}
		printf '%s\n' "$_raw" | grep -qxF "$base" || _orphans=$((_orphans + 1))
	done
done
check "no profile declares a report that TOOL_TABLE cannot collect" "$_orphans" "0"

# --- the specific tools that were invisible are now collected ----------------
for t in pint larastan php-cs-fixer phpstan-symfony phpstan-doctrine rector syft; do
	if printf '%s\n' "$_tbl" | awk -F'|' -v k="$t" '$1==k{found=1} END{exit !found}'; then
		pass "TOOL_TABLE has a row for '$t'"
	else
		fail "TOOL_TABLE lost its row for '$t' — its evidence becomes unreadable again"
	fi
done

# --- the dead keys must not come back ----------------------------------------
for dead in grype-fs trivy-image; do
	_n=$(grep -rl "\"$dead\"" profiles/ 2>/dev/null | grep -c . || true)
	case "$_n" in '' | *[!0-9]*) _n=0 ;; esac
	check "no profile references the unimplemented key '$dead'" "$_n" "0"
done

# --- content actually reaches the summary ------------------------------------
# The end-to-end proof: violations in the previously-orphaned reports must move counters.
_w=$(mktemp -d)
mkdir -p "$_w/reports/raw"
printf '{"files":[{"name":"a.php"},{"name":"b.php"}]}\n' > "$_w/reports/raw/pint.json"
printf '{"totals":{"errors":0,"file_errors":47}}\n' > "$_w/reports/raw/larastan.json"
( cd "$_w" && sh "$ROOT/scripts/build-security-summary.sh" --raw-dir reports/raw --output summary.json >/dev/null 2>&1 ) || true
if [ -f "$_w/summary.json" ]; then
	_ty=$(jq -r '.summary.type_errors // 0' "$_w/summary.json")
	_sv=$(jq -r '.summary.style_violations // 0' "$_w/summary.json")
	check "larastan errors reach type_errors (was 0 before wiring)" "$_ty" "47"
	check "pint violations reach style_violations (was 0 before wiring)" "$_sv" "2"
else
	fail "build-security-summary produced no summary for the wiring probe"
fi
rm -rf -- "$_w"

if [ "$FAILED" -eq 0 ]; then
	printf '\n272-profile-tool-integrity: ALL CHECKS PASSED\n'
else
	printf '\n272-profile-tool-integrity: FAILURES PRESENT\n'
fi
exit "$FAILED"
