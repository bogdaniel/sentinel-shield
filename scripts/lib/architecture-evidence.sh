#!/bin/sh
# Sentinel Shield — architecture evidence helpers (POSIX sh, source; do not execute).
#
# Shared by every architecture COLLECTOR (deptrac, php-arkitect, dependency-cruiser,
# eslint-boundaries, js-architecture-tests, architecture-tests) so the normalized
# architecture raw contract is implemented ONCE:
#
#   { "tool":"architecture", "status":"pass|findings|unavailable|not-configured|
#      execution-error|disabled|not-applicable",
#     "violations":0, "rule_count":12, "context_count":4, "failures":[] }
#
# Rules (docs/architecture-governance.md, docs/raw-report-contract.md):
#   pass       + violations 0   -> the suite ran, no boundary violations
#   findings   + violations > 0 -> the suite ran, boundary violations found
#   unavailable / not-configured / execution-error / disabled / not-applicable are
#              PRESERVED verbatim (never collapsed into a clean pass)
#   unknown status              -> fail closed as execution-error
#   missing/empty raw report    -> unavailable (ss_collector_guard)
#   invalid JSON                -> exit 2 (ss_collector_guard)
#
# Requires scripts/lib/sentinel-shield-common.sh already sourced (ss_emit_collector).

# arch_passthrough_status <tool> <input> — when the raw report carries a NON-evidence status,
# emit the collector object with that status preserved (zero counters, no evidence credit)
# and exit 0. Unknown/unexpected status fails closed as execution-error. Returns 0 (without
# emitting) when the status is empty/pass/findings so the caller can count violations.
arch_passthrough_status() {
	# A non-object top-level document (array/string/number) cannot carry a status: jq errors,
	# the status reads empty, and the caller's shape check then fails it closed.
	_as=$(jq -r 'if type=="object" then (.status // "") else "" end' "$2" 2>/dev/null || printf '')
	case "$_as" in
		'' | pass | findings | fail | warn) return 0 ;;
		unavailable | not-configured | execution-error | disabled | not-applicable)
			ss_emit_collector "$1" "$_as" "$(jq -n --arg s "$_as" '{status:$s, violations:0}')" '{}'
			exit 0 ;;
		*)
			ss_emit_collector "$1" "execution-error" \
				'{"status":"execution-error","violations":0,"reason":"unknown architecture status"}' '{}'
			exit 0 ;;
	esac
}

# arch_emit <tool> <violations> <rule_count> <context_count> — emit an EVIDENCE-bearing
# collector object. Status is derived from the violation count; the tool counts as one valid
# architecture producer (architecture_tool_count = 1) because it ran.
#
# Status vocabulary (two distinct surfaces — do not conflate them):
#   RAW REPORT (what a producer writes):  pass | findings | unavailable | ...
#   COLLECTOR  (what this emits):         pass | fail      | unavailable | ...
# `fail` is the long-standing collector vocabulary shared by every other finding-mapping
# collector (gitleaks, semgrep, phpstan, deptrac since v0.1.14, …) and is asserted by the
# v025-live self-test. The builder maps fail/findings identically, so this is naming only.
#
# A malformed or negative COUNT is not evidence: the report claimed to be readable but is not,
# so it fails closed as execution-error rather than being coerced to a clean 0 (which would
# also wrongly credit architecture_tool_count).
arch_emit() {
	_at=$1; _av=$2; _ar=${3:-0}; _ac=${4:-0}
	case "$_av" in
		'' | *[!0-9]*)
			log_warn "$_at: violation count '$_av' is not a non-negative integer; status=execution-error (never coerced to a clean 0)"
			ss_emit_collector "$_at" "execution-error" \
				'{"status":"execution-error","violations":0,"reason":"invalid violation count"}' '{}'
			return 0 ;;
	esac
	case "$_ar" in '' | *[!0-9]*) _ar=0 ;; esac
	case "$_ac" in '' | *[!0-9]*) _ac=0 ;; esac
	if [ "$_av" -gt 0 ]; then _ast="fail"; else _ast="pass"; fi
	_aov=$(jq -n --argjson v "$_av" --argjson r "$_ar" --argjson c "$_ac" \
		'{architecture_violations:$v, architecture_rule_count:$r, architecture_context_count:$c, architecture_tool_count:1}')
	_arep=$(jq -n --arg s "$_ast" --argjson v "$_av" --argjson r "$_ar" --argjson c "$_ac" \
		'{status:$s, violations:$v, rule_count:$r, context_count:$c}')
	ss_emit_collector "$_at" "$_ast" "$_arep" "$_aov"
}

# arch_write_status <out-path> <producer> <status> <message> — RUNNER-side helper: write the
# normalized architecture contract carrying an honest NON-evidence status. A run that did not
# happen never produces a violations count derived from nothing.
arch_write_status() {
	jq -n --arg p "$2" --arg s "$3" --arg m "$4" \
		'{tool:"architecture", producer:$p, status:$s, violations:0, failures:[], message:$m}' > "$1"
	log_warn "$2: $4 (status=$3)"
}

# arch_pkg_manager — npm | pnpm | yarn, detected from the lockfile in the current directory.
# Defaults to npm (npx) when no lockfile is present. Never forces npx on a pnpm/yarn project.
arch_pkg_manager() {
	if [ -f pnpm-lock.yaml ]; then printf 'pnpm'
	elif [ -f yarn.lock ]; then printf 'yarn'
	else printf 'npm'; fi
}

# arch_pkg_exec <package-manager> — the "run a binary from node_modules" prefix for that
# manager (`npx --no-install`, `pnpm exec`, `yarn`).
arch_pkg_exec() {
	case "$1" in
		pnpm) printf 'pnpm exec' ;;
		yarn) printf 'yarn' ;;
		*) printf 'npx --no-install' ;;
	esac
}

# arch_count <input> <jq-expression> — the VIOLATION count exactly as the report states it, or
# the literal string "invalid" when it is absent, non-numeric, negative or fractional. Unlike
# arch_num (informational metadata, safe to default to 0), a violation count must never be
# silently coerced: arch_emit turns "invalid" into execution-error so a broken report cannot
# read as clean.
arch_count() {
	jq -r "
		($2) as \$v
		| if (\$v | type) == \"number\" and \$v >= 0 and (\$v | floor) == \$v then (\$v | tostring)
		  else \"invalid\" end" "$1" 2>/dev/null || printf 'invalid'
}

# arch_num <input> <jq-expression> — non-negative integer from the raw report, or 0.
arch_num() {
	_n=$(jq "($2) | if type==\"number\" and . >= 0 then floor else 0 end" "$1" 2>/dev/null || printf 0)
	case "$_n" in '' | *[!0-9]*) printf 0 ;; *) printf '%s' "$_n" ;; esac
}
