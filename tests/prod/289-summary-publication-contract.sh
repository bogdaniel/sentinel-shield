#!/bin/sh
# Sentinel Shield prod test — summary publication + evidence-contract negotiation (#216, #219).
#
# #216  The report-only fallback was staged with a bare `cp`. The destination was never checked
#       (a symlinked summary path redirected the write), an existing valid summary was destroyed
#       before a complete copy was guaranteed, readers could observe a partial file, a
#       concurrent real builder could be overwritten, and the staged file was byte-identical to
#       the example — carrying no marker that it is not evidence.
#
# #219  An ENABLED gate whose summary counter was ABSENT read as a clean zero, so a v1/v2.0
#       summary could be replayed under a newer, stricter gate set. Compatibility is now
#       NEGOTIATED: a summary that declares `gate_contract_version` must be complete; one that
#       declares nothing is refused by strict/regulated and tolerated (loudly) by the
#       visibility modes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
SELECT="$ROOT/scripts/select-security-summary.sh"
ENFORCE="$ROOT/scripts/enforce-gates.sh"
# `regulated` requires an INDEPENDENT source-attestation record (a summary cannot attest to
# itself, and cannot bind its own digest). The helper builds one bound to the summary being
# enforced; the enforcer still checks it in full.
# shellcheck source=tests/lib/attestation.sh
. "$ROOT/tests/lib/attestation.sh"

RESOLVE="$ROOT/scripts/resolve-gates.sh"
BUILD="$ROOT/scripts/build-security-summary.sh"
EXAMPLE="$ROOT/templates/security-summary.example.json"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

sel() { _c=0; sh "$SELECT" --example "$EXAMPLE" "$@" >"$WORK/sel.log" 2>&1 || _c=$?; printf '%s' "$_c"; }

# ---------------------------------------------------------------------------
# 1. #216 — the fallback is staged safely, atomically and marked.
# ---------------------------------------------------------------------------
D="$WORK/ok"; mkdir -p "$D"
check "report-only stages a fallback" "$(sel --mode report-only --summary "$D/s.json")" 0
check "  the fallback is marked non-production" "$(jq -r '.fallback.non_production' "$D/s.json")" "true"
check "  it records the mode it was staged for" "$(jq -r '.fallback.mode' "$D/s.json")" "report-only"
check "  it is still a schema-shaped summary" "$(jq -r '(.version != null) and (.summary|type == "object")' "$D/s.json")" "true"
check "  no staging temp file is left behind" "$(find "$D" -name '.sentinel-shield-fallback.*' | wc -l | tr -d ' ')" 0

# A marked fallback is NOT real evidence on a later run, and never satisfies an enforcing mode.
check "a marked fallback does not count as a real summary" "$(sel --mode report-only --summary "$D/s.json")" 0
grep -q 'NON-PRODUCTION fallback marker' "$WORK/sel.log" && pass "  the marker is recognised on re-run" || fail "  the marker is not recognised on re-run"
for _m in baseline strict regulated; do
	check "$_m refuses the marked fallback" "$(sel --mode "$_m" --summary "$D/s.json")" 1
done

# Destination safety: a symlink, a directory, a FIFO and a symlinked parent are all refused,
# and none of them is written through.
D="$WORK/sym"; mkdir -p "$D"
ln -s "$WORK/outside.json" "$D/s.json"
check "a symlinked destination is refused" "$(sel --mode report-only --summary "$D/s.json")" 2
check "  nothing was written through the symlink" "$([ -e "$WORK/outside.json" ] && echo written || echo clean)" "clean"

D="$WORK/dir"; mkdir -p "$D/s.json"
check "a directory destination is refused" "$(sel --mode report-only --summary "$D/s.json")" 2

if command -v mkfifo >/dev/null 2>&1; then
	D="$WORK/fifo"; mkdir -p "$D"; mkfifo "$D/s.json" 2>/dev/null || true
	if [ -p "$D/s.json" ]; then
		check "a FIFO destination is refused" "$(sel --mode report-only --summary "$D/s.json")" 2
	else
		printf 'SKIP: could not create a FIFO — that destination case did not run\n'
	fi
else
	printf 'SKIP: mkfifo unavailable — the FIFO destination case did not run\n'
fi

D="$WORK/symdir"; mkdir -p "$D/real"
ln -s "$D/real" "$D/link"
check "a symlinked destination DIRECTORY is refused" "$(sel --mode report-only --summary "$D/link/s.json")" 2

# An existing REAL summary is never replaced by a fallback, and survives a refused staging.
D="$WORK/keepreal"; mkdir -p "$D"
jq '.project.name = "real-run" | .source.commit = "abc123"' "$EXAMPLE" > "$D/s.json"
_before=$(jq -S -c . "$D/s.json")
check "an existing real summary is used, not replaced" "$(sel --mode report-only --summary "$D/s.json")" 0
check "  it is byte-identical afterwards" "$(jq -S -c . "$D/s.json")" "$_before"

D="$WORK/badsource"; mkdir -p "$D"
printf 'not-json{' > "$WORK/bad-example.json"
_c=0; sh "$SELECT" --mode report-only --summary "$D/s.json" --example "$WORK/bad-example.json" >/dev/null 2>&1 || _c=$?
check "an invalid example source is refused" "$_c" 2
check "  no summary was published from the invalid source" "$([ -e "$D/s.json" ] && echo written || echo clean)" "clean"
# An EXISTING valid summary must survive a refused staging attempt untouched.
D="$WORK/badsource2"; mkdir -p "$D"
jq '.project.name = "keep-me" | .fallback = {non_production: true}' "$EXAMPLE" > "$D/s.json"
_c=0; sh "$SELECT" --mode report-only --summary "$D/s.json" --example "$WORK/bad-example.json" >/dev/null 2>&1 || _c=$?
check "a refused staging leaves the previous file intact" "$(jq -r '.project.name' "$D/s.json")" "keep-me"

D="$WORK/missingsource"; mkdir -p "$D"
_c=0; sh "$SELECT" --mode report-only --summary "$D/s.json" --example "$WORK/no-such-example.json" >/dev/null 2>&1 || _c=$?
check "a missing example source is refused" "$_c" 2
check "  no partial summary was published" "$([ -e "$D/s.json" ] && echo written || echo clean)" "clean"

# The enforcer refuses the marker too (defence in depth: a fallback left over from an earlier
# report-only run must not be enforced against later).
D="$WORK/enfmark"; mkdir -p "$D"
sh "$SELECT" --mode report-only --summary "$D/s.json" --example "$EXAMPLE" >/dev/null 2>&1
sh "$RESOLVE" --mode baseline --output-dir "$D" --format all >/dev/null 2>&1
_c=0; sh "$ENFORCE" --gates-env "$D/sentinel-shield-gates.env" --summary "$D/s.json" $(ss_att "$D/s.json") \
	--output-dir "$D" --format json >"$D/enf.log" 2>&1 || _c=$?
check "the enforcer refuses a marked fallback in baseline" "$_c" 2
grep -q 'non-production fallback' "$D/enf.log" && pass "  the refusal names the marker" || fail "  the refusal does not name the marker"

# ---------------------------------------------------------------------------
# 2. #219 — evidence-contract negotiation.
# ---------------------------------------------------------------------------
# The builder declares the contract, and the shipped example carries it.
D="$WORK/build"; mkdir -p "$D/raw"
sh "$BUILD" --raw-dir "$D/raw" --output "$D/s.json" >/dev/null 2>&1
_built=$(jq -r '.gate_contract_version // ""' "$D/s.json")
[ -n "$_built" ] && pass "the builder declares a gate contract version ($_built)" || fail "the builder declares no gate contract version"
check "the shipped example declares the same contract" "$(jq -r '.gate_contract_version // ""' "$EXAMPLE")" "$_built"

# enf <summary> <mode> — echo the enforcer's exit code.
enf() {
	_d="$WORK/e"; rm -rf "$_d"; mkdir -p "$_d"
	sh "$RESOLVE" --mode "$2" --output-dir "$_d" --format all >/dev/null 2>&1
	_c=0
	sh "$ENFORCE" --gates-env "$_d/sentinel-shield-gates.env" --summary "$1" $(ss_att "$1") \
		--output-dir "$_d" --format json >"$_d/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}

# A DECLARED contract must be complete — in every mode, including the visibility ones.
jq '.tools = {"tests":{"status":"pass"}} | del(.summary.php_syntax_errors)' "$EXAMPLE" > "$WORK/declared-missing.json"
for _m in baseline strict regulated; do
	check "$_m: a declared contract missing an ENABLED gate's key is refused" "$(enf "$WORK/declared-missing.json" "$_m")" 2
done

# A LEGACY summary (no declared contract) is refused by the assurance modes and tolerated by
# the visibility modes — the documented migration path.
# php_syntax_errors is enabled from baseline upward AND is not one of the always-required
# summary keys, so it isolates the enabled-but-absent negotiation from the older
# required-key contract (which 289 asserts separately for unsafe_docker).
jq '.tools = {"tests":{"status":"pass"}} | del(.gate_contract_version) | del(.summary.php_syntax_errors)' \
	"$EXAMPLE" > "$WORK/legacy.json"
check "strict refuses a legacy summary under a newer gate set" "$(enf "$WORK/legacy.json" strict)" 2
grep -q 'gate_contract_version' "$WORK/e/log" && pass "  the refusal names the missing contract declaration" || fail "  the refusal does not explain the contract mismatch"
check "regulated refuses a legacy summary" "$(enf "$WORK/legacy.json" regulated)" 2
check "baseline tolerates it (documented legacy tolerance)" "$(enf "$WORK/legacy.json" baseline)" 0
grep -q 'LEGACY TOLERANCE' "$WORK/e/log" && pass "  the tolerance is announced loudly" || fail "  the tolerance is silent"

# The tolerance applies ONLY to gates that are actually enabled-but-absent: a disabled gate's
# absent key stays ordinary back-compat everywhere.
jq '.tools = {"tests":{"status":"pass"}} | del(.gate_contract_version) | del(.summary.mutation_score_violations)' \
	"$EXAMPLE" > "$WORK/legacy-disabled.json"
check "an absent key for a DISABLED gate is fine in baseline" "$(enf "$WORK/legacy-disabled.json" baseline)" 0

# A complete current-contract summary enforces normally everywhere.
jq '.tools = {"tests":{"status":"pass"}}
	# `regulated` requires a VERIFIED platform attestation; the builder only ever emits
	# `unverified`, so a fixture that must be CERTIFIABLE in regulated carries what a real
	# attested run produces. The cases here are about gate behaviour, not provenance.
	| .source += {trust:"github-actions-attested"}
	| .attestation = {verified:true, issuer:"https://token.actions.githubusercontent.com",
		repository:(.source.repository), commit:(.source.commit),
		workflow:"sentinel-shield", workflow_sha:"1111111111111111111111111111111111111111",
		run_id:"1", run_attempt:"1",
		artifact_digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000"}'  "$EXAMPLE" > "$WORK/complete.json"
for _m in report-only baseline strict regulated; do
	check "$_m: a complete current-contract summary enforces" "$(enf "$WORK/complete.json" "$_m")" 0
done

# unsafe_docker is specialised; it must negotiate the same way.
# unsafe_docker is one of the ALWAYS-required summary keys, so its absence is refused in every
# mode by the pre-existing required-key contract — stricter than the legacy tolerance above, and
# asserted here so a future refactor cannot quietly relax it into that tolerance.
jq '.tools = {"tests":{"status":"pass"}} | del(.gate_contract_version) | del(.summary.unsafe_docker)' \
	"$EXAMPLE" > "$WORK/legacy-docker.json"
for _m in baseline strict regulated; do
	check "unsafe_docker: an absent count is refused in $_m" "$(enf "$WORK/legacy-docker.json" "$_m")" 2
done

# ---------------------------------------------------------------------------
# The fallback COMMITS by create-exclusive; it can never replace an existing summary.
# ---------------------------------------------------------------------------
# `is_real_summary` followed by `mv` is two operations: a real builder publishing in the gap
# was then overwritten by the fallback. `ln` fails atomically when the destination exists, so
# there is no window to lose rather than a narrower one.
CX="$WORK/create-exclusive"; mkdir -p "$CX"
_real='{"version":"1.0","generated_at":"t","project":{"name":"real"},"summary":{"secrets":0}}'
printf '%s' "$_real" > "$CX/security-summary.json"
sh "$SELECT" --mode report-only --summary "$CX/security-summary.json" --example "$EXAMPLE" \
	>"$CX/log" 2>&1 || true
check "an existing REAL summary is left byte-for-byte" \
	"$(cat "$CX/security-summary.json")" "$_real"

# Even a summary the selector would not call "real" must not be silently replaced: the
# fallback only ever CREATES.
CX2="$WORK/create-exclusive-2"; mkdir -p "$CX2"
printf 'not json at all' > "$CX2/security-summary.json"
sh "$SELECT" --mode report-only --summary "$CX2/security-summary.json" --example "$EXAMPLE" \
	>"$CX2/log" 2>&1 || true
check "an existing NON-summary file is not replaced by the fallback" \
	"$(cat "$CX2/security-summary.json")" "not json at all"
# sentinel-shield-harness: observation-only — the invariant is asserted by the `check` above;
# this only reports which refusal message the fallback emitted.
if grep -q 'never replaces an existing summary' "$CX2/log"; then
	pass "  and the refusal says the fallback never replaces an existing file"
else
	pass "  (the fallback declined without replacing it)"
fi

# The fallback DOES publish when nothing is there.
CX3="$WORK/create-exclusive-3"; mkdir -p "$CX3"
sh "$SELECT" --mode report-only --summary "$CX3/security-summary.json" --example "$EXAMPLE" \
	>"$CX3/log" 2>&1 || true
check "the fallback publishes when no summary exists" \
	"$(jq -r '.fallback.non_production' "$CX3/security-summary.json" 2>/dev/null)" "true"

# ---------------------------------------------------------------------------
# A duplicated mode key is ambiguous here too, not first-wins.
# ---------------------------------------------------------------------------
DM="$WORK/dup-mode"; mkdir -p "$DM"
printf 'SENTINEL_SHIELD_MODE=report-only\nSENTINEL_SHIELD_MODE=regulated\n' > "$DM/gates.env"
_c=0
sh "$SELECT" --gates-env "$DM/gates.env" --summary "$DM/security-summary.json" \
	--example "$EXAMPLE" >"$DM/log" 2>&1 || _c=$?
check "a duplicated SENTINEL_SHIELD_MODE is refused by the selector" "$_c" 2
if grep -q 'declares duplicate key(s): SENTINEL_SHIELD_MODE' "$DM/log"; then
	pass "  naming the ambiguity rather than taking the first value"
else
	fail "  the duplicate was not reported: $(head -2 "$DM/log")"
fi


printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '289-summary-publication-contract: ALL CHECKS PASSED\n'
	exit 0
fi
printf '289-summary-publication-contract: FAILURES PRESENT\n'
exit 1
