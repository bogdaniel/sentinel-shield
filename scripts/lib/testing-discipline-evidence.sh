#!/bin/sh
# Sentinel Shield — testing-discipline evidence helpers (POSIX sh, source; do not execute).
#
# Shared by the three testing-discipline COLLECTORS (test-change-evidence, behavior-specs,
# acceptance-tests) so the normalized raw contracts are read ONE way:
#
#   pass       -> the producer ran, nothing to report
#   findings   -> the producer ran, something to report (violations / failures)
#   unavailable / not-configured / execution-error / disabled / not-applicable are
#              PRESERVED verbatim (never collapsed into a clean pass)
#   unknown status              -> fail closed as execution-error
#   missing/empty raw report    -> unavailable (ss_collector_guard)
#   invalid JSON                -> exit 2 (ss_collector_guard)
#
# Scope honesty (docs/testing-discipline-governance.md): none of this proves that tests were
# written first. It proves that specific EVIDENCE exists or does not.
#
# Requires scripts/lib/sentinel-shield-common.sh already sourced (ss_emit_collector, log_*).

# td_passthrough_status <tool> <input> <zero-summary-overrides-json> — when the raw report
# carries a NON-evidence status, emit the collector object with that status preserved (zero
# counters, no evidence credit) and exit 0. Unknown/unexpected status fails closed as
# execution-error. Returns 0 (without emitting) when the status is empty/pass/findings/fail/
# warn so the caller can read its counters.
#
# <zero-summary-overrides-json> is the collector's own summary counters at their SAFE values.
# <report-extras-json> is merged into the emitted tool_report — the collectors pass their
# missing_* verdict there (e.g. '{"missing_acceptance_evidence":true}') so a NON-evidence
# status still records honestly WHY it is not evidence. The missing_* flags live in the
# tool_report, not the summary: only the builder knows whether that evidence was EXPECTED.
td_passthrough_status() {
	_tov=${3:-}; [ -n "$_tov" ] || _tov='{}'
	_tre=${4:-}; [ -n "$_tre" ] || _tre='{}'
	_ts=$(jq -r 'if type=="object" then (.status // "") else "" end' "$2" 2>/dev/null || printf '')
	case "$_ts" in
		'' | pass | findings | fail | warn) return 0 ;;
		unavailable | not-configured | execution-error | disabled | not-applicable)
			ss_emit_collector "$1" "$_ts" \
				"$(jq -n --arg s "$_ts" --argjson x "$_tre" '{status:$s} + $x')" "$_tov"
			exit 0 ;;
		*)
			log_warn "$1: unknown status '$_ts' in '$2'; status=execution-error (never reported as clean)"
			ss_emit_collector "$1" "execution-error" \
				"$(jq -n --argjson x "$_tre" '{status:"execution-error", reason:"unknown testing-discipline status"} + $x')" "$_tov"
			exit 0 ;;
	esac
}

# td_num <input> <jq-expression> — non-negative integer from the raw report, or 0. For
# INFORMATIONAL metadata only (counts that are safe to default).
td_num() {
	_n=$(jq "($2) | if type==\"number\" and . >= 0 then floor else 0 end" "$1" 2>/dev/null || printf 0)
	case "$_n" in '' | *[!0-9]*) printf 0 ;; *) printf '%s' "$_n" ;; esac
}

# td_count <input> <jq-expression> — the count exactly as the report states it, or the literal
# string "invalid" when it is absent, non-numeric, negative or fractional. Unlike td_num, a
# GATING count must never be silently coerced: the caller turns "invalid" into execution-error
# so a broken report cannot read as clean.
td_count() {
	jq -r "
		($2) as \$v
		| if (\$v | type) == \"number\" and \$v >= 0 and (\$v | floor) == \$v then (\$v | tostring)
		  else \"invalid\" end" "$1" 2>/dev/null || printf 'invalid'
}

# td_flag <input> <jq-expression> — true/false from a boolean field, defaulting to false when
# absent. A NON-boolean present value returns the literal "invalid" so the caller can fail it
# closed rather than reading a malformed flag as a clean false.
td_flag() {
	jq -r "
		($2) as \$v
		| if \$v == null then \"false\"
		  elif (\$v | type) == \"boolean\" then (\$v | tostring)
		  else \"invalid\" end" "$1" 2>/dev/null || printf 'invalid'
}

# td_bad_count <tool> <label> <summary-overrides-json> — emit execution-error for a recognized
# report whose GATING count/flag is malformed. The report claimed to be readable but is not,
# so it fails closed instead of being coerced to a clean 0.
td_bad_count() {
	_tbv=${3:-}; [ -n "$_tbv" ] || _tbv='{}'
	_tbr=${4:-}; [ -n "$_tbr" ] || _tbr='{}'
	log_warn "$1: $2 is malformed; status=execution-error (never coerced to a clean 0)"
	ss_emit_collector "$1" "execution-error" \
		"$(jq -n --arg r "$2" --argjson x "$_tbr" '{status:"execution-error", reason:("malformed " + $r)} + $x')" "$_tbv"
	exit 0
}

# td_write_status <out-path> <tool> <producer> <status> <message> <extra-json> — RUNNER-side
# helper: write a normalized testing-discipline contract carrying an honest NON-evidence
# status. A run that did not happen never produces counters derived from nothing.
td_write_status() {
	_twx=${6:-}; [ -n "$_twx" ] || _twx='{}'
	jq -n --arg t "$2" --arg p "$3" --arg s "$4" --arg m "$5" --argjson x "$_twx" \
		'{tool:$t, producer:$p, status:$s, message:$m} + $x' > "$1"
	log_warn "$3: $5 (status=$4)"
}

# td_pkg_manager — npm | pnpm | yarn, detected from the lockfile in the current directory.
# Defaults to npm (npx) when no lockfile is present. Never forces npx on a pnpm/yarn project.
td_pkg_manager() {
	if [ -f pnpm-lock.yaml ]; then printf 'pnpm'
	elif [ -f yarn.lock ]; then printf 'yarn'
	else printf 'npm'; fi
}

# td_pkg_exec <package-manager> — the "run a binary from node_modules" prefix for that manager.
td_pkg_exec() {
	case "$1" in
		pnpm) printf 'pnpm exec' ;;
		yarn) printf 'yarn' ;;
		*) printf 'npx --no-install' ;;
	esac
}
