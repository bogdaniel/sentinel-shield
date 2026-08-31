#!/bin/sh
# tests/prod/312-collector-contract.sh — THE COLLECTOR OUTPUT CONTRACT (#145).
#
# ss_emit_collector is where a collector's evidence becomes a document. Before #145 it checked
# that its two JSON arguments PARSED and that override KEYS were canonical, and nothing else.
# Everything below was accepted on master (53eb365), identically under sh, dash and bash:
#
#   status vocabulary   ss_emit_collector probe totally-bogus '{}' '{}'      -> exit 0
#   status agreement    outer "pass" beside tool_report {"status":"fail"}    -> exit 0
#   negative count      {"secrets":-1}   reached .summary.secrets = -1, and build-security-
#                       summary.sh SUMS across collectors, so one -1 cancels another
#                       scanner's real finding and the aggregate resolves clean.
#   fractional          {"secrets":1.5}                                      -> exit 0
#   wrong type          {"secrets":"3"} / true / null / [1] / {"a":1}        -> exit 0
#   unbounded           {"secrets":2147483648} and 99999999999999999999      -> exit 0,
#                       above the #146 maximum the enforcer then feeds to shell arithmetic.
#   contradiction       status "pass" beside {"critical_vulnerabilities":5}  -> exit 0
#   swallowed refusal   ss_shape_or_fail / ss_counts_or_fail emit and then `exit 0`
#                       UNCONDITIONALLY, so a refused emit became a collector that exited 0
#                       having printed nothing — and build-security-summary.sh's guard used
#                       `jq -c`, which exits 0 on EMPTY input, so the collector was dropped
#                       from the aggregate in silence.
#
# #145 does not create a second numeric policy: the integer class is decided by #146's
# ss_count_valid and SS_MAX_COUNT. This suite proves that by NEUTERING those primitives and
# requiring the emitter's verdict to change.
#
# Self-contained, NETWORK-FREE. jq is required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
LIB="$ROOT/scripts/lib/sentinel-shield-common.sh"
SCHEMA="$ROOT/schemas/security-summary.schema.json"
GATES="$ROOT/scripts/enforce-gates.sh"
BUILD="$ROOT/scripts/build-security-summary.sh"
DOC="$ROOT/docs/collector-output-contract.md"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n'; exit 1; }
for _f in "$LIB" "$SCHEMA" "$GATES" "$BUILD" "$DOC"; do
	[ -f "$_f" ] || { printf 'FAIL: missing %s\n' "$_f"; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$LIB"

MAX=2147483647   # 2^31-1, this suite's own expectation of the #146 maximum
OVER=2147483648
# The suite's expectation must be the LIBRARY's constant, asserted directly and not only through
# the schema and the documentation. Every label below — "exactly SS_MAX_COUNT is accepted", the
# raised-bound mutant — names $MAX; if SS_MAX_COUNT moved, those labels would describe a bound the
# emitter no longer enforces while the assertions still passed against a stale literal.
[ "${SS_MAX_COUNT:-unset}" = "$MAX" ] \
	&& pass "(0) SS_MAX_COUNT is $MAX, the bound this suite names throughout" \
	|| fail "(0) SS_MAX_COUNT is '${SS_MAX_COUNT:-unset}', not $MAX — every bound label below is misattributed"

# emit <status> <report> <overrides> — run the REAL emitter in a subshell and report
# "<rc>|<stdout>". The subshell matters: the emitter exits (not returns) on refusal, which is
# what makes every `emit && exit 0` caller in the library fail closed.
emit() { _o=$( ss_emit_collector probe "$1" "$2" "$3" 2>/dev/null ) && _r=0 || _r=$?; printf '%s|%s' "$_r" "$_o"; }
# emit_err <status> <report> <overrides> — the diagnostic text of a refusal (stderr only).
# The subshell is mandatory: the emitter EXITS on refusal, so calling it in the current shell
# would end this suite mid-run and report a pass count for assertions that never executed.
emit_err() { ( ss_emit_collector probe "$1" "$2" "$3" 2>&1 >/dev/null ) || :; }

# refused <label> <status> <report> <overrides> — must exit non-zero AND publish nothing.
# A non-zero exit alone is not evidence: the emitter could have written a partial document
# first, so the empty stdout is asserted separately.
refused() {
	_l=$1; shift
	_x=$(emit "$@")
	case "$_x" in
		0\|*)  fail "$_l: ACCEPTED (rc=0)" ;;
		*\|)   pass "$_l: refused, nothing published" ;;
		*)     fail "$_l: refused (rc=${_x%%|*}) but PUBLISHED '${_x#*|}'" ;;
	esac
}
# accepted <label> <jq-filter> <expected> <status> <report> <overrides>
accepted() {
	_l=$1; _f=$2; _e=$3; shift 3
	_x=$(emit "$@")
	if [ "${_x%%|*}" != "0" ]; then fail "$_l: REFUSED (rc=${_x%%|*}) — a valid case must be accepted"; return; fi
	_g=$(printf '%s' "${_x#*|}" | jq -r "$_f" 2>/dev/null || printf 'UNREADABLE')
	[ "$_g" = "$_e" ] && pass "$_l" || fail "$_l: $_f = '$_g', want '$_e'"
}

# sorted_set <space-separated> — one token per line, sorted, blanks dropped.
sorted_set() { printf '%s' "$1" | tr ' ' '\n' | grep . | sort; }
# same_set <label> <file-a> <file-b> — set equality that REFUSES to compare nothing.
# Two empty selectors compare equal, and "identical" is exactly the wrong word for it; a
# comparison whose sides are both empty is a broken selector, not agreement.
same_set() {
	_l=$1; _a=$2; _b=$3
	if [ ! -s "$_a" ] || [ ! -s "$_b" ]; then
		fail "$_l: a side of the comparison is EMPTY (a=$(wc -l <"$_a" | tr -d ' ') b=$(wc -l <"$_b" | tr -d ' ')) — the selector is broken, not the sets equal"
		return 1
	fi
	if cmp -s "$_a" "$_b"; then
		pass "$_l ($(wc -l <"$_a" | tr -d ' ') keys)"
		return 0
	fi
	fail "$_l: only-in-first=[$(comm -23 "$_a" "$_b" | tr '\n' ' ')] only-in-second=[$(comm -13 "$_a" "$_b" | tr '\n' ' ')]"
	return 1
}

# ============================================================================
# (1) THE CONTRACT LISTS ARE MECHANICALLY THE SCHEMA'S AND THE ENFORCER'S.
#
# Every list in the library is a COPY, kept for runtime independence from the schema file. A
# copy that nothing compares is a copy that drifts, so each one is reconciled here against the
# authority it was copied from.
# ============================================================================
jq -r '.properties.tools.additionalProperties.properties.status.enum[]' "$SCHEMA" | sort > "$WORK/st-schema"
sorted_set "$SS_COLLECTOR_STATUSES" > "$WORK/st-lib"
same_set "(1) SS_COLLECTOR_STATUSES is exactly the schema's tool status enum" "$WORK/st-lib" "$WORK/st-schema" || :

# The three type-class lists must be exactly the schema's non-default types. `boolean` and
# `number` are selected from the schema by TYPE, not by name, so a renamed or newly added field
# lands in the comparison automatically.
jq -r '.properties.summary.properties | to_entries[] | select(.value.type == "boolean") | .key' "$SCHEMA" | sort > "$WORK/bool-schema"
sorted_set "$SS_SUMMARY_BOOL_KEYS" > "$WORK/bool-lib"
same_set "(1) SS_SUMMARY_BOOL_KEYS is exactly the schema's boolean summary fields" "$WORK/bool-lib" "$WORK/bool-schema" || :

jq -r '.properties.summary.properties | to_entries[] | select(.value.type == "number" and .value.maximum == 100) | .key' "$SCHEMA" | sort > "$WORK/ratio-schema"
sorted_set "$SS_SUMMARY_RATIO_KEYS" > "$WORK/ratio-lib"
same_set "(1) SS_SUMMARY_RATIO_KEYS is exactly the schema's 0..100 number fields" "$WORK/ratio-lib" "$WORK/ratio-schema" || :

# The metric class is selected by its CEILING, not by the absence of one. It used to be
# `.maximum == null` — a selector that could only ever describe an unbounded field, so bounding
# the two keys would have emptied it and the class would have gone unchecked. Selecting on the
# ceiling means the list and the schema now have to agree about the NUMBER.
jq -r --argjson max "$MAX" '.properties.summary.properties | to_entries[] | select(.value.type == "number" and .value.maximum == $max) | .key' "$SCHEMA" | sort > "$WORK/metric-schema"
sorted_set "$SS_SUMMARY_METRIC_KEYS" > "$WORK/metric-lib"
same_set "(1) SS_SUMMARY_METRIC_KEYS is exactly the schema's number fields bounded at $MAX" "$WORK/metric-lib" "$WORK/metric-schema" || :

# EVERY numeric summary field carries an explicit maximum. This is the forgotten-field control
# for the whole vocabulary: `complexity_max` and `complexity_average` were `number` with no
# `maximum` at all, so the schema declared them unbounded while build-security-summary.sh was
# already refusing them above SS_MAX_COUNT — a contract that disagreed with its own enforcement.
_unbounded=$(jq -r '[ .properties.summary.properties | to_entries[]
	| select((.value.type == "number" or .value.type == "integer") and .value.maximum == null)
	| .key ] | join(" ")' "$SCHEMA")
[ -z "$_unbounded" ] \
	&& pass "(1) every numeric summary field in the schema carries an explicit maximum" \
	|| fail "(1) numeric summary field(s) declared with NO maximum: $_unbounded"
# CONTROL: the detector must actually see a missing maximum, or the check above is decoration.
jq 'del(.properties.summary.properties.complexity_max.maximum)' "$SCHEMA" > "$WORK/schema-unbounded.json"
_ctl=$(jq -r '[ .properties.summary.properties | to_entries[]
	| select((.value.type == "number" or .value.type == "integer") and .value.maximum == null)
	| .key ] | join(" ")' "$WORK/schema-unbounded.json")
[ "$_ctl" = "complexity_max" ] \
	&& pass "(1) CONTROL: the missing-maximum detector sees a maximum that was deleted" \
	|| fail "(1) the missing-maximum detector reported '$_ctl' on a schema with one deleted"
# And every numeric maximum in the summary is one of the two DECLARED ceilings — SS_MAX_COUNT
# for counts and metrics, 100 for percentages. A third value would be an invented constant.
_maxima=$(jq -r '[ .properties.summary.properties[] | select(.type == "number" or .type == "integer") | .maximum ] | unique | map(tostring) | join(",")' "$SCHEMA")
[ "$_maxima" = "100,$MAX" ] \
	&& pass "(1) the summary declares exactly two numeric ceilings: 100 and $MAX" \
	|| fail "(1) summary numeric maxima are [$_maxima], expected exactly [100,$MAX]"

# The three classes must not overlap, and every remaining canonical key is therefore the
# DEFAULT bounded-integer class. Without this, a key could sit in two lists and the first
# branch would silently decide it.
_ovl=$(cat "$WORK/bool-lib" "$WORK/ratio-lib" "$WORK/metric-lib" | sort | uniq -d | tr '\n' ' ')
[ -z "$_ovl" ] && pass "(1) the three type-class lists are disjoint" \
	|| fail "(1) key(s) in more than one type class: $_ovl"

# The gating set is exactly enforce-gates.sh's five COUNT-gate lists, minus the declared
# census carve-out. Parsed out of the enforcer rather than restated, so adding a gate there
# and forgetting it here is a failure, not a silent hole in the invariant.
_gate_src=""
for _v in INT_SUMMARY_KEYS THIRD_PARTY_KEYS ENTERPRISE_COUNT_KEYS QUALITY_COUNT_KEYS TESTING_DISCIPLINE_COUNT_KEYS; do
	_line=$(sed -n "s/^$_v=\"\\(.*\\)\"\$/\\1/p" "$GATES")
	[ -n "$_line" ] || { fail "(1) could not read $_v from enforce-gates.sh"; continue; }
	_gate_src="$_gate_src $_line"
done
sorted_set "$_gate_src" > "$WORK/gates-enforcer"
sorted_set "$SS_GATING_SUMMARY_KEYS $SS_NONGATING_COUNT_KEYS" > "$WORK/gates-lib"
same_set "(1) gating + non-gating equals enforce-gates.sh's count gates exactly" "$WORK/gates-lib" "$WORK/gates-enforcer" || :

# The carve-out is a CLOSED list, not an escape hatch that grows quietly.
[ "$SS_NONGATING_COUNT_KEYS" = "skipped_tests" ] \
	&& pass "(1) the non-gating carve-out is exactly skipped_tests" \
	|| fail "(1) SS_NONGATING_COUNT_KEYS is '$SS_NONGATING_COUNT_KEYS'; a widened carve-out weakens the invariant for every collector"

# Every gating key must also be a canonical summary key, or the invariant guards a field that
# can never be emitted.
_stray=""
for _k in $SS_GATING_SUMMARY_KEYS $SS_NONGATING_COUNT_KEYS; do
	ss_in_set "$_k" "$SS_SUMMARY_KEYS" || _stray="$_stray $_k"
done
[ -z "$_stray" ] && pass "(1) every gating key is a canonical summary key" \
	|| fail "(1) gating key(s) outside the canonical summary set:$_stray"

# No gating key may be boolean or fractional: the invariant compares with `-gt 0`.
_badcls=""
for _k in $SS_GATING_SUMMARY_KEYS; do
	if ss_in_set "$_k" "$SS_SUMMARY_BOOL_KEYS" || ss_in_set "$_k" "$SS_SUMMARY_RATIO_KEYS" || ss_in_set "$_k" "$SS_SUMMARY_METRIC_KEYS"; then
		_badcls="$_badcls $_k"
	fi
done
[ -z "$_badcls" ] && pass "(1) every gating key is in the integer class" \
	|| fail "(1) gating key(s) are not integers:$_badcls"

# The documentation states the same contract. Prose is not the authority, but prose that
# contradicts the code is worse than none.
_docmiss=""
for _s in $SS_COLLECTOR_STATUSES; do grep -q -- "\`$_s\`" "$DOC" || _docmiss="$_docmiss $_s"; done
[ -z "$_docmiss" ] && pass "(1) docs/collector-output-contract.md lists every status in the vocabulary" \
	|| fail "(1) status(es) missing from the contract doc:$_docmiss"
grep -q "$MAX" "$DOC" \
	&& pass "(1) the contract doc states the #146 maximum $MAX" \
	|| fail "(1) the contract doc does not state the bounded maximum"
grep -q "skipped_tests" "$DOC" \
	&& pass "(1) the contract doc names the non-gating carve-out" \
	|| fail "(1) the contract doc does not name the non-gating carve-out"

# ============================================================================
# (2) OUTER STATUS VOCABULARY.
# ============================================================================
for _s in $SS_COLLECTOR_STATUSES; do
	accepted "(2) CONTROL: '$_s' is accepted" '.status' "$_s" "$_s" "$(jq -n --arg s "$_s" '{status:$s}')" '{}'
done
refused "(2) an invented outer status" totally-bogus '{}' '{}'
refused "(2) an empty outer status"    ''            '{}' '{}'
refused "(2) an outer status with an embedded newline" 'pass
fail' '{}' '{}'
refused "(2) a status differing only in case" Pass '{}' '{}'
refused "(2) a status that is a superstring of a valid one" passx '{}' '{}'
# ss_in_set must not match a SUBSTRING: "as" is inside "pass" and must not be a status.
refused "(2) a status that is a substring of a valid one" as '{}' '{}'

# ============================================================================
# (3) STATUS AGREEMENT — the documented mapping is IDENTITY.
# ============================================================================
accepted "(3) CONTROL: agreeing statuses are accepted" '.tool_report.status' 'fail' \
	fail '{"status":"fail","findings":3}' '{"test_failures":3}'
accepted "(3) CONTROL: a tool report with NO status makes no claim" '.status' 'pass' \
	pass '{"findings":0}' '{}'
refused "(3) outer pass beside tool_report fail"            pass '{"status":"fail"}' '{}'
refused "(3) outer pass beside tool_report execution-error" pass '{"status":"execution-error"}' '{}'
refused "(3) outer fail beside tool_report pass"            fail '{"status":"pass"}' '{}'
refused "(3) a non-string tool_report status"               pass '{"status":1}'      '{}'
refused "(3) a tool_report status that is an object"        pass '{"status":{"a":1}}' '{}'
# AN EXPLICIT NULL IS A SUPPLIED STATUS, NOT AN ABSENT ONE. jq returns `null` both for a missing
# key and for `"status": null`, so a `(.status | type) == "null"` test conflated them and let a
# producer opt OUT of the agreement check by writing null rather than omitting the field. The
# production test is `has("status")`, and these two cases must therefore diverge.
refused "(3) an explicit null tool_report status"           pass '{"status":null}'   '{}'
refused "(3) an explicit null status beside a fail outer"   fail '{"status":null}'   '{}'
accepted "(3) CONTROL: the key being ABSENT still makes no claim" '.status' 'pass' \
	pass '{"findings":0,"health":"ok"}' '{}'
# The two must be distinguishable at the jq level, or the production branch is guessing.
_n1=$(printf '%s' '{"status":null}' | jq -r 'has("status")')
_n2=$(printf '%s' '{"findings":0}'  | jq -r 'has("status")')
_n3=$(printf '%s' '{"status":null}' | jq -r '.status | type')
_n4=$(printf '%s' '{"findings":0}'  | jq -r '.status | type')
[ "$_n1" = "true" ] && [ "$_n2" = "false" ] && [ "$_n3" = "null" ] && [ "$_n4" = "null" ] \
	&& pass "(3) has(\"status\") separates an explicit null from an absent key; (.status|type) does NOT" \
	|| fail "(3) the has()/type distinction did not reproduce (has=$_n1/$_n2 type=$_n3/$_n4)"
# The refusal must NAME the disagreement, or an operator cannot act on it.
emit_err pass '{"status":"fail"}' '{}' > "$WORK/e3" 2>&1 || :
grep -q "while its tool_report claims" "$WORK/e3" \
	&& pass "(3) the refusal diagnostic names the status disagreement" \
	|| fail "(3) the disagreement refusal is not attributable: $(head -1 "$WORK/e3")"

# ============================================================================
# (4) THE DOOR IS OPEN — EVERY canonical key, at 0 and at its class maximum.
#
# A validator that refuses everything would pass every negative test in this file. This block
# is the positive control for the whole contract: each of the 68 canonical keys is emitted at
# both ends of its declared range and must LAND in .summary with the value supplied.
# ============================================================================
_k0=0; _kmax=0; _kbad=""
for _k in $SS_SUMMARY_KEYS; do
	if ss_in_set "$_k" "$SS_SUMMARY_BOOL_KEYS"; then
		_lo=false; _hi=true
	elif ss_in_set "$_k" "$SS_SUMMARY_RATIO_KEYS"; then
		_lo=0; _hi=100
	elif ss_in_set "$_k" "$SS_SUMMARY_METRIC_KEYS"; then
		_lo=0; _hi=$MAX
	else
		_lo=0; _hi=$MAX
	fi
	# A positive gating count is only honest beside a non-clean status, so the high end of a
	# gating key is emitted as `fail`. That is the contract, not a workaround for it.
	if ss_in_set "$_k" "$SS_GATING_SUMMARY_KEYS"; then _hs=fail; else _hs=pass; fi

	_x=$(emit pass "$(jq -n --arg s pass '{status:$s}')" "$(jq -n --arg k "$_k" --argjson v "$_lo" '{($k):$v}')")
	if [ "${_x%%|*}" = "0" ] && [ "$(printf '%s' "${_x#*|}" | jq -r --arg k "$_k" '.summary[$k]')" = "$_lo" ]; then
		_k0=$((_k0 + 1))
	else _kbad="$_kbad $_k@lo"; fi

	_x=$(emit "$_hs" "$(jq -n --arg s "$_hs" '{status:$s}')" "$(jq -n --arg k "$_k" --argjson v "$_hi" '{($k):$v}')")
	if [ "${_x%%|*}" = "0" ] && [ "$(printf '%s' "${_x#*|}" | jq -r --arg k "$_k" '.summary[$k]')" = "$_hi" ]; then
		_kmax=$((_kmax + 1))
	else _kbad="$_kbad $_k@hi"; fi
done
_ktot=$(sorted_set "$SS_SUMMARY_KEYS" | wc -l | tr -d ' ')
if [ -z "$_kbad" ] && [ "$_k0" = "$_ktot" ] && [ "$_kmax" = "$_ktot" ]; then
	pass "(4) all $_ktot canonical keys accepted at their low AND high bound, and each value reached .summary"
else
	fail "(4) canonical key(s) rejected or lost at a bound:$_kbad (lo ok=$_k0/$_ktot, hi ok=$_kmax/$_ktot)"
fi
# And the merge is a MERGE: an override must not wipe the zeroed defaults beside it.
accepted "(4) CONTROL: an override leaves the sibling defaults in place" '.summary.critical_vulnerabilities' '0' \
	fail '{"status":"fail"}' '{"secrets":1}'
accepted "(4) CONTROL: no override at all yields the zeroed default summary" '[.summary | to_entries[] | select(.value != 0)] | length' '0' \
	pass '{"status":"pass"}' '{}'

# ============================================================================
# (5) ADVERSARIAL VALUES — each refused, for the intended reason.
# ============================================================================
refused "(5) negative integer"            fail '{"status":"fail"}' '{"secrets":-1}'
refused "(5) fractional integer-class"    fail '{"status":"fail"}' '{"secrets":1.5}'
refused "(5) numeric string"              fail '{"status":"fail"}' '{"secrets":"3"}'
refused "(5) boolean in an integer field" fail '{"status":"fail"}' '{"secrets":true}'
refused "(5) null value"                  fail '{"status":"fail"}' '{"secrets":null}'
refused "(5) array value"                 fail '{"status":"fail"}' '{"secrets":[1]}'
refused "(5) nested object value"         fail '{"status":"fail"}' '{"secrets":{"a":1}}'
refused "(5) SS_MAX_COUNT + 1"            fail '{"status":"fail"}' "{\"secrets\":$OVER}"
refused "(5) an arbitrarily large integer" fail '{"status":"fail"}' '{"secrets":99999999999999999999}'
refused "(5) a number in a boolean field" pass '{"status":"pass"}' '{"missing_sbom":1}'
refused "(5) a string in a boolean field" pass '{"status":"pass"}' '{"missing_sbom":"true"}'
refused "(5) a percentage above 100"      pass '{"status":"pass"}' '{"coverage_line_percent":100.1}'
refused "(5) a negative percentage"       pass '{"status":"pass"}' '{"coverage_line_percent":-0.5}'
refused "(5) an unbounded metric"         pass '{"status":"pass"}' "{\"complexity_average\":$OVER}"
refused "(5) a negative metric"           pass '{"status":"pass"}' '{"complexity_average":-1}'
refused "(5) overrides that are an array"  pass '{"status":"pass"}' '[]'
refused "(5) overrides that are a string"  pass '{"status":"pass"}' '"secrets"'
refused "(5) overrides that are a scalar"  pass '{"status":"pass"}' '7'
refused "(5) overrides that are JSON null" pass '{"status":"pass"}' 'null'
refused "(5) overrides that are not JSON"  pass '{"status":"pass"}' '{secrets:1}'
refused "(5) a tool report that is not JSON" pass '{oops' '{}'
refused "(5) an empty tool report string"  pass ''      '{}'
refused "(5) an empty overrides string"    pass '{}'    ''

# Boundary attribution: MAX is accepted, MAX+1 is not, and the DIFFERENCE is the bound.
accepted "(5) CONTROL: exactly SS_MAX_COUNT is accepted" '.summary.secrets' "$MAX" \
	fail '{"status":"fail"}' "{\"secrets\":$MAX}"
accepted "(5) CONTROL: a percentage of exactly 100 is accepted" '.summary.coverage_line_percent' '100' \
	pass '{"status":"pass"}' '{"coverage_line_percent":100}'
accepted "(5) CONTROL: a FRACTIONAL percentage is accepted, not floored" '.summary.coverage_line_percent' '87.5' \
	pass '{"status":"pass"}' '{"coverage_line_percent":87.5}'
accepted "(5) CONTROL: a fractional metric is accepted, not floored" '.summary.complexity_average' '12.75' \
	pass '{"status":"pass"}' '{"complexity_average":12.75}'
accepted "(5) CONTROL: a boolean evidence flag is accepted" '.summary.missing_sbom' 'true' \
	pass '{"status":"pass"}' '{"missing_sbom":true}'
# NEVER COERCED. If any of these were rounded/clamped instead of refused, the emitter would
# have exited 0 with an altered value — the #146 failure mode, re-checked at this boundary.
for _v in 1.5 -1 "$OVER" 99999999999999999999; do
	_x=$(emit fail '{"status":"fail"}' "{\"secrets\":$_v}")
	case "$_x" in
		0\|*) fail "(5) '$_v' was COERCED to $(printf '%s' "${_x#*|}" | jq -r '.summary.secrets')" ;;
		*)    pass "(5) '$_v' is refused, never rounded or clamped" ;;
	esac
done
# --- (5m) THE TWO COMPLEXITY METRICS ARE BOUNDED, AND STILL FRACTIONAL ------------------
#
# `complexity_max` and `complexity_average` are the only summary numbers that are neither
# counts nor percentages. The schema declared them `number, minimum 0` with NO maximum, while
# build-security-summary.sh was ALREADY refusing every summary number above SS_MAX_COUNT — a
# contract that disagreed with its own enforcement. The ceiling is SS_MAX_COUNT, not a constant
# invented for them: it is the bound already in force downstream, and the one their sibling
# worst-observed metrics (max_file_lines, max_function_lines) already carry.
#
# Bounding them must not make them integers. An average cyclomatic complexity of 12.75 is the
# normal case, so every fractional control below has to keep passing.
for _mk in complexity_max complexity_average; do
	# domain values, exact round-trip
	for _mv in 0 0.125 12.75 0.001 1000.5; do
		accepted "(5m) CONTROL: $_mk=$_mv is accepted and round-trips exactly" ".summary.$_mk" "$_mv" \
			pass '{"status":"pass"}' "{\"$_mk\":$_mv}"
	done
	# the boundary itself, and boundary+1 in both an integral and a FRACTIONAL spelling
	accepted "(5m) CONTROL: $_mk at exactly $MAX is accepted" ".summary.$_mk" "$MAX" \
		pass '{"status":"pass"}' "{\"$_mk\":$MAX}"
	accepted "(5m) CONTROL: $_mk at $MAX minus a half is accepted and exact" ".summary.$_mk" "2147483646.5" \
		pass '{"status":"pass"}' "{\"$_mk\":2147483646.5}"
	refused "(5m) $_mk at $MAX + 1"           pass '{"status":"pass"}' "{\"$_mk\":$OVER}"
	refused "(5m) $_mk at $MAX + a half"      pass '{"status":"pass"}' "{\"$_mk\":2147483647.5}"
	refused "(5m) $_mk negative"              pass '{"status":"pass"}' "{\"$_mk\":-0.5}"
	# arbitrarily large, in every spelling a JSON parser will take
	for _mv in 1e30 1e400 1e999 99999999999999999999 Infinity -Infinity NaN nan; do
		refused "(5m) $_mk = $_mv is refused before publication" pass '{"status":"pass"}' "{\"$_mk\":$_mv}"
	done
	# and the non-numeric spellings
	refused "(5m) $_mk as a numeric string"   pass '{"status":"pass"}' "{\"$_mk\":\"12.75\"}"
	refused "(5m) $_mk as the string NaN"     pass '{"status":"pass"}' "{\"$_mk\":\"NaN\"}"
	refused "(5m) $_mk as null"               pass '{"status":"pass"}' "{\"$_mk\":null}"
	refused "(5m) $_mk as a boolean"          pass '{"status":"pass"}' "{\"$_mk\":true}"
done
# jq PARSES `NaN` and `Infinity` even though neither is JSON, and renders NaN back as `null`.
# The refusals above must therefore be attributable to the RANGE test, not to a parse error:
# both arrive as type "number", and `NaN >= 0` is false, which is what refuses them.
[ "$(printf '%s' '{"a":NaN}' | jq -r '.a | type')" = "number" ] \
	&& [ "$(printf '%s' '{"a":NaN}' | jq -r '.a >= 0')" = "false" ] \
	&& pass "(5m) jq admits NaN as a number and NaN >= 0 is false — the range test is what refuses it" \
	|| fail "(5m) the NaN pin did not hold; the NaN refusals above are unattributable"
[ "$(printf '%s' '{"a":Infinity}' | jq -r '.a | type')" = "number" ] \
	&& pass "(5m) jq admits Infinity as a number — the ceiling is what refuses it, not the parser" \
	|| fail "(5m) the Infinity pin did not hold"
# THE INTEGER CLASS IS REFUSED BY STRING SHAPE, NOT BY A RANGE TEST — pinned, because the two
# classes are protected by DIFFERENT mechanisms and only one of them is a range comparison.
# The ratio/metric classes are refused in jq by `>= 0` / `<= max`. The integer class has no range
# test at all: ss_count_valid judges the string `tostring` produced, and every non-finite or
# exponential value renders with a character its `*[!0-9]*` case rejects. That protection is
# incidental to jq's FORMATTING, so it is pinned here rather than assumed — a jq that rendered
# Infinity as 309 expanded digits would fail this block instead of silently shifting which
# mechanism does the work. (Raised in review of #145 on PR #368.)
for _nf in NaN Infinity -Infinity 1e30 1e400 1e999; do
	_rend=$(printf '%s' "{\"a\":$_nf}" | jq -r '.a | tostring' 2>/dev/null || printf 'UNPARSED')
	case "$_rend" in
		'' | *[!0-9]*) pass "(5m) jq renders $_nf as '$_rend' — a shape ss_count_valid's digit test refuses" ;;
		*) fail "(5m) jq renders $_nf as '$_rend', which is pure digits; the integer class would judge it numerically" ;;
	esac
	ss_count_valid "$_rend" \
		&& fail "(5m) ss_count_valid ACCEPTED the rendering of $_nf ('$_rend')" \
		|| pass "(5m) ss_count_valid refuses the rendering of $_nf"
	# and the same value on a real INT-class key must be refused end to end
	refused "(5m) integer-class secrets = $_nf" fail '{"status":"fail"}' "{\"secrets\":$_nf}"
done
# CONTROL: a legitimate count renders as pure digits and IS accepted, so the block above is
# discriminating between shapes rather than refusing every rendering.
_rend=$(printf '%s' "{\"a\":$MAX}" | jq -r '.a | tostring')
case "$_rend" in
	'' | *[!0-9]*) fail "(5m) CONTROL: $MAX rendered as '$_rend', not pure digits" ;;
	*) ss_count_valid "$_rend" \
		&& pass "(5m) CONTROL: $MAX renders as pure digits and ss_count_valid accepts it" \
		|| fail "(5m) CONTROL: ss_count_valid refused the rendering of $MAX" ;;
esac

# EXACTNESS FOR THE DECLARED DOMAIN. A double carries 53 bits of mantissa and the ceiling needs
# 31, so every value in 0..SS_MAX_COUNT with a few decimal places is exact. Proven by round trip
# through the real emitter at both ends of the range rather than asserted.
_mx=$(emit pass '{"status":"pass"}' '{"complexity_average":2147483646.5,"complexity_max":0.125}')
[ "$(printf '%s' "${_mx#*|}" | jq -r '[.summary.complexity_average, .summary.complexity_max] | join(",")')" = "2147483646.5,0.125" ] \
	&& pass "(5m) both metrics survive the emitter exactly at the top and bottom of the domain" \
	|| fail "(5m) a metric value was altered in transit: $(printf '%s' "${_mx#*|}" | jq -c '{a:.summary.complexity_average, m:.summary.complexity_max}')"
# The bound must be the SCHEMA's, not a number this suite happens to agree with.
for _mk in complexity_max complexity_average; do
	_smax=$(jq -r --arg k "$_mk" '.properties.summary.properties[$k].maximum // "NONE"' "$SCHEMA")
	[ "$_smax" = "$MAX" ] \
		&& pass "(5m) the schema bounds $_mk at $MAX" \
		|| fail "(5m) the schema bounds $_mk at '$_smax'"
	grep -q "\`$_mk\`" "$DOC" \
		&& pass "(5m) the contract doc names $_mk" \
		|| fail "(5m) the contract doc does not name $_mk"
done

# The refusal names the offending KEY, redacted and bounded.
emit_err fail '{"status":"fail"}' '{"secrets":-1}' > "$WORK/e5" 2>&1 || :
grep -q "secrets" "$WORK/e5" && grep -q "bounded contract" "$WORK/e5" \
	&& pass "(5) the value refusal names the offending key and the contract" \
	|| fail "(5) the value refusal is not attributable: $(head -1 "$WORK/e5")"

# ============================================================================
# (6) ATOMICITY — one invalid sibling refuses the WHOLE override object.
# ============================================================================
_x=$(emit fail '{"status":"fail"}' '{"critical_vulnerabilities":2,"secrets":-1}')
case "$_x" in
	0\|*) fail "(6) a mixed valid/invalid override was ACCEPTED — the valid sibling hid the invalid one" ;;
	*\|)  pass "(6) one invalid sibling refuses the whole override, publishing nothing" ;;
	*)    fail "(6) refused but published '${_x#*|}'" ;;
esac
# The refusal must not be attributable to the VALID sibling: the same object without the
# invalid member is accepted, and the valid value lands.
accepted "(6) CONTROL: the valid sibling alone is accepted and reaches .summary" '.summary.critical_vulnerabilities' '2' \
	fail '{"status":"fail"}' '{"critical_vulnerabilities":2}'
# Three keys, one bad: still nothing published, and no partial summary anywhere.
_x=$(emit fail '{"status":"fail"}' '{"secrets":1,"type_errors":2,"test_failures":-3}')
[ "${_x#*|}" = "" ] && [ "${_x%%|*}" != "0" ] \
	&& pass "(6) two valid keys plus one invalid publish nothing at all" \
	|| fail "(6) partial publication: rc=${_x%%|*} out='${_x#*|}'"
# Ordering must not matter — the invalid member first is refused just the same.
_x=$(emit fail '{"status":"fail"}' '{"test_failures":-3,"secrets":1}')
[ "${_x%%|*}" != "0" ] && pass "(6) refusal is order-independent" \
	|| fail "(6) an invalid FIRST member was accepted; the loop is short-circuiting"

# ============================================================================
# (7) UNKNOWN VOCABULARY.
# ============================================================================
refused "(7) an unknown override key" pass '{"status":"pass"}' '{"diff_coverage_violations":1}'
refused "(7) an unknown key beside a valid one" fail '{"status":"fail"}' '{"secrets":1,"nope":0}'
refused "(7) a key differing by case" pass '{"status":"pass"}' '{"Secrets":0}'
refused "(7) a key that is a prefix of a canonical one" pass '{"status":"pass"}' '{"secret":0}'
refused "(7) an empty-string key" pass '{"status":"pass"}' '{"":0}'
accepted "(7) CONTROL: the correctly spelled key is accepted" '.summary.changed_lines_coverage_violations' '1' \
	fail '{"status":"fail"}' '{"changed_lines_coverage_violations":1}'
emit_err pass '{"status":"pass"}' '{"diff_coverage_violations":1}' > "$WORK/e7" 2>&1 || :
grep -q "diff_coverage_violations" "$WORK/e7" \
	&& pass "(7) the unknown-key refusal names the key it refused" \
	|| fail "(7) the unknown-key refusal is not attributable"

# ============================================================================
# (8) THE STATUS/COUNT INVARIANT.
# ============================================================================
refused "(8) pass beside 5 critical vulnerabilities" pass '{"status":"pass"}' '{"critical_vulnerabilities":5}'
refused "(8) pass beside 1 secret"                   pass '{"status":"pass"}' '{"secrets":1}'
refused "(8) pass beside a quality violation"        pass '{"status":"pass"}' '{"complexity_violations":1}'
refused "(8) pass beside a testing-discipline count" pass '{"status":"pass"}' '{"acceptance_test_failures":1}'
# EVERY gating key must be individually load-bearing. A single forgotten member is exactly the
# hole this invariant exists to close, so all of them are exercised, not a representative few.
_missed=""
for _k in $SS_GATING_SUMMARY_KEYS; do
	_x=$(emit pass '{"status":"pass"}' "$(jq -n --arg k "$_k" '{($k):1}')")
	[ "${_x%%|*}" = "0" ] && _missed="$_missed $_k"
done
[ -z "$_missed" ] && pass "(8) all $(sorted_set "$SS_GATING_SUMMARY_KEYS" | wc -l | tr -d ' ') gating keys refuse a clean pass" \
	|| fail "(8) gating key(s) tolerate a clean pass:$_missed"
# Only `pass` is constrained. warn/findings/fail already claim something was found, and the
# non-run statuses carry the zeroed defaults their emit paths supply.
for _s in fail warn findings; do
	accepted "(8) CONTROL: '$_s' may carry a positive gating count" '.summary.critical_vulnerabilities' '5' \
		"$_s" "$(jq -n --arg s "$_s" '{status:$s}')" '{"critical_vulnerabilities":5}'
done
# The census carve-out: skipped_tests and the informational metrics are legitimate beside pass.
accepted "(8) CONTROL: pass beside skipped_tests (a census, not a verdict)" '.summary.skipped_tests' '3' \
	pass '{"status":"pass"}' '{"skipped_tests":3}'
accepted "(8) CONTROL: pass beside test_count" '.summary.test_count' '42' \
	pass '{"status":"pass"}' '{"test_count":42}'
accepted "(8) CONTROL: pass beside architecture_rule_count" '.summary.architecture_rule_count' '12' \
	pass '{"status":"pass"}' '{"architecture_rule_count":12}'
accepted "(8) CONTROL: pass beside a coverage percentage" '.summary.coverage_line_percent' '91.2' \
	pass '{"status":"pass"}' '{"coverage_line_percent":91.2}'
accepted "(8) CONTROL: pass beside a gating key at ZERO" '.summary.secrets' '0' \
	pass '{"status":"pass"}' '{"secrets":0}'
emit_err pass '{"status":"pass"}' '{"secrets":1}' > "$WORK/e8" 2>&1 || :
grep -q "gating finding" "$WORK/e8" \
	&& pass "(8) the contradiction refusal says what contradicts what" \
	|| fail "(8) the contradiction refusal is not attributable: $(head -1 "$WORK/e8")"

# ============================================================================
# (9) NO STALE EVIDENCE SURVIVES A REFUSAL.
#
# Two halves, and BOTH were broken. The library's guards emitted and then `exit 0`
# unconditionally, so a refused emit exited 0 with empty stdout; and the builder's own
# "did not return a JSON object" guard used `jq -c`, which exits 0 on EMPTY input, so that
# collector was dropped from the aggregate without a word.
# ============================================================================
printf '%s' '{"error":"boom"}' > "$WORK/bad.json"
_o=$( ss_shape_or_fail probe "$WORK/bad.json" '.nope == 1' '{"bogus_key":1}' 2>/dev/null ) && _r=0 || _r=$?
[ "$_r" != "0" ] && [ -z "$_o" ] \
	&& pass "(9) ss_shape_or_fail propagates a refused emit as a non-zero exit (rc=$_r)" \
	|| fail "(9) ss_shape_or_fail swallowed a refused emit (rc=$_r out='$_o')"
_o=$( ss_counts_or_fail probe '{"critical_vulnerabilities":-1}' '{"bogus_key":1}' 2>/dev/null ) && _r=0 || _r=$?
[ "$_r" != "0" ] && [ -z "$_o" ] \
	&& pass "(9) ss_counts_or_fail propagates a refused emit as a non-zero exit (rc=$_r)" \
	|| fail "(9) ss_counts_or_fail swallowed a refused emit (rc=$_r out='$_o')"
# CONTROL: with VALID overrides the same guards still emit their execution-error object and
# exit 0, so (9) above is attributable to the refusal and not to the guard being broken.
_o=$( ss_shape_or_fail probe "$WORK/bad.json" '.nope == 1' '{"secrets":0}' 2>/dev/null ) && _r=0 || _r=$?
[ "$_r" = "0" ] && [ "$(printf '%s' "$_o" | jq -r '.status')" = "execution-error" ] \
	&& pass "(9) CONTROL: ss_shape_or_fail still emits execution-error and exits 0 on valid overrides" \
	|| fail "(9) CONTROL: ss_shape_or_fail broke on valid overrides (rc=$_r)"
# The builder's guard must reject EMPTY collector output. Asserted on the real flag, not a
# paraphrase of it: `-c` alone exits 0 here, which is precisely why the bug was invisible.
grep -q 'jq -ce --arg p "\$key"' "$BUILD" \
	&& pass "(9) build-security-summary.sh guards collector output with jq -ce" \
	|| fail "(9) build-security-summary.sh no longer uses jq -ce; empty collector output would pass again"
printf '' | jq -c  '. + {p:1}' >/dev/null 2>&1 && _c=0 || _c=$?
printf '' | jq -ce '. + {p:1}' >/dev/null 2>&1 && _e=0 || _e=$?
[ "$_c" = "0" ] && [ "$_e" != "0" ] \
	&& pass "(9) the -e flag is load-bearing: jq -c accepts empty input (rc=$_c), jq -ce does not (rc=$_e)" \
	|| fail "(9) the -e demonstration did not reproduce (jq -c rc=$_c, jq -ce rc=$_e)"
# `-e` ALONE IS NOT ENOUGH, AND THE SELECT IS NOT DECORATION. `null + {producer: …}` is a valid
# jq expression that yields the metadata object, so a collector printing the four bytes `null`
# satisfied `-e` and was appended to the aggregate as a producer record with no tool, no status
# and no summary. An array or a string already errored on the `+`; null was the one shape that
# added cleanly. Selecting the object type first makes the pipeline empty instead.
grep -q 'select(type == "object")' "$BUILD" \
	&& pass "(9) build-security-summary.sh selects the object type before merging producer metadata" \
	|| fail "(9) build-security-summary.sh no longer type-checks collector output before the merge"
_nullmerge=$(printf '%s' 'null' | jq -ce '. + {producer:"p"}' 2>/dev/null) && _nm=0 || _nm=$?
[ "$_nm" = "0" ] && [ "$_nullmerge" = '{"producer":"p"}' ] \
	&& pass "(9) the defect is real: null + {…} yields a truthy object and satisfies -e on its own" \
	|| fail "(9) the null-merge demonstration did not reproduce (rc=$_nm out='$_nullmerge')"
for _shape in null '[]' '"str"' ''; do
	printf '%s' "$_shape" | jq -ce 'select(type == "object") | . + {producer:"p"}' >/dev/null 2>&1 \
		&& fail "(9) the production filter ACCEPTED non-object collector output <$_shape>" \
		|| pass "(9) the production filter refuses non-object collector output <${_shape:-empty}>"
done
printf '%s' '{"tool":"probe","status":"pass"}' | jq -ce 'select(type == "object") | . + {producer:"p"}' >/dev/null 2>&1 \
	&& pass "(9) CONTROL: the production filter still accepts a real collector object" \
	|| fail "(9) CONTROL: the production filter rejects a valid collector object"
# A refusal writes NOTHING to stdout — checked byte-wise, because "non-zero exit" alone does
# not prove a partial document was never produced.
( ss_emit_collector probe pass '{}' '{"secrets":-1}' > "$WORK/stale.out" 2>/dev/null ) || :
[ ! -s "$WORK/stale.out" ] \
	&& pass "(9) a refusal leaves a zero-byte stdout, never a partial document" \
	|| fail "(9) a refusal produced $(wc -c <"$WORK/stale.out" | tr -d ' ') bytes of output"

# ============================================================================
# (10) THE PRODUCTION PATH — every shipped collector still satisfies the contract.
#
# The negative tests above prove the boundary rejects. This proves no shipped collector was
# relying on what it now rejects, over BOTH of the paths every collector has: its clean
# template fixture, and its missing-input (unavailable) path.
# ============================================================================
_ncol=0; _bad=""
for _f in "$ROOT"/templates/raw/*.example.json; do
	_n=$(basename "$_f" .example.json)
	_c="$ROOT/scripts/collectors/$_n.sh"
	[ -f "$_c" ] || continue
	_ncol=$((_ncol + 1))
	_o=$(sh "$_c" --input "$_f" 2>/dev/null) || { _bad="$_bad $_n(exit)"; continue; }
	printf '%s' "$_o" | jq -e 'type == "object"' >/dev/null 2>&1 || { _bad="$_bad $_n(no-object)"; continue; }
	# outer status in the vocabulary, tool_report agreeing, no positive gating count with pass
	_st=$(printf '%s' "$_o" | jq -r '.status')
	ss_in_set "$_st" "$SS_COLLECTOR_STATUSES" || _bad="$_bad $_n(status=$_st)"
	_tr=$(printf '%s' "$_o" | jq -r 'if (.tool_report | type) == "object" and ((.tool_report.status | type) == "string") then .tool_report.status else "" end')
	[ -z "$_tr" ] || [ "$_tr" = "$_st" ] || _bad="$_bad $_n(report=$_tr!=$_st)"
	if [ "$_st" = "pass" ]; then
		# `.key` must be BOUND before it is used as an argument to index(): inside
		# `$G | index(...)` the input is the ARRAY, so a bare `.key` there indexes an array
		# with a string and errors. See (12g).
		_pos=$(printf '%s' "$_o" | jq -r --arg g "$SS_GATING_SUMMARY_KEYS" \
			'($g | split(" ") | map(select(length > 0))) as $G
			 | [ (.summary // {}) | to_entries[] | .key as $k | .value as $v
			     | select(($G | index($k)) != null and ($v | type) == "number" and $v > 0) | $k ] | join(",")')
		[ -z "$_pos" ] || _bad="$_bad $_n(pass+$_pos)"
	fi
done
[ "$_ncol" -ge 30 ] || fail "(10) only $_ncol collector fixtures were exercised — the sweep is not covering the shipped set"
[ -z "$_bad" ] && pass "(10) all $_ncol collectors satisfy the contract on their template fixture" \
	|| fail "(10) collector(s) violating the contract on their own fixture:$_bad"

_nun=0; _badu=""
for _c in "$ROOT"/scripts/collectors/*.sh; do
	_n=$(basename "$_c" .sh)
	_o=$(sh "$_c" --input "$WORK/absent-$_n.json" 2>/dev/null) || { _badu="$_badu $_n(exit)"; continue; }
	printf '%s' "$_o" | jq -e 'type == "object" and has("summary")' >/dev/null 2>&1 || continue
	_nun=$((_nun + 1))
	_st=$(printf '%s' "$_o" | jq -r '.status')
	ss_in_set "$_st" "$SS_COLLECTOR_STATUSES" || _badu="$_badu $_n(status=$_st)"
	_tr=$(printf '%s' "$_o" | jq -r 'if (.tool_report | type) == "object" and ((.tool_report.status | type) == "string") then .tool_report.status else "" end')
	[ -z "$_tr" ] || [ "$_tr" = "$_st" ] || _badu="$_badu $_n(report=$_tr!=$_st)"
done
[ "$_nun" -ge 30 ] || fail "(10) only $_nun collectors were exercised on their unavailable path"
[ -z "$_badu" ] && pass "(10) all $_nun collectors satisfy the contract on their unavailable path" \
	|| fail "(10) collector(s) violating the contract when their input is absent:$_badu"

# The malformed-report path: a valid-JSON, wrong-shape input must still produce a
# contract-valid execution-error object rather than a refusal.
_badshape=""
for _n in actionlint hadolint psalm phpstan dockle conftest nuclei terrascan third-party-semgrep dependency-policy; do
	_c="$ROOT/scripts/collectors/$_n.sh"
	[ -f "$_c" ] || continue
	_o=$(sh "$_c" --input "$WORK/bad.json" 2>/dev/null) || { _badshape="$_badshape $_n(exit)"; continue; }
	[ "$(printf '%s' "$_o" | jq -r '.status // "MISSING"')" = "execution-error" ] || _badshape="$_badshape $_n"
done
[ -z "$_badshape" ] && pass "(10) the malformed-shape path still emits execution-error under the new contract" \
	|| fail "(10) collector(s) broken on the malformed-shape path:$_badshape"

# No shipped collector may emit `invalid-output` as a tool_report status: it is outside the
# vocabulary and it disagreed with the outer status that accompanied it.
#
# TWO `-e` PATTERNS, NOT A `\|` ALTERNATION. BRE alternation is a GNU extension: where it is not
# supported the pattern matches nothing, `_io` is empty, and this reports "no collector emits it"
# having searched for a string that cannot occur — a check that passes precisely because it is
# broken. The positive control below is the other half of that: the same invocation must FIND a
# seeded occurrence, so an empty result can only mean the collectors are clean.
_io_grep() { grep -rl -e 'status:"invalid-output"' -e '"status":"invalid-output"' "$1" 2>/dev/null; }
mkdir -p "$WORK/seed"
printf '%s\n' 'ss_emit_collector "$T" "execution-error" '"'"'{status:"invalid-output"}'"'"' '"'"'{}'"'"'' > "$WORK/seed/seeded.sh"
if [ -n "$(_io_grep "$WORK/seed" | tr '\n' ' ')" ]; then
	pass "(10) CONTROL: the invalid-output sweep finds a seeded occurrence — an empty result is meaningful"
else
	fail "(10) the invalid-output sweep cannot find a seeded occurrence; its empty result over the real collectors proves nothing"
fi
_io=$(_io_grep "$ROOT/scripts/collectors" | tr '\n' ' ')
[ -z "$_io" ] && pass "(10) no collector emits a tool_report status outside the vocabulary" \
	|| fail "(10) collector(s) still emit status:\"invalid-output\": $_io"

# ============================================================================
# (11) IDENTICAL UNDER sh, dash AND bash.
#
# The verdicts are compared byte-for-byte, and the comparison refuses to run on an empty
# transcript — three empty files also compare equal, and that would report a shell matrix
# that never executed as agreement.
# ============================================================================
cat > "$WORK/matrix.sh" <<'MEOF'
. "$LIBPATH"
r() { _o=$(ss_emit_collector probe "$2" "$3" "$4" 2>/dev/null) && _c=0 || _c=$?; printf '%s rc=%s len=%s\n' "$1" "$_c" "${#_o}"; }
r vocab-bad      totally-bogus '{}'                '{}'
r vocab-ok       pass          '{"status":"pass"}' '{}'
r agree-bad      pass          '{"status":"fail"}' '{}'
r neg            fail          '{"status":"fail"}' '{"secrets":-1}'
r frac           fail          '{"status":"fail"}' '{"secrets":1.5}'
r str            fail          '{"status":"fail"}' '{"secrets":"3"}'
r boolv          fail          '{"status":"fail"}' '{"secrets":true}'
r nullv          fail          '{"status":"fail"}' '{"secrets":null}'
r arrv           fail          '{"status":"fail"}' '{"secrets":[1]}'
r objv           fail          '{"status":"fail"}' '{"secrets":{"a":1}}'
r at-max         fail          '{"status":"fail"}' '{"secrets":2147483647}'
r over-max       fail          '{"status":"fail"}' '{"secrets":2147483648}'
r huge           fail          '{"status":"fail"}' '{"secrets":99999999999999999999}'
r dup-key        fail          '{"status":"fail"}' '{"secrets":0,"secrets":-5}'
r mixed          fail          '{"status":"fail"}' '{"critical_vulnerabilities":2,"secrets":-1}'
r unknown        pass          '{"status":"pass"}' '{"nope":1}'
r nonobject      pass          '{"status":"pass"}' '[]'
r contradiction  pass          '{"status":"pass"}' '{"critical_vulnerabilities":5}'
r census         pass          '{"status":"pass"}' '{"skipped_tests":3}'
r ratio          pass          '{"status":"pass"}' '{"coverage_line_percent":87.5}'
r boolkey        pass          '{"status":"pass"}' '{"missing_sbom":true}'
r empty          pass          '{"status":"pass"}' '{}'
MEOF
_shells=""
for _sh in sh dash bash; do
	command -v "$_sh" >/dev/null 2>&1 || continue
	LIBPATH="$LIB" "$_sh" "$WORK/matrix.sh" > "$WORK/m-$_sh" 2>/dev/null || :
	_shells="$_shells $_sh"
done
_first=""
_nshell=0
for _sh in $_shells; do
	[ -s "$WORK/m-$_sh" ] || { fail "(11) the $_sh transcript is EMPTY — the matrix did not run there"; continue; }
	_nshell=$((_nshell + 1))
	if [ -z "$_first" ]; then _first=$_sh; continue; fi
	cmp -s "$WORK/m-$_first" "$WORK/m-$_sh" \
		&& pass "(11) $_sh agrees with $_first byte-for-byte" \
		|| fail "(11) $_sh differs from $_first: $(diff "$WORK/m-$_first" "$WORK/m-$_sh" | head -4 | tr '\n' ' ')"
done
[ "$_nshell" -ge 2 ] \
	&& pass "(11) the shell matrix ran in $_nshell shells ($(printf '%s' "$_shells" | tr -s ' '))" \
	|| fail "(11) the shell matrix ran in only $_nshell shell(s) — agreement across one shell is not agreement"
# The transcript must actually contain both verdicts, or "identical" would only mean the
# emitter is uniformly broken.
if [ -n "$_first" ]; then
	grep -q 'rc=0 ' "$WORK/m-$_first" && grep -q 'rc=2 ' "$WORK/m-$_first" \
		&& pass "(11) the transcript contains both accepted and refused cases" \
		|| fail "(11) the transcript is uniform ($(sort -u "$WORK/m-$_first" | wc -l | tr -d ' ') distinct lines) — it proves nothing"
	# A duplicate JSON key resolves last-wins in jq, so the LAST value is what the validator
	# judges. Recorded as a contract statement, not left to be discovered.
	grep -q 'dup-key rc=2' "$WORK/m-$_first" \
		&& pass "(11) a duplicate JSON key is judged on its last-wins value (-5 refused)" \
		|| fail "(11) a duplicate JSON key carrying an invalid last value was accepted"
fi

# ============================================================================
# (12) MUTATION CONTROLS — each guard is individually load-bearing.
#
# Each mutant removes or neuters ONE guard in a COPY of the library and requires the emitter's
# verdict to flip. None of them re-implements the rule it tests: they delete the production
# rule and observe the consequence, so a mutant cannot pass by agreeing with a broken oracle.
# ============================================================================
MUT="$WORK/mut"; mkdir -p "$MUT"
mutate() { # mutate <name> <sed-expr>
	sed "$2" "$LIB" > "$MUT/$1.sh"
	if cmp -s "$LIB" "$MUT/$1.sh"; then fail "(12) mutant '$1' changed nothing — the pattern no longer matches production"; return 1; fi
	return 0
}
# run_mut <mutant> <status> <report> <overrides> -> rc
run_mut() {
	_m=$1; shift
	( __SENTINEL_SHIELD_COMMON_LOADED=; . "$MUT/$_m.sh"; ss_emit_collector probe "$1" "$2" "$3" ) >/dev/null 2>&1 && printf 0 || printf 1
}
# (a) THE #146 MAXIMUM decides the integer bound, not an incidental length test. Raising only
#     the constant — to another ten-digit value, so no length comparison changes — must make
#     SS_MAX_COUNT+1 acceptable.
if mutate raised-max 's/^SS_MAX_COUNT=2147483647$/SS_MAX_COUNT=9999999999/'; then
	[ "$(run_mut raised-max fail '{"status":"fail"}' "{\"secrets\":$OVER}")" = "0" ] \
		&& pass "(12) MUTATION: raising ONLY SS_MAX_COUNT accepts $OVER — #145 consumes the #146 maximum" \
		|| fail "(12) MUTATION: $OVER stays refused with a raised maximum, so something other than SS_MAX_COUNT decides it"
	[ "$(run_mut raised-max fail '{"status":"fail"}' '{"secrets":-1}')" = "1" ] \
		&& pass "(12) MUTATION CONTROL: the raised-maximum mutant still refuses a negative count" \
		|| fail "(12) MUTATION CONTROL: the raised-maximum mutant refuses nothing at all"
fi
# (b) ss_count_valid is the acting authority for the integer class. Neutering it must make a
#     negative and an over-maximum count acceptable.
if mutate blind-validator 's/^ss_count_valid() {$/ss_count_valid() { return 0;/'; then
	[ "$(run_mut blind-validator fail '{"status":"fail"}' '{"secrets":-1}')" = "0" ] \
		&& pass "(12) MUTATION: neutering ss_count_valid accepts -1 — #145 does not carry its own integer policy" \
		|| fail "(12) MUTATION: -1 is refused even with ss_count_valid neutered, so #145 duplicates the check"
fi
# (c) the status vocabulary
if mutate wide-vocab 's/^SS_COLLECTOR_STATUSES="pass /SS_COLLECTOR_STATUSES="totally-bogus pass /'; then
	[ "$(run_mut wide-vocab totally-bogus '{}' '{}')" = "0" ] \
		&& pass "(12) MUTATION: widening the vocabulary accepts the invented status — the list is load-bearing" \
		|| fail "(12) MUTATION: the invented status is refused even when the vocabulary contains it"
fi
# (d) the status-agreement branch
# A backslash-continued LITERAL newline, not `\n`. `\n` in a sed replacement is a GNU extension;
# where it is not honoured it inserts the letter `n`, producing a mutant that does not parse — and
# a mutant that cannot be sourced proves nothing about the guard it was built to remove.
if mutate no-agreement 's/^		differs:\*)$/		differs:*) : ;;\
		__never)/'; then
	[ "$(run_mut no-agreement pass '{"status":"fail"}' '{}')" = "0" ] \
		&& pass "(12) MUTATION: removing the differs branch accepts contradictory statuses" \
		|| fail "(12) MUTATION: contradictory statuses stay refused without the differs branch"
fi
# (e) the gating set
# The constant spans continuation lines, so it is OVERRIDDEN immediately before the emitter
# rather than rewritten in place: editing only its first line would orphan the continuations
# and produce a mutant that fails to parse, which proves nothing about the guard.
if mutate no-gating 's|^ss_emit_collector() {$|SS_GATING_SUMMARY_KEYS=""\
ss_emit_collector() {|'; then
	[ "$(run_mut no-gating pass '{"status":"pass"}' '{"secrets":1}')" = "0" ] \
		&& pass "(12) MUTATION: emptying the gating set accepts pass beside a positive count" \
		|| fail "(12) MUTATION: the contradiction is refused with an empty gating set — something else refuses it"
	[ "$(run_mut no-gating fail '{"status":"fail"}' '{"secrets":-1}')" = "1" ] \
		&& pass "(12) MUTATION CONTROL: the empty-gating mutant still refuses a negative count" \
		|| fail "(12) MUTATION CONTROL: the empty-gating mutant refuses nothing at all"
fi
# (f) ss_in_set must be an EXACT membership test. A substring implementation would accept
#     "as" as a status and "secret" as a canonical key, both of which (2) and (7) assert.
( . "$LIB"; ss_in_set as "$SS_COLLECTOR_STATUSES" ) \
	&& fail "(12) ss_in_set matches a substring" || pass "(12) ss_in_set rejects a substring match"
( . "$LIB"; ss_in_set pass "$SS_COLLECTOR_STATUSES" ) \
	&& pass "(12) CONTROL: ss_in_set finds an exact member" || fail "(12) ss_in_set cannot find an exact member"
( . "$LIB"; ss_in_set '*' "$SS_COLLECTOR_STATUSES" ) \
	&& fail "(12) ss_in_set treats a glob as a wildcard" || pass "(12) ss_in_set treats a glob metacharacter literally"

# (g) THE jq SCOPE TRAP. `index(.key)` inside `to_entries[]` asks the ENTRY object for an index
#     and errors; the correct form indexes the ARRAY with the key as an argument. Demonstrated
#     both ways so the production selector's shape is pinned by observed behavior, not by
#     reading it.
# Inside `index(...)` the INPUT is whatever was piped in, so an unbound `.key` there does not
# mean "this entry's key". Both wrong forms are exercised, because they fail DIFFERENTLY and
# the quiet one is the dangerous one:
#   bare `index(.key)`      — input is the ENTRY object, index() returns null, select() drops
#                             every row: exit 0, NO error, EMPTY result. An empty result read
#                             as "no gating keys present" is a false clean.
#   `$G | index(.key)`      — input is the ARRAY: hard error, "Cannot index array with string".
# Only a key bound BEFORE the pipe (`.key as $k`) does what it reads as, which is the form the
# production selector and every selector in this suite use.
_w1out=$(printf '%s' '{"secrets":1}' | jq -r 'to_entries[] | select(index(.key)) | .key' 2>/dev/null) && _w1rc=0 || _w1rc=$?
_w2err=$(printf '%s' '{"secrets":1}' | jq -r '["secrets"] as $G | to_entries[] | select(($G | index(.key)) != null) | .key' 2>&1 >/dev/null || :)
_right=$(printf '%s' '{"secrets":1}' | jq -r '["secrets"] as $G | to_entries[] | .key as $k | select(($G | index($k)) != null) | $k' 2>/dev/null || printf 'ERRORED')
case "$_w2err" in *"Cannot index array with string"*) _w2seen=yes ;; *) _w2seen=no ;; esac
[ "$_w1rc" = "0" ] && [ -z "$_w1out" ] \
	&& pass "(12) bare index(.key) silently yields NOTHING at exit 0 — the empty-result false clean" \
	|| fail "(12) bare index(.key) did not reproduce (rc=$_w1rc out='$_w1out')"
[ "$_w2seen" = "yes" ] \
	&& pass "(12) \$G | index(.key) hard-errors on array scope" \
	|| fail "(12) the array-scope error did not reproduce: '$_w2err'"
[ "$_right" = "secrets" ] \
	&& pass "(12) CONTROL: the bound form (.key as \$k) selects the key" \
	|| fail "(12) the bound form did not select the key (got '$_right')"
# In jq, 0 is TRUTHY, so `index()` returning 0 for the first list member is NOT a trap — but
# that is worth pinning rather than assuming, because the opposite is true in most languages
# and a future rewrite reaching for `!= null` or `>= 0` should know which one it is relying on.
_first_key=$(printf '%s' "$SS_GATING_SUMMARY_KEYS" | cut -d' ' -f1)
_zero=$(printf '%s' "{\"$_first_key\":1}" | jq -r --arg g "$SS_GATING_SUMMARY_KEYS" \
	'($g|split(" ")) as $G | [ to_entries[] | .key as $k | select(($G | index($k)) != null) | $k ] | length' 2>/dev/null || printf 'ERR')
[ "$(jq -n 'if 0 then "t" else "f" end')" = '"t"' ] && [ "$_zero" = "1" ] \
	&& pass "(12) jq treats 0 as truthy, so the FIRST list member is not lost by index()" \
	|| fail "(12) the index()-is-0 pin did not hold (zero-index select=$_zero)"
# And the invariant really does catch that first key in production.
refused "(12) CONTROL: the FIRST gating key ($_first_key) is caught by the invariant" \
	pass '{"status":"pass"}' "{\"$_first_key\":1}"

printf '\n312-collector-contract: %d failure(s)\n' "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
printf 'All collector-output-contract assertions passed.\n'
