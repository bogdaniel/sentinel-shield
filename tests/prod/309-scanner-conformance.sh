#!/bin/sh
# Sentinel Shield production test — the scanner conformance matrix (#96-#105).
#
# LAYER 2 OF THREE, TABLE-DRIVEN.
#
# Ten adapters, five scenarios, one suite. Every expected state is read from
# config/scanner-contracts.json rather than written here, so a scanner whose semantics differ
# declares that in its row instead of forking a test body. Onboarding a scanner is a table row.
#
# WHAT THIS SUITE DOES NOT DO. It does not re-prove the shared lifecycle -- tests/prod/308 does
# that once, through a probe adapter with a one-field validator. Here the only lifecycle claim is
# that each real adapter PARTICIPATES in it. Nor does it prove tool-specific semantics: that a
# Grype image reference is refused, or that OSV separates no-targets from clean, is Layer 3's job
# (tests/prod/310). A matrix that claimed those would be claiming coverage it does not exercise.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/scanner-fake.sh"
TABLE="$ROOT/config/scanner-contracts.json"

assert_precondition "jq is available" command -v jq
assert_precondition "the contract table exists" test -f "$TABLE"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# ===========================================================================
# MATRIX INTEGRITY, BEFORE ANY SCENARIO RUNS.
#
# A conformance matrix that silently covers nine of ten rows, or exercises one scanner twice under
# two names, reports success while proving less than it claims. Each defect below is refused.
# ===========================================================================
ROWS=$(jq -r '.scanners | length' "$TABLE")
assert_true "the table declares at least one scanner row (rows=$ROWS)" test "$ROWS" -gt 0

_dupes=$(jq -r '[.scanners[].tool] | group_by(.) | map(select(length > 1) | .[0]) | join(" ")' "$TABLE")
assert_equal "producer keys are unique — no row can shadow another" "" "$_dupes"

_dup_out=$(jq -r '[.scanners[].output] | group_by(.) | map(select(length > 1) | .[0]) | join(" ")' "$TABLE")
assert_equal "no two rows publish to the same output path" "" "$_dup_out"

_scenarios=$(jq -r '.scenarios | join(" ")' "$TABLE")
assert_true "the table declares the scenario set" test -n "$_scenarios"

# Every row must resolve to a real adapter and a real validator. An unknown validator name would
# make a row's rejection meaningless -- it would fail for being unresolvable, not for its contract.
jq -r '.scanners[] | [.tool, .adapter, .validator, .binary, .output] | @tsv' "$TABLE" > "$TMP/rows"
_bad_adapter=""; _bad_validator=""; _n_rows=0
while IFS="$(printf '\t')" read -r _tool _adapter _validator _binary _output; do
	[ -n "$_tool" ] || continue
	_n_rows=$((_n_rows + 1))
	[ -f "$ROOT/$_adapter" ] || _bad_adapter="$_bad_adapter $_tool:$_adapter"
	grep -qE "^$_validator\(\)" "$ROOT/scripts/lib/scanner-contracts.sh" || _bad_validator="$_bad_validator $_tool:$_validator"
done < "$TMP/rows"
assert_equal "every row resolves to an adapter that exists" "" "$_bad_adapter"
assert_equal "every row resolves to a declared tool-specific validator" "" "$_bad_validator"
assert_equal "every declared row was read" "$ROWS" "$_n_rows"

# Each adapter must actually use the shared transaction. Without this a row could pass the matrix
# with a private lifecycle of its own, which is the duplication this batch removed.
_not_shared=""
while IFS="$(printf '\t')" read -r _tool _adapter _rest; do
	[ -n "$_tool" ] || continue
	grep -q 'scanner-transaction.sh' "$ROOT/$_adapter" || _not_shared="$_not_shared $_tool"
done < "$TMP/rows"
assert_equal "every adapter participates in the shared transaction" "" "$_not_shared"

# ===========================================================================
# THE MATRIX. Every row, every scenario, expectations read from the row.
# ===========================================================================
EXERCISED="$TMP/exercised"; : > "$EXERCISED"
_matrix_fail=0

while IFS="$(printf '\t')" read -r TOOL ADAPTER VALIDATOR BINARY OUTPUT; do
	[ -n "$TOOL" ] || continue
	CLEAN=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .fakes.clean' "$TABLE")
	FIND=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .fakes.findings' "$TABLE")
	MALF=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .fakes.malformed' "$TABLE")
	WRITES=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .writes' "$TABLE")
	FEXIT=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .findings_exit' "$TABLE")

	for SCEN in clean findings malformed fail missing; do
		WANT=$(jq -r --arg t "$TOOL" --arg s "$SCEN" '.scanners[] | select(.tool==$t) | .expected[$s]' "$TABLE")
		D="$TMP/$TOOL-$SCEN"
		P=$(sf_project "$D")
		case "$SCEN" in
		clean)     PAY="$CLEAN" ;;
		findings)  PAY="$FIND" ;;
		malformed) PAY="$MALF" ;;
		*)         PAY="" ;;
		esac
		if [ "$SCEN" = "missing" ]; then mkdir -p "$D/bin"; else sf_make "$D" "$BINARY" "$WRITES" "$SCEN" "$PAY" "$FEXIT" >/dev/null; fi
		# Row-declared setup and environment: a scanner needing a policy directory or an image ref
		# says so in the table rather than in a special case here.
		for _f in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .setup_files[]?' "$TABLE"); do
			mkdir -p "$P/$(dirname "$_f")"; printf 'package main\n' > "$P/$_f"
		done
		set -- ; for _e in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .env[]?' "$TABLE"); do set -- "$@" "$_e"; done
		sf_plant_stale "$P" "$OUTPUT"
		sf_run "$P" "$D/bin" "$ROOT/$ADAPTER" "$OUTPUT" "$@" || :

		GOT=$(sf_state "$P" "$OUTPUT")
		# Every diagnostic names the producer key AND the scenario, so a matrix failure is
		# attributable without re-running anything.
		assert_equal "[$TOOL/$SCEN] reaches the state its contract row declares" "$WANT" "$GOT"
		assert_false "[$TOOL/$SCEN] stale evidence does not survive" sf_stale_survived "$P" "$OUTPUT"
		assert_equal "[$TOOL/$SCEN] no owned workspace remains" "0" "$(sf_temp_left "$P")"
		# Only a completed scan may leave a report standing.
		case "$WANT" in
		completed-*) assert_true  "[$TOOL/$SCEN] a completed scan publishes its report" test -f "$P/$OUTPUT" ;;
		*)           assert_false "[$TOOL/$SCEN] a non-completed state publishes nothing" test -f "$P/$OUTPUT" ;;
		esac
		printf '%s\n' "$TOOL" >> "$EXERCISED"
	done

	# HOST ISOLATION, per row. With no fake present the adapter must report unavailable — never a
	# result obtained from a scanner that happens to be installed on this machine. This is asserted
	# per row because it has already gone wrong twice during this batch.
	D="$TMP/$TOOL-hostiso"; P=$(sf_project "$D"); mkdir -p "$D/bin"
	set -- ; for _e in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .env[]?' "$TABLE"); do set -- "$@" "$_e"; done
	sf_run "$P" "$D/bin" "$ROOT/$ADAPTER" "$OUTPUT" "$@" || :
	_iso=$(sf_state "$P" "$OUTPUT")
	assert_false "[$TOOL/host-isolation] no result is obtained from a host-installed scanner" \
		test "$_iso" = "completed-clean" -o "$_iso" = "completed-findings"
done < "$TMP/rows"

# ===========================================================================
# COVERAGE: the matrix must have exercised every declared row. A row added to the table and never
# run would otherwise sit there looking like coverage.
# ===========================================================================
_ex_rows=$(sort -u "$EXERCISED" | grep -c . || true)
assert_equal "every declared contract row was exercised by the matrix" "$ROWS" "$_ex_rows"
_ex_runs=$(grep -c . "$EXERCISED" || true)
assert_equal "every row ran the full scenario set" "$((ROWS * 5))" "$_ex_runs"

# A row cannot accidentally exercise another scanner: each adapter's published path is the one its
# own row declares, and no two rows share a path (asserted above).
_wrong_path=""
while IFS="$(printf '\t')" read -r _tool _adapter _v _b _out; do
	[ -n "$_tool" ] || continue
	grep -qF "$_out" "$ROOT/$_adapter" || _wrong_path="$_wrong_path $_tool"
done < "$TMP/rows"
assert_equal "each adapter names its own row's output path" "" "$_wrong_path"

# ===========================================================================
# THE ABANDONED TRIVY SPELLING CANNOT SATISFY THE EVIDENCE CONTRACT (#99).
#
# scripts/audits/trivy-fs.sh and scripts/audits/trivy-image.sh BOTH defaulted to
# reports/raw/trivy.json, so a filesystem scan and an image scan overwrote each other and no
# consumer could tell which scan it was reading. Three CI workflows wrote fs results there while a
# fourth wrote an image result to the same name. Meanwhile profiles and the scheduled workflow
# expected reports/raw/trivy-fs.json -- a path no producer wrote.
#
# The two scanners now have two paths. These assertions keep it that way.
_fs_out=$(jq -r '.scanners[] | select(.tool=="trivy-fs") | .output' "$TABLE")
assert_equal "the filesystem scanner's canonical path names its scan type" "reports/raw/trivy-fs.json" "$_fs_out"
assert_false "no active producer still writes the ambiguous bare spelling" \
	grep -rq 'reports/raw/trivy\.json' "$ROOT/scripts/audits"
assert_false "no active collector still reads it" \
	grep -rq 'reports/raw/trivy\.json' "$ROOT/scripts/collectors"
assert_false "no profile or workflow still names it" \
	grep -rq 'reports/raw/trivy\.json' "$ROOT/profiles" "$ROOT/.github/workflows" "$ROOT/templates"
# The two Trivy producers must not converge again. A shared path is what made the evidence
# unattributable in the first place.
_img_out=$(grep -oE 'reports/raw/trivy[a-z-]*\.json' "$ROOT/scripts/audits/trivy-image.sh" | head -1)
assert_false "the filesystem and image scanners do not share an output path" test "$_fs_out" = "$_img_out"

assert_summary "scanner-conformance ($ROWS rows x 5 scenarios, expectations derived from the contract table)"
