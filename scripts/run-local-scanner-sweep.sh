#!/bin/sh
# Sentinel Shield — local scanner SWEEP (NON-AUTHORITATIVE convenience tool).
#
# Runs whatever security scanners happen to be installed GLOBALLY, opportunistically,
# so a developer can get a quick local read. It is deliberately NOT part of the gate:
#   - it MAY SKIP any tool that is not installed (a SKIP is NOT a pass);
#   - it does NOT produce normalized gate evidence (no reports/security-summary.json);
#   - it does NOT replace scripts/run-local-pipeline.sh (the authoritative local run).
# Treat its output strictly as a hint. A clean sweep is NEVER proof that a project
# passes the gate — only the authoritative pipeline + enforce-gates can establish that.
#
# Usage: run-local-scanner-sweep.sh [--target <dir>] [--strict-exit] [--format text]
#   --target <dir>   Directory to scan (default: .). A bare positional path is also
#                    accepted for backward compatibility with run-local-security.sh.
#   --strict-exit    Exit nonzero (1) when any installed scanner reports findings/errors.
#                    Default: always exit 0 (convenience mode never blocks the shell).
#   --format text    Output format. Only 'text' is supported.
#
# Exit codes:
#   0 = sweep ran (default mode; also --strict-exit with no findings)
#   1 = --strict-exit set AND an installed scanner reported findings/errors
#   2 = invalid invocation / bad argument
set -eu

# Resolve the engine's bundled rules from THIS script's location (the pinned ENGINE
# checkout), captured BEFORE any cwd switch so the target project's ./semgrep cannot
# shadow them.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENGINE_SEMGREP="$SCRIPT_DIR/../semgrep/app"

TARGET="."
STRICT=0
FORMAT="text"
while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--strict-exit) STRICT=1; shift ;;
		--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
		-h | --help)
			printf 'Usage: run-local-scanner-sweep.sh [--target <dir>] [--strict-exit] [--format text]\n'
			exit 0 ;;
		--*) printf '%s\n' "[sweep][error] unknown argument: $1" >&2; exit 2 ;;
		*) TARGET="$1"; shift ;;
	esac
done

case "$FORMAT" in
	text) ;;
	*) printf '%s\n' "[sweep][error] unsupported --format '$FORMAT' (only 'text' supported)" >&2; exit 2 ;;
esac

[ -d "$TARGET" ] || { printf '%s\n' "[sweep][error] target not a directory: $TARGET" >&2; exit 2; }
cd "$TARGET"

OVERALL=0

have() { command -v "$1" >/dev/null 2>&1; }

# run_tool — opportunistically run an installed scanner; SKIP (not fail) if absent.
run_tool() {
	label="$1"
	bin="$2"
	shift 2
	if have "$bin"; then
		echo ">> $label ($bin)"
		if "$bin" "$@"; then
			echo "   $label: ok"
		else
			echo "   $label: findings or error (review output)" >&2
			OVERALL=1
		fi
	else
		echo ">> $label: '$bin' not installed, skipping (NOT a pass)"
	fi
}

echo "=================================================================="
echo "Sentinel Shield — LOCAL SCANNER SWEEP (NON-AUTHORITATIVE)"
echo "Target: $TARGET"
echo "This convenience sweep runs only globally-installed scanners and MAY"
echo "SKIP any that are missing. It does NOT produce gate evidence and does"
echo "NOT replace run-local-pipeline.sh. A clean sweep is NOT proof of"
echo "passing the gate — it is a developer hint only."
echo "=================================================================="

# Secret scanning (always relevant).
run_tool "Gitleaks (secrets)" gitleaks detect --no-banner --redact

# SAST.
if have semgrep; then
	echo ">> Semgrep"
	# Prefer the engine's bundled rules (resolved from SCRIPT_DIR, NOT the target's
	# ./semgrep); fall back to the registry only when the bundle is unavailable.
	if [ -d "$ENGINE_SEMGREP" ]; then
		semgrep --error --config "$ENGINE_SEMGREP" || OVERALL=1
	else
		semgrep --error --config "p/owasp-top-ten" || OVERALL=1
	fi
else
	echo ">> Semgrep: not installed, skipping (NOT a pass)"
fi

# Vulnerability / IaC scanning.
run_tool "Trivy (filesystem)" trivy fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL --ignore-unfixed .

# Dependency vulnerability scanning.
run_tool "OSV-Scanner" osv-scanner --recursive .

# Language-native audits.
if [ -f composer.json ] && have composer; then
	echo ">> composer audit"
	composer audit --locked || OVERALL=1
fi

if [ -f package.json ] && have npm; then
	echo ">> npm audit"
	npm audit --audit-level=high || OVERALL=1
fi

echo "===="
echo "Local scanner sweep complete (NON-authoritative — not gate evidence)."
if [ "$OVERALL" -eq 0 ]; then
	echo "Sweep: no blocking findings from the installed tools (missing tools were skipped)."
else
	echo "Sweep: findings/errors reported by installed scanners. Review output above." >&2
	if [ "$STRICT" -eq 1 ]; then
		exit 1
	fi
fi

# Default mode is intentionally tolerant: do not hard-fail the developer shell.
# Authoritative blocking lives in run-local-pipeline.sh + enforce-gates / CI.
exit 0
