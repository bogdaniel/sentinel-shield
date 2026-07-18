#!/bin/sh
# Sentinel Shield runner — custom architecture tests (generic producer, v2.1.0).
#
# Runs the PROJECT's own architecture-test command (Pest arch tests, PHPUnit arch suites,
# jest/vitest boundary tests, a bespoke script — anything) and normalizes its result to the
# architecture raw contract. This is the escape hatch that keeps architecture governance
# producer-agnostic: any tool that can emit the contract can feed the same gate.
#
# Command source (first wins):
#   --command
#   $<env var>                                  (default: SENTINEL_SHIELD_ARCH_TEST_CMD)
#   architecture.tools.architecture_tests.command in the architecture policy
#
# Result contract:
#   command absent                    -> unavailable (never a faked pass)
#   command wrote <output> as JSON    -> preserved (normalized contract expected)
#   command printed JSON on stdout    -> that JSON is the report
#   command failed with no JSON       -> execution-error
#   command succeeded with no JSON    -> pass, violations 0 (exit code is the evidence)
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/architecture-evidence.sh
. "$SCRIPT_DIR/../lib/architecture-evidence.sh"
# shellcheck source=scripts/lib/architecture-policy.sh
. "$SCRIPT_DIR/../lib/architecture-policy.sh"

OUT="reports/raw/architecture-tests.json"
CMD=""
ENV_VAR="SENTINEL_SHIELD_ARCH_TEST_CMD"
PRODUCER="architecture-tests"
POLICY=".sentinel-shield/architecture-policy.yaml"

usage() {
	cat <<'EOF'
Usage: architecture-tests.sh [--output <path>] [--command <cmd>] [--env-var <NAME>]
                             [--producer <name>] [--policy <path>] [<output>]
Run the project's architecture-test command and normalize the result.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--command) CMD="${2:?--command requires a value}"; shift 2 ;;
		--env-var) ENV_VAR="${2:?--env-var requires a value}"; shift 2 ;;
		--producer) PRODUCER="${2:?--producer requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		--*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
		*) OUT="$1"; shift ;;   # positional output path (back-compat with v0.1.14)
	esac
done

ensure_dir "$(dirname -- "$OUT")"

ap_load "$POLICY"
if ap_present; then
	if ! ap_enabled; then arch_write_status "$OUT" "$PRODUCER" disabled "architecture governance disabled in $POLICY"; exit 0; fi
	if ! ap_tool_enabled architecture_tests false; then arch_write_status "$OUT" "$PRODUCER" disabled "architecture_tests disabled in $POLICY"; exit 0; fi
fi

# env var (indirect read) then policy. The NAME is validated as a POSIX shell identifier before
# the indirect expansion, so a crafted --env-var value can never smuggle shell code into eval.
if [ -z "$CMD" ]; then
	case "$ENV_VAR" in
		[A-Za-z_][A-Za-z0-9_]*) CMD=$(eval "printf '%s' \"\${$ENV_VAR:-}\"") ;;
		*)
			log_error "invalid --env-var name '$ENV_VAR' (expected a POSIX shell identifier)"
			exit 2 ;;
	esac
fi
if [ -z "$CMD" ] && ap_present; then
	CMD=$(ap_get architecture.tools.architecture_tests.command)
fi
if [ -z "$CMD" ]; then
	arch_write_status "$OUT" "$PRODUCER" unavailable "no architecture-test command (\$$ENV_VAR unset and no architecture.tools.architecture_tests.command)"
	exit 0
fi

STDOUT_LOG=$(mktemp 2>/dev/null || mktemp -t ss-archtests)
RC=0
# Remove any STALE report first: a leftover file from a previous run (possibly an honest
# "unavailable") must never be mistaken for this run's evidence.
rm -f "$OUT"
# Only STDOUT is captured (it may carry the JSON contract); stderr passes through to the caller
# so a failing architecture suite is debuggable instead of silently swallowed.
sh -c "$CMD" > "$STDOUT_LOG" || RC=$?

# 1) the command wrote the report file itself (preferred: full contract with failures[]).
if [ -s "$OUT" ] && jq -e . "$OUT" >/dev/null 2>&1; then
	rm -f "$STDOUT_LOG"
	log_info "$PRODUCER: report produced by project command -> $OUT"
	exit 0
fi

# 2) the command printed the contract on stdout.
if [ -s "$STDOUT_LOG" ] && jq -e . "$STDOUT_LOG" >/dev/null 2>&1; then
	jq --arg p "$PRODUCER" 'if type=="object" then . + {producer:$p} else . end' "$STDOUT_LOG" > "$OUT"
	rm -f "$STDOUT_LOG"
	log_info "$PRODUCER: normalized stdout JSON -> $OUT"
	exit 0
fi
# Neither path produced JSON: surface whatever the command printed before discarding it, so the
# operator can see WHY (a stack trace, a usage error, a plain-text test summary).
if [ -s "$STDOUT_LOG" ]; then
	log_warn "$PRODUCER: command produced no JSON contract; its output was:"
	cat "$STDOUT_LOG" >&2
fi
rm -f "$STDOUT_LOG"

# 3) no JSON at all: the EXIT CODE is the only evidence. Success is an honest clean run;
#    failure is an execution-error, never "violations: 1" invented from an unknown failure.
if [ "$RC" -eq 0 ]; then
	jq -n --arg p "$PRODUCER" \
		'{tool:"architecture", producer:$p, status:"pass", violations:0, rule_count:0, context_count:0, failures:[],
		  message:"command exited 0 and emitted no JSON; exit code is the only evidence"}' > "$OUT"
	log_info "$PRODUCER: command exited 0 with no JSON -> pass (violations=0)"
else
	arch_write_status "$OUT" "$PRODUCER" execution-error "architecture-test command failed (exit $RC) without emitting the JSON contract"
fi
exit 0
