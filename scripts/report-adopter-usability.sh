#!/bin/sh
# Sentinel Shield — external-adopter usability scorecard generator (POSIX sh).
#
# Folds one or more adopter-session records (schemas/adopter-session.schema.json)
# into a single, machine-readable SCORECARD (schemas/adopter-scorecard.schema.json)
# plus a human-readable Markdown summary, and yields ONE production-readiness verdict.
#
# It scores the adopter experience against a FIXED set of BLOCKING criteria, each
# derived deterministically from the recorded evidence:
#   * undocumented-prerequisites  — no scenario hit a hidden prereq / interactive prompt.
#   * unexplained-failures        — every failed step carries a reason.
#   * unrecoverable-mutations     — every mutation-bearing failure was recoverable.
#   * errors-have-next-actions    — every failed step carries a safe next action.
#   * bounded-durations           — every mandatory step ran within its budget.
#   * files-attributable          — every generated file is attributable to a redacted root.
#   * recovery-restores-state     — every performed recovery verifiably restored state.
#   * no-secrets-no-abs-paths     — no session leaks a secret shape or absolute local path.
#
# FAIL-CLOSED: missing, empty, malformed, non-conformant, or ambiguous evidence is a
# failure, never a silent pass. An empty evidence set produces NO scorecard and exits 3.
# Every FAILED criterion carries a copy-pasteable reproduction command. The scorecard
# carries NO secrets and NO absolute local paths (a redaction guard refuses to emit one).
#
# Usage:
#   sh scripts/report-adopter-usability.sh --sessions-dir <dir> \
#       [--json-out <path>] [--md-out <path>] [--budget-seconds <n>] \
#       [--skipped <scenario>=<reason> ...]
#   sh scripts/report-adopter-usability.sh --session <a.json> --session <b.json> ...
#
# Exit codes:
#   0  scorecard result=pass
#   1  scorecard result=fail (>=1 blocking criterion failed)
#   2  invalid invocation
#   3  no/invalid evidence (fail-closed: nothing to score, or a session is malformed)
set -eu

DEFAULT_BUDGET=120

SESSIONS_DIR=""
JSON_OUT=""
MD_OUT=""
BUDGET="$DEFAULT_BUDGET"
SESSION_FILES=""   # newline-separated explicit session paths
SKIPPED_JSONL=""   # newline-separated {scenario,reason} JSON objects

usage() {
	cat <<'EOF'
Usage: report-adopter-usability.sh (--sessions-dir <dir> | --session <file> ...)
  --sessions-dir <dir>       Directory of *.session.json adopter-session records.
  --session <file>           An explicit session file (repeatable).
  --json-out <path>          Write the JSON scorecard here (default: stdout only).
  --md-out <path>            Also write a Markdown scorecard here.
  --budget-seconds <n>       Default per-step budget for sessions without their own (default: 120).
  --skipped <name>=<reason>  Record a scenario the suite could not run (repeatable; explicit reason required).
  -h, --help                 Show help.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--sessions-dir) SESSIONS_DIR="${2:?--sessions-dir requires a value}"; shift 2 ;;
		--session) SESSION_FILES="$SESSION_FILES${SESSION_FILES:+
}${2:?--session requires a value}"; shift 2 ;;
		--json-out) JSON_OUT="${2:?--json-out requires a value}"; shift 2 ;;
		--md-out) MD_OUT="${2:?--md-out requires a value}"; shift 2 ;;
		--budget-seconds) BUDGET="${2:?--budget-seconds requires a value}"; shift 2 ;;
		--skipped)
			_kv="${2:?--skipped requires <scenario>=<reason>}"; shift 2
			_sc=${_kv%%=*}; _rs=${_kv#*=}
			if [ -z "$_sc" ] || [ "$_sc" = "$_kv" ] || [ -z "$_rs" ]; then
				printf 'error: --skipped expects <scenario>=<reason> (got %s)\n' "$_kv" >&2; exit 2
			fi
			_obj=$(jq -cn --arg s "$_sc" --arg r "$_rs" '{scenario:$s, reason:$r}')
			SKIPPED_JSONL="$SKIPPED_JSONL${SKIPPED_JSONL:+
}$_obj"
			;;
		-h|--help) usage; exit 0 ;;
		*) printf 'error: unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
	esac
done

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required to produce/validate the scorecard\n' >&2; exit 2; }

# Validate that BUDGET is a positive number.
case "$BUDGET" in
	''|*[!0-9.]*) printf 'error: --budget-seconds must be a positive number (got %s)\n' "$BUDGET" >&2; exit 2 ;;
esac
printf '%s' "$BUDGET" | jq -e '(tonumber) > 0' >/dev/null 2>&1 || {
	printf 'error: --budget-seconds must be > 0 (got %s)\n' "$BUDGET" >&2; exit 2
}

# --- collect candidate session files (explicit + directory glob) -----------------
if [ -n "$SESSIONS_DIR" ]; then
	[ -d "$SESSIONS_DIR" ] || { printf 'FAIL: --sessions-dir %s is not a directory\n' "$SESSIONS_DIR" >&2; exit 3; }
	for _f in "$SESSIONS_DIR"/*.session.json; do
		[ -e "$_f" ] || continue
		SESSION_FILES="$SESSION_FILES${SESSION_FILES:+
}$_f"
	done
fi

[ -n "$SESSION_FILES" ] || { printf 'FAIL: no adopter-session evidence supplied (fail-closed: nothing to score)\n' >&2; exit 3; }

# rau_validate_session <file> — jq-structural conformance to adopter-session.schema.json.
# Fail-closed: missing/empty/non-JSON/non-conformant returns non-zero.
rau_validate_session() {
	[ -s "$1" ] || { printf 'FAIL: session %s is missing or empty\n' "$1" >&2; return 1; }
	jq -e . "$1" >/dev/null 2>&1 || { printf 'FAIL: session %s is not valid JSON\n' "$1" >&2; return 1; }
	jq -e '
		(.schema_version == "1")
		and (.harness | IN("black-box-install","adopter-scenarios"))
		and (.started_at | type == "string" and (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
		and (.finished_at | type == "string" and (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
		and (.documented_environment | type == "array")
		and (.injected_inputs | type == "array")
		and (.unexpected_prompt | type == "boolean")
		and (.result | IN("pass","fail"))
		and (.steps | type == "array")
		and (.steps | all(
			(.step | type == "string" and (length > 0))
			and (.command | type == "string")
			and ((.exit_code == null) or (.exit_code | type == "number"))
			and ((.elapsed_seconds == null) or (.elapsed_seconds | type == "number"))
			and (.status | IN("ok","skip","fail"))
		))
		and ((.scenario == null) or (.scenario | type == "string" and (length > 0)))
		and ((.budget_seconds == null) or (.budget_seconds | type == "number" and (. > 0)))
		and ((.recovery == null) or (
			(.recovery.required | type == "boolean")
			and (.recovery.performed | type == "boolean")
			and (.recovery.restored | type == "boolean")
		))
	' "$1" >/dev/null 2>&1 || { printf 'FAIL: session %s does not conform to adopter-session.schema.json\n' "$1" >&2; return 1; }
	return 0
}

# --- validate every session and assemble the augmented session array -------------
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssscorecard)
trap 'rm -rf "$WORK"' EXIT INT TERM
AUG="$WORK/sessions.jsonl"
: > "$AUG"

_oifs=$IFS
IFS='
'
_count=0
for _sf in $SESSION_FILES; do
	IFS=$_oifs
	[ -n "$_sf" ] || continue
	rau_validate_session "$_sf" || exit 3
	_base=$(basename "$_sf")
	# Augment each session with its redacted source basename and effective budget.
	jq -c --arg source "$_base" --argjson default "$BUDGET" '
		. + {
			_source: $source,
			_scenario: (.scenario // .harness),
			_budget: (.budget_seconds // $default)
		}' "$_sf" >> "$AUG"
	_count=$((_count + 1))
	IFS='
'
done
IFS=$_oifs

[ "$_count" -ge 1 ] || { printf 'FAIL: no conformant sessions to score (fail-closed)\n' >&2; exit 3; }

SESSIONS_JSON=$(jq -s '.' "$AUG")
SKIPPED_JSON=$(printf '%s\n' "$SKIPPED_JSONL" | jq -s 'map(select(type=="object"))')
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Redacted directory label for reproduction commands (never a real absolute path).
SESSIONS_LABEL="<sessions>"

# --- compute the scorecard (single jq pass over all sessions) --------------------
# Every criterion collects redacted offenders; status=fail iff any offender exists.
SCORECARD=$(jq -n \
	--argjson sessions "$SESSIONS_JSON" \
	--argjson skipped "$SKIPPED_JSON" \
	--argjson budgetdefault "$BUDGET" \
	--arg generated_at "$GENERATED_AT" \
	--arg label "$SESSIONS_LABEL" \
	'
	def cap: .[0:50];
	($sessions) as $S
	| ($S | length) as $n
	# --- offender collectors (each yields [{scenario,step?,detail}]) ---
	| ( [ $S[] | ._scenario as $s
	      | (if .unexpected_prompt == true
	         then {scenario:$s, detail:"an engine command tried to prompt interactively (unexpected_prompt=true)"}
	         else empty end),
	        (.steps[] | select(.status=="skip" and ((.message // "")==""))
	         | {scenario:$s, step:.step, detail:"skip without an explicit reason (a skip is not a pass)"})
	    ] | cap ) as $c_prereq
	| ( [ $S[] | ._scenario as $s
	      | .steps[] | select(.status=="fail" and ((.message // "")==""))
	      | {scenario:$s, step:.step, detail:"failed step with no explanatory message"} ] | cap ) as $c_unexpl
	| ( [ $S[] | select((.recovery.required==true) and (.recovery.restored!=true))
	      | {scenario:._scenario, detail:"mutation-bearing failure was not recovered (recovery.required=true, restored!=true)"} ] | cap ) as $c_unrec
	| ( [ $S[] | ._scenario as $s
	      | .steps[] | select(.status=="fail" and ((.next_action // "")==""))
	      | {scenario:$s, step:.step, detail:"failed step with no safe next_action"} ] | cap ) as $c_next
	| ( [ $S[] | ._scenario as $s | ._budget as $b
	      | .steps[] | select(.elapsed_seconds != null and .elapsed_seconds > $b)
	      | {scenario:$s, step:.step, detail:("step ran " + (.elapsed_seconds|tostring) + "s, over the " + ($b|tostring) + "s budget")} ] | cap ) as $c_dur
	| ( [ $S[] | ._scenario as $s
	      | .steps[] | .step as $st | (.generated_files // [])[]
	      | select((startswith("<target>") or startswith("<workspace>") or startswith("<engine-src>") or startswith("~") or startswith("<home>")) | not)
	      | {scenario:$s, step:$st, detail:"a generated file was not attributable to a redacted root (see reproduction to list it)"} ] | cap ) as $c_attr
	| ( [ $S[] | select((.recovery.performed==true) and (.recovery.restored!=true))
	      | {scenario:._scenario, detail:"recovery ran but did not restore expected state (recovery.performed=true, restored!=true)"} ] | cap ) as $c_recov
	| ( [ $S[] | ._scenario as $s | [.. | strings] | .[]
	      | select(test("/Users/|/home/[A-Za-z0-9]|/root/|/private/var|/var/folders|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[=:][ \t]*[A-Za-z0-9/+]"))
	      | {scenario:$s, detail:"session string leaks a secret shape or an absolute local path"} ] | cap ) as $c_secret
	# --- criterion assembler ---
	| def crit($id; $title; $off; $repro):
	    { id:$id, title:$title, blocking:true,
	      status: (if ($off|length)==0 then "pass" else "fail" end),
	      offenders:$off, reproduction:$repro };
	  [
	    crit("undocumented-prerequisites"; "Zero undocumented prerequisites or interactive prompts"; $c_prereq;
	      ("jq -s '"'"'[.[]|select(.unexpected_prompt==true or ([.steps[]|select(.status==\"skip\" and ((.message//\"\")==\"\"))]|length>0))|(.scenario//.harness)]'"'"' " + $label + "/*.session.json")),
	    crit("unexplained-failures"; "Zero unexplained failures"; $c_unexpl;
	      ("jq -s '"'"'[.[]|.scenario as $s|.steps[]|select(.status==\"fail\" and ((.message//\"\")==\"\"))]'"'"' " + $label + "/*.session.json")),
	    crit("unrecoverable-mutations"; "Zero unrecoverable mutations"; $c_unrec;
	      ("jq -s '"'"'[.[]|select((.recovery.required==true) and (.recovery.restored!=true))|(.scenario//.harness)]'"'"' " + $label + "/*.session.json")),
	    crit("errors-have-next-actions"; "All errors include safe next actions"; $c_next;
	      ("jq -s '"'"'[.[]|.steps[]|select(.status==\"fail\" and ((.next_action//\"\")==\"\"))]'"'"' " + $label + "/*.session.json")),
	    crit("bounded-durations"; "All mandatory flows within bounded durations"; $c_dur;
	      ("jq -s --argjson b " + ($budgetdefault|tostring) + " '"'"'[.[]|(.budget_seconds // $b) as $bs|.steps[]|select(.elapsed_seconds!=null and .elapsed_seconds>$bs)]'"'"' " + $label + "/*.session.json")),
	    crit("files-attributable"; "All generated files attributable"; $c_attr;
	      ("jq -s '"'"'[.[]|.steps[]|(.generated_files//[])[]|select((startswith(\"<target>\") or startswith(\"<workspace>\") or startswith(\"<engine-src>\") or startswith(\"~\"))|not)]'"'"' " + $label + "/*.session.json")),
	    crit("recovery-restores-state"; "All recovery operations restore expected state"; $c_recov;
	      ("jq -s '"'"'[.[]|select((.recovery.performed==true) and (.recovery.restored!=true))|(.scenario//.harness)]'"'"' " + $label + "/*.session.json")),
	    crit("no-secrets-no-abs-paths"; "No secrets and no absolute local paths recorded"; $c_secret;
	      ("jq -s '"'"'[.[]|[..|strings]|.[]|select(test(\"/Users/|/home/|/root/|/private/var|/var/folders\"))]'"'"' " + $label + "/*.session.json"))
	  ] as $criteria
	| ( [ $S[] | {
	        scenario: ._scenario,
	        harness: .harness,
	        source: ._source,
	        result: .result,
	        steps_total: (.steps|length),
	        steps_failed: ([.steps[]|select(.status=="fail")]|length),
	        steps_skipped: ([.steps[]|select(.status=="skip")]|length),
	        budget_seconds: ._budget
	      } + (if .recovery == null then {} else {recovery: .recovery} end) ] ) as $scenarios
	| ([ $criteria[] | select(.status=="pass") ] | length) as $cpass
	| ([ $criteria[] | select(.status=="fail") ] | length) as $cfail
	| {
	    schema_version: "1",
	    generator: "report-adopter-usability",
	    generated_at: $generated_at,
	    budget_seconds_default: $budgetdefault,
	    sessions_evaluated: $n,
	    scenarios: $scenarios,
	    skipped_scenarios: $skipped,
	    criteria: $criteria,
	    totals: {
	      scenarios: $n,
	      sessions_passed: ([ $S[] | select(.result=="pass") ] | length),
	      sessions_failed: ([ $S[] | select(.result=="fail") ] | length),
	      criteria_passed: $cpass,
	      criteria_failed: $cfail
	    },
	    result: (if ($n >= 1
	                 and $cfail == 0
	                 and ([ $S[] | select(.result=="fail") ] | length) == 0)
	             then "pass" else "fail" end)
	  }
	')

# --- redaction guard: refuse to emit a scorecard that leaks a secret/abs path ----
# Scan every string EXCEPT the criteria[].reproduction filters, which legitimately
# embed path-root tokens as jq regex alternations (they are documentation, not evidence).
if printf '%s' "$SCORECARD" | jq -e '(del(.criteria[].reproduction)) | [.. | strings] | any(test("/Users/|/home/[A-Za-z0-9]|/root/|/private/var|/var/folders|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[=:][ \t]*[A-Za-z0-9/+]"))' >/dev/null 2>&1; then
	printf 'FAIL: refusing to emit scorecard — it would leak a secret shape or absolute local path\n' >&2
	exit 3
fi

# --- write JSON scorecard --------------------------------------------------------
if [ -n "$JSON_OUT" ]; then
	printf '%s\n' "$SCORECARD" > "$JSON_OUT"
fi

# --- write Markdown scorecard ----------------------------------------------------
if [ -n "$MD_OUT" ]; then
	{
		printf '# External-adopter usability scorecard\n\n'
		# shellcheck disable=SC2016 # backticks below are literal Markdown, not a subshell
		printf -- '- Generated: `%s`\n' "$(printf '%s' "$SCORECARD" | jq -r '.generated_at')"
		printf -- '- Sessions evaluated: **%s**\n' "$(printf '%s' "$SCORECARD" | jq -r '.sessions_evaluated')"
		printf -- '- Overall result: **%s**\n\n' "$(printf '%s' "$SCORECARD" | jq -r '.result' | tr '[:lower:]' '[:upper:]')"
		printf '## Blocking criteria\n\n'
		printf '| Criterion | Status | Offenders |\n| --- | --- | --- |\n'
		printf '%s' "$SCORECARD" | jq -r '.criteria[] | "| " + .title + " | " + (.status|ascii_upcase) + " | " + ((.offenders|length)|tostring) + " |"'
		printf '\n## Scenarios\n\n'
		printf '| Scenario | Result | Steps | Failed | Skipped | Budget (s) |\n| --- | --- | --- | --- | --- | --- |\n'
		printf '%s' "$SCORECARD" | jq -r '.scenarios[] | "| " + .scenario + " | " + (.result|ascii_upcase) + " | " + (.steps_total|tostring) + " | " + (.steps_failed|tostring) + " | " + ((.steps_skipped // 0)|tostring) + " | " + (.budget_seconds|tostring) + " |"'
		_nskip=$(printf '%s' "$SCORECARD" | jq -r '.skipped_scenarios | length')
		if [ "$_nskip" -gt 0 ]; then
			printf '\n## Skipped scenarios (explicitly reasoned — not a pass)\n\n'
			printf '| Scenario | Reason |\n| --- | --- |\n'
			printf '%s' "$SCORECARD" | jq -r '.skipped_scenarios[] | "| " + .scenario + " | " + .reason + " |"'
		fi
		# Reproduction command for every FAILED criterion.
		if printf '%s' "$SCORECARD" | jq -e '[.criteria[]|select(.status=="fail")]|length>0' >/dev/null 2>&1; then
			printf '\n## Reproduction (failed criteria)\n\n'
			printf '%s' "$SCORECARD" | jq -r '.criteria[] | select(.status=="fail") | "### " + .title + "\n\n```sh\n" + .reproduction + "\n```\n"'
		fi
	} > "$MD_OUT"
fi

# --- echo JSON scorecard to stdout + human summary to stderr ---------------------
printf '%s\n' "$SCORECARD"
RESULT=$(printf '%s' "$SCORECARD" | jq -r '.result')
CFAIL=$(printf '%s' "$SCORECARD" | jq -r '.totals.criteria_failed')
printf '\nreport-adopter-usability: result=%s (%s blocking criterion/criteria failed across %s session(s))\n' \
	"$RESULT" "$CFAIL" "$_count" >&2

[ "$RESULT" = pass ] && exit 0
exit 1
