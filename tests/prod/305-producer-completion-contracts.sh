#!/bin/sh
# Sentinel Shield production test — the normative producer completion contract (#204 C2 prereq).
#
# WHAT THIS ASSERTS, AND WHY IT IS NOT A DOCUMENTATION TEST
#
# `config/producer-completion-contracts.json` is the canonical statement of what each of the
# nine engineering-quality producers currently observes and what C2 must observe before it may
# grant completed-analysis credit. A contract nothing checks is prose.
#
# So every row is checked against PRODUCTION CODE — the runner file, its declared output, the
# builder's TOOL_TABLE mapping, and the actual backend SELECTION BRANCHES — and the rendered
# document is regenerated and compared byte for byte, so the JSON and the markdown cannot drift
# apart. There is exactly one hand-maintained source.
#
# THE DISTINCTION THIS SUITE EXISTS TO PROTECT
#
#   report parses            ->  proves the report is READABLE
#   report parses            ->  does NOT prove the producer analysed the full target
#   process status discarded ->  UNOBSERVED, which is not the same fact as
#   tool exit table unknown  ->  UNKNOWN with a named missing source
#
# Conflating those is how "a parseable report" became "a completed scan" in #310.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SRC="$ROOT/config/producer-completion-contracts.json"
DOC="$ROOT/docs/producer-completion-contracts.md"
RENDER="$ROOT/scripts/render-producer-contracts.sh"
BUILD="$ROOT/scripts/build-security-summary.sh"

# CANONICAL ASSERTION SUITE (#345 Part C). Registered in config/harness-assertion-policy.json.
# Every verdict comes from a declared helper, and no helper line carries a command substitution
# — the two diagnostics that used to build their detail with `$(diff ...)` and `$(printf ... |
# tr ...)` now compute it into a variable first. tests/prod/307 enforces both over this file.
. "$ROOT/tests/lib/assert.sh"

assert_precondition "jq is available" command -v jq
for _f in "$SRC" "$DOC" "$RENDER" "$BUILD"; do
	assert_precondition "${_f#"$ROOT"/} exists" test -f "$_f"
done

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

EXPECTED_PRODUCERS=9

# --- 0. the document is GENERATED, not maintained ------------------------------------------
# Regenerate and compare. A hand edit to either side fails here, which is the only thing that
# makes "canonical source" true rather than aspirational.
assert_true "the renderer runs" sh "$RENDER" --check
sh "$RENDER" --check > "$TMP/rendered.md" 2>/dev/null || :
_render_diff=$(diff "$TMP/rendered.md" "$DOC" 2>/dev/null | head -3 | tr '\n' ' ')
assert_equal "docs/producer-completion-contracts.md is exactly what the renderer produces from the JSON" \
	"" "$_render_diff"
assert_true "the document declares itself generated" grep -q 'GENERATED FILE' "$DOC"

# --- 1. exactly nine rows, and the parser is not vacuous ------------------------------------
N=$(jq -r '.producers | length' "$SRC")
assert_equal "the inventory holds exactly $EXPECTED_PRODUCERS producer rows" "$EXPECTED_PRODUCERS" "$N"
# A parser that finds nothing must FAIL, never pass vacuously. Everything below iterates the
# rows, so a zero-row source would otherwise satisfy every loop silently.
assert_precondition "at least one producer row parsed — a zero-row source would satisfy every loop below" \
	test "$N" -gt 0

# --- 2. duplicate producer keys are rejected ------------------------------------------------
_dupes=$(jq -r '[.producers[].producer_key] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$SRC")
assert_equal "producer keys are unique" "" "$_dupes"

# --- 3. every row agrees with PRODUCTION CODE ------------------------------------------------
jq -r '.producers[] | [.producer_key, .runner, .channel, .native_report, (.backends|join(","))] | @tsv' "$SRC" > "$TMP/rows"
_rows_seen=0
while IFS="$(printf '\t')" read -r _key _runner _chan _report _backends; do
	[ -n "$_key" ] || continue
	_rows_seen=$((_rows_seen + 1))

	assert_true "$_key: runner $_runner exists" test -f "$ROOT/$_runner"

	# The runner must declare the report this row claims.
	_base=${_report#reports/raw/}
	assert_true "$_key: the runner writes $_base" \
		grep -qE "^OUTPUT=\"reports/raw/$_base\"" "$ROOT/$_runner"

	# The builder must map this producer key to that report and that channel.
	_row=$(grep -E "^$_key\|" "$BUILD" | head -1)
	assert_true "$_key: TOOL_TABLE has a row — the producer key exists in the builder" test -n "$_row"
	if [ -n "$_row" ]; then
		_t_report=$(printf '%s' "$_row" | awk -F'|' '{print $2}')
		_t_emit=$(printf '%s' "$_row" | awk -F'|' '{print $4}')
		assert_equal "$_key: builder maps it to $_base" "$_base" "$_t_report"
		assert_equal "$_key: builder emits channel $_chan" "$_chan" "$_t_emit"
	fi

	# CHANNEL MUST NOT BE THE PRODUCER. If a row ever declared them equal for a producer the
	# builder renames, provenance and presentation would have collapsed again.
	assert_false "$_key: producer key and channel are distinct identities in the contract" \
		test "$_key" = "$_chan"

	# BACKEND MUST NOT BE THE PRODUCER either.
	# The one-armed `[ ... ] && fail` form is gone: it produced a verdict only on failure, so a
	# passing row was invisible in the output and uncounted.
	#
	# ONE RECORD PER BACKEND, NEWLINE-DELIMITED. `for _b in $_blist` split on IFS, so the single
	# declared backend `consumer package.json coverage script` became FOUR iterations and the
	# assertion compared fragments. Backends are read as whole lines instead. (The comma join is
	# gone too: a name containing a comma would have had the same problem one level up.)
	jq -r --arg k "$_key" '.producers[] | select(.producer_key == $k) | .backends[]' "$SRC" > "$TMP/blist"
	while IFS= read -r _b; do
		[ -n "$_b" ] || continue
		assert_false "$_key: backend '$_b' is not the producer key — a backend cannot stand in for producer identity" \
			test "$_b" = "$_key"
	done < "$TMP/blist"
done < "$TMP/rows"
assert_equal "every one of the $N rows was evaluated" "$N" "$_rows_seen"

# --- 4. every declared backend is reachable through a real selection branch -------------------
# Not a name search: knip.sh mentions ts-prune in a 'no tool found' message, so a name grep
# would pass with the fallback deleted. Each backend must appear in an executable test or an
# explicit script/binary selection.
_backend_bad=0
jq -r '.producers[] | .producer_key as $k | .runner as $r | .backends[] | [$k, $r, .] | @tsv' "$SRC" > "$TMP/backends"
while IFS="$(printf '\t')" read -r _k _r _b; do
	[ -n "$_b" ] || continue
	# The `case` selects WHICH PROPERTY applies to this backend; it does not decide a verdict.
	# That distinction is the policy: control flow may choose the assertion, only a helper may
	# reach a conclusion.
	_rbase=$(basename "$_r")
	case "$_b" in
	"consumer package.json coverage script")
		# The backend is the adopter's script; the reachable evidence is the script probe.
		assert_true "$_k: the consumer coverage script is selected by an explicit probe" \
			grep -qE "for _s in test:coverage coverage" "$ROOT/$_r"
		grep -qE "for _s in test:coverage coverage" "$ROOT/$_r" || _backend_bad=1
		;;
	*)
		assert_true "$_k: backend '$_b' is reachable through a selection branch in $_rbase" \
			grep -qE "(-x [^ ]*$_b\]|-x [^ ]*$_b |command_exists $_b|BIN=\"[^\"]*$_b\"|/$_b\b)" "$ROOT/$_r"
		grep -qE "(-x [^ ]*$_b\]|-x [^ ]*$_b |command_exists $_b|BIN=\"[^\"]*$_b\"|/$_b\b)" "$ROOT/$_r" || _backend_bad=1
		;;
	esac
done < "$TMP/backends"
assert_equal "every declared backend is reachable" 0 "$_backend_bad"

# --- 5. completion semantics must be present or explicitly unresolved -----------------------
# A row may say "unknown" — that is a truthful state. What it may NOT do is omit the field, or
# claim an implementation status the rest of the row contradicts.
_vocab='implemented partial unobserved unknown'
_bad_status=$(jq -r --arg v "$_vocab" '.producers[] | select((.implementation_status | IN($v | split(" ")[]))|not) | .producer_key' "$SRC")
assert_equal "every implementation_status is in vocabulary ($_vocab)" "" "$_bad_status"

for _field in current_process_observation current_report_observation upstream_exit_semantics \
	normative_completion_requirement report_finalization_condition record_report_binding \
	no_observation_behavior enforcing_mode_requirement residual_gap; do
	_missing=$(jq -r --arg f "$_field" '.producers[] | select(has($f)|not) | .producer_key' "$SRC")
	assert_equal "every row declares $_field" "" "$_missing"
done

# An UNKNOWN upstream exit table must name what is missing. "unknown" without a reason is a
# gap disguised as a finding.
_unknown_no_source=$(jq -r '.producers[]
	| select(.upstream_exit_semantics.status == "unknown")
	| select((.upstream_exit_semantics.missing_source // "") == "")
	| .producer_key' "$SRC")
assert_equal "every unknown upstream exit table names its missing source" "" "$_unknown_no_source"

# --- 6. a parseable report is never recorded as proof of completion --------------------------
# This is the #310 lesson in contract form. Every row must state what its report observation
# does NOT prove.
_no_caveat=$(jq -r '.producers[] | select((.current_report_observation.does_not_prove // "") == "") | .producer_key' "$SRC")
assert_equal "every row states what its report observation does NOT prove" "" "$_no_caveat"
_overclaim=$(jq -r '.producers[]
	| select(.current_report_observation.proves | test("complet|full|success"; "i"))
	| .producer_key' "$SRC")
assert_equal "no row claims its report observation proves completion or success" "" "$_overclaim"

# --- 7. findings exits are not classified as execution failure ------------------------------
# The producers whose non-zero exit is a FINDINGS or TEST-FAILURE signal must not be described
# as completing only on exit 0. PHPMD and the coverage pair are the live examples.
# BOUNDED HEURISTIC, stated as such: this matches an `exit_code == 0` completion rule and
# excludes rows that mention it in order to FORBID it. It cannot parse intent in general — a
# row phrased in some third way would escape it — so it is a floor, not a proof. The PHPMD row
# is exactly the case that made the distinction necessary: it names the rule to rule it out.
_naive=$(jq -r '.producers[]
	| select(.normative_completion_requirement | test("exit_code *== *0"))
	| select(.normative_completion_requirement | test("CANNOT|cannot|must not|never|not be") | not)
	| select((.upstream_exit_semantics.status // "") != "known")
	| .producer_key' "$SRC")
assert_equal "no row asserts exit_code==0 as completion without an established exit table" "" "$_naive"

# The coverage producers must keep the test-runner result separate from report finalization.
for _cov in php-coverage php-diff-coverage; do
	# A `case` glob deciding a verdict is replaced by a fixed-string match over the value as
	# DATA. grep -qF also removes the glob-metacharacter question the pattern raised.
	jq -r --arg k "$_cov" '.producers[] | select(.producer_key == $k) | .normative_completion_requirement' "$SRC" > "$TMP/req"
	assert_true "$_cov: completion is bound to the report, not the test-runner exit" \
		grep -qF "not of the test-runner exit status" "$TMP/req"
done

# --- 8. execution failure is never classified as completed analysis -------------------------
_bad_noobs=$(jq -r '.producers[]
	| select((.no_observation_behavior.matrix // "") | test("never valid-clean") | not)
	| .producer_key' "$SRC")
assert_equal "every row states that an unobserved producer can never be clean" "" "$_bad_noobs"

# --- 9. the multi-backend rows must say the backend changes the meaning ---------------------
_multi=$(jq -r '.producers[] | select((.backends | length) > 1) | .producer_key' "$SRC")
_multi_list=$(printf '%s' "$_multi" | tr '\n' ' ')
assert_true "multi-backend producers are present in the inventory ($_multi_list)" test -n "$_multi"
for _m in $_multi; do
	jq -r --arg k "$_m" '.producers[] | select(.producer_key == $k) | .record_report_binding.required' "$SRC" > "$TMP/note"
	assert_true "$_m: the record must carry the backend that produced the report" \
		grep -qF backend "$TMP/note"
done

assert_summary "producer-completion-contracts ($N producers; document generated, not maintained)"
