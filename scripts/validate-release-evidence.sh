#!/bin/sh
# Sentinel Shield — validate a release-evidence file (fail-closed).
#
# Structurally validates evidence/releases/<version>.json against
# schemas/release-evidence.schema.json using jq (ajv may be absent), and
# optionally GATES the file against a release stage's evidence needs.
#
# The gate is fail-closed by construction: an honest "no proof yet" file
# (empty consumer_runs[], required_evidence all false) is schema-VALID but
# fails every --require-stage check. A required_evidence flag only counts when
# a successful, artifact-verified consumer_run with a non-empty workflow_run_id
# backs it. This script never fabricates run IDs and never relaxes a stage.
#
# Usage: validate-release-evidence.sh [--file <path>] [--require-stage <alpha|beta|rc|ga>]
#   --file <path>           Evidence file (default: evidence/releases/v2.0.0.json).
#   --require-stage <stage> Also assert the file meets <stage>'s evidence needs.
#
# Exit:
#   0 = success (schema-valid; and, if --require-stage given, the stage is met)
#   1 = stage gate failure (schema-valid but evidence does not meet --require-stage)
#   2 = invalid config/input (malformed JSON, schema violation, bad invocation, missing jq)
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# usage — print CLI usage/help to stdout.
usage() {
	printf 'Usage: validate-release-evidence.sh [--file <path>] [--require-stage <alpha|beta|rc|ga>]\n'
}

FILE="$REPO_ROOT/evidence/releases/v2.0.0.json"
REQUIRE_STAGE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--file) FILE="${2:?--file requires a value}"; shift 2 ;;
		--require-stage) REQUIRE_STAGE="${2:?--require-stage requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

case "$REQUIRE_STAGE" in
	"" | alpha | beta | rc | ga) ;;
	*) log_error "--require-stage must be one of: alpha beta rc ga"; exit 2 ;;
esac

command_exists jq || { log_error "jq is required for JSON parsing but was not found. Install jq."; exit 2; }

[ -f "$FILE" ] || { log_error "evidence file not found: $FILE"; exit 2; }
jq -e . "$FILE" >/dev/null 2>&1 || { log_error "evidence file is not valid JSON: $FILE"; exit 2; }

# --- structural validation (schema mirror) ----------------------------------
# Emits one line per violation; any output => schema-invalid => exit 2.
ERRORS=$(jq -r '
	def nestr: (type == "string") and (length > 0);
	def isbool: type == "boolean";
	def stacks: ["laravel","symfony","php_library","node_react","combined_profile","bootstrap_apply","rollback_npm","rollback_pnpm","rollback_yarn"];
	def tmodes: ["config-only","require-existing","bootstrap-tools"];
	def results: ["success","failure","cancelled","skipped"];
	def runkeys: ["stack","repository","commit","profile","tool_mode","workflow_run_id","result","artifacts_verified"];
	. as $doc
	| [
		(if ($doc|type) == "object" then empty else "root: not an object" end),
		(if ($doc|has("version")) and ($doc.version|nestr) then empty else "version: missing or not a non-empty string" end),
		(if ($doc|has("stage")) and (["alpha","beta","rc","ga"]|index($doc.stage // null)) then empty else "stage: missing or not in enum" end),
		(if ($doc|has("engine_commit")) and ($doc.engine_commit|nestr) then empty else "engine_commit: missing or not a non-empty string" end),
		(if ($doc|has("consumer_runs")) and (($doc.consumer_runs|type) == "array") then empty else "consumer_runs: missing or not an array" end),
		(if ($doc|has("required_evidence")) and (($doc.required_evidence|type) == "object") then empty else "required_evidence: missing or not an object" end),
		(if ($doc|type) == "object"
		 then (($doc|keys[]) as $rk | select((["version","stage","engine_commit","consumer_runs","required_evidence"]|index($rk)) | not) | "root.\($rk): unexpected key")
		 else empty end),
		(if (($doc.engine_commit // "") == "unknown")
		    and ( (($doc.consumer_runs // []) | length > 0)
		          or ( ($doc.required_evidence // {}) | to_entries | any(.value == true) ) )
		 then "engine_commit: 'unknown' is not allowed once consumer_runs/required_evidence indicate real evidence; record the real commit SHA"
		 else empty end),
		( ($doc.required_evidence // {}) as $re
		  | if ($re|type) == "object"
		    then ( (stacks[] as $k | select((($re|has($k)) and ($re[$k]|isbool)) | not) | "required_evidence.\($k): missing or not a boolean"),
		           (($re|keys[]) as $kk | select((stacks|index($kk)) | not) | "required_evidence.\($kk): unexpected key") )
		    else empty end ),
		( ($doc.consumer_runs // []) | (if type == "array" then . else [] end)
		  | to_entries[] as $e
		  | ($e.value) as $r
		  | if ($r|type) == "object"
		    then ( (runkeys[] as $rk | select(($r|has($rk)) | not) | "consumer_runs[\($e.key)].\($rk): missing"),
		           (($r|keys[]) as $rkk | select((runkeys|index($rkk)) | not) | "consumer_runs[\($e.key)].\($rkk): unexpected key"),
		           (if ($r.stack? and (stacks|index($r.stack))) then empty else "consumer_runs[\($e.key)].stack: invalid" end),
		           (if ($r.repository? | nestr) then empty else "consumer_runs[\($e.key)].repository: invalid" end),
		           (if ($r.commit? | nestr) then empty else "consumer_runs[\($e.key)].commit: invalid" end),
		           (if ($r.profile? | nestr) then empty else "consumer_runs[\($e.key)].profile: invalid" end),
		           (if ($r.tool_mode? and (tmodes|index($r.tool_mode))) then empty else "consumer_runs[\($e.key)].tool_mode: invalid" end),
		           (if ($r.workflow_run_id? | nestr) then empty else "consumer_runs[\($e.key)].workflow_run_id: invalid" end),
		           (if ($r.result? and (results|index($r.result))) then empty else "consumer_runs[\($e.key)].result: invalid" end),
		           (if ($r.artifacts_verified? | isbool) then empty else "consumer_runs[\($e.key)].artifacts_verified: not a boolean" end) )
		    else "consumer_runs[\($e.key)]: not an object" end )
	  ]
	| .[]
' "$FILE" 2>/dev/null) || { log_error "evidence file failed structural validation: $FILE"; exit 2; }

if [ -n "$ERRORS" ]; then
	log_error "evidence file is schema-invalid: $FILE"
	printf '%s\n' "$ERRORS" >&2
	exit 2
fi

[ -z "$REQUIRE_STAGE" ] && exit 0

# --- stage gate (fail-closed) ------------------------------------------------
# A stage key is MET only when required_evidence[key] is true AND a consumer_run
# with stack==key proves it: non-empty workflow_run_id, result=success,
# artifacts_verified=true. Unmet keys are listed; any unmet => exit 1.
UNMET=$(jq -r --arg stage "$REQUIRE_STAGE" '
	def need:
		if . == "alpha" then []
		elif . == "beta" then ["laravel","symfony"]
		elif . == "rc" then ["laravel","symfony","php_library","node_react","combined_profile"]
		else ["laravel","symfony","php_library","node_react","combined_profile","bootstrap_apply","rollback_npm","rollback_pnpm","rollback_yarn"]
		end;
	. as $doc
	| [ ($stage|need)[]
		| . as $k
		| select(
			( (($doc.required_evidence[$k] // false) == true)
			  and ( ($doc.consumer_runs // [])
			        | any(.stack == $k
			              and ((.workflow_run_id // "") | length > 0)
			              and (.result == "success")
			              and (.artifacts_verified == true)) ) ) | not ) ]
	| join(" ")
' "$FILE")

if [ -n "$UNMET" ]; then
	log_error "release evidence does not meet stage '$REQUIRE_STAGE'; unmet: $UNMET"
	exit 1
fi

log_info "release evidence meets stage '$REQUIRE_STAGE': $FILE"
exit 0
