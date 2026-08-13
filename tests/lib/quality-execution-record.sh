# shellcheck shell=sh
# Sentinel Shield test helper — write an execution record for a quality report (#204 C1).
#
# WHY THIS EXISTS
#
# C1 makes `unobserved` a distinct execution state that can never be `valid-clean`. That
# strengthens the engine and invalidates a shortcut every quality suite was taking: a fixture
# report with no execution record beside it now describes a producer nobody watched, so it
# cannot legitimately reach `pass`.
#
# The wrong repair is to rewrite each affected control's expectation from `pass` to
# `execution-error`. That would assert only that the collector refuses things, and a collector
# that refuses EVERYTHING would satisfy it — which is how the #310 enforcement gate shipped
# dead. The right repair is to give a control the provenance it was always implicitly claiming,
# so the suite proves the pair:
#
#     same native report + NO execution observation   -> not clean
#     same native report + observed-complete record   -> its normal verdict
#
# One report, one variable, two outcomes. That is a stronger statement than either half.
#
# The record is written the way a real invoker would write it: bound to the report's CURRENT
# digest and naming the producer, so it is refused if the report is edited afterwards.

# qer_write <tool> <report-path> [status] [exit-code]
#
# Default status `success` (observed-complete). Pass `failed`/`timed-out` for the
# observed-incomplete cases. The record lands at the sidecar path the collector derives, so
# callers never spell that convention themselves.
qer_write() {
	_qer_tool=$1
	_qer_report=$2
	_qer_status=${3:-success}
	_qer_rc=${4:-0}
	_qer_digest=$({ command -v sha256sum >/dev/null 2>&1 && sha256sum "$_qer_report" \
		|| shasum -a 256 "$_qer_report"; } 2>/dev/null | awk '{print $1}')

	# SCOPE is mandatory for quality evidence, and the helper computes a real one rather than
	# stubbing the field. `ne_quality_verify` refuses a record whose scope is empty or absent —
	# "a producer that analyzed nothing has not measured zero violations" — so a control that
	# faked the scope would be asserting a clean pass over an analysis of no files, which is
	# the #204 defect wearing a different hat. The digest is over the sorted, newline-separated
	# path list, matching ne_scope_digest.
	_qer_scope_list=$(printf '%s\n' "src/Example.php" "src/Service/Thing.php" | sort)
	_qer_scope_digest=$(printf '%s\n' "$_qer_scope_list" \
		| { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } 2>/dev/null \
		| awk '{print $1}')

	jq -n \
		--arg t "$_qer_tool" \
		--arg st "$_qer_status" \
		--argjson rc "$_qer_rc" \
		--arg out "$_qer_report" \
		--arg d "$_qer_digest" \
		--arg sd "$_qer_scope_digest" \
		--arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
		{
			record: "sentinel-shield/execution-record@1",
			producer: { tool: $t },
			execution: {
				observed: true,
				status: $st,
				completed: ($st == "success"),
				exit_code: $rc,
				signal: null,
				timed_out: ($st == "timed-out"),
				duration_seconds: 1,
				recorded_at: $at
			},
			output: { path: $out, sha256: $d },
			scope: { paths: ["src/Example.php", "src/Service/Thing.php"], sha256: $sd },
			target: { repository: null, commit: null }
		}' > "${_qer_report%.json}.execution.json"
}

# qer_clear <report-path> — remove any execution record, restoring the UNOBSERVED state.
# Explicit rather than incidental: several suites reuse one report path across cases, and a
# record left behind from a previous case would silently make the next one observed.
qer_clear() { rm -f "${1%.json}.execution.json"; }
