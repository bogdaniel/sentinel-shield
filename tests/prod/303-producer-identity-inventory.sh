#!/bin/sh
# Sentinel Shield production test — the producer identity inventory (#204 C2 prerequisite).
#
# WHY THIS EXISTS
#
# docs/producer-identity-inventory.md records, for each of the nine engineering-quality runner
# paths, four separate identities: the runner SCRIPT, the BACKEND it actually executes, the
# producer KEY (tkey), and the emitted CHANNEL. The prerequisite work rests on that table
# being true.
#
# A table nothing checks is a table that drifts. Worse, it drifts silently in exactly the
# direction that matters: someone renames a report, adds a stack, or repoints a runner, and the
# document keeps asserting an identity mapping the code no longer has. So every row is
# asserted against the code here, in BOTH directions.
#
# This is identity ONLY. Exit semantics, completion semantics and scope/configuration binding
# belong to the normative producer inventory, which is separate work.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DOC="$ROOT/docs/producer-identity-inventory.md"
BUILD="$ROOT/scripts/build-security-summary.sh"

# CANONICAL ASSERTION SUITE (#345 Part C). Registered in config/harness-assertion-policy.json.
#
# Every verdict below comes from a declared helper, never from a conditional, so a
# both-branches-pass assertion cannot be written here at all. Every diagnostic is argument one
# of a helper call, and no such line may contain a command substitution — which is why the
# published-table diagnostic further down computes its detail into a variable first.
# tests/prod/307 enforces both properties over this file.
. "$ROOT/tests/lib/assert.sh"

assert_precondition "jq is available" command -v jq
assert_precondition "docs/producer-identity-inventory.md exists" test -f "$DOC"
assert_precondition "scripts/build-security-summary.sh exists" test -f "$BUILD"

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# runner | producer key (tkey) | native report basename | collector | emitted channel
#
# Held here as data rather than parsed out of the markdown: a test that reads the document it
# is validating can only prove the document is self-consistent, not that it describes the code.
INVENTORY='infection|php-mutation|php-mutation.json|mutation.sh|php_mutation
stryker|js-mutation|js-mutation.json|mutation.sh|js_mutation
phpmd-complexity|php-complexity|php-complexity.json|complexity.sh|php_complexity
phpcpd|php-duplication|php-duplication.json|duplication.sh|php_duplication
jscpd|js-duplication|js-duplication.json|duplication.sh|js_duplication
knip|js-dead-code|js-dead-code.json|dead-code.sh|js_dead_code
php-coverage|php-coverage|php-coverage.json|coverage.sh|php_coverage
js-coverage|js-coverage|js-coverage.json|coverage.sh|js_coverage
php-diff-coverage|php-diff-coverage|php-diff-coverage.json|diff-coverage.sh|php_diff_coverage'

# Fed from a FILE, not a pipeline. `printf ... | while read` runs the loop body in a SUBSHELL,
# so every `fail` inside it would increment a copy of FAILS and the suite would exit 0 with
# FAIL lines printed above it — a suite that reports failures and passes. Verified: mutating a
# row while the loop was a pipeline printed the FAIL and still exited 0.
printf '%s\n' "$INVENTORY" > "$TMP/inventory"
while IFS='|' read -r _runner _tkey _report _collector _emit; do
	[ -n "$_runner" ] || continue

	# 1. the runner exists and writes the report this row claims.
	_rs="$ROOT/scripts/runners/$_runner.sh"
	if [ ! -f "$_rs" ]; then
		assert_true "$_runner: scripts/runners/$_runner.sh exists" false
		continue
	fi
	assert_true "$_runner -> $_report (runner declares OUTPUT=reports/raw/$_report)" \
		grep -qE "^OUTPUT=\"reports/raw/$_report\"" "$_rs"

	# 2. TOOL_TABLE maps the producer key to that report, that collector and that channel.
	_row=$(grep -E "^$_tkey\|" "$BUILD" | head -1)
	if [ -z "$_row" ]; then
		assert_true "$_tkey: TOOL_TABLE has a row — the producer key in the inventory exists" false
		continue
	fi
	_t_report=$(printf '%s' "$_row" | awk -F'|' '{print $2}')
	_t_coll=$(printf '%s' "$_row" | awk -F'|' '{print $3}')
	_t_emit=$(printf '%s' "$_row" | awk -F'|' '{print $4}')
	# assert_equal reports expected-versus-got itself, so the two-armed form that used to spell
	# the mismatch out by hand is gone along with its second label.
	assert_equal "$_tkey: TOOL_TABLE report is $_report" "$_report" "$_t_report"
	assert_equal "$_tkey: collector is $_collector" "$_collector" "$_t_coll"
	assert_equal "$_tkey: emitted channel is $_emit" "$_emit" "$_t_emit"

	# 3. THE FINDING THIS INVENTORY EXISTS FOR. Where the producer key differs from the
	#    emitted channel, the two are NOT interchangeable, and any code that treats them as
	#    one value is the overload the prerequisite must remove.
	assert_false "$_tkey != $_emit — producer key and channel are distinct identities" \
		test "$_tkey" = "$_emit"

	printf 'x\n' >> "$TMP/count"
done < "$TMP/inventory"

_rows=$(grep -c '|' "$TMP/inventory")
_seen=$( [ -f "$TMP/count" ] && grep -c x "$TMP/count" || printf '0')
assert_equal "the inventory covers exactly the nine engineering-quality runner paths" 9 "$_rows"
assert_equal "every inventory row was evaluated" "$_rows" "$_seen"

# --- the DOCUMENT must match the inventory too ----------------------------------------------
# $DOC was only checked for existence, so a documentation-only mapping change passed every
# assertion in this suite: the code checks above compare INVENTORY to the code, and nothing
# compared the published table to either. The table is what a reader acts on, so it is held to
# the same standard.
#
# Parsed from the markdown table: runner | backend | producer key | report | collector | channel.
# The backend column is prose (`knip _or_ ts-prune`) and is deliberately NOT compared — it is
# asserted structurally by the multi-backend section below.
awk -F'|' '
	/^\| `[a-z0-9-]+\.sh` \|/ {
		for (i = 2; i <= 7; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i); gsub(/`|\*\*/, "", $i) }
		sub(/\.sh$/, "", $2)
		print $2 "|" $4 "|" $5 "|" $6 "|" $7
	}
' "$DOC" | sort > "$TMP/doc-rows"
awk -F'|' '{print $1 "|" $2 "|" $3 "|" $4 "|" $5}' "$TMP/inventory" | sort > "$TMP/inv-rows"

_docn=$(grep -c . "$TMP/doc-rows" || true)
# The zero-rows case is its own assertion rather than a branch of the comparison: a table whose
# shape changed parses to nothing, and nothing compares equal to nothing.
assert_false "rows were parsed from producer-identity-inventory.md" test "$_docn" -eq 0
# THE DIAGNOSTIC IS COMPUTED FIRST. This detail used to be built with two `$(comm ...)`
# substitutions inside the failure message — a command substitution in a diagnostic argument,
# which is exactly the shape D9 exists to find and could not reliably see. Under the canonical
# policy the line carrying a helper call may contain no substitution at all, so the detail is
# data by the time it reaches the helper.
_only_doc=$(comm -23 "$TMP/doc-rows" "$TMP/inv-rows" | tr '\n' ' ')
_only_inv=$(comm -13 "$TMP/doc-rows" "$TMP/inv-rows" | tr '\n' ' ')
assert_equal "the published table matches the inventory exactly ($_docn rows): only-in-doc" "" "$_only_doc"
assert_equal "the published table matches the inventory exactly ($_docn rows): only-in-inventory" "" "$_only_inv"

# --- the multi-backend runners -------------------------------------------------------------
# knip.sh and the coverage runners select their backend AT RUNTIME, so one producer key can
# describe two tools with different counting semantics. That is the reason the record must
# carry the backend separately from the verified identity, and it is asserted rather than
# assumed because a refactor could quietly collapse the fallback.
# These assertions used to grep for the backend NAME. That is not enough: knip.sh mentions
# ts-prune in its "no dead-code tool found" message, so the fallback could be deleted entirely
# and the grep would still match. The same applies to the coverage runners, which name both
# binaries in a warning. Assert the SELECTION — an executable test that binds the backend — and
# for knip that the fallback is actually invoked.
assert_true "knip.sh SELECTS the ts-prune fallback — one producer key, two counting semantics" \
	grep -qE '^[[:space:]]*elif \[ -x node_modules/\.bin/ts-prune \]' "$ROOT/scripts/runners/knip.sh"
assert_true "knip.sh INVOKES the ts-prune fallback it selects" \
	grep -qE '^[[:space:]]*_tp_out=\$\("\$_TP"' "$ROOT/scripts/runners/knip.sh"
for _cov in php-coverage php-diff-coverage; do
	assert_true "$_cov.sh binds pest by executable test at runtime" \
		grep -qE '^[[:space:]]*if \[ -x vendor/bin/pest \]; then BIN=' "$ROOT/scripts/runners/$_cov.sh"
	assert_true "$_cov.sh binds phpunit by executable test at runtime" \
		grep -qE '^[[:space:]]*elif \[ -x vendor/bin/phpunit \]; then BIN=' "$ROOT/scripts/runners/$_cov.sh"
done

# --- the identity SPLIT (was: the overload) --------------------------------------------------
# This assertion pinned the overload while it existed and required that removing it be a
# deliberate change made together with the document. The split has now landed, so it inverts:
# the overload must not come back.
assert_false "coverage.sh: --tool-name sets the CHANNEL only, never PRODUCER" \
	grep -qE '^\s*--tool-name\) TOOL=[^;]*PRODUCER=' "$ROOT/scripts/collectors/coverage.sh"
assert_true "coverage.sh: --producer-key sets the verified producer identity" \
	grep -qE '^\s*--producer-key\) PRODUCER=' "$ROOT/scripts/collectors/coverage.sh"
# The default must be established BEFORE argument parsing, so no ordering of channel arguments
# can influence it.
_pl=$(grep -n '^PRODUCER=' "$ROOT/scripts/collectors/coverage.sh" | head -1 | cut -d: -f1)
_al=$(grep -n 'while \[ $# -gt 0 \]' "$ROOT/scripts/collectors/coverage.sh" | head -1 | cut -d: -f1)
assert_true "coverage.sh: PRODUCER is captured before argument parsing (line $_pl < $_al)" \
	test -n "$_pl" -a -n "$_al" -a "$_pl" -lt "$_al"

# --- the many-to-one CHANNEL case ----------------------------------------------------------
# This assertion previously counted producer keys served by coverage.sh and called that
# many-to-one. It is not: coverage, php-coverage and js-coverage each emit a DIFFERENT channel
# (coverage, php_coverage, js_coverage), so it demonstrated collector FAN-IN and would have
# passed even if no two producers ever shared a channel — leaving the documented invariant
# untested.
#
# The real case is two distinct producer keys emitting ONE channel. If channel identity were
# used for provenance, those two producers would be indistinguishable in the evidence, which is
# the precise opposite of what execution provenance exists to provide.
_shared=$(awk -F'|' 'NF>=4 && $1 !~ /^#/ && $4 != "" {print $4}' "$BUILD" | sort | uniq -d | grep -E '^[a-z0-9_]+$' || true)
assert_true "at least one emitted channel is shared by two producer keys — the many-to-one claim is supported by TOOL_TABLE" \
	test -n "$_shared"
for _ch in $_shared; do
	_producers=$(awk -F'|' -v c="$_ch" '$4==c {printf "%s ", $1}' "$BUILD")
	_n=$(printf '%s' "$_producers" | wc -w | tr -d ' ')
	assert_true "channel '$_ch' is emitted by $_n distinct producer keys ($_producers) — channel identity cannot be provenance" \
		test "$_n" -ge 2
done
# Collector fan-in is a SEPARATE, weaker property. Kept, but named honestly.
_cov_keys=$(awk -F'|' '$3=="coverage.sh"' "$BUILD" | wc -l | tr -d ' ')
assert_true "coverage.sh serves $_cov_keys producer keys (collector fan-in, not channel sharing)" \
	test "$_cov_keys" -ge 3

# The epilogue lives in the library: non-zero on any failure, and non-zero when NOTHING ran, so
# a suite whose assertions were globbed away cannot report success over an empty set.
assert_summary "producer-identity-inventory (9 runner paths; producer key, backend and channel are distinct)"
