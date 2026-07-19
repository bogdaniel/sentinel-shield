#!/bin/sh
# Sentinel Shield collector — codeql. Maps vulnerability severities to vuln buckets
# (critical/high/medium_vulnerabilities). Accepts native format or a normalized
# {critical,high,medium} object. Severity parsing is best-effort; see docs.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="codeql"
INPUT="reports/raw/codeql.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: codeql.sh [--input <path>] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
# Resolve each result's effective SARIF level, then map security-severity to a bucket.
#
# Two defects fixed. (1) critical_vulnerabilities was hardcoded 0, so CodeQL alone could
# never trip the critical gate no matter what it found. (2) Only the per-result `.level`
# was read; CodeQL commonly OMITS it and carries the level in the rule's
# `defaultConfiguration.level` instead, so real error-level findings defaulted to
# "warning" -> medium_vulnerabilities, which does not block in baseline.
#
# CodeQL's own `security-severity` tag (a CVSS-style 0-10 score) is authoritative when
# present: >= 9.0 is critical, >= 7.0 high, otherwise medium. Absent that, the effective
# level decides: error -> high, warning/note -> medium.
OV=$(jq '
	if has("runs") then
		[ .runs[]? as $r
		  | ($r.tool.driver.rules // []) as $rules
		  | $r.results[]?
		  | . as $res
		  # `first(... // empty)` — a result whose ruleId matches NO rule must still be
		  # counted. A bare `$rules[] | select(...)` yields EMPTY when nothing matches,
		  # which silently drops the entire result from the pipeline.
		  | (first($rules[] | select(.id == ($res.ruleId // ""))) // {}) as $rule
		  | (($res.level // $rule.defaultConfiguration.level // "warning")) as $lvl
		  | (($rule.properties["security-severity"] // "") | tostring) as $sev
		  | if ($sev | test("^[0-9]")) then
				(($sev | tonumber) as $n
				 | if $n >= 9 then "critical" elif $n >= 7 then "high" else "medium" end)
			elif $lvl == "error" then "high"
			else "medium" end ] as $b
		| {critical_vulnerabilities: ([$b[]|select(.=="critical")]|length),
		   high_vulnerabilities:     ([$b[]|select(.=="high")]|length),
		   medium_vulnerabilities:   ([$b[]|select(.=="medium")]|length)}
	else
		{critical_vulnerabilities:(.critical//0), high_vulnerabilities:(.high//0), medium_vulnerabilities:(.medium//0)}
	end' "$INPUT")
TOTAL=$(printf '%s' "$OV" | jq '[.[]] | add // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" '{status:$s, critical:.critical_vulnerabilities, high:.high_vulnerabilities, medium:.medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
