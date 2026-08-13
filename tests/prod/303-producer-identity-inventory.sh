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

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$DOC" ] || { fail "docs/producer-identity-inventory.md is missing"; exit 1; }
[ -f "$BUILD" ] || { fail "scripts/build-security-summary.sh is missing"; exit 1; }

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
		fail "$_runner: scripts/runners/$_runner.sh does not exist"
		continue
	fi
	if grep -qE "^OUTPUT=\"reports/raw/$_report\"" "$_rs"; then
		pass "$_runner -> $_report"
	else
		fail "$_runner does not declare OUTPUT=reports/raw/$_report (inventory is stale)"
	fi

	# 2. TOOL_TABLE maps the producer key to that report, that collector and that channel.
	_row=$(grep -E "^$_tkey\|" "$BUILD" | head -1)
	if [ -z "$_row" ]; then
		fail "$_tkey: no TOOL_TABLE row — the producer key in the inventory does not exist"
		continue
	fi
	_t_report=$(printf '%s' "$_row" | awk -F'|' '{print $2}')
	_t_coll=$(printf '%s' "$_row" | awk -F'|' '{print $3}')
	_t_emit=$(printf '%s' "$_row" | awk -F'|' '{print $4}')
	[ "$_t_report" = "$_report" ] \
		&& pass "$_tkey: TOOL_TABLE report is $_report" \
		|| fail "$_tkey: TOOL_TABLE report is '$_t_report', inventory says '$_report'"
	[ "$_t_coll" = "$_collector" ] \
		&& pass "$_tkey: collector is $_collector" \
		|| fail "$_tkey: TOOL_TABLE collector is '$_t_coll', inventory says '$_collector'"
	[ "$_t_emit" = "$_emit" ] \
		&& pass "$_tkey: emitted channel is $_emit" \
		|| fail "$_tkey: TOOL_TABLE emit is '$_t_emit', inventory says '$_emit'"

	# 3. THE FINDING THIS INVENTORY EXISTS FOR. Where the producer key differs from the
	#    emitted channel, the two are NOT interchangeable, and any code that treats them as
	#    one value is the overload the prerequisite must remove.
	if [ "$_tkey" != "$_emit" ]; then
		pass "$_tkey != $_emit — producer key and channel are distinct identities"
	else
		fail "$_tkey == $_emit — this row cannot demonstrate the distinction; the inventory needs a row that can"
	fi

	printf 'x\n' >> "$TMP/count"
done < "$TMP/inventory"

_rows=$(grep -c '|' "$TMP/inventory")
_seen=$( [ -f "$TMP/count" ] && grep -c x "$TMP/count" || printf '0')
[ "$_rows" -eq 9 ] \
	&& pass "the inventory covers exactly the nine engineering-quality runner paths" \
	|| fail "the inventory has $_rows rows, expected 9"
[ "$_seen" -eq "$_rows" ] \
	&& pass "every inventory row was evaluated" \
	|| fail "only $_seen of $_rows inventory rows were evaluated"

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
if [ "$_docn" -eq 0 ]; then
	fail "no rows parsed from $DOC — the table shape changed and this check silently validated nothing"
elif cmp -s "$TMP/doc-rows" "$TMP/inv-rows"; then
	pass "the published table in producer-identity-inventory.md matches the inventory exactly ($_docn rows)"
else
	fail "the published table and the inventory disagree: only-in-doc=[$(comm -23 "$TMP/doc-rows" "$TMP/inv-rows" | tr '\n' ' ')] only-in-inventory=[$(comm -13 "$TMP/doc-rows" "$TMP/inv-rows" | tr '\n' ' ')]"
fi

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
if grep -qE '^[[:space:]]*elif \[ -x node_modules/\.bin/ts-prune \]' "$ROOT/scripts/runners/knip.sh" \
	&& grep -qE '^[[:space:]]*_tp_out=\$\("\$_TP"' "$ROOT/scripts/runners/knip.sh"; then
	pass "knip.sh selects AND invokes the ts-prune fallback — one producer key, two counting semantics"
else
	fail "knip.sh no longer selects and invokes a ts-prune fallback — the inventory's multi-backend finding is stale"
fi
for _cov in php-coverage php-diff-coverage; do
	if grep -qE '^[[:space:]]*if \[ -x vendor/bin/pest \]; then BIN=' "$ROOT/scripts/runners/$_cov.sh" \
		&& grep -qE '^[[:space:]]*elif \[ -x vendor/bin/phpunit \]; then BIN=' "$ROOT/scripts/runners/$_cov.sh"; then
		pass "$_cov.sh BINDS pest or phpunit by executable test at runtime"
	else
		fail "$_cov.sh no longer binds a backend by executable test — the inventory is stale"
	fi
done

# --- the overload itself --------------------------------------------------------------------
# This is the defect the prerequisite removes. While it is present, the assertion documents it
# at the point it lives; when the prerequisite lands, this assertion is what must be updated,
# so the two cannot silently disagree.
# BOTH BRANCHES USED TO `pass`. That made this assertion a false green: removing the overload —
# the single change it exists to notice — left the suite exiting 0 while the document went on
# describing an architecture the code no longer had. It is the same class of defect this
# inventory was written to expose, committed inside the test that exposes it.
#
# The inventoried condition is now enforced in one direction only: while the overload is
# present, this passes; the moment it is removed, this FAILS, and the identity-repair PR must
# update this assertion and the document in the same change. That is the point — the two
# cannot silently disagree.
if grep -qE '^\s*--tool-name\) TOOL=' "$ROOT/scripts/collectors/coverage.sh"; then
	pass "coverage.sh: --tool-name still sets TOOL — the identity/channel overload is present, as inventoried"
else
	fail "coverage.sh: --tool-name no longer sets TOOL — the identity contract changed without updating docs/producer-identity-inventory.md and this suite"
fi

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
if [ -n "$_shared" ]; then
	for _ch in $_shared; do
		_producers=$(awk -F'|' -v c="$_ch" '$4==c {printf "%s ", $1}' "$BUILD")
		_n=$(printf '%s' "$_producers" | wc -w | tr -d ' ')
		[ "$_n" -ge 2 ] \
			&& pass "channel '$_ch' is emitted by $_n distinct producer keys ($_producers) — channel identity cannot be provenance" \
			|| fail "channel '$_ch' appeared shared but resolves to $_n producer key(s)"
	done
else
	fail "no emitted channel is shared by two producer keys — the many-to-one claim in the inventory is unsupported by TOOL_TABLE"
fi
# Collector fan-in is a SEPARATE, weaker property. Kept, but named honestly.
_cov_keys=$(awk -F'|' '$3=="coverage.sh"' "$BUILD" | wc -l | tr -d ' ')
[ "$_cov_keys" -ge 3 ] \
	&& pass "coverage.sh serves $_cov_keys producer keys (collector fan-in, not channel sharing)" \
	|| fail "expected coverage.sh to serve at least 3 producer keys, found $_cov_keys"

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d producer-identity check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nproducer-identity-inventory: OK (9 runner paths; producer key, backend and channel are distinct)\n'
exit 0
