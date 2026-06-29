#!/bin/sh
# Sentinel Shield — project-level tool-policy override loader (POSIX sh library).
#
# Loads + schema-validates a consuming project's .sentinel-shield/tool-policy.yaml
# (schemas/tool-policy-override.schema.json) and APPLIES its policy-only overrides
# onto a composed profile policy (the tools{} map produced by profile-compose.sh).
#
# Source this file; do not execute it (it also runs as a small CLI for testing):
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"   # first
#   . "$SCRIPT_DIR/lib/tool-policy-override.sh"
#   tpo_load   <override.yaml>                 # -> validated {tools:{...}} on stdout
#   tpo_apply  <composed-tools.json|-> <yaml>  # -> merged tools{} map on stdout
#
# The override file may ONLY adjust the `policy` of a tool the active profile already
# declares (schema: tools -> toolKey -> { policy }; additionalProperties:false). It
# cannot add packages, runners, or report paths.
#
# HARD CONSTRAINTS enforced here (see docs/profile-tool-policy.md):
#   1. A project CANNOT disable a non-suppressible security control (secrets
#      detection — category 'secrets', e.g. gitleaks/trufflehog) without a documented
#      policy record (SENTINEL_SHIELD_DOCUMENTED_DISABLE_RECORD=<existing file>).
#   2. A project CANNOT convert an execution-error into a pass. This is structural:
#      the override is POLICY-ONLY (the schema permits no `status`/state field), so an
#      override can never set a tool's runtime state — an execution-error stays an
#      execution-error and is gated per its (possibly overridden) policy.
#
# Precedence (documented ladder, applied by profile-compose.sh across profiles):
#   required > recommended > optional > disabled. A project override is an EXPLICIT,
#   per-tool decision and REPLACES the composed policy for that tool (e.g. downgrade a
#   noisy `recommended` check to `optional`), subject to the two hard constraints above.
#
# stdout = machine-readable JSON only. All logs go to stderr.
# Exit (CLI): 0 ok; 2 invalid invocation / missing jq / unknown tool / config error;
#             3 invalid override file (schema validation failed).
set -eu

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_TPO_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_TPO_LOADED=1

# Source the shared library if the caller has not already done so. When run as a CLI,
# $0 points at this file (scripts/lib/); when sourced by a scripts/ wrapper, $0 points
# at that wrapper (scripts/), so check both shapes.
# ponytail: $0-based lookup is the only locator POSIX sh has when sourced.
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	_tpo_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	if [ -f "$_tpo_d/sentinel-shield-common.sh" ]; then
		. "$_tpo_d/sentinel-shield-common.sh"
	elif [ -f "$_tpo_d/lib/sentinel-shield-common.sh" ]; then
		. "$_tpo_d/lib/sentinel-shield-common.sh"
	else
		printf '%s\n' "[sentinel-shield][error] tool-policy-override: cannot locate sentinel-shield-common.sh; source it first." >&2
		exit 2
	fi
fi

TPO_TAB=$(printf '\t')

# The policy enum (schemas/tool-policy.schema.json#/$defs/policy).
TPO_POLICY_ENUM='required recommended optional one-of disabled external'

# Tool keys whose control is non-suppressible regardless of category metadata
# (secrets detection). Mirrors enforce-gates.sh: the `secrets` gate is never
# suppressible. category=='secrets' in the composed policy also triggers this.
TPO_NONSUPPRESSIBLE_KEYS=' gitleaks trufflehog '

# die_cfg <message...> — configuration/input error -> exit 2 (engine convention).
tpo__die_cfg() { log_error "$*"; exit 2; }

# tpo__yq_v4 — true if a usable mikefarah yq v4 is on PATH.
tpo__yq_v4() {
	command_exists yq || return 1
	yq --version 2>/dev/null | grep -Eq 'mikefarah|version v4'
}

# tpo__to_json <override.yaml> — print the override file as a faithful JSON document
# ({"tools":{...}}) on stdout. Prefers mikefarah yq v4; otherwise a focused POSIX-safe
# parser for the canonical 2-space shape (block OR inline `{ policy: x }`).
# ponytail: the awk fallback understands ONLY the documented shape (a single `tools`
# map of toolKey -> fields). Any other top-level key, or non-2-space indentation, is
# rejected with a request to install yq v4 — safe (reject) rather than silently wrong.
tpo__to_json() {
	command_exists jq || tpo__die_cfg "tool-policy-override: jq is required."
	[ -f "$1" ] || tpo__die_cfg "tool-policy-override: file not found: $1"
	if tpo__yq_v4; then
		_j=$(yq -o=json e '.' "$1" 2>/dev/null) || tpo__die_cfg "tool-policy-override: yq failed to parse $1"
		[ -n "$_j" ] && [ "$_j" != "null" ] || { log_error "tool-policy-override: $1 is empty (a 'tools:' mapping is required)."; return 3; }
		printf '%s' "$_j"
		return 0
	fi
	# Fallback parser.
	_rows=$(awk '
		function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); return s }
		function unq(s){ gsub(/^["\047]|["\047]$/,"",s); return s }
		BEGIN{ in_tools=0; cur="" }
		{
			line=$0
			if (line ~ /^[[:space:]]*#/) next
			if (line ~ /^[[:space:]]*$/) next
			sub(/[[:space:]]+#.*$/,"",line)
			match(line,/^ */); indent=RLENGTH
			content=substr(line,indent+1)
			if (indent==0) {
				ci=index(content,":")
				if (ci==0) { print "ERR\tunsupported top-level line" > "/dev/stderr"; exit 3 }
				key=trim(substr(content,1,ci-1))
				if (key!="tools") { print "ERR\tunsupported top-level key: " key > "/dev/stderr"; exit 3 }
				# `tools:` must introduce a MAP, not a scalar. Reject `tools: something`
				# (anything non-empty after the colon that is not an inline `{}`) so a
				# malformed override fails fast instead of becoming a silent empty map.
				topval=trim(substr(content,ci+1))
				if (topval!="" && topval !~ /^\{/) { print "ERR\ttools must be a mapping, got scalar: " topval > "/dev/stderr"; exit 3 }
				in_tools=1; cur=""; next
			}
			if (!in_tools) next
			ci=index(content,":")
			if (ci==0) next
			key=trim(substr(content,1,ci-1))
			rest=trim(substr(content,ci+1))
			if (indent<=2) {
				cur=key
				if (rest ~ /^\{/) {
					gsub(/[{}]/,"",rest)
					n=split(rest,parts,",")
					for(i=1;i<=n;i++){
						p=parts[i]; pi=index(p,":")
						if(pi>0){ fk=trim(substr(p,1,pi-1)); fv=unq(trim(substr(p,pi+1))); if(fk!="") print cur "\t" fk "\t" fv }
					}
					cur=""
				} else if (rest!="") {
					# scalar directly on the tool key (e.g. "scorecard: optional") — not the
					# documented {policy: x} shape; surface it so validation rejects it.
					print cur "\t__bare__\t" unq(rest); cur=""
				}
				next
			}
			if (cur!="" && rest!="") print cur "\t" key "\t" unq(rest)
		}
		END{ if (!in_tools) { print "ERR\tmissing required top-level tools mapping" > "/dev/stderr"; exit 3 } }
	' "$1") || return 3
	printf '%s\n' "$_rows" | jq -Rn '
		[ inputs | select(length>0) | split("\t") ]
		| reduce .[] as $r ({}; .[$r[0]][$r[1]] = $r[2])
		| { tools: . }
	'
}

# tpo__validate_json <doc-json> — validate the override document against the schema's
# constraints. Returns 0 if valid, 3 otherwise (with a specific log_error).
tpo__validate_json() {
	_doc="$1"
	if ! printf '%s' "$_doc" | jq -e '(type=="object") and (keys==["tools"])' >/dev/null 2>&1; then
		log_error "tool-policy-override: document must have exactly one top-level key 'tools'."
		return 3
	fi
	if ! printf '%s' "$_doc" | jq -e '.tools | type=="object"' >/dev/null 2>&1; then
		log_error "tool-policy-override: 'tools' must be a mapping of toolKey -> { policy }."
		return 3
	fi
	# Per-tool: key matches toolKey pattern; value is { policy } ONLY; policy in enum.
	_bad=$(printf '%s' "$_doc" | jq -r --arg enum "$TPO_POLICY_ENUM" '
		($enum | split(" ")) as $E
		| .tools | to_entries[]
		| select(
			((.key|test("^[a-z0-9][a-z0-9-]*$"))|not)
			or ((.value|type)!="object")
			or ((.value|keys)!=["policy"])
			or ((.value.policy|type)!="string")
			or (([.value.policy] - $E) != [])
		)
		| .key
	' 2>/dev/null) || { log_error "tool-policy-override: could not evaluate override document."; return 3; }
	if [ -n "$_bad" ]; then
		log_error "tool-policy-override: invalid override entr(y/ies) (each must be 'toolkey: { policy: <required|recommended|optional|one-of|disabled|external> }' and nothing else): $(printf '%s' "$_bad" | tr '\n' ' ')"
		return 3
	fi
	return 0
}

# tpo_load <override.yaml> — parse + schema-validate; print the validated {tools:{...}}
# JSON document on stdout. Returns 0 on success, 2/3 on error.
tpo_load() {
	[ -n "${1:-}" ] || tpo__die_cfg "tpo_load: missing override file path."
	_doc=$(tpo__to_json "$1") || return $?
	tpo__validate_json "$_doc" || return 3
	printf '%s\n' "$_doc"
}

# tpo__nonsuppressible <composed-json> <toolkey> — true if the tool is a
# non-suppressible security control (secrets): category=='secrets' or a known key.
tpo__nonsuppressible() {
	case "$TPO_NONSUPPRESSIBLE_KEYS" in
		*" $2 "*) return 0 ;;
	esac
	_cat=$(printf '%s' "$1" | jq -r --arg k "$2" '.[$k].category // ""' 2>/dev/null || true)
	[ "$_cat" = "secrets" ]
}

# tpo__has_documented_record <toolkey> — true if a documented policy record permits
# disabling a non-suppressible control. ponytail: the record is an out-of-band,
# owner-approved document; we only check that an operator pointed us at an existing
# file via SENTINEL_SHIELD_DOCUMENTED_DISABLE_RECORD. Absence => refuse (safe default).
tpo__has_documented_record() {
	_rec="${SENTINEL_SHIELD_DOCUMENTED_DISABLE_RECORD:-}"
	[ -n "$_rec" ] && [ -f "$_rec" ]
}

# tpo_apply <composed-tools.json|-> <override.yaml> — apply the validated overrides
# onto the composed tools{} map and print the merged map on stdout. The composed input
# is a bare toolsMap ({ toolkey: { policy, category, ... } }) such as profile-compose.sh
# emits. Reads '-' from stdin.
tpo_apply() {
	command_exists jq || tpo__die_cfg "tool-policy-override: jq is required."
	[ -n "${1:-}" ] || tpo__die_cfg "tpo_apply: missing composed tools JSON path (or '-')."
	[ -n "${2:-}" ] || tpo__die_cfg "tpo_apply: missing override file path."
	if [ "$1" = "-" ]; then
		_composed=$(cat)
	else
		[ -f "$1" ] || tpo__die_cfg "tool-policy-override: composed tools file not found: $1"
		_composed=$(cat "$1")
	fi
	printf '%s' "$_composed" | jq -e 'type=="object"' >/dev/null 2>&1 \
		|| tpo__die_cfg "tool-policy-override: composed tools input is not a JSON object."

	_doc=$(tpo_load "$2") || exit 3

	# Iterate "toolkey<TAB>policy" pairs from the validated override.
	_pairs=$(printf '%s' "$_doc" | jq -r '.tools | to_entries[] | "\(.key)\t\(.value.policy)"')
	_oifs=$IFS
	IFS='
'
	for _p in $_pairs; do
		IFS=$_oifs
		[ -n "$_p" ] || { IFS='
'; continue; }
		_k=${_p%%"$TPO_TAB"*}
		_pol=${_p#*"$TPO_TAB"}
		# The tool must be declared by the active profile.
		if ! printf '%s' "$_composed" | jq -e --arg k "$_k" 'has($k)' >/dev/null 2>&1; then
			tpo__die_cfg "tool-policy-override: override targets undeclared tool '$_k' (not in the active profile's composed policy)."
		fi
		# HARD CONSTRAINT 1: cannot disable a non-suppressible control without a record.
		if [ "$_pol" = "disabled" ] && tpo__nonsuppressible "$_composed" "$_k"; then
			if tpo__has_documented_record "$_k"; then
				log_warn "tool-policy-override: disabling non-suppressible control '$_k' permitted by documented record '$SENTINEL_SHIELD_DOCUMENTED_DISABLE_RECORD'."
			else
				tpo__die_cfg "tool-policy-override: refusing to disable non-suppressible security control '$_k' (secrets detection) without a documented policy record. Set SENTINEL_SHIELD_DOCUMENTED_DISABLE_RECORD to an owner-approved record file. See docs/profile-tool-policy.md."
			fi
		fi
		_composed=$(printf '%s' "$_composed" | jq --arg k "$_k" --arg p "$_pol" '.[$k].policy = $p')
		log_info "tool-policy-override: $_k -> policy=$_pol"
		IFS='
'
	done
	IFS=$_oifs
	printf '%s\n' "$_composed"
}

# --- CLI entrypoint (only when executed directly, not when sourced) ----------
tpo__usage() {
	cat <<'EOF'
usage: tool-policy-override.sh <command> [args]
  validate <override.yaml>                 Schema-validate the override file (exit 3 if invalid).
  load     <override.yaml>                 Print the validated {tools:{...}} JSON.
  apply    <composed-tools.json|-> <yaml>  Apply policy overrides onto a composed tools map.
EOF
}

case "$0" in
	*tool-policy-override.sh)
		_cmd="${1:-}"
		case "$_cmd" in
			validate)
				[ -n "${2:-}" ] || tpo__die_cfg "usage: tool-policy-override.sh validate <override.yaml>"
				tpo_load "$2" >/dev/null || exit $?
				log_info "tool-policy-override: $2 is valid."
				;;
			load)
				[ -n "${2:-}" ] || tpo__die_cfg "usage: tool-policy-override.sh load <override.yaml>"
				tpo_load "$2" || exit $?
				;;
			apply)
				[ -n "${2:-}" ] && [ -n "${3:-}" ] || tpo__die_cfg "usage: tool-policy-override.sh apply <composed-tools.json|-> <override.yaml>"
				tpo_apply "$2" "$3"
				;;
			-h | --help | "") tpo__usage ;;
			*) tpo__die_cfg "unknown command '$_cmd' (try -h)" ;;
		esac
		;;
esac
