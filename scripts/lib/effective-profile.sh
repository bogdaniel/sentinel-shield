#!/bin/sh
# Sentinel Shield — canonical effective-profile resolver (v2).
#
# THE single source of truth for "what is the composed, override-aware tool
# policy for a profile". Every v2 consumer (installer, sync, tool planner,
# bootstrap, doctor, maturity, workflow planner, run-tool-plan, summary builder,
# gate, upgrade planner, migration) MUST resolve through here and MUST NOT
# implement its own composition. (Blocker 1 / Significant fix 11.)
#
# Source this file; it defines functions only. The CLI wrapper is
# scripts/resolve-effective-profile.sh.
#
# Composition precedence (strongest wins; a child can NEVER weaken a parent):
#   required > one-of > recommended > optional > external > disabled
# On EQUAL policy the later (more specific / child) object wins, but the merged
# entry keeps the stronger policy. Project overrides are applied AFTER inheritance
# with their OWN explicit rules (see ep__apply_override).
#
# Fail-closed (exit 2) for: unknown/missing parent manifest, invalid parent JSON,
# inheritance cycle (reports the path), invalid policy value, invalid override,
# invalid one-of group. NEVER warn-and-continue with a weaker policy.
#
# Output JSON (stdout; all logs to stderr):
#   { "profile", "tool_policy_version", "extends", "tools": {<key>:{...,"applicability"}},
#     "one_of_groups": {<group>:{policy,alternatives,selection,fallback_order,
#                                 status,selected,available}},
#     "diagnostics": [ ... ] }
# No top-level `set -eu`: this file is sourced and defines functions only; it must not
# mutate the sourcing shell's options. Every caller sets its own `set -eu`.

if [ "${__SENTINEL_SHIELD_EFFECTIVE_PROFILE_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_EFFECTIVE_PROFILE_LOADED=1

# Source the shared library if not already loaded ($0-based; works sourced or CLI).
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	_ep_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	if [ -f "$_ep_d/sentinel-shield-common.sh" ]; then . "$_ep_d/sentinel-shield-common.sh"
	elif [ -f "$_ep_d/lib/sentinel-shield-common.sh" ]; then . "$_ep_d/lib/sentinel-shield-common.sh"
	else printf '%s\n' "[sentinel-shield][error] effective-profile: cannot locate sentinel-shield-common.sh" >&2; exit 2
	fi
fi

# Shared control-waiver validator (a project override may only WEAKEN a required /
# one-of control when a valid, unexpired waiver covers that tool — Part A1/A4).
if [ "${__SENTINEL_SHIELD_CONTROL_WAIVERS_LOADED:-}" != "1" ]; then
	_ep_cw=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	for _c in "$_ep_cw/control-waivers.sh" "$_ep_cw/lib/control-waivers.sh"; do
		[ -f "$_c" ] && { . "$_c"; break; }
	done
fi

# Policy precedence ranks (higher = stronger). Matches docs/profile-tool-policy.md.
EP_RANK='{"required":5,"one-of":4,"recommended":3,"optional":2,"external":1,"disabled":0}'
EP_VALID_POLICIES="required recommended optional one-of disabled external"

# ep__rank <policy> — numeric strength (−1 for unknown).
ep__rank() { printf '%s' "$EP_RANK" | jq -r --arg p "$1" '.[$p] // -1'; }
# Non-suppressible security controls: a project override CANNOT set these to
# disabled without a documented control waiver (Blocker 9 owns the waiver path).
EP_NON_SUPPRESSIBLE=" gitleaks trufflehog "

ep__die_cfg() { log_error "$*"; exit 2; }

# ep__repo_root — print the Sentinel Shield repo root (dir holding profiles/).
ep__repo_root() {
	if [ -n "${EP_REPO_ROOT:-}" ] && [ -d "$EP_REPO_ROOT/profiles" ]; then printf '%s\n' "$EP_REPO_ROOT"; return 0; fi
	_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	for _c in "$_d/../.." "$_d/.." "$_d" "$PWD"; do
		[ -d "$_c/profiles" ] && { (CDPATH= cd -- "$_c" && pwd); return 0; }
	done
	return 1
}

# ep__manifest_path <root> <profile> — print manifest path or non-zero.
ep__manifest_path() {
	for _c in "$1/profiles/$2/profile.manifest.json" "$1/profiles/combinations/$2.manifest.json"; do
		[ -f "$_c" ] && { printf '%s\n' "$_c"; return 0; }
	done
	return 1
}

# ep__collect <root> <profile> <path-so-far> — depth-first chain collection with
# cycle detection. Appends manifest paths (parents first, self last) to EP_CHAIN.
# EP_VISITING tracks the active recursion stack (cycle); EP_RESOLVED dedups.
ep__collect() {
	_root="$1"; _p="$2"; _path="$3"
	case " $EP_VISITING " in
		*" $_p "*) ep__die_cfg "profile inheritance cycle: ${_path}${_p}" ;;
	esac
	case " $EP_RESOLVED " in
		*" $_p "*) return 0 ;;   # already fully merged elsewhere in the DAG
	esac
	_mf=$(ep__manifest_path "$_root" "$_p") \
		|| ep__die_cfg "unknown parent profile '$_p' (no manifest in profiles/$_p/ or profiles/combinations/)${_path:+; via ${_path%% -> }}"
	jq -e . "$_mf" >/dev/null 2>&1 || ep__die_cfg "invalid JSON in parent manifest: $_mf"
	# Validate every declared tool's policy value up-front (fail-closed).
	_badpol=$(jq -r '
		(.tools // {}) | to_entries[]
		| select((.value.policy // "") | IN("required","recommended","optional","one-of","disabled","external") | not)
		| .key' "$_mf" 2>/dev/null || true)
	[ -z "$_badpol" ] || ep__die_cfg "invalid policy value for tool(s) in $_mf: $(printf '%s' "$_badpol" | tr '\n' ' ')"
	EP_VISITING="$EP_VISITING $_p"
	for _parent in $(jq -r '.extends[]? // empty' "$_mf"); do
		ep__collect "$_root" "$_parent" "${_path}${_p} -> "
	done
	# pop from the visiting stack, mark resolved, record in merge order
	EP_VISITING=$(printf '%s' " $EP_VISITING " | sed "s/ $_p / /" | sed 's/^ //;s/ $//')
	EP_RESOLVED="$EP_RESOLVED $_p"
	EP_CHAIN="$EP_CHAIN $_mf"
}

# ep__merge_tools <chain...> — strongest-policy merge of every manifest's tools{}.
ep__merge_tools() {
	# shellcheck disable=SC2086
	jq -n --argjson rank "$EP_RANK" '
		reduce inputs as $m ({};
			reduce (($m.tools // {}) | to_entries[]) as $e (.;
				($rank[$e.value.policy] // -1) as $nr
				| (if has($e.key) then ($rank[.[$e.key].policy] // -1) else -2 end) as $cr
				| if $nr > $cr then .[$e.key] = $e.value
				  elif $nr == $cr then .[$e.key] = ($e.value + {policy: .[$e.key].policy})
				  else . end))' "$@"
}

# ep__apply_override <tools-json> <override-json|""> — apply a project override.
# Rules (explicit, separate from inheritance):
#   - override may only change the `policy` of a tool the profile already declares;
#   - a non-suppressible control may NOT be set to disabled (fail-closed exit 2);
#   - the override policy WINS for that tool (project intent is authoritative).
# Emits the new tools JSON; appends notes to the global EP_DIAG (newline list).
# ep__apply_override <tools-json> <override-json|""> <waivers-file|""> — apply a
# project override, FAIL-CLOSED. Rules (Part A1/A2/B12):
#   - every override entry must be an object with a `policy` in the valid enum;
#     a malformed entry (null/missing/numeric/unknown policy, non-object) => exit 2.
#   - an override for a tool the profile does NOT declare => exit 2 (no typos /
#     undeclared tools in alpha).
#   - an override may STRENGTHEN policy freely (rank up or equal).
#   - an override may NOT WEAKEN a `required` or `one-of` control (rank down)
#     unless a VALID, unexpired control-waiver covers that tool => otherwise exit 2.
#   - a non-suppressible control can never be weakened, even with a waiver.
ep__apply_override() {
	_tools="$1"; _ovr="$2"; _wf="${3:-}"
	[ -n "$_ovr" ] || { printf '%s' "$_tools"; return 0; }

	# (B12) structural validation of every override entry.
	_malformed=$(printf '%s' "$_ovr" | jq -r --arg ok "$EP_VALID_POLICIES" '
		($ok | split(" ")) as $OK
		| (.tools // {}) | to_entries[]
		| select((.value | type != "object")
			or (.value | has("policy") | not)
			or ((.value.policy | type) != "string")
			or ((.value.policy) as $p | ($OK | index($p)) == null))
		| .key' 2>/dev/null || true)
	[ -z "$_malformed" ] || ep__die_cfg "tool-policy override has malformed entry(ies) (need {\"policy\": one of $EP_VALID_POLICIES}): $(printf '%s' "$_malformed" | tr '\n' ' ')"

	# (A2) unknown override tool key => fail closed.
	_unknown=$(printf '%s' "$_tools" | jq -r --argjson o "$_ovr" '
		. as $T | ($o.tools // {}) | keys[] as $k | select($T | has($k) | not) | $k' 2>/dev/null || true)
	[ -z "$_unknown" ] || ep__die_cfg "tool-policy override references unknown tool(s) not declared by the profile: $(printf '%s' "$_unknown" | tr '\n' ' ') (typo? alpha does not allow undeclared override tools)"

	# (A1) no-downgrade: reject weakening of required/one-of unless waived; never
	# weaken a non-suppressible control even with a waiver.
	_waived_keys=""
	if [ -n "$_wf" ] && command -v cw_valid_keys >/dev/null 2>&1; then
		_waived_keys=$(cw_valid_keys "$_wf") || ep__die_cfg "invalid control-waivers file: $_wf"
	fi
	for _k in $(printf '%s' "$_ovr" | jq -r '(.tools // {}) | keys[]'); do
		_cur=$(printf '%s' "$_tools" | jq -r --arg k "$_k" '.[$k].policy // "-"')
		_new=$(printf '%s' "$_ovr" | jq -r --arg k "$_k" '.tools[$k].policy')
		_rc=$(ep__rank "$_cur"); _rn=$(ep__rank "$_new")
		[ "$_rn" -ge "$_rc" ] && continue        # strengthen or equal: always allowed
		# weakening: only blocked when the CURRENT control is required or one-of.
		case "$_cur" in
			required | one-of)
				case " $EP_NON_SUPPRESSIBLE " in
					*" $_k "*) ep__die_cfg "tool-policy override may not weaken non-suppressible control '$_k' ($_cur -> $_new)" ;;
				esac
				case "
$_waived_keys
" in
					*"
$_k
"*) EP_DIAG="${EP_DIAG}override weakens '$_k' ($_cur -> $_new) under control-waiver
" ;;
					*) ep__die_cfg "tool-policy override may not weaken required/one-of control '$_k' ($_cur -> $_new) without a valid control-waiver" ;;
				esac ;;
		esac
	done

	printf '%s' "$_tools" | jq --argjson o "$_ovr" '
		. as $t
		| reduce (($o.tools // {}) | to_entries[]) as $e ($t;
			if has($e.key) then .[$e.key].policy = $e.value.policy else . end)'
}

# ep__one_of_groups <tools-json> — derive explicit one-of groups. A GROUP is a
# one-of tool whose key is NOT listed as an alternative of any other one-of tool
# (e.g. `tests`); the alternatives are member tools (e.g. pest/phpunit). Members
# keep their own entries for provisioning/execution.
ep__one_of_groups() {
	printf '%s' "$1" | jq '
		(to_entries | map(select(.value.policy=="one-of"))) as $oneofs
		| ([ $oneofs[] | .value.alternatives // [] ] | add // []) as $members
		| reduce ($oneofs[] | select(.key as $k | ($members | index($k)) | not)) as $g ({};
			.[$g.key] = {
				policy: "required",
				alternatives: ($g.value.alternatives // []),
				selection: ($g.value.selection // "prefer-existing"),
				fallback_order: ($g.value.fallback_order // ($g.value.alternatives // [])),
				status: "unknown", selected: null, available: []
			})'
}

# ep__exe_present <target> <tools-json> <key> — true if any of a tool's candidate
# executables resolves under <target> or on PATH.
ep__exe_present() {
	_t="$1"; _tj="$2"; _k="$3"
	for _e in $(printf '%s' "$_tj" | jq -r --arg k "$_k" '(.[$k].executable // [])[]' 2>/dev/null); do
		case "$_e" in
			/*) [ -x "$_e" ] && return 0 ;;
			*/*) [ -x "$_t/$_e" ] && return 0 ;;
			*) command -v "$_e" >/dev/null 2>&1 && return 0; [ -x "$_t/$_e" ] && return 0 ;;
		esac
	done
	return 1
}

# ep__applicability <target> <tools-json> <key> — applicable | not-applicable |
# unknown. Built-in conditional rules (documented in docs/workflow-execution-model.md):
#   typescript        -> requires a tsconfig*.json in target
#   phpstan-doctrine  -> requires a doctrine/* package in composer.lock
# Everything else is `applicable` when a target is given, else `unknown`.
ep__applicability() {
	_t="$1"; _k="$3"
	[ -n "$_t" ] && [ -d "$_t" ] || { printf 'unknown'; return 0; }
	case "$_k" in
		typescript)
			if ls "$_t"/tsconfig*.json >/dev/null 2>&1; then printf 'applicable'; else printf 'not-applicable'; fi ;;
		phpstan-doctrine)
			if [ -f "$_t/composer.lock" ] && grep -q '"doctrine/' "$_t/composer.lock" 2>/dev/null; then printf 'applicable'; else printf 'not-applicable'; fi ;;
		*) printf 'applicable' ;;
	esac
}

# ep__validate_policies <manifest-path> — fail-closed on any invalid policy value.
ep__validate_policies() {
	_bp=$(jq -r '
		(.tools // {}) | to_entries[]
		| select((.value.policy // "") | IN("required","recommended","optional","one-of","disabled","external") | not)
		| .key' "$1" 2>/dev/null || true)
	[ -z "$_bp" ] || ep__die_cfg "invalid policy value for tool(s) in $1: $(printf '%s' "$_bp" | tr '\n' ' ')"
}

# ep_resolve <profile> [override-json-file] [target] [waivers-file] — emit the
# effective profile for a NAMED profile (resolved under profiles/).
ep_resolve() {
	command_exists jq || ep__die_cfg "effective-profile: jq is required."
	[ -n "${1:-}" ] || ep__die_cfg "ep_resolve: missing profile name."
	_profile="$1"; _ovrfile="${2:-}"; _target="${3:-}"; EP_WAIVERS_FILE="${4:-}"
	_root=$(ep__repo_root) || ep__die_cfg "effective-profile: cannot locate repo root (no profiles/); set EP_REPO_ROOT."
	EP_CHAIN=""; EP_VISITING=""; EP_RESOLVED=""; EP_DIAG=""
	ep__collect "$_root" "$_profile" ""
	_topmf=$(ep__manifest_path "$_root" "$_profile")
	# shellcheck disable=SC2086
	ep__finish "$_profile" "$_topmf" "$_ovrfile" "$_target" $EP_CHAIN
}

# ep_resolve_manifest <manifest-file> [override-json-file] [target] — emit the
# effective profile for an arbitrary manifest FILE (e.g. a test fixture not under
# profiles/). Its `extends` still resolve BY NAME against the repo, through the
# SAME collect/merge/fail-closed path as ep_resolve — there is no second
# composition algorithm (Significant fix 11).
ep_resolve_manifest() {
	command_exists jq || ep__die_cfg "effective-profile: jq is required."
	[ -n "${1:-}" ] && [ -f "$1" ] || ep__die_cfg "ep_resolve_manifest: manifest file not found: ${1:-}"
	_mf="$1"; _ovrfile="${2:-}"; _target="${3:-}"; EP_WAIVERS_FILE="${4:-}"
	jq -e . "$_mf" >/dev/null 2>&1 || ep__die_cfg "invalid JSON in manifest: $_mf"
	_root=$(ep__repo_root) || ep__die_cfg "effective-profile: cannot locate repo root (no profiles/); set EP_REPO_ROOT."
	_profile=$(jq -r '.profile // "unknown"' "$_mf")
	EP_CHAIN=""; EP_VISITING=""; EP_RESOLVED=""; EP_DIAG=""
	EP_VISITING=" $_profile "        # guard self-reference in the seed's extends
	ep__validate_policies "$_mf"
	for _parent in $(jq -r '.extends[]? // empty' "$_mf"); do
		ep__collect "$_root" "$_parent" "$_profile -> "
	done
	# seed manifest merges LAST (most specific), like the child in ep__collect.
	EP_CHAIN="$EP_CHAIN $_mf"
	# shellcheck disable=SC2086
	ep__finish "$_profile" "$_mf" "$_ovrfile" "$_target" $EP_CHAIN
}

# ep__finish <profile> <top-manifest> <override-file> <target> <chain...> — the
# ONE merge+override+annotate+groups+emit tail shared by both entry points.
ep__finish() {
	_profile="$1"; _topmf="$2"; _ovrfile="$3"; _target="$4"; shift 4
	_extends=$(jq -c '.extends // []' "$_topmf")
	_tpv=$(jq '.tool_policy_version // null' "$_topmf")

	# shellcheck disable=SC2086
	_tools=$(ep__merge_tools "$@")

	# Project override (already JSON; the caller converts YAML→JSON + schema-validates).
	_ovr=""
	if [ -n "$_ovrfile" ] && [ -f "$_ovrfile" ]; then
		jq -e . "$_ovrfile" >/dev/null 2>&1 || ep__die_cfg "invalid tool-policy override JSON: $_ovrfile"
		jq -e '.tools | type == "object"' "$_ovrfile" >/dev/null 2>&1 || ep__die_cfg "invalid tool-policy override (missing/!object 'tools'): $_ovrfile"
		_ovr=$(cat "$_ovrfile")
	fi
	_tools=$(ep__apply_override "$_tools" "$_ovr" "${EP_WAIVERS_FILE:-}")

	# Annotate applicability per tool.
	_annot="{}"
	for _k in $(printf '%s' "$_tools" | jq -r 'keys[]'); do
		_app=$(ep__applicability "$_target" "$_tools" "$_k")
		_annot=$(printf '%s' "$_tools" | jq --argjson acc "$_annot" --arg k "$_k" --arg app "$_app" \
			'$acc + {($k): (.[$k] + {applicability: $app})}')
	done
	_tools="$_annot"

	# one-of groups (+ satisfaction when a target is given).
	_groups=$(ep__one_of_groups "$_tools")
	if [ -n "$_target" ] && [ -d "$_target" ]; then
		for _g in $(printf '%s' "$_groups" | jq -r 'keys[]'); do
			_avail=""
			for _m in $(printf '%s' "$_groups" | jq -r --arg g "$_g" '.[$g].fallback_order[]'); do
				if ep__exe_present "$_target" "$_tools" "$_m"; then _avail="$_avail $_m"; fi
			done
			_sel=$(printf '%s' "$_groups" | jq -r --arg g "$_g" --arg av "$_avail" '
				($av | split(" ") | map(select(length>0))) as $A
				| (.[$g].fallback_order[] | select(. as $x | $A | index($x)) ) // empty' | head -n1)
			_status="unsatisfied"; [ -n "$_sel" ] && _status="satisfied"
			# shellcheck disable=SC2086
			_avjson=$(printf '%s\n' $_avail | jq -R . | jq -s 'map(select(length>0))')
			_groups=$(printf '%s' "$_groups" | jq --arg g "$_g" --arg st "$_status" --arg sel "$_sel" --argjson av "$_avjson" \
				'.[$g] |= (.status=$st | .selected=(if $sel=="" then null else $sel end) | .available=$av)')
		done
	fi

	# diagnostics array
	# shellcheck disable=SC2046
	_diagjson=$(printf '%s' "$EP_DIAG" | jq -R . | jq -s 'map(select(length>0))')

	jq -n \
		--arg profile "$_profile" \
		--argjson tpv "$_tpv" \
		--argjson extends "$_extends" \
		--argjson tools "$_tools" \
		--argjson groups "$_groups" \
		--argjson diag "$_diagjson" \
		'{profile:$profile, tool_policy_version:$tpv, extends:$extends, tools:$tools, one_of_groups:$groups, diagnostics:$diag}'
}
