#!/bin/sh
# Sentinel Shield collector — Rector (automated refactoring / upgrade suggestions).
#
# ADVISORY BY DESIGN: this collector reports Rector's suggestion count in tool_report but
# contributes ZERO to every gated counter. Rector proposes refactors and framework
# upgrades; a large count is normal mid-upgrade and is NOT a defect signal. Mapping it to
# `style_violations` (as pint/php-cs-fixer do) would let a routine Laravel upgrade path
# fail a strict style gate — a false positive that punishes adopters for using the tool.
# Every profile wires rector as `missing_behavior: warn`, matching that advisory intent.
#
# What this DOES enforce: the report must exist and be parseable. Before this collector
# existed, rector.json was written by the runner and then read by nothing at all, so its
# contents were invisible to the summary entirely.
#
# Upgrade path: if a project wants Rector gated, add a dedicated counter for refactoring
# debt rather than folding it into the style channel — channel separation is deliberate.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="rector"
INPUT="reports/raw/rector.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: rector.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a Rector JSON report.
Advisory: reports suggestion counts, contributes 0 to all gated counters.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--input) INPUT="${2:?--input requires a value}"; shift 2 ;;
		--tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
	esac
done

ss_collector_guard "$TOOL" "$INPUT"

# Rector's native shape is {"totals":{"changed_files":N},"file_diffs":[...]}. Accept either,
# and a bare {} (nothing to suggest). `// 0` is safe here: these are numbers, never false.
N=$(jq '((.totals.changed_files // (.file_diffs | length)? // 0)) | floor' "$INPUT" 2>/dev/null || printf 'x')
case "$N" in '' | *[!0-9]*)
	log_error "$TOOL: could not read a suggestion count from '$INPUT'"
	exit 2 ;;
esac

# Status is `pass` whenever the report parses: suggestions are not failures.
REPORT=$(jq -n --argjson n "$N" '{status:"pass", suggested_changes:$n, gated:false}')
ss_emit_collector "$TOOL" "pass" "$REPORT" '{}'
