#!/bin/sh
# Sentinel Shield production test — the canonical assertion syntax policy (#345 Part C).
#
# WHY THIS EXISTS
#
# tests/prod/306's two retained bypasses — D3's single-line both-branches-pass and D9's
# earlier-quote argument boundary — have one cause: both detectors must interpret arbitrary
# shell. Two line-oriented AWK extensions were attempted and reverted; each flagged eight real
# suites and classification found zero genuine defects.
#
# This suite does not add a third parser. It enforces a POLICY that makes the two properties
# checkable without parsing, over a bounded, enumerated set of suites:
#
#   P1  a registered suite has no pass/fail of its own, so no conditional can reach a verdict
#   P2  a helper line carries no command substitution, so no argument boundary must be resolved
#   P3  a security-critical rejection carries its control as an argument
#   P4  the library is sourced and the epilogue is called
#   P5  embedded awk/jq is excluded STRUCTURALLY — nothing here tracks quote state
#   P6  the library itself neither evals nor puts a label in a command position
#   P7  an inline conditional may select an assertion, never produce one
#   P8  the registered set is enumerated, non-empty, and every entry exists
#
# WHAT IS NOT CLAIMED
#
# 131 of 3247 static verdict sites are canonical (4.03%). The policy is enforced over the registered
# suites ONLY; 306, 304 and 117 are named in config/harness-assertion-policy.json with their
# reasons and residual gaps. The legacy detectors in 306 still carry the corpus, still with the
# gaps recorded on #345. Nothing here migrates the corpus or claims it is covered.
#
# This suite is itself registered, so the enforcement suite is subject to its own policy.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
POLICY="$ROOT/config/harness-assertion-policy.json"
INVENTORY="$ROOT/config/harness-assertion-inventory.json"
RENDER="$ROOT/scripts/render-assertion-inventory.sh"
LIB="$ROOT/tests/lib/assert.sh"
FIX="$ROOT/tests/fixtures/harness-assertion"

. "$ROOT/tests/lib/assert.sh"

assert_precondition "jq is available" command -v jq
assert_precondition "config/harness-assertion-policy.json exists" test -f "$POLICY"
assert_precondition "tests/lib/assert.sh exists" test -f "$LIB"
assert_precondition "scripts/render-assertion-inventory.sh exists" test -f "$RENDER"

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

HELPERS=$(jq -r '[.canonical_helpers[].name] | join("|")' "$POLICY")

# ============================================================================
# THE DETECTORS. Every one is a grep or an awk pass anchored on a HELPER NAME at a command
# position. None of them strips quotes, tracks quote state, or parses shell — that anchor is
# what P5 means by a structural exclusion, and it is why an `if` inside a single-quoted awk
# program is simply out of scope rather than a case to be handled.
# ============================================================================

# Comment lines are removed first for the same reason 306 does it: a suite that DOCUMENTS a
# forbidden shape in prose must not be flagged for describing it.
_strip() { grep -vE '^[[:space:]]*#' "$1"; }

# P1 — no verdict primitive of the suite's own, defined or called.
p1() { # p1 <file> -> 1 when the file defines or calls pass/fail directly
	# `pass ()` with a space is the same definition as `pass()`; only the second was recognised.
	_strip "$1" | grep -qE '^[[:space:]]*(pass|fail)[[:space:]]*\(\)' && return 1
	# `{` and `(` open a command position. Without them `{ pass "a"; }` reached a verdict inside
	# a registered suite while every detector looked away — the D3 class, restored by grouping.
	_strip "$1" | grep -qE '(^|;|&&|\|\||\{|\(|[[:space:]](then|else|do))[[:space:]]*(pass|fail)[[:space:]]+["'"'"']' && return 1
	return 0
}

# P2 — no command substitution on a line that carries a helper call.
#
# CONTINUATION IS TRACKED, QUOTING IS NOT. A helper call may span lines with a trailing
# backslash, and a substitution on the continuation line belongs to the same call. Following a
# backslash is unambiguous — it is the last character of the line — which is exactly what quote
# state is not.
p2() { # p2 <file> -> 1 when a helper line carries $( or a backtick
	_strip "$1" | awk -v helpers="$HELPERS" '
		function unsafe(s) { return (index(s, "$(") > 0 || index(s, "\140") > 0) }
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			# Peel any command-group openers so a helper inside `{ ... }` or `( ... )` is still
			# seen at a command position. Purely lexical: `{` and `(` are only ever removed from
			# the START of a line, so nothing inside a quoted program is touched.
			while (line ~ /^[{(][ \t]*/) { sub(/^[{(][ \t]*/, "", line) }
			if (incall) {
				if (unsafe(line)) { bad = 1 }
				incall = (line ~ /\\$/)
				next
			}
			if (line ~ "^(" helpers ")[ \t]") {
				if (unsafe(line)) { bad = 1 }
				incall = (line ~ /\\$/)
			}
		}
		END { exit (bad ? 1 : 0) }
	' && return 0
	return 1
}

# P3 — a security-critical rejection must carry its control in the call.
p3() { # p3 <file> -> 1 when a bare assert_reject is present
	_strip "$1" | grep -qE '(^|;|&&|\|\||\{|\(|[[:space:]](then|else|do))[[:space:]]*assert_reject[[:space:]]' && return 1
	return 0
}

# P4 — the library is sourced and the epilogue is called.
p4() { # p4 <file> -> 1 when the library or the epilogue is missing
	_strip "$1" | grep -qE '^[[:space:]]*\.[[:space:]]+"\$(ROOT|\{ROOT\})?/?[^"]*tests/lib/assert\.sh"' || return 1
	_strip "$1" | grep -qE '(^|;|&&|\|\|)[[:space:]]*assert_summary[[:space:]]' || return 1
	return 0
}

# ============================================================================
# P8 first: a policy enforced over an empty set reports success over nothing.
# ============================================================================
_reg_n=$(jq -r '.registered_suites | length' "$POLICY")
assert_true "the policy registers at least one suite (registered=$_reg_n)" test "$_reg_n" -gt 0
assert_true "the policy declares at least one canonical helper" test -n "$HELPERS"

jq -r '.registered_suites[] | [.suite, (.security_critical|tostring)] | @tsv' "$POLICY" > "$TMP/registered"
_checked=0
while IFS="$(printf '\t')" read -r _suite _sec; do
	[ -n "$_suite" ] || continue
	_checked=$((_checked + 1))
	_f="$ROOT/$_suite"
	assert_true "$_suite: the registered suite exists" test -f "$_f"
	[ -f "$_f" ] || continue
	assert_true "P1 $_suite: no pass/fail of its own — no conditional can reach a verdict" p1 "$_f"
	assert_true "P2 $_suite: no command substitution on any helper line" p2 "$_f"
	assert_true "P4 $_suite: sources the library and ends with the epilogue" p4 "$_f"
	if [ "$_sec" = "true" ]; then
		assert_true "P3 $_suite: no bare rejection — every rejection carries its control" p3 "$_f"
	fi
done < "$TMP/registered"
assert_equal "every registered suite was evaluated" "$_reg_n" "$_checked"

# ============================================================================
# THE DETECTORS ARE PROVED. Each rule rejects a deliberately broken fixture and accepts a valid
# control, so a rule that stops working fails here rather than going quiet.
# ============================================================================
assert_false "P1 rejects a fixture that defines and calls pass/fail" p1 "$FIX/bad-p1-bare-pass-fail.sh"
assert_true "P1 CONTROL: canonical verdicts plus a selecting conditional are accepted" p1 "$FIX/good-p1-canonical-only.sh"

assert_false "P2 rejects a command substitution inside a diagnostic" p2 "$FIX/bad-p2-substitution-in-diagnostic.sh"
assert_false "P2 rejects a substitution preceded by an unrelated safe quote — the retained D9 bypass" p2 "$FIX/bad-p2-earlier-quote-then-substitution.sh"
assert_false "P2 rejects a backtick substitution on a helper line" p2 "$FIX/bad-p2-backtick.sh"
assert_true "P2 CONTROL: a precomputed detail passed as data is accepted" p2 "$FIX/good-p2-precomputed-diagnostic.sh"

assert_false "P3 rejects a bare assert_reject" p3 "$FIX/bad-p3-bare-reject.sh"
assert_true "P3 CONTROL: a control-paired rejection is accepted" p3 "$FIX/good-p3-paired-rejection.sh"

assert_false "P4 rejects a suite with no epilogue" p4 "$FIX/bad-p4-no-summary.sh"
assert_true "P4 CONTROL: a suite that sources the library and calls the epilogue is accepted" p4 "$FIX/good-p1-canonical-only.sh"

# COMMAND GROUPS ARE COMMAND POSITIONS. Review found that `{ ... }` and `( ... )` hid a verdict,
# a substitution and an uncontrolled rejection from all three rules at once, which handed back
# the D3 and D9 classes inside a suite still counted as canonical. Each is now a named mutation
# with its control, so the closure is proven rather than asserted.
# SINGLE FAULT EACH. These were one fixture carrying two independent P1 violations, so a
# rejection was not attributable to either. Split, per the same discipline the D5 negatives use.
assert_false "P1 rejects a SPACED verdict-primitive definition" \
	p1 "$FIX/bad-p1-spaced-definition.sh"
assert_false "P1 rejects a verdict reached inside a command group" \
	p1 "$FIX/bad-p1-compound-verdict.sh"
assert_false "P2 rejects a command substitution on a helper line inside a command group" \
	p2 "$FIX/bad-p2-compound-substitution.sh"
assert_false "P3 rejects a bare assert_reject inside a command group" \
	p3 "$FIX/bad-p3-compound-reject.sh"
# CONTINUATION LINES belong to the call that opened them. This was already true; it is now
# proven in both directions rather than left to inspection.
assert_false "P2 rejects a substitution on the CONTINUATION line of a helper call" \
	p2 "$FIX/bad-p2-continued-substitution.sh"
assert_true "P2 CONTROL: a multi-line call whose detail is data is accepted" \
	p2 "$FIX/good-p2-continued-call.sh"
# The group openers must not swallow legitimate code: the controls above still pass, and so does
# the awk/jq fixture, whose embedded program contains braces of its own.
assert_true "P1 CONTROL: the command-group rules do not reject the canonical control" \
	p1 "$FIX/good-p1-canonical-only.sh"
assert_true "P3 CONTROL: the command-group rules do not reject a control-paired rejection" \
	p3 "$FIX/good-p3-paired-rejection.sh"

assert_true "P5 CONTROL: embedded awk and jq conditionals are out of scope, not handled" p2 "$FIX/good-p5-awk-if-not-shell.sh"
# P2 has NO exception for an escaped backtick. This label originally spelled `if` in backticks
# and was flagged, correctly: the alternative is an escape-aware scanner, which is the parsing
# problem D9 died of. Rewording costs nothing; an exception would cost the guarantee.
assert_true "P5 CONTROL: the same fixture satisfies P1 — an awk conditional is not a shell verdict" \
	p1 "$FIX/good-p5-awk-if-not-shell.sh"

# ============================================================================
# EXECUTABLE PROOF. The structural rules above are text; these two run the fixtures and observe
# behaviour, because the zero-assertion case is a property of the library, not of the source.
# ============================================================================
assert_false "the epilogue refuses to report success when zero assertions ran" \
	sh "$FIX/bad-p4-zero-assertions.sh"
assert_true "CONTROL: a fixture with real assertions and an epilogue exits 0" \
	sh "$FIX/good-p1-canonical-only.sh"
assert_true "CONTROL: the control-paired rejection fixture exits 0" \
	sh "$FIX/good-p3-paired-rejection.sh"
assert_true "CONTROL: the awk/jq fixture exits 0" sh "$FIX/good-p5-awk-if-not-shell.sh"

# The unsafe fixtures prove EXECUTION is what the policy prevents, not merely bad style. Each
# writes a fixed sentinel; nothing reads the environment, the account or the network.
_d9_out=$(sh "$FIX/bad-p2-substitution-in-diagnostic.sh" 2>&1 || :)
printf '%s\n' "$_d9_out" > "$TMP/d9.out"
assert_true "the substitution fixture DOES execute its diagnostic — the risk is real, not stylistic" \
	grep -q 'D9-EXECUTED' "$TMP/d9.out"

# ============================================================================
# P6 — the canonical path must not reintroduce what P2 forbids.
# ============================================================================
# Comments are stripped first here too. The library's own header promises it does not eval, and
# an unstripped scan flagged that promise as the violation.
_strip "$LIB" > "$TMP/lib-code"
assert_false "P6 the library never evals" grep -qE '(^|[^_[:alnum:]])eval[[:space:]]' "$TMP/lib-code"
assert_false "P6 the library never places a label variable in a command position" \
	grep -qE '(^|;|&&|\|\||[[:space:]](then|else|do))[[:space:]]*\$_ssa_label' "$TMP/lib-code"
assert_true "P6 the library defines every helper the policy declares" test -n "$HELPERS"
_missing_helper=""
for _h in $(jq -r '.canonical_helpers[].name' "$POLICY"); do
	grep -qE "^$_h\(\)" "$LIB" || _missing_helper="$_missing_helper $_h"
done
assert_equal "P6 every declared helper exists in the library" "" "$_missing_helper"

# ============================================================================
# THE INVENTORY IS GENERATED, not maintained. Regenerate and compare byte for byte.
# ============================================================================
assert_true "the inventory renderer runs" sh "$RENDER" --check
sh "$RENDER" --check > "$TMP/rendered.json" 2>/dev/null || :
assert_true "config/harness-assertion-inventory.json is exactly what the renderer produces" \
	cmp -s "$TMP/rendered.json" "$INVENTORY"
assert_true "the inventory declares itself generated" grep -q 'GENERATED FILE' "$INVENTORY"

# Every registered suite appears in the inventory, and every excluded suite is named there too —
# what is uncovered sits in the same document as what is covered.
_inv_canon=$(jq -r '.totals.canonical_sites' "$INVENTORY")
_inv_legacy=$(jq -r '.totals.legacy_suites_named' "$INVENTORY")
assert_true "the inventory records canonical sites (canonical=$_inv_canon)" test "$_inv_canon" -gt 0
assert_true "the inventory names the unmigrated evidence-critical suites (legacy=$_inv_legacy)" test "$_inv_legacy" -gt 0
# Equal counts are satisfied by an inventory that drops one excluded suite and names another.
# The sorted identity sets are compared, and the count is kept only as a zero-target guard.
_excl_n=$(jq -r '.excluded_suites | length' "$POLICY")
_excl_ids=$(jq -r '[.excluded_suites[].suite] | sort | join(" ")' "$POLICY")
_inv_ids=$(jq -r '[.rows[] | select(.syntax == "legacy") | .suite] | sort | join(" ")' "$INVENTORY")
assert_equal "every excluded suite is named in the inventory, by identity" "$_excl_ids" "$_inv_ids"
assert_equal "the excluded-suite count agrees too" "$_excl_n" "$_inv_legacy"

# No row may claim a rejection without a control. `MISSING` is what the renderer writes for a
# bare assert_reject, so this is the inventory-side counterpart of P3.
_inv_missing=$(jq -r '[.rows[] | select(.acceptance_control == "MISSING") | .site] | join(" ")' "$INVENTORY")
assert_equal "no inventory row records a rejection with a missing control" "" "$_inv_missing"

# Every excluded suite must state a residual gap. An exclusion with no named gap is an
# unrecorded hole.
_excl_no_gap=$(jq -r '[.excluded_suites[] | select((.residual_gap // "") == "") | .suite] | join(" ")' "$POLICY")
assert_equal "every excluded suite names its residual gap" "" "$_excl_no_gap"

# ============================================================================
# THE CENSUS MUST NOT OVERSTATE COVERAGE.
# ============================================================================
_census_sites=$(jq -r '.corpus_census.verdict_sites' "$POLICY")
_census_migrated=$(jq -r '.corpus_census.migrated_static_call_sites_this_pr' "$POLICY")
assert_true "the census records more corpus sites than migrated ones — no coverage claim is implied" \
	test "$_census_sites" -gt "$_census_migrated"
assert_equal "the census migrated count equals the inventory's canonical count" "$_inv_canon" "$_census_migrated"
_uncovered=$(jq -r '.totals.uncovered_sites' "$INVENTORY")
assert_true "the inventory states how many sites remain uncovered ($_uncovered)" test "$_uncovered" -gt 0

# 306 must remain the legacy safeguard: it is excluded BY DESIGN, and its bypass fixtures stay.
_306_status=$(jq -r '.excluded_suites[] | select(.suite == "tests/prod/306-harness-truthfulness.sh") | .migration_status' "$POLICY")
assert_equal "306 is excluded by design, not by omission" "excluded-by-design" "$_306_status"
assert_true "the D3 inline bypass fixture is retained" \
	test -f "$ROOT/tests/fixtures/harness-truthfulness/bad-inline-both-branches-pass.sh"
assert_true "the D9 earlier-quote bypass fixture is retained for legacy syntax" \
	test -f "$ROOT/tests/fixtures/harness-truthfulness/bad-d9-earlier-quote.sh"

# ============================================================================
# MIGRATION REGRESSION EVIDENCE. Four real defects surfaced by converting 303 and 305 — three
# live command substitutions inside diagnostics, and one one-armed assertion that emitted no
# verdict for passing rows. Each is held here with its mutation and its control, so the repair is
# regression-protected rather than described.
# ============================================================================
_mf_n=$(jq -r '.migration_findings.findings | length' "$POLICY")
assert_true "the policy records the migration findings (findings=$_mf_n)" test "$_mf_n" -gt 0

# Every finding must carry all five elements. A finding missing its mutation is a story.
_mf_bad=""
for _fld in id suite rule prior_shape canonical_replacement why_it_mattered mutation_fixture control_fixture mutation_expectation; do
	_n=$(jq -r --arg f "$_fld" '[.migration_findings.findings[] | select(has($f) | not)] | length' "$POLICY")
	[ "$_n" = "0" ] || _mf_bad="$_mf_bad $_fld"
done
assert_equal "every migration finding records shape, replacement, control, mutation and expectation" "" "$_mf_bad"

# Every named fixture must exist, and every P2 mutation must actually be rejected while its
# control is accepted. This is the part that makes the evidence a regression test.
jq -r '.migration_findings.findings[] | [.id, .rule, .mutation_fixture, .control_fixture] | @tsv' "$POLICY" > "$TMP/mf"
_mf_checked=0
while IFS="$(printf '\t')" read -r _id _rule _mut _ctl; do
	[ -n "$_id" ] || continue
	_mf_checked=$((_mf_checked + 1))
	assert_true "$_id: the mutation fixture exists" test -f "$ROOT/$_mut"
	assert_true "$_id: the control fixture exists" test -f "$ROOT/$_ctl"
	case $_rule in
	P2)
		assert_false "$_id: P2 rejects the pre-migration shape" p2 "$ROOT/$_mut"
		assert_true "$_id: P2 CONTROL accepts the canonical replacement" p2 "$ROOT/$_ctl"
		;;
	esac
done < "$TMP/mf"
assert_equal "every migration finding was evaluated" "$_mf_n" "$_mf_checked"

# MF4 is a VISIBILITY defect, not a syntax one, so it is proven by running both shapes over the
# same three correct rows and counting verdicts.
sh "$ROOT/tests/fixtures/harness-assertion/legacy-one-armed-fail.sh" > "$TMP/legacy.out" 2>&1 || :
sh "$ROOT/tests/fixtures/harness-assertion/canonical-one-armed-replacement.sh" > "$TMP/canon.out" 2>&1 || :
_legacy_pass=$(grep -c '^PASS' "$TMP/legacy.out" || true)
_canon_pass=$(grep -c '^PASS' "$TMP/canon.out" || true)
assert_equal "MF4: the one-armed shape emits NO verdict for three correct rows" 0 "$_legacy_pass"
assert_equal "MF4: the canonical replacement emits one verdict per row" 3 "$_canon_pass"
assert_true "MF4: the legacy shape exits 0 while saying nothing — which is why it was invisible" \
	sh "$ROOT/tests/fixtures/harness-assertion/legacy-one-armed-fail.sh"

# The recorded runtime counts are MINIMUMS: passing rows are individually visible now, so a
# regression that silences them lowers the count and fails here.
_c303=$(jq -r '.migration_findings.runtime_assertion_counts["tests/prod/303-producer-identity-inventory.sh"]' "$POLICY")
_c305=$(jq -r '.migration_findings.runtime_assertion_counts["tests/prod/305-producer-completion-contracts.sh"]' "$POLICY")
sh "$ROOT/tests/prod/303-producer-identity-inventory.sh" > "$TMP/303.out" 2>&1 || :
sh "$ROOT/tests/prod/305-producer-completion-contracts.sh" > "$TMP/305.out" 2>&1 || :
_r303=$(grep -c '^PASS' "$TMP/303.out" || true)
_r305=$(grep -c '^PASS' "$TMP/305.out" || true)
assert_true "303 emits at least its recorded $_c303 runtime verdicts (observed $_r303)" test "$_r303" -ge "$_c303"
assert_true "305 emits at least its recorded $_c305 runtime verdicts (observed $_r305)" test "$_r305" -ge "$_c305"

# MF5 is a RECORD-INTEGRITY defect, proven by running both shapes over the real multi-word
# backend value and counting records. It is the one finding here that only reproduces under
# POSIX sh: the interactive shell used during development is zsh, which does not word-split, so
# the legacy shape looked correct until it was re-run under the shell CI actually uses.
sh "$ROOT/tests/fixtures/harness-assertion/legacy-word-split-backend.sh" > "$TMP/ws-legacy.out" 2>&1 || :
sh "$ROOT/tests/fixtures/harness-assertion/canonical-whole-record-backend.sh" > "$TMP/ws-canon.out" 2>&1 || :
_ws_legacy=$(grep -c '^RECORD:' "$TMP/ws-legacy.out" || true)
_ws_canon=$(grep -c '^RECORD:' "$TMP/ws-canon.out" || true)
assert_equal "MF5: the word-splitting shape shatters one declared backend into four records" 4 "$_ws_legacy"
assert_equal "MF5: the canonical shape keeps it as one record" 1 "$_ws_canon"
assert_true "MF5: the canonical record is the declared value, not a fragment" \
	grep -qxF 'RECORD: consumer package.json coverage script' "$TMP/ws-canon.out"
assert_false "MF5: the legacy shape never produces the declared value" \
	grep -qxF 'RECORD: consumer package.json coverage script' "$TMP/ws-legacy.out"

# ============================================================================
# P2 HAS NO ESCAPED-BACKTICK EXCEPTION. Recorded as a decision, with its reasoning, because the
# rule flagged one of this suite's own labels and the label was reworded instead.
# ============================================================================
assert_true "the policy records why P2 takes no exception for an inert escaped backtick" \
	grep -q 'escape-aware' "$POLICY"
assert_false "P2 refuses an escaped backtick on a helper line, inert or not" \
	p2 "$FIX/bad-p2-backtick.sh"

assert_summary "harness-assertion-policy ($_reg_n registered suite(s), $_inv_canon canonical site(s), $_uncovered site(s) uncovered)"
