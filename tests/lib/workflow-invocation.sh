# shellcheck shell=sh
# Shared matcher: does a workflow file INVOKE scripts/self-test.sh with a given argument?
#
# Extracted from tests/prod/111-workflow-timeouts.sh so the suite-topology proof
# (tests/prod/113-suite-topology.sh) reuses the hardened logic instead of growing a second,
# weaker parser. Two matchers for the same contract is how one of them quietly stops matching.
#
# The matcher must see the INVOCATION, not one spelling of it. The first version of this
# required `run: sh scripts/self-test.sh <arg>` on a single line, so `./scripts/self-test.sh
# all`, `bash scripts/self-test.sh all`, and the same command inside a multiline `run: |`
# block all counted as zero — and a workflow could regain the complete suite, and its timeout
# risk, while still passing the check. A contract enforced against one spelling is not
# enforced.
#
# So: any line invoking the script with that argument, however spelled, whether or not `run:`
# is on the same line. Comment lines are excluded, so prose mentioning a command is never
# counted as running it.

# wf_run_count <workflow-file-abs-path> <self-test-arg> — print the invocation count.
# Prints 0 (never an error) for a missing file: callers assert on the number.
wf_run_count() {
	grep -vE '^[[:space:]]*#' "$1" 2>/dev/null |
		grep -cE "(^|[[:space:]]|/)(sh|bash|dash)?[[:space:]]*\.?/?scripts/self-test\.sh[[:space:]]+$2([[:space:]]|\$)" ||
		true
}

# wf_run_count_int <workflow-file-abs-path> <self-test-arg> — as above, coerced to an integer.
wf_run_count_int() {
	_wfc=$(wf_run_count "$1" "$2")
	case "$_wfc" in '' | *[!0-9]*) _wfc=0 ;; esac
	printf '%s' "$_wfc"
}

# wf_run_count_selfcheck <pass-fn> <fail-fn> — prove the matcher still sees every spelling.
#
# A matcher that silently stopped matching would make every assertion built on it report
# "0 invocations", which reads identically to "correctly absent". Each fixture below is a way
# a workflow could regain a suite while a naive check reported zero.
wf_run_count_selfcheck() {
	_sc_pass=$1
	_sc_fail=$2
	_sc_dir=$(mktemp -d)
	printf 'jobs:\n  a:\n    steps:\n      - run: ./scripts/self-test.sh all\n' >"$_sc_dir/direct.yml"
	printf 'jobs:\n  a:\n    steps:\n      - run: bash scripts/self-test.sh all\n' >"$_sc_dir/bash.yml"
	printf 'jobs:\n  a:\n    steps:\n      - run: dash scripts/self-test.sh all\n' >"$_sc_dir/dash.yml"
	printf 'jobs:\n  a:\n    steps:\n      - run: |\n          set -eu\n          sh scripts/self-test.sh all\n' >"$_sc_dir/multiline.yml"
	printf 'jobs:\n  a:\n    steps:\n      # sh scripts/self-test.sh all  (documentation, not an invocation)\n      - run: echo hi\n' >"$_sc_dir/comment.yml"
	# `ci-core` must not be matched by a search for `all`, or the topology proof would read
	# the replacement invocation as the thing it replaced.
	printf 'jobs:\n  a:\n    steps:\n      - run: sh scripts/self-test.sh ci-core\n' >"$_sc_dir/cicore.yml"

	for _sc_form in direct bash dash multiline; do
		if [ "$(wf_run_count_int "$_sc_dir/$_sc_form.yml" all)" -eq 1 ]; then
			"$_sc_pass" "matcher detects the $_sc_form invocation form"
		else
			"$_sc_fail" "matcher missed the $_sc_form invocation form — a suite could be restored without any check noticing"
		fi
	done
	if [ "$(wf_run_count_int "$_sc_dir/comment.yml" all)" -eq 0 ]; then
		"$_sc_pass" "matcher does not count a commented-out invocation"
	else
		"$_sc_fail" "matcher counted a comment as an invocation"
	fi
	if [ "$(wf_run_count_int "$_sc_dir/cicore.yml" all)" -eq 0 ]; then
		"$_sc_pass" "matcher does not confuse 'ci-core' with 'all'"
	else
		"$_sc_fail" "matcher counted 'self-test.sh ci-core' as an invocation of 'all'"
	fi
	if [ "$(wf_run_count_int "$_sc_dir/cicore.yml" ci-core)" -eq 1 ]; then
		"$_sc_pass" "matcher detects a 'ci-core' invocation"
	else
		"$_sc_fail" "matcher missed a 'ci-core' invocation"
	fi
	rm -rf "$_sc_dir"
}
