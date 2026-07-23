#!/bin/sh
# Sentinel Shield collector — php-syntax. Maps finding count -> php_syntax_errors.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="php-syntax"
INPUT="reports/raw/php-syntax.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: php-syntax.sh [--input <path>] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
# `.files` is the list of files LINTED, not the list that failed. Counting its length
# reported one syntax error per scanned file, and php_syntax_errors blocks from BASELINE
# up — a clean `php -l` sweep failed the gate for every project. Only an explicit
# `.errors` count, an array of error records, or per-file error entries are errors.
N=$(jq '
	(if type=="object" and ((.errors? | type) == "number") then .errors
	 elif type=="object" and ((.errors? | type) == "array") then (.errors | length)
	 elif type=="array" then length
	 elif type=="object" and ((.files? | type) == "array") then (.files | length)
	 elif type=="object" and ((.files? | type) == "object") then
		([ .files[] | if type=="object" then ((.errors // 0)
			| if type=="number" then . elif type=="array" then length else 0 end) else 0 end ] | add // 0)
	 else 0 end) // 0 | floor' "$INPUT")
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status:$s, php_syntax_errors:$n}')
OV=$(jq -n --argjson n "$N" '{php_syntax_errors:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
