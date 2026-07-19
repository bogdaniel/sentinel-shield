#!/bin/sh
# Sentinel Shield collector — php-style. Maps finding count -> style_violations.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="php-style"
INPUT="reports/raw/php-style.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: php-style.sh [--input <path>] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
# Count VIOLATIONS, not scanned files. PHP_CodeSniffer's `.files` is an object keyed by
# EVERY scanned file including clean ones, so `(.files|length)` reported one violation per
# file: a clean run over a 400-file project emitted style_violations=400, and
# style_violations blocks in strict — every PHP project failed permanently, with a count
# that scaled with repo size. The real totals live in `.totals.errors|.warnings`, and
# per-file counts live in `.files[].errors|.warnings`.
N=$(jq '
	(if type=="object" and (.totals? | type) == "object" then
		((.totals.errors // 0) + (.totals.warnings // 0))
	 elif type=="object" and (.files? | type) == "object" then
		([ .files[] | ((.errors // 0) + (.warnings // 0)) ] | add // 0)
	 elif type=="object" and (.files? | type) == "array" then
		# `.files` as an ARRAY has DIFFERENT semantics from the phpcs object above, and the
		# distinction is the whole point of this collector:
		#   phpcs  -> .files is an OBJECT keyed by every SCANNED file, clean ones included,
		#             so entries must never be counted; only their errors/warnings are.
		#   PHP-CS-Fixer -> .files is an ARRAY of files that NEEDED FIXING, so each entry
		#             IS a finding (it carries appliedFixers/diff, not a count).
		# Explicit per-record counts win when present; otherwise a record in a
		# problems-only array counts as one finding.
		([ .files[]
		   | if ((.violations? | type) == "array") then (.violations | length)
		     elif ((.messages? | type) == "array") then (.messages | length)
		     elif (has("errors") or has("warnings")) then ((.errors // 0) + (.warnings // 0))
		     else 1 end ] | add // 0)
	 elif type=="object" and ((.violations? | type) == "number") then .violations
	 elif type=="array" then length
	 else 0 end) // 0 | floor' "$INPUT")
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status:$s, style_violations:$n}')
OV=$(jq -n --argjson n "$N" '{style_violations:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
