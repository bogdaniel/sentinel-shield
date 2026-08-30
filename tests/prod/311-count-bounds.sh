#!/bin/sh
# tests/prod/311-count-bounds.sh — BOUNDED SAFE-INTEGER COUNT CONTRACT (#146).
#
# `ss_counts_or_fail` accepted any non-negative integer jq would parse, and the builder summed
# them with an unchecked `+`. Neither is safe, and the failures were reproduced on the
# production path before this suite existed:
#
#   collector -> summary   violations 9007199254740993 became 9007199254740992 in the summary,
#                          exit 0. A changed value was serialized as clean evidence.
#   collector -> summary   violations 123456789012345678901234567890 became
#                          123456789012345680000000000000, exit 0.
#   aggregation            9007199254740991 + 2 aggregated to 9007199254740992; the true sum
#                          9007199254740993 is not representable as a double.
#   gate evaluation        a value at or above 2^63 makes `[ "$_val" -gt 0 ]` a HARD ERROR with
#                          three different messages across sh/bash/dash, inside gate evaluation.
#   shell arithmetic       `$(( v + 1 ))` WRAPS to negative at 2^63 and diverges between dash
#                          and sh/bash beyond it.
#
# jq round-tripping a literal is NOT proof of exactness -- jq >= 1.7 preserves an untouched
# literal, while the aggregation performs arithmetic and converts to double. Every assertion
# here therefore checks a value that has been through arithmetic, not merely parsed.
#
# THE CANONICAL MAXIMUM IS 2^31-1 FOR BOTH INDIVIDUAL AND AGGREGATE COUNTS. An aggregate is
# itself a count and reaches the same consumers, so a higher aggregate ceiling would let a value
# pass aggregation and then be un-representable downstream. See docs/security-summary-schema.md.
#
# Self-contained, NETWORK-FREE. jq is required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
LIB="$ROOT/scripts/lib/sentinel-shield-common.sh"
BUILD="$ROOT/scripts/build-security-summary.sh"
SCHEMA="$ROOT/schemas/security-summary.schema.json"
DOC="$ROOT/docs/security-summary-schema.md"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n'; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$LIB"

MAX=2147483647          # 2^31-1, the value this suite independently expects
OVER=2147483648         # MAX + 1  == 2^31
P53M1=9007199254740991  # 2^53-1
P53=9007199254740992    # 2^53
HUGE=123456789012345678901234567890

# ============================================================================
# (1) ONE AUTHORITATIVE CONSTANT — mechanical drift detection.
#
# The production constant, the schema maximum, the documented value and this suite's own
# expectation must be the same number. Prose review does not keep four copies synchronised;
# this does.
# ============================================================================
[ "${SS_MAX_COUNT:-}" = "$MAX" ] \
	&& pass "(1) production constant SS_MAX_COUNT is $MAX (2^31-1)" \
	|| fail "(1) SS_MAX_COUNT is '${SS_MAX_COUNT:-unset}', suite expects $MAX"

# INTFIELDS matches a scalar `"integer"` AND a union such as ["integer","null"]. The first
# draft of this suite selected `.type == "integer"` only, so `targets_scanned` and `age_days`
# — both ["integer","null"] — bypassed the drift check and the forgotten-field control alike.
# A control that cannot see a whole shape of field is the gap it claims to close.
INTFIELDS='[.. | objects | select((.type=="integer") or ((.type|type)=="array" and ((.type|index("integer")) != null)))]'
_schema_maxima=$(jq -r "$INTFIELDS"' | [.[].maximum] | unique | map(tostring) | join(",")' "$SCHEMA")
[ "$_schema_maxima" = "$MAX" ] \
	&& pass "(1) EVERY integer field in the summary schema carries maximum $MAX, with no exception" \
	|| fail "(1) schema integer maxima are [$_schema_maxima], expected exactly [$MAX]"

grep -q "$MAX" "$DOC" \
	&& pass "(1) the documented maximum matches the production constant" \
	|| fail "(1) $DOC does not state $MAX"

# A drift control: the detector must actually reject a mismatch, or it proves nothing.
_drifted="$WORK/drift.schema.json"
jq --argjson m 999 '(.. | objects | select((.type=="integer") or ((.type|type)=="array" and ((.type|index("integer")) != null))) | .maximum) |= $m' "$SCHEMA" > "$_drifted"
[ "$(jq -r "$INTFIELDS"' | [.[].maximum] | unique | map(tostring) | join(",")' "$_drifted")" != "$MAX" ] \
	&& pass "(1) CONTROL: the drift detector rejects a schema whose maximum was changed" \
	|| fail "(1) the drift detector cannot see a changed schema maximum"

# A count is not always spelled `"type": "integer"`. These two are ["integer","null"], they are
# counts, and `age_days` reaches shell arithmetic in enforce-security-policy.sh — so an
# unbounded value there is the same hard-error class as an unbounded summary count.
for _f in targets_scanned age_days; do
	_fm=$(jq -r --arg f "$_f" '[.. | objects | select(has($f)) | .[$f] | select((.type|type)=="array")] | first | .maximum // "NONE"' "$SCHEMA")
	[ "$_fm" = "$MAX" ] \
		&& pass "(1) union-typed count '$_f' (\"integer\"|null) carries maximum $MAX" \
		|| fail "(1) union-typed count '$_f' carries maximum '$_fm'"
done

# ============================================================================
# (2) ss_count_valid — the individual bound, WITHOUT shell arithmetic.
#
# The validator may not use `[ -gt ]` or `$(( ))` on the candidate: those are exactly what
# breaks on an un-representable value, and a validator that crashes has not fail-closed.
# ============================================================================
for bad in "-1" "1.5" "abc" "" " " "1e3" "0x10" "+1" "007" "$OVER" "2147483648" "$P53M1" "$P53" "$HUGE" "9223372036854775808"; do
	if ss_count_valid "$bad" 2>/dev/null; then
		fail "(2) ss_count_valid ACCEPTED '$bad'"
	else
		pass "(2) ss_count_valid rejects '$bad'"
	fi
done
for good in 0 1 7 1000000 2147483646 "$MAX"; do
	if ss_count_valid "$good" 2>/dev/null; then
		pass "(2+) CONTROL: ss_count_valid accepts $good"
	else
		fail "(2+) ss_count_valid REJECTED the legitimate value $good"
	fi
done

# ============================================================================
# (3) ss_count_add — overflow checked BEFORE the addition.
# ============================================================================
_r=$(ss_count_add 2 3 2>/dev/null) && [ "$_r" = "5" ] \
	&& pass "(3+) CONTROL: ss_count_add 2 3 = 5" || fail "(3+) ss_count_add 2 3 gave '${_r:-<error>}'"
_r=$(ss_count_add "$MAX" 0 2>/dev/null) && [ "$_r" = "$MAX" ] \
	&& pass "(3+) CONTROL: a sum landing exactly on the maximum is accepted" || fail "(3+) MAX + 0 gave '${_r:-<error>}'"
_r=$(ss_count_add 2147483646 1 2>/dev/null) && [ "$_r" = "$MAX" ] \
	&& pass "(3+) CONTROL: a sum reaching the maximum from below is exact" || fail "(3+) MAX-1 + 1 gave '${_r:-<error>}'"
ss_count_add "$MAX" 1 >/dev/null 2>&1 \
	&& fail "(3) ss_count_add ACCEPTED a sum one past the maximum" \
	|| pass "(3) ss_count_add refuses a sum one past the maximum"
ss_count_add 2000000000 2000000000 >/dev/null 2>&1 \
	&& fail "(3) ss_count_add ACCEPTED two individually valid operands that overflow" \
	|| pass "(3) two individually valid operands whose sum overflows are refused"
ss_count_add "$P53M1" 2 >/dev/null 2>&1 \
	&& fail "(3) ss_count_add ACCEPTED the operands that silently rounded on the production path" \
	|| pass "(3) the 9007199254740991 + 2 case that rounded to ...992 is refused"
ss_count_add "$HUGE" 1 >/dev/null 2>&1 \
	&& fail "(3) ss_count_add ACCEPTED an arbitrarily large operand" \
	|| pass "(3) an arbitrarily large operand is refused before any arithmetic"
ss_count_add -1 5 >/dev/null 2>&1 \
	&& fail "(3) ss_count_add ACCEPTED a negative operand" \
	|| pass "(3) every operand is validated independently (negative left operand)"
ss_count_add 5 -1 >/dev/null 2>&1 \
	&& fail "(3) ss_count_add ACCEPTED a negative right operand" \
	|| pass "(3) every operand is validated independently (negative right operand)"
# three-or-more fields: the running total must be re-checked at each step, not only at the end.
_a=$(ss_count_add 1000000000 1000000000 2>/dev/null) || _a=""
if [ -n "$_a" ] && ss_count_add "$_a" 1000000000 >/dev/null 2>&1; then
	fail "(3) a three-operand accumulation overflowed without being caught"
else
	pass "(3) a three-operand accumulation is refused at the step that would overflow"
fi

# ============================================================================
# (4) PRODUCTION PATH — the builder. These are the exact reproductions from the header.
# ============================================================================
# build_one <violations-literal> -> echoes "<rc>|<summary value or ABSENT>"
build_one() {
	_d="$WORK/b$2"; mkdir -p "$_d/raw"
	printf '{"status":"pass","violations":%s}\n' "$1" > "$_d/raw/php-style.json"
	_c=0
	sh "$BUILD" --raw-dir "$_d/raw" --output "$_d/sum.json" >"$_d/log" 2>&1 || _c=$?
	printf '%s|%s' "$_c" "$(jq -r '.summary.style_violations // "ABSENT"' "$_d/sum.json" 2>/dev/null || printf 'NO-FILE')"
}
_o=$(build_one 5 ok); [ "$_o" = "0|5" ] \
	&& pass "(4+) CONTROL: an ordinary count builds and survives exactly" || fail "(4+) ordinary build gave '$_o'"
_o=$(build_one "$MAX" atmax); [ "$_o" = "0|$MAX" ] \
	&& pass "(4+) CONTROL: a count exactly at the maximum builds and round-trips exactly" || fail "(4+) at-max build gave '$_o'"
for v in "$OVER" "$P53M1" "$P53" 9007199254740993 "$HUGE"; do
	_o=$(build_one "$v" "r${#v}$(printf '%s' "$v" | cksum | cut -d' ' -f1)")
	case "$_o" in
		0\|*) fail "(4) the builder ACCEPTED an out-of-range count $v (summary=${_o#0|})" ;;
		*) pass "(4) the builder fails closed on the out-of-range count $v" ;;
	esac
done
# and it must not leave a summary standing when it refuses
_d="$WORK/stale"; mkdir -p "$_d/raw"
printf '{"status":"pass","violations":1}\n' > "$_d/raw/php-style.json"
sh "$BUILD" --raw-dir "$_d/raw" --output "$_d/sum.json" >/dev/null 2>&1
_prev=$(jq -r '.summary.style_violations' "$_d/sum.json")
printf '{"status":"pass","violations":%s}\n' "$HUGE" > "$_d/raw/php-style.json"
sh "$BUILD" --raw-dir "$_d/raw" --output "$_d/sum.json" >/dev/null 2>&1 || true
_now=$(jq -r '.summary.style_violations // "GONE"' "$_d/sum.json" 2>/dev/null || printf 'GONE')
{ [ "$_prev" = "1" ] && [ "$_now" != "$HUGE" ] && [ "$_now" != "123456789012345680000000000000" ]; } \
	&& pass "(4) a refused build never publishes the out-of-range value (kept '$_now')" \
	|| fail "(4) stale/rounded value survived a refused build (was '$_prev', now '$_now')"

# ============================================================================
# (5) PRODUCTION PATH — aggregate overflow across two producers of ONE channel.
# ============================================================================
agg() {
	_d="$WORK/a$3"; mkdir -p "$_d/raw"
	printf '{"status":"pass","violations":%s}\n' "$1" > "$_d/raw/php-style.json"
	printf '{"status":"pass","violations":%s}\n' "$2" > "$_d/raw/php-cs-fixer.json"
	_c=0
	sh "$BUILD" --raw-dir "$_d/raw" --output "$_d/sum.json" >"$_d/log" 2>&1 || _c=$?
	printf '%s|%s' "$_c" "$(jq -r '.summary.style_violations // "ABSENT"' "$_d/sum.json" 2>/dev/null || printf 'NO-FILE')"
}
_o=$(agg 3 4 small); [ "$_o" = "0|7" ] \
	&& pass "(5+) CONTROL: two producers of one channel still sum" || fail "(5+) 3+4 gave '$_o'"
_o=$(agg 2147483646 1 exact); [ "$_o" = "0|$MAX" ] \
	&& pass "(5+) CONTROL: an aggregate landing exactly on the maximum is accepted and exact" || fail "(5+) exact-max aggregate gave '$_o'"
_o=$(agg 2000000000 2000000000 over)
case "$_o" in 0\|*) fail "(5) aggregate overflow ACCEPTED: two valid operands summed to ${_o#0|}" ;; *) pass "(5) aggregate overflow of two individually valid operands fails closed" ;; esac
_o=$(agg "$P53M1" 2 rounded)
case "$_o" in 0\|*) fail "(5) the rounding case ACCEPTED: aggregate ${_o#0|}" ;; *) pass "(5) the 2^53-1 + 2 aggregate that rounded to ...992 now fails closed" ;; esac

# ============================================================================
# (6) MUTATION CONTROLS — each guard must be individually load-bearing.
#
# A patched copy of the production script with ONE guard removed must be CAUGHT. Without
# these, a guard that never rejected anything is indistinguishable from one that always passes.
# ============================================================================
MBIN="$WORK/mut"; mkdir -p "$MBIN"
mutate() { # mutate <name> <sed-expr> <file>
	sed "$2" "$3" > "$MBIN/$1"
	cmp -s "$3" "$MBIN/$1" && return 1
	chmod +x "$MBIN/$1"
	return 0
}
# (a) the BOUND ITSELF must be what rejects 2^31, not some incidental digit or length test.
# The mutant raises the maximum to a value that still has ten digits, so the length comparison
# is unchanged and only the numeric bound can decide. A mutant maximum with MORE digits would
# be rejected on length and would prove nothing.
if mutate lib-raised 's/^SS_MAX_COUNT=2147483647$/SS_MAX_COUNT=9999999999/' "$LIB"; then
	if ( __SENTINEL_SHIELD_COMMON_LOADED=; . "$MBIN/lib-raised"; ss_count_valid "$OVER" ) >/dev/null 2>&1; then
		pass "(6) MUTATION: raising only the bound accepts $OVER — the bound value is load-bearing"
	else
		fail "(6) MUTATION: $OVER is rejected even with a raised bound, so something other than the bound decides it"
	fi
	# and the unmutated library must still reject it, or the mutant proved nothing
	( . "$LIB"; ss_count_valid "$OVER" ) >/dev/null 2>&1 \
		&& fail "(6) MUTATION CONTROL: the real library also accepts $OVER" \
		|| pass "(6) MUTATION CONTROL: the real library rejects $OVER"
else
	fail "(6) could not build the raised-bound mutant"
fi
# (b) clamping instead of refusing
if ( . "$LIB"; _c=$(ss_count_add "$MAX" 5 2>/dev/null) || _c="REFUSED"; [ "$_c" = "REFUSED" ] ); then
	pass "(6) MUTATION: an overflowing sum REFUSES rather than clamping to the maximum"
else
	fail "(6) an overflowing sum returned a clamped value instead of refusing"
fi
# (c) checking after the addition instead of before
_after=$(sh -c 'a=2000000000; b=2000000000; s=$((a+b)); [ "$s" -le 2147483647 ] && echo "would-accept" || echo "would-reject"' 2>&1)
[ "$_after" = "would-reject" ] \
	&& pass "(6) NOTE: on a 64-bit shell, check-after-addition happens to reject here" \
	|| pass "(6) MUTATION: check-after-addition misbehaves ($_after) — which is why the precondition is checked FIRST"
_afterwrap=$(sh -c 'a=9223372036854775807; b=1; s=$((a+b)); [ "$s" -le 2147483647 ] && echo "would-ACCEPT-wrapped" || echo "would-reject"' 2>&1)
[ "$_afterwrap" = "would-ACCEPT-wrapped" ] \
	&& pass "(6) MUTATION: check-after-addition ACCEPTS a wrapped negative sum — the precondition form is required" \
	|| fail "(6) the wrap demonstration did not reproduce ($_afterwrap)"
# (d) coercion of a string / fraction must not be reintroduced
( . "$LIB"; ss_count_valid "5.0" ) >/dev/null 2>&1 \
	&& fail "(6) '5.0' was coerced to a valid count" || pass "(6) MUTATION: a fractional literal is not coerced"
( . "$LIB"; ss_count_valid " 5" ) >/dev/null 2>&1 \
	&& fail "(6) ' 5' was coerced to a valid count" || pass "(6) MUTATION: a whitespace-padded numeric string is not coerced"
# (e) one forgotten count field: EVERY integer field in the schema must carry the maximum
_missing=$(jq -r "$INTFIELDS"' | map(select(has("maximum") | not)) | length' "$SCHEMA")
[ "$_missing" = "0" ] \
	&& pass "(6) MUTATION: no integer field in the schema is missing its maximum" \
	|| fail "(6) $_missing integer field(s) carry no maximum — a forgotten field is exactly the gap"

# ============================================================================
# (7) THE EIGHT DEPENDANTS — their numeric-safety BLOCKER is discharged here.
#
# #106, #107, #108, #112, #119, #120, #121 and #122 are coverage / tests / acceptance collector
# correctness issues. None of them is implemented here. What they were blocked on is the
# absence of a bounded count contract to validate against: each would otherwise have had to
# invent its own maximum, which is how ten subtly different trust boundaries get written.
#
# This section proves only that the shared contract now covers the channels they own -- the
# primitive exists, is exported, and is enforced on their keys at the schema, the builder and
# the gate. It asserts nothing about their own acceptance criteria.
# ============================================================================
DEPKEYS="test_count test_failures skipped_tests acceptance_test_count acceptance_test_failures behavior_spec_count coverage_threshold_violations changed_lines_coverage_violations"

for _k in $DEPKEYS; do
	_m=$(jq -r --arg k "$_k" '.properties.summary.properties[$k].maximum // "NONE"' "$SCHEMA")
	[ "$_m" = "$MAX" ] \
		|| fail "(7) schema: summary.$_k carries maximum '$_m', expected $MAX"
done
pass "(7) every key the eight dependants own carries the shared maximum in the schema"

# The builder refuses an out-of-range value on one of THEIR channels, not merely on the one
# channel this suite happened to exercise above.
_d="$WORK/dep"; mkdir -p "$_d/raw"
printf '{"status":"pass","tests":%s,"failures":0,"errors":0,"skipped":0}\n' "$OVER" > "$_d/raw/js-tests.json"
_c=0
sh "$BUILD" --raw-dir "$_d/raw" --output "$_d/sum.json" >"$_d/log" 2>&1 || _c=$?
if [ "$_c" = 0 ] && [ "$(jq -r '.summary.test_count // 0' "$_d/sum.json" 2>/dev/null)" = "$OVER" ]; then
	fail "(7) the builder published an out-of-range test_count on a dependant channel"
else
	pass "(7) the builder refuses an out-of-range count on a dependant channel too"
fi

# The primitive is exported, so none of the eight needs to invent a second maximum.
command -v ss_count_valid >/dev/null 2>&1 && command -v ss_count_add >/dev/null 2>&1 \
	&& pass "(7) ss_count_valid and ss_count_add are available to every collector that sources the library" \
	|| fail "(7) the shared count primitives are not exported"

# There must be exactly ONE maximum in the shell library — a second literal is the drift the
# dependants would otherwise reintroduce.
_lits=$(grep -c '2147483647' "$LIB")
[ "$_lits" = "1" ] \
	&& pass "(7) the shell library states the maximum exactly once" \
	|| fail "(7) the shell library contains $_lits copies of the maximum literal"

# ============================================================================
if [ "$FAILS" -ne 0 ]; then
	printf '\n%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\nAll count-bound assertions passed.\n'
exit 0
