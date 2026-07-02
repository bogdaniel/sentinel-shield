#!/bin/sh
# Sentinel Shield — validate a release-evidence file (fail-closed).
#
# Validates evidence/releases/<version>.json against
# schemas/release-evidence.schema.json using jq (ajv may be absent), enforcing
# field FORMATS (40-hex commits, positive-integer run ids, owner/repo, a
# canonical GitHub Actions run URL, ISO-8601 UTC timestamps) and SEMANTIC
# cross-field consistency so that a free-form string can never masquerade as
# proof. Optionally GATES the file against a release stage's evidence needs.
#
# The gate is fail-closed by construction: an honest "no proof yet" file
# (empty consumer_runs[], required_evidence all false) is schema-VALID but
# fails every --require-stage check. A required_evidence flag only counts when
# a successful, artifact-verified consumer_run with a non-empty workflow_run_id
# backs it. This script never fabricates run IDs and never relaxes a stage.
#
# MODES:
#   --offline (default)  STRUCTURAL validation only: schema + formats +
#                        cross-field semantics + stage consistency. This proves
#                        the record is WELL-FORMED and self-consistent; it does
#                        NOT prove the referenced runs actually exist.
#   --verify-github      Additionally call the GitHub API (through $GH_BIN,
#                        default 'gh') to verify each run exists, its head SHA
#                        equals the consumer commit, its conclusion equals
#                        result, its url/run-id match, and its artifacts exist
#                        with matching ids+names. Network is used ONLY here.
#
# Usage: validate-release-evidence.sh [--file <path>] [--require-stage <alpha|beta|rc|ga>]
#                                     [--offline | --verify-github]
#
# Exit:
#   0 = valid (well-formed; stage met if --require-stage; github-verified if asked)
#   1 = evidence unmet (schema-valid but stage not met, or GitHub verification
#       found a run/artifact missing or mismatched) — overridable upstream
#   2 = malformed / schema / format / semantic error — NON-overridable
#   3 = required tool unavailable (jq, or gh under --verify-github)
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# usage — print CLI usage/help to stdout.
usage() {
	printf 'Usage: validate-release-evidence.sh [--file <path>] [--require-stage <alpha|beta|rc|ga>] [--scope <engine-only|framework-validated|full-platform>] [--offline|--verify-github]\n'
}

FILE="$REPO_ROOT/evidence/releases/v2.0.0.json"
REQUIRE_STAGE=""
MODE="offline"
SCOPE_OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--file) FILE="${2:?--file requires a value}"; shift 2 ;;
		--require-stage) REQUIRE_STAGE="${2:?--require-stage requires a value}"; shift 2 ;;
		--scope) SCOPE_OVERRIDE="${2:?--scope requires a value}"; shift 2 ;;
		--offline) MODE="offline"; shift ;;
		--verify-github) MODE="verify-github"; shift ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

case "$REQUIRE_STAGE" in
	"" | alpha | beta | rc | ga) ;;
	*) log_error "--require-stage must be one of: alpha beta rc ga"; exit 2 ;;
esac
case "$SCOPE_OVERRIDE" in
	"" | engine-only | framework-validated | full-platform) ;;
	*) log_error "--scope must be one of: engine-only framework-validated full-platform"; exit 2 ;;
esac

command_exists jq || { log_error "jq is required for JSON parsing but was not found. Install jq."; exit 3; }

[ -f "$FILE" ] || { log_error "evidence file not found: $FILE"; exit 2; }
jq -e . "$FILE" >/dev/null 2>&1 || { log_error "evidence file is not valid JSON: $FILE"; exit 2; }

# Effective release scope: --scope overrides the file's release_scope field, which
# itself defaults to 'framework-validated' when absent (so a legacy evidence file
# with no release_scope keeps its stricter per-stack meaning).
FILE_SCOPE=$(jq -r '.release_scope // "framework-validated"' "$FILE")
SCOPE="${SCOPE_OVERRIDE:-$FILE_SCOPE}"
case "$SCOPE" in
	engine-only | framework-validated | full-platform) ;;
	*) log_error "evidence release_scope is invalid: '$SCOPE'"; exit 2 ;;
esac

# --- structural validation (schema mirror, incl. FORMATS) -------------------
# Emits one line per violation; any output => schema/format-invalid => exit 2.
ERRORS=$(jq -r '
	def nestr: (type == "string") and (length > 0);
	def isbool: type == "boolean";
	def hex40: (type == "string") and test("^[0-9a-f]{40}$");
	def repo: (type == "string") and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$");
	def posintid: ((type == "number") and (. == floor) and (. >= 1)) or ((type == "string") and test("^[1-9][0-9]*$"));
	def posint: (type == "number") and (. == floor) and (. >= 1);
	def runurl: (type == "string") and test("^https://github\\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/actions/runs/[1-9][0-9]*$");
	def isoz: (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z$");
	def stacks: ["laravel","symfony","php_library","node_react","combined_profile","bootstrap_apply","rollback_npm","rollback_pnpm","rollback_yarn"];
	def tmodes: ["config-only","require-existing","bootstrap-tools"];
	def results: ["success","failure","cancelled","skipped"];
	def runkeys: ["stack","repository","commit","sentinel_shield_commit","profile","tool_mode","workflow_run_id","workflow_url","result","artifacts","artifacts_verified","verified_at","verification_method"];
	def ecikeys: ["workflow_name","repository","commit","event","workflow_run_id","workflow_url","result","artifacts","artifacts_verified","verified_at","verification_method"];
	def events: ["push","pull_request","schedule","workflow_dispatch"];
	def scopes: ["engine-only","framework-validated","full-platform"];
	def artkeys: ["id","name","verified"];
	. as $doc
	| [
		(if ($doc|type) == "object" then empty else "root: not an object" end),
		(if ($doc|has("version")) and ($doc.version|nestr) then empty else "version: missing or not a non-empty string" end),
		(if ($doc|has("stage")) and (["alpha","beta","rc","ga"]|index($doc.stage // null)) then empty else "stage: missing or not in enum" end),
		(if ($doc|has("engine_commit")) and (($doc.engine_commit|hex40) or ($doc.engine_commit == "unknown")) then empty else "engine_commit: must be 40 lowercase hex or the literal unknown" end),
		(if ($doc|has("consumer_runs")) and (($doc.consumer_runs|type) == "array") then empty else "consumer_runs: missing or not an array" end),
		(if ($doc|has("required_evidence")) and (($doc.required_evidence|type) == "object") then empty else "required_evidence: missing or not an object" end),
		(if ($doc|has("release_scope")) and ((scopes|index($doc.release_scope // null)) | not) then "release_scope: must be one of engine-only|framework-validated|full-platform" else empty end),
		(if ($doc|has("engine_ci")) and (($doc.engine_ci|type) != "array") then "engine_ci: not an array" else empty end),
		(if ($doc|type) == "object"
		 then (($doc|keys[]) as $rk | select((["version","stage","release_scope","engine_commit","engine_ci","consumer_runs","required_evidence"]|index($rk)) | not) | "root.\($rk): unexpected key")
		 else empty end),
		(if (($doc.engine_commit // "") == "unknown")
		    and ( (($doc.consumer_runs // []) | length > 0)
		          or (($doc.engine_ci // []) | length > 0)
		          or ( ($doc.required_evidence // {}) | to_entries | any(.value == true) ) )
		 then "engine_commit: unknown is not allowed once consumer_runs/engine_ci/required_evidence indicate real evidence; record the real 40-hex commit SHA"
		 else empty end),
		( ($doc.engine_ci // []) | (if type == "array" then . else [] end)
		  | to_entries[] as $e
		  | ($e.value) as $r
		  | if ($r|type) == "object"
		    then ( (ecikeys[] as $rk | select(($r|has($rk)) | not) | "engine_ci[\($e.key)].\($rk): missing"),
		           (($r|keys[]) as $rkk | select((ecikeys|index($rkk)) | not) | "engine_ci[\($e.key)].\($rkk): unexpected key"),
		           (if ($r.workflow_name? | nestr) then empty else "engine_ci[\($e.key)].workflow_name: empty" end),
		           (if ($r.repository? | repo) then empty else "engine_ci[\($e.key)].repository: not owner/repo" end),
		           (if ($r.commit? | hex40) then empty else "engine_ci[\($e.key)].commit: not 40 lowercase hex" end),
		           (if ($r.event? and (events|index($r.event))) then empty else "engine_ci[\($e.key)].event: invalid" end),
		           (if ($r|has("workflow_run_id")) and ($r.workflow_run_id | posintid) then empty else "engine_ci[\($e.key)].workflow_run_id: not a positive integer" end),
		           (if ($r.workflow_url? | runurl) then empty else "engine_ci[\($e.key)].workflow_url: not a GitHub Actions run URL" end),
		           (if ($r.result? and (results|index($r.result))) then empty else "engine_ci[\($e.key)].result: invalid" end),
		           (if ($r.artifacts? | type) == "array" then empty else "engine_ci[\($e.key)].artifacts: not an array" end),
		           (if ($r.artifacts? | type) == "array"
		            then ( ($r.artifacts | to_entries[]) as $ae | ($ae.value) as $a
		                   | if ($a|type) == "object"
		                     then ( (artkeys[] as $ak | select(($a|has($ak)) | not) | "engine_ci[\($e.key)].artifacts[\($ae.key)].\($ak): missing"),
		                            (($a|keys[]) as $akk | select((artkeys|index($akk)) | not) | "engine_ci[\($e.key)].artifacts[\($ae.key)].\($akk): unexpected key"),
		                            (if ($a.id? | posint) then empty else "engine_ci[\($e.key)].artifacts[\($ae.key)].id: not a positive integer" end),
		                            (if ($a.name? | nestr) then empty else "engine_ci[\($e.key)].artifacts[\($ae.key)].name: empty" end),
		                            (if ($a.verified? | isbool) then empty else "engine_ci[\($e.key)].artifacts[\($ae.key)].verified: not a boolean" end) )
		                     else "engine_ci[\($e.key)].artifacts[\($ae.key)]: not an object" end )
		            else empty end),
		           (if ($r.artifacts_verified? | isbool) then empty else "engine_ci[\($e.key)].artifacts_verified: not a boolean" end),
		           (if ($r.verified_at? | isoz) then empty else "engine_ci[\($e.key)].verified_at: not an ISO-8601 UTC timestamp" end),
		           (if ($r.verification_method? | nestr) then empty else "engine_ci[\($e.key)].verification_method: empty" end) )
		    else "engine_ci[\($e.key)]: not an object" end ),
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
		           (if ($r.repository? | repo) then empty else "consumer_runs[\($e.key)].repository: not owner/repo" end),
		           (if ($r.commit? | hex40) then empty else "consumer_runs[\($e.key)].commit: not 40 lowercase hex" end),
		           (if ($r.sentinel_shield_commit? | hex40) then empty else "consumer_runs[\($e.key)].sentinel_shield_commit: not 40 lowercase hex" end),
		           (if ($r.profile? | nestr) then empty else "consumer_runs[\($e.key)].profile: empty" end),
		           (if ($r.tool_mode? and (tmodes|index($r.tool_mode))) then empty else "consumer_runs[\($e.key)].tool_mode: invalid" end),
		           (if ($r|has("workflow_run_id")) and ($r.workflow_run_id | posintid) then empty else "consumer_runs[\($e.key)].workflow_run_id: not a positive integer" end),
		           (if ($r.workflow_url? | runurl) then empty else "consumer_runs[\($e.key)].workflow_url: not a GitHub Actions run URL" end),
		           (if ($r.result? and (results|index($r.result))) then empty else "consumer_runs[\($e.key)].result: invalid" end),
		           (if ($r.artifacts? | type) == "array" then empty else "consumer_runs[\($e.key)].artifacts: not an array" end),
		           (if ($r.artifacts? | type) == "array"
		            then ( ($r.artifacts | to_entries[]) as $ae | ($ae.value) as $a
		                   | if ($a|type) == "object"
		                     then ( (artkeys[] as $ak | select(($a|has($ak)) | not) | "consumer_runs[\($e.key)].artifacts[\($ae.key)].\($ak): missing"),
		                            (($a|keys[]) as $akk | select((artkeys|index($akk)) | not) | "consumer_runs[\($e.key)].artifacts[\($ae.key)].\($akk): unexpected key"),
		                            (if ($a.id? | posint) then empty else "consumer_runs[\($e.key)].artifacts[\($ae.key)].id: not a positive integer" end),
		                            (if ($a.name? | nestr) then empty else "consumer_runs[\($e.key)].artifacts[\($ae.key)].name: empty" end),
		                            (if ($a.verified? | isbool) then empty else "consumer_runs[\($e.key)].artifacts[\($ae.key)].verified: not a boolean" end) )
		                     else "consumer_runs[\($e.key)].artifacts[\($ae.key)]: not an object" end )
		            else empty end),
		           (if ($r.artifacts_verified? | isbool) then empty else "consumer_runs[\($e.key)].artifacts_verified: not a boolean" end),
		           (if ($r.verified_at? | isoz) then empty else "consumer_runs[\($e.key)].verified_at: not an ISO-8601 UTC timestamp" end),
		           (if ($r.verification_method? | nestr) then empty else "consumer_runs[\($e.key)].verification_method: empty" end) )
		    else "consumer_runs[\($e.key)]: not an object" end )
	  ]
	| .[]
' "$FILE" 2>/dev/null) || { log_error "evidence file failed structural validation: $FILE"; exit 2; }

if [ -n "$ERRORS" ]; then
	log_error "evidence file is schema/format-invalid: $FILE"
	printf '%s\n' "$ERRORS" >&2
	exit 2
fi

# --- semantic cross-field validation (offline) ------------------------------
# Integrity checks that no individual format can catch. Any output => exit 2.
SEMERRORS=$(jq -r '
	def famtokens:
		{ "laravel":["laravel"],
		  "symfony":["symfony"],
		  "php_library":["php","library"],
		  "node_react":["node","react"],
		  "rollback_npm":["node","react","npm"],
		  "rollback_pnpm":["node","react","pnpm"],
		  "rollback_yarn":["node","react","yarn"] };
	. as $doc
	| ($doc.engine_commit // "") as $eng
	| [
		# Per-run semantics.
		( ($doc.consumer_runs // []) | to_entries[] as $e | ($e.value) as $r
		  | ($r.profile // "" | ascii_downcase) as $p
		  | ($r.stack // "") as $stk
		  | ($r.repository // "") as $rep
		  | (($r.workflow_run_id // "") | tostring) as $wrid
		  | ($r.result // "") as $res
		  | ($r.tool_mode // "") as $tm
		  | ($r.verification_method // "" | ascii_downcase) as $vm
		  | (
			# (3) sentinel_shield_commit must equal the top-level engine_commit.
			(if ($r.sentinel_shield_commit // "") == $eng then empty
			 else "consumer_runs[\($e.key)]: sentinel_shield_commit does not match top-level engine_commit" end),
			# (1)+(2) workflow_url owner/repo and run-id must match.
			( ($r.workflow_url // "") as $u
			  | ($u | capture("^https://github\\.com/(?<owner>[^/]+)/(?<repo>[^/]+)/actions/runs/(?<rid>[0-9]+)$") // null) as $cap
			  | if $cap == null then "consumer_runs[\($e.key)]: workflow_url unparseable"
			    else ( ("\($cap.owner)/\($cap.repo)") as $urepo
			           | (if $urepo == $rep then empty
			              else "consumer_runs[\($e.key)]: workflow_url repo \($urepo) != repository \($rep)" end),
			           (if $cap.rid == $wrid then empty
			              else "consumer_runs[\($e.key)]: workflow_url run-id \($cap.rid) != workflow_run_id \($wrid)" end) )
			    end ),
			# (5) every listed artifact must be verified=true.
			( ($r.artifacts // []) | to_entries[] as $ae
			  | select(($ae.value.verified // false) != true)
			  | "consumer_runs[\($e.key)].artifacts[\($ae.key)]: verified must be true" ),
			# (4) artifacts_verified=true requires a non-empty artifacts list.
			(if (($r.artifacts_verified // false) == true) and (($r.artifacts // []) | length == 0)
			 then "consumer_runs[\($e.key)]: artifacts_verified is true but artifacts[] is empty" else empty end),
			# (6) an artifact-verified ("success") run must not be cancelled/skipped/failed.
			(if (($r.artifacts_verified // false) == true) and ($res != "success")
			 then "consumer_runs[\($e.key)]: artifacts_verified is true but result is \($res) (must be success)" else empty end),
			# (8) stack/profile compatibility.
			( if $stk == "bootstrap_apply" then empty
			  elif $stk == "combined_profile"
			  then (if (($p | test("laravel|symfony|php")) and ($p | test("node|react"))) then empty
			        else "consumer_runs[\($e.key)]: combined_profile requires a php+node profile, got \($p)" end)
			  else ( (famtokens[$stk] // []) as $toks
			         | if ($toks | length) == 0 then empty
			           elif (any($toks[]; . as $t | $p | test($t))) then empty
			           else "consumer_runs[\($e.key)]: profile \($p) is incompatible with stack \($stk)" end )
			  end ),
			# (9) bootstrap_apply evidence must use tool_mode=bootstrap-tools.
			(if $stk == "bootstrap_apply" and ($tm != "bootstrap-tools")
			 then "consumer_runs[\($e.key)]: bootstrap_apply must use tool_mode=bootstrap-tools, got \($tm)" else empty end),
			# (10) rollback evidence must represent an actual rollback test.
			(if ($stk | startswith("rollback")) and (($vm | test("rollback")) | not)
			 then "consumer_runs[\($e.key)]: rollback stack \($stk) must document an actual rollback test (verification_method must mention rollback)" else empty end)
		  ) ),
		# (7) the SAME workflow_run_id cannot back two DIFFERENT stacks.
		( ($doc.consumer_runs // [])
		  | group_by(.workflow_run_id | tostring)
		  | .[]
		  | select(([ .[].stack ] | unique | length) > 1)
		  | "workflow_run_id \(.[0].workflow_run_id) is reused across distinct stacks (\([.[].stack] | unique | join(",")))" ),
		# engine_ci semantics: each engine run must exercise engine_commit and be self-consistent.
		( ($doc.engine_ci // []) | to_entries[] as $e | ($e.value) as $r
		  | ($r.repository // "") as $rep
		  | (($r.workflow_run_id // "") | tostring) as $wrid
		  | ($r.result // "") as $res
		  | (
			(if ($r.commit // "") == $eng then empty
			 else "engine_ci[\($e.key)]: commit does not match top-level engine_commit" end),
			( ($r.workflow_url // "") as $u
			  | ($u | capture("^https://github\\.com/(?<owner>[^/]+)/(?<repo>[^/]+)/actions/runs/(?<rid>[0-9]+)$") // null) as $cap
			  | if $cap == null then "engine_ci[\($e.key)]: workflow_url unparseable"
			    else ( ("\($cap.owner)/\($cap.repo)") as $urepo
			           | (if $urepo == $rep then empty
			              else "engine_ci[\($e.key)]: workflow_url repo \($urepo) != repository \($rep)" end),
			           (if $cap.rid == $wrid then empty
			              else "engine_ci[\($e.key)]: workflow_url run-id \($cap.rid) != workflow_run_id \($wrid)" end) )
			    end ),
			( ($r.artifacts // []) | to_entries[] as $ae
			  | select(($ae.value.verified // false) != true)
			  | "engine_ci[\($e.key)].artifacts[\($ae.key)]: verified must be true" ),
			(if (($r.artifacts_verified // false) == true) and (($r.artifacts // []) | length == 0)
			 then "engine_ci[\($e.key)]: artifacts_verified is true but artifacts[] is empty" else empty end),
			(if (($r.artifacts_verified // false) == true) and ($res != "success")
			 then "engine_ci[\($e.key)]: artifacts_verified is true but result is \($res) (must be success)" else empty end)
		  ) )
	  ]
	| .[]
' "$FILE" 2>/dev/null) || { log_error "evidence file failed semantic validation: $FILE"; exit 2; }

if [ -n "$SEMERRORS" ]; then
	log_error "evidence file failed semantic cross-field validation: $FILE"
	printf '%s\n' "$SEMERRORS" >&2
	exit 2
fi

# --- stage consistency (the doc must CLAIM at least the requested stage) -----
# stage_rank <stage> — ordinal; alpha<beta<rc<ga.
stage_rank() {
	case "$1" in
		alpha) printf '%s' 0 ;; beta) printf '%s' 1 ;; rc) printf '%s' 2 ;; ga) printf '%s' 3 ;; *) printf '%s' -1 ;;
	esac
}

if [ -n "$REQUIRE_STAGE" ]; then
	DOC_STAGE=$(jq -r '.stage // ""' "$FILE")
	REQ_RANK=$(stage_rank "$REQUIRE_STAGE")
	DOC_RANK=$(stage_rank "$DOC_STAGE")
	if [ "$DOC_RANK" -lt "$REQ_RANK" ]; then
		log_error "release evidence declares stage '$DOC_STAGE' which is below the requested stage '$REQUIRE_STAGE'; a lower-stage document cannot satisfy a higher-stage request"
		exit 1
	fi
fi

# --- optional GitHub verification (network) ---------------------------------
# Proves each consumer_run actually exists upstream. Routed through $GH_BIN so
# tests can stub it; never invoked in the default --offline mode.
if [ "$MODE" = "verify-github" ]; then
	: "${GH_BIN:=gh}"
	command_exists "$GH_BIN" || { log_error "GitHub verification requested but '$GH_BIN' is not available"; exit 3; }
	_n=$(jq '.consumer_runs | length' "$FILE")
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_repo=$(jq -r ".consumer_runs[$_i].repository" "$FILE")
		_commit=$(jq -r ".consumer_runs[$_i].commit" "$FILE")
		_rid=$(jq -r ".consumer_runs[$_i].workflow_run_id | tostring" "$FILE")
		_wurl=$(jq -r ".consumer_runs[$_i].workflow_url" "$FILE")
		_result=$(jq -r ".consumer_runs[$_i].result" "$FILE")
		_runj=$("$GH_BIN" api "repos/$_repo/actions/runs/$_rid" 2>/dev/null) || {
			log_error "GitHub verification: run not found: $_repo run $_rid"; exit 1; }
		printf '%s' "$_runj" | jq -e . >/dev/null 2>&1 || {
			log_error "GitHub verification: malformed run response for $_repo run $_rid"; exit 1; }
		_hs=$(printf '%s' "$_runj" | jq -r '.head_sha // ""')
		_concl=$(printf '%s' "$_runj" | jq -r '.conclusion // ""')
		_url=$(printf '%s' "$_runj" | jq -r '.html_url // ""')
		_idr=$(printf '%s' "$_runj" | jq -r '.id // "" | tostring')
		[ "$_hs" = "$_commit" ] || { log_error "GitHub verification: run $_rid head SHA ($_hs) != consumer commit ($_commit)"; exit 1; }
		[ "$_concl" = "$_result" ] || { log_error "GitHub verification: run $_rid conclusion ($_concl) != result ($_result)"; exit 1; }
		[ "$_url" = "$_wurl" ] || { log_error "GitHub verification: run $_rid html_url ($_url) != workflow_url ($_wurl)"; exit 1; }
		[ "$_idr" = "$_rid" ] || { log_error "GitHub verification: run id ($_idr) != workflow_run_id ($_rid)"; exit 1; }
		_artj=$("$GH_BIN" api "repos/$_repo/actions/runs/$_rid/artifacts" 2>/dev/null) || {
			log_error "GitHub verification: could not list artifacts for $_repo run $_rid"; exit 1; }
		printf '%s' "$_artj" | jq -e . >/dev/null 2>&1 || {
			log_error "GitHub verification: malformed artifacts response for $_repo run $_rid"; exit 1; }
		_want=$(jq -c ".consumer_runs[$_i].artifacts" "$FILE")
		_miss=$(jq -nr --argjson have "$_artj" --argjson want "$_want" '
			($have.artifacts // []) as $h
			| [ $want[] | . as $w
			    | select( ([ $h[] | select(.id == $w.id and .name == $w.name) ] | length) == 0 )
			    | "\($w.id):\($w.name)" ]
			| join(",")')
		if [ -n "$_miss" ]; then
			log_error "GitHub verification: run $_rid is missing declared artifacts upstream: $_miss"
			exit 1
		fi
		_i=$((_i + 1))
	done
	log_info "GitHub verification passed for all $_n consumer run(s) in $FILE"

	# Verify engine_ci runs against the engine repository itself.
	_en=$(jq '.engine_ci | length' "$FILE")
	_ei=0
	while [ "$_ei" -lt "$_en" ]; do
		_erepo=$(jq -r ".engine_ci[$_ei].repository" "$FILE")
		_ecommit=$(jq -r ".engine_ci[$_ei].commit" "$FILE")
		_erid=$(jq -r ".engine_ci[$_ei].workflow_run_id | tostring" "$FILE")
		_ewurl=$(jq -r ".engine_ci[$_ei].workflow_url" "$FILE")
		_eresult=$(jq -r ".engine_ci[$_ei].result" "$FILE")
		_eevent=$(jq -r ".engine_ci[$_ei].event" "$FILE")
		_erunj=$("$GH_BIN" api "repos/$_erepo/actions/runs/$_erid" 2>/dev/null) || {
			log_error "GitHub verification: engine run not found: $_erepo run $_erid"; exit 1; }
		printf '%s' "$_erunj" | jq -e . >/dev/null 2>&1 || {
			log_error "GitHub verification: malformed engine run response for $_erepo run $_erid"; exit 1; }
		_ehs=$(printf '%s' "$_erunj" | jq -r '.head_sha // ""')
		_econcl=$(printf '%s' "$_erunj" | jq -r '.conclusion // ""')
		_eurl=$(printf '%s' "$_erunj" | jq -r '.html_url // ""')
		_eidr=$(printf '%s' "$_erunj" | jq -r '.id // "" | tostring')
		_eapievent=$(printf '%s' "$_erunj" | jq -r '.event // ""')
		[ "$_ehs" = "$_ecommit" ] || { log_error "GitHub verification: engine run $_erid head SHA ($_ehs) != commit ($_ecommit)"; exit 1; }
		[ "$_econcl" = "$_eresult" ] || { log_error "GitHub verification: engine run $_erid conclusion ($_econcl) != result ($_eresult)"; exit 1; }
		[ "$_eapievent" = "$_eevent" ] || { log_error "GitHub verification: engine run $_erid event ($_eapievent) != declared event ($_eevent)"; exit 1; }
		[ "$_eurl" = "$_ewurl" ] || { log_error "GitHub verification: engine run $_erid html_url ($_eurl) != workflow_url ($_ewurl)"; exit 1; }
		[ "$_eidr" = "$_erid" ] || { log_error "GitHub verification: engine run id ($_eidr) != workflow_run_id ($_erid)"; exit 1; }
		_ewant=$(jq -c ".engine_ci[$_ei].artifacts" "$FILE")
		_eartj=$("$GH_BIN" api "repos/$_erepo/actions/runs/$_erid/artifacts" 2>/dev/null) || {
			log_error "GitHub verification: could not list artifacts for engine $_erepo run $_erid"; exit 1; }
		printf '%s' "$_eartj" | jq -e . >/dev/null 2>&1 || {
			log_error "GitHub verification: malformed artifacts response for engine $_erepo run $_erid"; exit 1; }
		_emiss=$(jq -nr --argjson have "$_eartj" --argjson want "$_ewant" '
			($have.artifacts // []) as $h
			| [ $want[] | . as $w
			    | select( ([ $h[] | select(.id == $w.id and .name == $w.name) ] | length) == 0 )
			    | "\($w.id):\($w.name)" ]
			| join(",")')
		if [ -n "$_emiss" ]; then
			log_error "GitHub verification: engine run $_erid is missing declared artifacts upstream: $_emiss"
			exit 1
		fi
		_ei=$((_ei + 1))
	done
	[ "$_en" -gt 0 ] && log_info "GitHub verification passed for all $_en engine_ci run(s) in $FILE"
fi

# --- stage gate (fail-closed) ------------------------------------------------
# A stage key is MET only when required_evidence[key] is true AND a consumer_run
# with stack==key proves it: non-empty workflow_run_id, result=success,
# artifacts_verified=true. Unmet keys are listed; any unmet => exit 1.
# The engine-only track proves the reusable engine, NOT any framework. Disclose
# that loudly and unmissably so an engine-only pass is never mistaken for
# framework-validated readiness.
if [ "$SCOPE" = "engine-only" ]; then
	printf '%s\n' "FRAMEWORK LIVE-VALIDATION NOT INCLUDED"
	log_warn "release_scope=engine-only: this record backs the ENGINE via its own CI only; Laravel/Symfony and other real-consumer live-validation are NOT included, and this release cannot claim framework-validated status"
fi

if [ -n "$REQUIRE_STAGE" ]; then
	UNMET=$(jq -r --arg stage "$REQUIRE_STAGE" --arg scope "$SCOPE" '
		def need($scope):
			if $scope == "engine-only" then []
			elif $scope == "full-platform" then
				(if . == "alpha" then [] else ["laravel","symfony","php_library","node_react","combined_profile","bootstrap_apply","rollback_npm","rollback_pnpm","rollback_yarn"] end)
			else
				(if . == "alpha" then []
				 elif . == "beta" then ["laravel","symfony"]
				 elif . == "rc" then ["laravel","symfony","php_library","node_react","combined_profile"]
				 else ["laravel","symfony","php_library","node_react","combined_profile","bootstrap_apply","rollback_npm","rollback_pnpm","rollback_yarn"] end)
			end;
		. as $doc
		| [ ($stage|need($scope))[]
			| . as $k
			| select(
				( (($doc.required_evidence[$k] // false) == true)
				  and ( ($doc.consumer_runs // [])
				        | any(.stack == $k
				              and ((.workflow_run_id // "") | tostring | length > 0)
				              and (.result == "success")
				              and (.artifacts_verified == true)) ) ) | not ) ]
		| join(" ")
	' "$FILE")

	if [ -n "$UNMET" ]; then
		log_error "release evidence does not meet stage '$REQUIRE_STAGE' (scope=$SCOPE); unmet: $UNMET"
		exit 1
	fi

	# engine-only beta+ is NOT "no gate": it must be backed by the engine's own
	# green default-branch CI at engine_commit. Empty/failed engine_ci => fail closed.
	if [ "$SCOPE" = "engine-only" ] && [ "$(stage_rank "$REQUIRE_STAGE")" -ge 1 ]; then
		_eng_commit=$(jq -r '.engine_commit' "$FILE")
		ENG_UNMET=$(jq -r --arg eng "$_eng_commit" '
			def core: ["ci-self-test","ci-pipeline"];
			(.engine_ci // []) as $ec
			| [ (if ($ec|length) == 0 then "engine_ci is empty (engine-only beta+ requires the engine default-branch CI runs at engine_commit)" else empty end),
			    ($ec[] | select(.result != "success") | "engine_ci run \(.workflow_name) result=\(.result) (must be success)"),
			    ($ec[] | select(.commit != $eng) | "engine_ci run \(.workflow_name) commit does not match engine_commit"),
			    (core[] as $c | select(([ $ec[] | select(.workflow_name == $c and .result == "success") ] | length) == 0) | "engine_ci is missing a successful \($c) run") ]
			| unique | join("; ")
		' "$FILE")
		if [ -n "$ENG_UNMET" ]; then
			log_error "engine-only stage '$REQUIRE_STAGE' evidence unmet: $ENG_UNMET"
			exit 1
		fi
	fi

	log_info "release evidence meets stage '$REQUIRE_STAGE' (scope=$SCOPE): $FILE"
fi

if [ "$MODE" = "verify-github" ]; then
	log_info "validation OK (GitHub-verified): $FILE"
else
	log_info "structural evidence validation OK: $FILE — well-formed and self-consistent; this does NOT prove the referenced runs exist (use --verify-github for that)"
fi
exit 0
