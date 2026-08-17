# shellcheck shell=sh
# Sentinel Shield test helper — canonical assertion primitives (#345 Part C).
#
# WHY THIS EXISTS
#
# Two detector gaps in tests/prod/306 have the same root cause, and neither can be closed by a
# better regex:
#
#   D3  a both-branches-`pass` conditional written on ONE line is not detected, because
#       recognising it needs multi-line shell quote state.
#   D9  an unsafe diagnostic is missed when an unrelated quoted expression precedes it, because
#       the argument boundary is inferred from the first quote on the line.
#
# Two line-oriented AWK extensions were attempted and reverted. Each flagged eight real suites;
# classification showed zero genuine defects. That path is measured and exhausted.
#
# THE SHIFT: DETECTION -> CONSTRUCTION
#
# Both gaps exist because the detectors must interpret arbitrary shell. Remove the arbitrary
# shell from the assertion surface and the questions stop being hard:
#
#   * A verdict comes from a HELPER CALL, never from a conditional. A registered suite calls no
#     `pass`/`fail` of its own, so there is no branch that could pass in both arms. D3's class
#     is not detected better — it becomes unwritable.
#   * A diagnostic is ARGUMENT ONE of a helper whose name opens the line. The boundary is
#     declared by position, not inferred from quoting. The policy then forbids command
#     substitution anywhere on such a line, which is checkable with no parsing at all and has
#     no false negatives.
#   * Lines that do not begin with a registered helper name are not assertion logic. An
#     embedded awk or jq program is therefore excluded STRUCTURALLY — no quote stripping is
#     involved anywhere, which is what made the previous attempts fragile.
#
# WHAT THIS IS NOT
#
# It is not a shell parser, and it does not migrate the corpus. 3247 static verdict sites exist
# across 98 suites and 118 are canonical (3.63%); the registered set is bounded and named in
# config/harness-assertion-policy.json,
# and tests/prod/307 asserts the policy only over that set. Unregistered suites keep the legacy
# detectors, and their residual gaps stay recorded rather than implied away.
#
# OUTPUT CONTRACT
#
# `PASS: ` / `FAIL: ` on stdout, byte-identical to what every suite already prints, because
# scripts/self-test.sh and D1 read that format. The counter lives here so a registered suite
# cannot lose it in a subshell — the #345 defect 1 family.

SS_ASSERT_FAILS=0
SS_ASSERT_RAN=0
SS_ASSERT_REJECTIONS=0
SS_ASSERT_CONTROLS=0

# Internal. Not part of the assertion vocabulary: a suite calling these directly defeats the
# point, and tests/prod/307 refuses a registered suite that does.
_ss_pass() {
	SS_ASSERT_RAN=$((SS_ASSERT_RAN + 1))
	printf 'PASS: %s\n' "$1"
}
_ss_fail() {
	SS_ASSERT_RAN=$((SS_ASSERT_RAN + 1))
	SS_ASSERT_FAILS=$((SS_ASSERT_FAILS + 1))
	printf 'FAIL: %s\n' "$1"
}

# assert_true <label> <command...>
# The command runs; exit 0 is the pass. `set -e` is deliberately not disarmed around it because
# the status is captured in an `if`, which is the one form that does not terminate the suite.
assert_true() {
	_ssa_label="${1:?assert_true: label required}"
	shift
	[ $# -gt 0 ] || { _ss_fail "$_ssa_label [assert_true called with no command]"; return 0; }
	if "$@" >/dev/null 2>&1; then
		_ss_pass "$_ssa_label"
	else
		_ss_fail "$_ssa_label"
	fi
}

# assert_false <label> <command...> — a non-zero exit is the pass.
assert_false() {
	_ssa_label="${1:?assert_false: label required}"
	shift
	[ $# -gt 0 ] || { _ss_fail "$_ssa_label [assert_false called with no command]"; return 0; }
	if "$@" >/dev/null 2>&1; then
		_ss_fail "$_ssa_label"
	else
		_ss_pass "$_ssa_label"
	fi
}

# assert_accept <label> <command...>
# Semantically distinct from assert_true even though the mechanics match: this one states that a
# component ACCEPTS valid input. Recorded separately so a rejection can be shown to have a
# control rather than being satisfied by a component that refuses everything.
assert_accept() {
	SS_ASSERT_CONTROLS=$((SS_ASSERT_CONTROLS + 1))
	assert_true "$@"
}

# assert_reject <label> <command...> — the component must refuse.
# Bare rejections are permitted for non-security assertions. A security-critical rejection must
# use assert_rejection_with_control, and tests/prod/307 enforces that for suites declared
# security-critical in the policy.
assert_reject() {
	SS_ASSERT_REJECTIONS=$((SS_ASSERT_REJECTIONS + 1))
	assert_false "$@"
}

# assert_equal <label> <expected> <actual>
assert_equal() {
	_ssa_label="${1:?assert_equal: label required}"
	if [ "${2-}" = "${3-}" ]; then
		_ss_pass "$_ssa_label"
	else
		_ss_fail "$_ssa_label [expected '${2-}', got '${3-}']"
	fi
}

# assert_contains_exact <label> <needle> <file>
# A WHOLE-LINE fixed-string match: `grep -qxF`. Neither a substring nor a pattern, which is the
# #345 defect 4 family — a substring grep for a variable name still matched after a rename.
assert_contains_exact() {
	_ssa_label="${1:?assert_contains_exact: label required}"
	_ssa_needle="${2?assert_contains_exact: needle required}"
	_ssa_file="${3:?assert_contains_exact: file required}"
	if [ ! -f "$_ssa_file" ]; then
		_ss_fail "$_ssa_label [no such file: $_ssa_file]"
	elif grep -qxF -- "$_ssa_needle" "$_ssa_file"; then
		_ss_pass "$_ssa_label"
	else
		_ss_fail "$_ssa_label [no line exactly equal to '$_ssa_needle']"
	fi
}

# assert_rejection_with_control <label> -- <reject-command...> -- <accept-command...>
#
# ONE call proving both halves: the component refuses the bad input AND still accepts the good
# one. This is the shape #310's enforcement gate shipped without — every assertion there was
# satisfied by a collector that refused everything, including one that was simply broken.
#
# The control is not optional and not adjacent-by-convention: it is an argument. A rejection
# whose control is missing cannot be expressed.
assert_rejection_with_control() {
	_ssa_label="${1:?assert_rejection_with_control: label required}"
	shift
	[ "${1-}" = "--" ] || { _ss_fail "$_ssa_label [expected -- before the rejection command]"; return 0; }
	shift
	# Split on the second `--`. Positional-only, so no eval and no word splitting of a string.
	_ssa_rej=""
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do
		_ssa_rej="$_ssa_rej$1$(printf '\034')"
		shift
	done
	[ "${1-}" = "--" ] || { _ss_fail "$_ssa_label [expected -- before the control command]"; return 0; }
	shift
	[ $# -gt 0 ] || { _ss_fail "$_ssa_label [no control command given]"; return 0; }
	# The control command is what remains in "$@"; the rejection command is replayed from the
	# record above with IFS set to the separator, so arguments containing spaces survive.
	_ssa_ok=1
	(
		IFS=$(printf '\034')
		# shellcheck disable=SC2086 # deliberate: split on \034, which cannot occur in argv here
		set -- $_ssa_rej
		"$@" >/dev/null 2>&1
	) && _ssa_ok=0
	if [ "$_ssa_ok" = 0 ]; then
		SS_ASSERT_REJECTIONS=$((SS_ASSERT_REJECTIONS + 1))
		_ss_fail "$_ssa_label [the input that must be refused was ACCEPTED]"
		return 0
	fi
	if "$@" >/dev/null 2>&1; then
		SS_ASSERT_REJECTIONS=$((SS_ASSERT_REJECTIONS + 1))
		SS_ASSERT_CONTROLS=$((SS_ASSERT_CONTROLS + 1))
		_ss_pass "$_ssa_label"
	else
		SS_ASSERT_REJECTIONS=$((SS_ASSERT_REJECTIONS + 1))
		_ss_fail "$_ssa_label [CONTROL failed: valid input was also refused, so the rejection proves nothing]"
	fi
}

# assert_precondition <label> <command...>
# A precondition is not an assertion: if jq is absent or a required file is missing, nothing
# below it means anything. Failing one prints FAIL and exits non-zero immediately, which keeps
# the FAIL-output/zero-exit property (#345 defect 1) intact for the abort path too.
assert_precondition() {
	_ssa_label="${1:?assert_precondition: label required}"
	shift
	if [ $# -gt 0 ] && "$@" >/dev/null 2>&1; then
		_ss_pass "$_ssa_label"
	else
		_ss_fail "$_ssa_label [precondition]"
		printf '\nprecondition failed: %s\n' "$_ssa_label" >&2
		exit 1
	fi
}

# assert_summary <suite label>
# The epilogue every registered suite ends with. Three properties in one place:
#   * a non-zero exit when anything failed;
#   * a non-zero exit when NOTHING ran, so a suite whose assertions were skipped or globbed
#     away cannot report success over an empty set;
#   * the FAIL/exit-code agreement D1 checks, made structural rather than detected.
assert_summary() {
	_ssa_what="${1:-suite}"
	if [ "$SS_ASSERT_RAN" -eq 0 ]; then
		printf 'FAIL: %s ran zero assertions — refusing to report success over an empty set\n' "$_ssa_what"
		return 1
	fi
	if [ "$SS_ASSERT_FAILS" -gt 0 ]; then
		printf '\n%s: %d of %d assertion(s) failed\n' "$_ssa_what" "$SS_ASSERT_FAILS" "$SS_ASSERT_RAN" >&2
		return 1
	fi
	printf '\n%s: OK (%d assertions, %d rejection(s), %d control(s))\n' \
		"$_ssa_what" "$SS_ASSERT_RAN" "$SS_ASSERT_REJECTIONS" "$SS_ASSERT_CONTROLS"
	return 0
}
