#!/bin/sh
# Sentinel Shield production test — the normalized-evidence trust boundary (#182).
#
# WHY THIS EXISTS
#
# Four collectors accepted a bare `{critical, high, medium}` object instead of native scanner
# output, so a three-number file became gate evidence:
#
#     echo '{"critical":0,"high":0,"medium":0}' > reports/raw/grype.json
#     -> { "status": "pass", "tool_report": { "health": "ok", ... } }
#
# `health: "ok"` is what made it dangerous. The shortcut did not merely skip parsing — it
# manufactured a POSITIVE assertion that the scanner ran and found nothing.
#
# The production rule is now: a native report Sentinel normalizes itself, or nothing. There is
# no digest-checked external path, because a SHA-256 proves the integrity of bytes and not who
# produced them — accepting a self-declared envelope on a digest would rebuild the same defect
# one layer up.
#
# The single most important assertion in this file is `envelope claiming native trust` below:
# `trust.type` is STAMPED by the normalizer after it parses native source, and is never
# honoured when it arrives as an input claim. A document cannot authorise itself.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$ROOT/scripts/lib/normalized-evidence.sh" ] || { fail "scripts/lib/normalized-evidence.sh is missing"; exit 1; }

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# The evidence binding is absolute: a collector reads no field until provenance proves a scan
# produced THIS report. These cases are about normalized evidence, not about binding, so they generate the
# sidecar a real transaction would have written instead of tripping over its absence. A forged or
# malformed report still gets REAL provenance — that is the point, it then reaches the guard the
# case is actually testing rather than being turned away one layer early.
. "$ROOT/tests/lib/collector-provenance.sh"

# collect <tool> <input-file> [extra-args...] — run a collector, print its JSON.
collect() {
	_c_tool=$1; _c_in=$2; shift 2
	( cd "$TMP" && cp_write "$_c_in" "$_c_tool.sh" && sh "$ROOT/scripts/collectors/$_c_tool.sh" --input "$_c_in" "$@" 2>/dev/null ) || true
}
# collect_unbound — same, with NO provenance generated. For cases whose subject is what happens to
# evidence nothing vouches for.
collect_unbound() {
	_cu_tool=$1; _cu_in=$2; shift 2
	( cd "$TMP" && sh "$ROOT/scripts/collectors/$_cu_tool.sh" --input "$_cu_in" "$@" 2>/dev/null ) || true
}
field() { printf '%s' "$1" | jq -r "$2 // \"\"" 2>/dev/null; }

# tool -> (native fixture json, raw filename)
# A real Grype report always carries `source` and `descriptor`, and a real osv-scanner result
# always records the manifest it came from. The bare `{"matches":[...]}` and `{"results":[...]}`
# stubs below were shorter than anything either scanner emits, so the per-tool validators refuse
# them — correctly. The fixtures are corrected to the native shape rather than the validators
# relaxed to accept a shape no scanner produces.
_GR_DESC='"source":{"type":"directory","target":"."},"descriptor":{"name":"grype","version":"0.74.0","db":{"built":"'"$(date -u +%Y-%m-%d)"'T00:00:00Z"}}'
native_json() {
	case "$1" in
	grype) printf '{"matches":[{"vulnerability":{"severity":"CRITICAL"}}],%s}' "$_GR_DESC" ;;
	codeql) printf '{"runs":[{"tool":{"driver":{"rules":[]}},"results":[{"level":"error"}]}]}' ;;
	osv-scanner) printf '{"results":[{"source":{"path":"go.mod"},"packages":[{"vulnerabilities":[{"id":"X"}]}]}]}' ;;
	dependency-check) printf '{"dependencies":[{"vulnerabilities":[{"severity":"CRITICAL"}]}]}' ;;
	esac
}
clean_native_json() {
	case "$1" in
	grype) printf '{"matches":[],%s}' "$_GR_DESC" ;;
	codeql) printf '{"runs":[{"tool":{"driver":{"rules":[]}},"results":[]}]}' ;;
	osv-scanner) printf '{"results":[{"source":{"path":"go.mod"},"packages":[]}]}' ;;
	dependency-check) printf '{"dependencies":[]}' ;;
	esac
}

TOOLS="grype codeql osv-scanner dependency-check"

# --- 1. the forged zero object — the reported defect ----------------------
for t in $TOOLS; do
	printf '{"critical":0,"high":0,"medium":0}\n' > "$TMP/$t.json"
	# DELIBERATELY UNBOUND. This case is about a forged object with no scan behind it, so giving
	# it provenance would change what is being tested. Since the evidence binding became
	# absolute, the refusal now happens one layer EARLIER — before any field is read — and reports
	# `unbound-evidence` rather than `untrusted-evidence`. Both are refusals and the earlier one
	# is the stronger claim, so either token satisfies "refused, not reported clean". The status
	# is still pinned to execution-error; only the layer that refused it may vary.
	out=$(collect_unbound "$t" "$t.json")
	_h=$(field "$out" .tool_report.health)
	if [ "$(field "$out" .status)" = "execution-error" ] && { [ "$_h" = "untrusted-evidence" ] || [ "$_h" = "unbound-evidence" ]; }; then
		pass "$t: a forged {critical,high,medium} object is refused, not reported clean"
	else
		fail "$t: forged zero object produced status=$(field "$out" .status) health=$(field "$out" .tool_report.health) — the #182 defect is back"
	fi
done

# --- 2. a self-declared envelope claiming native trust --------------------
# The load-bearing case. If this passes as evidence, everything above is decoration.
for t in $TOOLS; do
	jq -n '{envelope:"sentinel-shield/normalized-evidence@1",
	        producer:{tool:"x",normalizer:"sentinel-shield",normalizer_version:"1"},
	        trust:{type:"sentinel-native-normalization"},
	        counts:{critical:0,high:0,medium:0}}' > "$TMP/$t.json"
	out=$(collect "$t" "$t.json")
	if [ "$(field "$out" .status)" = "execution-error" ]; then
		pass "$t: an input CLAIMING trust.type=sentinel-native-normalization is refused"
	else
		fail "$t: an input granted itself native trust (status=$(field "$out" .status)) — a document must not authorise itself"
	fi
done

# --- 3. the valid native path ---------------------------------------------
for t in $TOOLS; do
	native_json "$t" > "$TMP/$t.json"
	out=$(cd "$TMP" && GITHUB_REPOSITORY=acme/app \
		GITHUB_SHA=1111111111111111111111111111111111111111 \
		cp_write "$t.json" "$t.sh"; sh "$ROOT/scripts/collectors/$t.sh" --input "$t.json" 2>/dev/null || true)
	_trust=$(field "$out" .tool_report.evidence.trust.type)
	_digest=$(field "$out" .tool_report.evidence.source.sha256)
	_commit=$(field "$out" .tool_report.evidence.target.commit)
	if [ "$_trust" = "sentinel-native-normalization" ] && [ -n "$_digest" ] && [ "$_commit" = "1111111111111111111111111111111111111111" ]; then
		pass "$t: a native report yields internally-stamped trust, a source digest and a target commit"
	else
		fail "$t: native path incomplete (trust=$_trust digest=${_digest:-none} commit=${_commit:-none})"
	fi
	# The counts must be DERIVED, not read: this fixture carries one real finding.
	if [ "$(field "$out" .status)" = "fail" ]; then
		pass "$t: counts are derived from the source report (one seeded finding -> fail)"
	else
		fail "$t: a seeded finding did not produce fail (status=$(field "$out" .status)) — counts may not be derived"
	fi
done

# --- 4. digest binds to the actual bytes ----------------------------------
native_json grype > "$TMP/grype.json"
d1=$(field "$(collect grype grype.json)" .tool_report.evidence.source.sha256)
clean_native_json grype > "$TMP/grype.json"
d2=$(field "$(collect grype grype.json)" .tool_report.evidence.source.sha256)
if [ -n "$d1" ] && [ -n "$d2" ] && [ "$d1" != "$d2" ]; then
	pass "the source digest changes when the source report changes"
else
	fail "the source digest did not track the source content (d1=${d1:-none} d2=${d2:-none})"
fi

# --- 5. a malformed commit is recorded as null, never as an identity ------
native_json grype > "$TMP/grype.json"
out=$(cd "$TMP" && GITHUB_REPOSITORY=acme/app GITHUB_SHA="not-a-commit" \
	cp_write grype.json grype.sh; sh "$ROOT/scripts/collectors/grype.sh" --input grype.json 2>/dev/null || true)
if [ -z "$(field "$out" .tool_report.evidence.target.commit)" ]; then
	pass "a malformed commit becomes null rather than being carried as a target identity"
else
	fail "a malformed commit was recorded as an identity: $(field "$out" .tool_report.evidence.target.commit)"
fi
out=$(cd "$TMP" && GITHUB_REPOSITORY=acme/app GITHUB_SHA=$(printf '1%.0s' 1 2 3 4 5 6 7 8 9 0) \
	cp_write grype.json grype.sh; sh "$ROOT/scripts/collectors/grype.sh" --input grype.json 2>/dev/null || true)
if [ -z "$(field "$out" .tool_report.evidence.target.commit)" ]; then
	pass "a short (non-40-hex) commit is rejected as a target identity"
else
	fail "a short commit was accepted as a target identity"
fi

# --- 6. fixture mode needs EVERY condition --------------------------------
mk_fixture() { jq -n '{envelope:"sentinel-shield/normalized-evidence@1",trust:{type:"fixture"},counts:{critical:0,high:0,medium:0}}' > "$TMP/grype.json"; }

mk_fixture
if [ "$(field "$(collect grype grype.json)" .status)" = "execution-error" ]; then
	pass "fixture: a fixture-labelled envelope WITHOUT the explicit flag is refused"
else
	fail "fixture: a fixture envelope was accepted without the explicit invocation flag"
fi

mk_fixture
out=$(collect grype grype.json --fixture-evidence)
if [ "$(field "$out" .status)" = "pass" ] && [ "$(field "$out" .tool_report.non_production)" = "true" ] \
	&& [ "$(field "$out" .tool_report.evidence.trust.type)" = "fixture" ]; then
	pass "fixture: explicit flag + fixture label + non-release is accepted and stamped non_production"
else
	fail "fixture: the permitted path did not produce a stamped non-production result (status=$(field "$out" .status) np=$(field "$out" .tool_report.non_production))"
fi

mk_fixture
out=$(cd "$TMP" && cp_write grype.json grype.sh; GITHUB_REF=refs/tags/v9.9.9 sh "$ROOT/scripts/collectors/grype.sh" \
	--input grype.json --fixture-evidence 2>/dev/null || true)
if [ "$(field "$out" .status)" = "execution-error" ]; then
	pass "fixture: refused in a RELEASE context even with the explicit flag"
else
	fail "fixture: accepted in a release context — the conditions are not independent"
fi

mk_fixture
out=$(cd "$TMP" && cp_write grype.json grype.sh; SENTINEL_SHIELD_RELEASE_CONTEXT=1 sh "$ROOT/scripts/collectors/grype.sh" \
	--input grype.json --fixture-evidence 2>/dev/null || true)
if [ "$(field "$out" .status)" = "execution-error" ]; then
	pass "fixture: refused when SENTINEL_SHIELD_RELEASE_CONTEXT is set"
else
	fail "fixture: accepted despite an explicit release-context marker"
fi

# --- 7. enforcing modes reject non-production tool evidence ---------------
# Counts are all zero, so this can only be caught by the LABEL.
for mode in baseline strict regulated; do
	jq -n --arg m "$mode" '{
		schema_version:"1", mode:$m,
		summary:{secrets:0,critical_vulnerabilities:0,high_vulnerabilities:0,medium_vulnerabilities:0},
		tools:{grype:{status:"pass",critical:0,high:0,medium:0,non_production:true,
		              evidence:{trust:{type:"fixture"}}}}
	}' > "$TMP/summary-$mode.json"
	if grep -q 'non_production' "$ROOT/scripts/enforce-gates.sh"; then
		:
	else
		fail "enforce-gates.sh carries no non_production check at all"
		break
	fi
done
# Structural assertion: the refusal must cover every enforcing mode, keyed on the label.
_blk=$(grep -A12 'the same principle one level DOWN' "$ROOT/scripts/enforce-gates.sh" | grep -c 'baseline | strict | regulated' || true)
if [ "${_blk:-0}" -ge 1 ]; then
	pass "enforce-gates refuses non-production tool evidence in baseline/strict/regulated"
else
	fail "the non-production tool-evidence refusal does not cover all enforcing modes"
fi
if grep -vE '^[[:space:]]*#' "$ROOT/scripts/enforce-gates.sh" | grep -q 'non_production // false) == true'; then
	pass "the refusal keys on the non_production label, not on counts"
else
	fail "no label-keyed non_production refusal found in enforce-gates.sh"
fi

# --- 8. no collector still accepts a bare count object --------------------
_left=$(grep -l '\.critical? | type) == "number"' "$ROOT"/scripts/collectors/*.sh 2>/dev/null | tr '\n' ' ')
if [ -z "$_left" ]; then
	pass "no collector accepts a bare count object as a native shape"
else
	fail "collector(s) still accept bare count objects: $_left"
fi

# --- 9. the gate must not be callable in a subshell -----------------------
# The first implementation printed its decision and called `exit` on refusal, so callers wrote
# `NE_KIND=$(ne_gate_input ...)`. Command substitution is a subshell: the exit killed the
# subshell and the collector carried on, so a forged object still produced pass/ok. The
# refusal path existed, was correct, and never fired. Assert the call shape that made it work.
_bad_call=$(grep -ln 'NE_KIND=\$(ne_gate_input' "$ROOT"/scripts/collectors/*.sh 2>/dev/null | tr '\n' ' ')
if [ -z "$_bad_call" ]; then
	pass "no collector calls ne_gate_input inside a command substitution"
else
	fail "collector(s) call ne_gate_input in a subshell, so its refusal cannot stop them: $_bad_call"
fi
# The call spans a line continuation, so the guard must be matched across lines rather than
# with a per-line grep — a per-line grep reported every collector unguarded while all four
# were in fact correct, which is a false alarm in the same family as a vacuous pass.
_unguarded=0
for t in $TOOLS; do
	# The jq recognizer argument itself contains `|`, so the span cannot be expressed as
	# [^|]*; bound it by length instead.
	# Comments are stripped first: the surrounding explanation mentions ne_gate_input by name,
	# and matching from there pushes the guard outside the window. Match the INVOCATION.
	if grep -vE '^[[:space:]]*#' "$ROOT/scripts/collectors/$t.sh" | tr '\n' ' ' \
		| grep -q 'ne_gate_input.\{0,200\}|| exit 0'; then
		:
	else
		fail "$t: ne_gate_input is not guarded with '|| exit 0'"
		_unguarded=1
	fi
done
# `if`, not `[ ] && pass`: under `set -e` a false trailing test exits the suite, which would
# turn a real finding into a silent early termination.
if [ "$_unguarded" = 0 ]; then
	pass "every migrated collector guards ne_gate_input with '|| exit 0'"
fi

# ===========================================================================
# The tri-state execution contract (#204 C1), asserted DIRECTLY on the matrix
# ===========================================================================
# WHY THIS IS HERE AND NOT ONLY IN 118/269.
#
# C1's headline property is that no legal caller operation can turn `unobserved` into
# `observed-complete`. 118 and 269 prove the CONSEQUENCE — an unobserved producer never
# reaches a clean verdict — by driving collectors. They cannot prove the property itself,
# because after C1 no collector passes a boolean any more.
#
# Measured, not assumed: mutating ne_status_consistency to accept `true` as complete again
# broke ZERO assertions across the whole suite. The leniency was unreachable through the
# collectors, so the strictness arm had no regression at all. These assertions call the matrix
# directly, which is the only place that arm is observable.
. "$ROOT/scripts/lib/normalized-evidence.sh"

_sc() { ne_status_consistency "$1" "$2" "$3"; }

# The three declared states behave as specified.
[ "$(_sc pass 0 observed-complete)" = "valid-clean" ] \
	&& pass "C1: observed-complete + zero + pass -> valid-clean" \
	|| fail "C1: observed-complete + zero + pass gave $(_sc pass 0 observed-complete)"
[ "$(_sc findings 3 observed-complete)" = "valid-findings" ] \
	&& pass "C1: observed-complete + findings -> valid-findings" \
	|| fail "C1: observed-complete + findings gave $(_sc findings 3 observed-complete)"
case "$(_sc pass 0 observed-incomplete)" in
invalid:*) pass "C1: observed-incomplete is NEVER clean ($(_sc pass 0 observed-incomplete))" ;;
*) fail "C1: observed-incomplete + zero produced $(_sc pass 0 observed-incomplete)" ;;
esac
case "$(_sc pass 0 unobserved)" in
invalid:unobserved-zero-is-not-a-measured-clean) pass "C1: unobserved + zero is NEVER clean" ;;
*) fail "C1: unobserved + zero produced $(_sc pass 0 unobserved)" ;;
esac
# Findings from an unobserved producer are REAL — something was found. What the run cannot
# support is the claim that this is all there was, so it gets its own verdict rather than
# being discarded or promoted.
[ "$(_sc findings 3 unobserved)" = "valid-findings-unobserved" ] \
	&& pass "C1: unobserved + findings is a lower-bound signal, not a complete scan" \
	|| fail "C1: unobserved + findings gave $(_sc findings 3 unobserved)"

# THE STRICTNESS ARM. Every one of these was a legal third argument before C1.
for _bad in true false 1 0 "" "complete" "yes"; do
	case "$(_sc pass 0 "$_bad")" in
	invalid:execution-state-not-declared-*)
		pass "C1: '${_bad:-<empty>}' is refused as an execution state, not interpreted" ;;
	*)
		fail "C1: '${_bad:-<empty>}' was accepted as an execution state -> $(_sc pass 0 "$_bad")" ;;
	esac
done

# A contradiction outranks the observation question: it is untrusted evidence either way, and
# must not be reported as merely unobserved.
case "$(_sc pass 3 unobserved)" in
invalid:raw-status-pass-with-3-violations) pass "C1: a contradiction is judged before the unobserved split" ;;
*) fail "C1: an unobserved contradiction reported as $(_sc pass 3 unobserved)" ;;
esac

# ne_execution_state must derive `unobserved` from honestly-recorded evidence. `observed:false`
# is the exact shape jq's `//` swallows (#320), so it is asserted rather than assumed.
[ "$(ne_execution_state "$NE_EXEC_UNOBSERVED")" = "unobserved" ] \
	&& pass "C1: the unobserved constant derives to the unobserved state" \
	|| fail "C1: NE_EXEC_UNOBSERVED derived to $(ne_execution_state "$NE_EXEC_UNOBSERVED")"
[ "$(ne_execution_state '{"observed":true,"completed":true}')" = "observed-complete" ] \
	&& pass "C1: observed+completed derives to observed-complete" \
	|| fail "C1: observed+completed derived wrongly"
[ "$(ne_execution_state '{"observed":true,"completed":false}')" = "observed-incomplete" ] \
	&& pass "C1: observed+not-completed derives to observed-incomplete" \
	|| fail "C1: observed+not-completed derived wrongly"
# Observed but with NO completion verdict is not a completion verdict.
[ "$(ne_execution_state '{"observed":true}')" = "unobserved" ] \
	&& pass "C1: observed with no completion verdict is not treated as complete" \
	|| fail "C1: observed with no completion verdict derived to $(ne_execution_state '{"observed":true}')"

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d normalized-evidence check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nnormalized-evidence: OK (4 collectors migrated; forged, self-declared and fixture inputs all refused)\n'
exit 0
