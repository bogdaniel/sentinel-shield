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

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
for _f in "$SRC" "$DOC" "$RENDER" "$BUILD"; do
	[ -f "$_f" ] || { fail "missing ${_f#"$ROOT"/}"; exit 1; }
done

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

EXPECTED_PRODUCERS=9

# --- 0. the document is GENERATED, not maintained ------------------------------------------
# Regenerate and compare. A hand edit to either side fails here, which is the only thing that
# makes "canonical source" true rather than aspirational.
sh "$RENDER" --check > "$TMP/rendered.md" 2>/dev/null || fail "the renderer failed to run"
if cmp -s "$TMP/rendered.md" "$DOC"; then
	pass "docs/producer-completion-contracts.md is exactly what the renderer produces from the JSON"
else
	fail "the rendered document and the committed document differ — one of them was hand-edited: $(diff "$TMP/rendered.md" "$DOC" | head -3 | tr '\n' ' ')"
fi
grep -q 'GENERATED FILE' "$DOC" \
	&& pass "the document declares itself generated" \
	|| fail "the document does not warn that it is generated"

# --- 1. exactly nine rows, and the parser is not vacuous ------------------------------------
N=$(jq -r '.producers | length' "$SRC")
[ "$N" -eq "$EXPECTED_PRODUCERS" ] \
	&& pass "the inventory holds exactly $EXPECTED_PRODUCERS producer rows" \
	|| fail "the inventory holds $N rows, expected $EXPECTED_PRODUCERS"
# A parser that finds nothing must FAIL, never pass vacuously. Everything below iterates the
# rows, so a zero-row source would otherwise satisfy every loop silently.
[ "$N" -gt 0 ] || { fail "zero producer rows parsed — every check below would pass vacuously"; exit 1; }

# --- 2. duplicate producer keys are rejected ------------------------------------------------
_dupes=$(jq -r '[.producers[].producer_key] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$SRC")
[ -z "$_dupes" ] \
	&& pass "producer keys are unique" \
	|| fail "duplicate producer key(s): $_dupes"

# --- 3. every row agrees with PRODUCTION CODE ------------------------------------------------
jq -r '.producers[] | [.producer_key, .runner, .channel, .native_report, (.backends|join(","))] | @tsv' "$SRC" > "$TMP/rows"
_rows_seen=0
while IFS="$(printf '\t')" read -r _key _runner _chan _report _backends; do
	[ -n "$_key" ] || continue
	_rows_seen=$((_rows_seen + 1))

	[ -f "$ROOT/$_runner" ] \
		&& pass "$_key: runner $_runner exists" \
		|| fail "$_key: declared runner $_runner does not exist"

	# The runner must declare the report this row claims.
	_base=${_report#reports/raw/}
	if grep -qE "^OUTPUT=\"reports/raw/$_base\"" "$ROOT/$_runner" 2>/dev/null; then
		pass "$_key: the runner writes $_base"
	else
		fail "$_key: $_runner does not declare OUTPUT=reports/raw/$_base"
	fi

	# The builder must map this producer key to that report and that channel.
	_row=$(grep -E "^$_key\|" "$BUILD" | head -1)
	if [ -z "$_row" ]; then
		fail "$_key: no TOOL_TABLE row — the producer key does not exist in the builder"
	else
		_t_report=$(printf '%s' "$_row" | awk -F'|' '{print $2}')
		_t_emit=$(printf '%s' "$_row" | awk -F'|' '{print $4}')
		[ "$_t_report" = "$_base" ] \
			&& pass "$_key: builder maps it to $_base" \
			|| fail "$_key: builder maps it to '$_t_report', the contract says '$_base'"
		[ "$_t_emit" = "$_chan" ] \
			&& pass "$_key: builder emits channel $_chan" \
			|| fail "$_key: builder emits '$_t_emit', the contract says '$_chan'"
	fi

	# CHANNEL MUST NOT BE THE PRODUCER. If a row ever declared them equal for a producer the
	# builder renames, provenance and presentation would have collapsed again.
	if [ "$_key" = "$_chan" ]; then
		fail "$_key: producer key and channel are identical in the contract — they are different identities"
	fi

	# BACKEND MUST NOT BE THE PRODUCER either.
	for _b in $(printf '%s' "$_backends" | tr ',' ' '); do
		[ "$_b" = "$_key" ] && fail "$_key: backend '$_b' is the producer key — a backend cannot stand in for producer identity"
	done
done < "$TMP/rows"
[ "$_rows_seen" -eq "$N" ] \
	&& pass "every one of the $N rows was evaluated" \
	|| fail "only $_rows_seen of $N rows were evaluated"

# --- 4. every declared backend is reachable through a real selection branch -------------------
# Not a name search: knip.sh mentions ts-prune in a 'no tool found' message, so a name grep
# would pass with the fallback deleted. Each backend must appear in an executable test or an
# explicit script/binary selection.
_backend_bad=0
jq -r '.producers[] | .producer_key as $k | .runner as $r | .backends[] | [$k, $r, .] | @tsv' "$SRC" > "$TMP/backends"
while IFS="$(printf '\t')" read -r _k _r _b; do
	[ -n "$_b" ] || continue
	case "$_b" in
	"consumer package.json coverage script")
		# The backend is the adopter's script; the reachable evidence is the script probe.
		grep -qE "for _s in test:coverage coverage" "$ROOT/$_r" \
			&& pass "$_k: the consumer coverage script is selected by an explicit probe" \
			|| { fail "$_k: no coverage-script probe found in $_r"; _backend_bad=1; }
		;;
	*)
		if grep -qE "(-x [^ ]*$_b\]|-x [^ ]*$_b |command_exists $_b|BIN=\"[^\"]*$_b\"|/$_b\b)" "$ROOT/$_r"; then
			pass "$_k: backend '$_b' is reachable through a selection branch in $(basename "$_r")"
		else
			fail "$_k: backend '$_b' is declared but no selection branch in $_r reaches it"
			_backend_bad=1
		fi
		;;
	esac
done < "$TMP/backends"
[ "$_backend_bad" -eq 0 ] && pass "every declared backend is reachable"

# --- 5. completion semantics must be present or explicitly unresolved -----------------------
# A row may say "unknown" — that is a truthful state. What it may NOT do is omit the field, or
# claim an implementation status the rest of the row contradicts.
_vocab='implemented partial unobserved unknown'
_bad_status=$(jq -r --arg v "$_vocab" '.producers[] | select((.implementation_status | IN($v | split(" ")[]))|not) | .producer_key' "$SRC")
[ -z "$_bad_status" ] \
	&& pass "every implementation_status is in vocabulary ($_vocab)" \
	|| fail "out-of-vocabulary implementation_status on: $_bad_status"

for _field in current_process_observation current_report_observation upstream_exit_semantics \
	normative_completion_requirement report_finalization_condition record_report_binding \
	no_observation_behavior enforcing_mode_requirement residual_gap; do
	_missing=$(jq -r --arg f "$_field" '.producers[] | select(has($f)|not) | .producer_key' "$SRC")
	[ -z "$_missing" ] \
		&& pass "every row declares $_field" \
		|| fail "rows missing $_field: $_missing"
done

# An UNKNOWN upstream exit table must name what is missing. "unknown" without a reason is a
# gap disguised as a finding.
_unknown_no_source=$(jq -r '.producers[]
	| select(.upstream_exit_semantics.status == "unknown")
	| select((.upstream_exit_semantics.missing_source // "") == "")
	| .producer_key' "$SRC")
[ -z "$_unknown_no_source" ] \
	&& pass "every unknown upstream exit table names its missing source" \
	|| fail "unknown exit semantics with no missing_source named: $_unknown_no_source"

# --- 6. a parseable report is never recorded as proof of completion --------------------------
# This is the #310 lesson in contract form. Every row must state what its report observation
# does NOT prove.
_no_caveat=$(jq -r '.producers[] | select((.current_report_observation.does_not_prove // "") == "") | .producer_key' "$SRC")
[ -z "$_no_caveat" ] \
	&& pass "every row states what its report observation does NOT prove" \
	|| fail "rows claiming a report observation with no stated limit: $_no_caveat"
_overclaim=$(jq -r '.producers[]
	| select(.current_report_observation.proves | test("complet|full|success"; "i"))
	| .producer_key' "$SRC")
[ -z "$_overclaim" ] \
	&& pass "no row claims its report observation proves completion or success" \
	|| fail "row(s) claiming a report proves completion: $_overclaim"

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
[ -z "$_naive" ] \
	&& pass "no row asserts exit_code==0 as completion without an established exit table" \
	|| fail "row(s) asserting a naive exit_code==0 completion rule: $_naive"

# The coverage producers must keep the test-runner result separate from report finalization.
for _cov in php-coverage php-diff-coverage; do
	_req=$(jq -r --arg k "$_cov" '.producers[] | select(.producer_key == $k) | .normative_completion_requirement' "$SRC")
	case "$_req" in
	*"not of the test-runner exit status"*) pass "$_cov: completion is bound to the report, not the test-runner exit" ;;
	*) fail "$_cov: the contract does not separate report finalization from the test-runner exit status" ;;
	esac
done

# --- 8. execution failure is never classified as completed analysis -------------------------
_bad_noobs=$(jq -r '.producers[]
	| select((.no_observation_behavior.matrix // "") | test("never valid-clean") | not)
	| .producer_key' "$SRC")
[ -z "$_bad_noobs" ] \
	&& pass "every row states that an unobserved producer can never be clean" \
	|| fail "rows without the unobserved-is-never-clean rule: $_bad_noobs"

# --- 9. the multi-backend rows must say the backend changes the meaning ---------------------
_multi=$(jq -r '.producers[] | select((.backends | length) > 1) | .producer_key' "$SRC")
[ -n "$_multi" ] \
	&& pass "multi-backend producers are present in the inventory ($(printf '%s' "$_multi" | tr '\n' ' '))" \
	|| fail "no multi-backend producer recorded — knip/ts-prune and pest/phpunit both exist in the runners"
for _m in $_multi; do
	_note=$(jq -r --arg k "$_m" '.producers[] | select(.producer_key == $k) | .record_report_binding.required' "$SRC")
	case "$_note" in
	*backend*) pass "$_m: the record must carry the backend that produced the report" ;;
	*) fail "$_m: multi-backend producer whose record binding does not require the backend identity" ;;
	esac
done

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d producer-completion-contract check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nproducer-completion-contracts: OK (%d producers; document generated, not maintained)\n' "$N"
exit 0
