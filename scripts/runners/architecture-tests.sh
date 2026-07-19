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
#   command succeeded with no JSON    -> execution-error (an exit code is NOT evidence, v2.0.1)
#   command from the scanned project.s policy -> refused unless --allow-project-command
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
CMD_SOURCE=""          # operator | project — decides whether CMD may execute (v2.0.1)
ALLOW_PROJECT_CMD=0    # --allow-project-command: explicit operator consent, off by default
ENV_VAR="SENTINEL_SHIELD_ARCH_TEST_CMD"
PRODUCER="architecture-tests"
POLICY=".sentinel-shield/architecture-policy.yaml"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: architecture-tests.sh [--output <path>] [--command <cmd>] [--env-var <NAME>]
                             [--producer <name>] [--policy <path>]
                             [--allow-project-command] [<output>]
Run the project's architecture-test command and normalize the result.

SECURITY (v2.0.1): a command taken from the SCANNED PROJECT's architecture-policy.yaml is
NOT executed by default — that file is attacker-controlled input to a security gate. Pass
--allow-project-command to opt in explicitly, or supply the command via --command / the
$SENTINEL_SHIELD_ARCH_TEST_CMD env var, both of which are operator-controlled.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--command) CMD="${2:?--command requires a value}"; CMD_SOURCE="operator"; shift 2 ;;
		--allow-project-command) ALLOW_PROJECT_CMD=1; shift ;;
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
		[A-Za-z_][A-Za-z0-9_]*)
			CMD=$(eval "printf '%s' \"\${$ENV_VAR:-}\"")
			[ -n "$CMD" ] && CMD_SOURCE="operator" ;;
		*)
			log_error "invalid --env-var name '$ENV_VAR' (expected a POSIX shell identifier)"
			exit 2 ;;
	esac
fi
if [ -z "$CMD" ] && ap_present; then
	CMD=$(ap_get architecture.tools.architecture_tests.command)
	[ -n "$CMD" ] && CMD_SOURCE="project"
fi

# REFUSE to execute a scanned-repo-supplied shell string (v2.0.1 security hotfix).
#
# `sh -c "$CMD"` below runs this verbatim. Sourced from the scanned project's
# architecture-policy.yaml, that is arbitrary code execution in the gate runner, granted to
# whoever can open a pull request — proven with `command: "id > /tmp/proof; true"`. Note the
# contrast this fix removes: the --env-var NAME was already validated against eval injection
# a few lines above, while the command VALUE went straight to a shell.
#
# Operator-supplied commands (--command, $SENTINEL_SHIELD_ARCH_TEST_CMD) are unchanged: the
# person who wrote the CI workflow already controls the runner. Only the untrusted source is
# gated, behind explicit --allow-project-command consent.
if [ "$CMD_SOURCE" = "project" ] && [ "$ALLOW_PROJECT_CMD" -ne 1 ]; then
	arch_write_status "$OUT" "$PRODUCER" execution-error \
		"unsupported_project_command: refusing to execute an architecture-test command supplied by the scanned project's $POLICY. Pass --allow-project-command to opt in, or set the command via --command / \$$ENV_VAR (operator-controlled)."
	exit 0
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

# 3) no JSON at all. An exit code is NOT architecture evidence (v2.0.1 hotfix).
#
# This branch used to synthesise {status:"pass", violations:0} from `exit 0`, so any
# command that merely succeeds — `true`, a no-op script, a suite that silently collected
# zero rules — manufactured a clean architecture report. That single file then satisfied
# BOTH architecture_violations and missing_architecture_evidence, defeating the evidence
# chain the builder works to protect. "It exited 0" and "it checked the architecture and
# found nothing wrong" are different claims and only the second is evidence.
if [ "$RC" -eq 0 ]; then
	arch_write_status "$OUT" "$PRODUCER" execution-error \
		"architecture-test command exited 0 but emitted no JSON contract; an exit code is not architecture evidence (write the normalized contract to \$SENTINEL_SHIELD_ARCH_OUT or stdout)"
else
	arch_write_status "$OUT" "$PRODUCER" execution-error "architecture-test command failed (exit $RC) without emitting the JSON contract"
fi
exit 0
