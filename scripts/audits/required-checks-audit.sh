#!/bin/sh
# Sentinel Shield — required-checks REGISTRY DRIFT audit.
#
# GitHub branch protection matches a check RUN by its name — jobs.<id>.name, or
# the job id when no name is set — NOT by the .github/workflows/*.yml filename
# (docs/branch-protection.md). If a job is renamed, removed, duplicated or a new
# one is added without updating the required-checks configuration, a "required"
# status check silently stops matching and the gate rots open.
#
# This deterministic, fail-CLOSED gate parses the live jobs.<id>.name from every
# .github/workflows/*.yml and diffs the resulting stable check names against the
# canonical registry (config/required-checks.json). It flags:
#
#   renamed              — a registered check disappeared and a new one appeared
#                          in the SAME file (1 missing + 1 unregistered = rename).
#   missing              — a registered check no longer exists in its workflow.
#   unregistered         — a live check name is not in the registry (added w/o
#                          registering).
#   duplicate            — two jobs in ONE file publish the same check name
#                          (ambiguous / collides on the same required check).
#   unregistered-workflow— a shipped workflow file is absent from the registry.
#   missing-workflow     — the registry references a workflow file not on disk.
#   cross-workflow-duplicate — one check NAME is published by more than one workflow. Branch
#                          protection matches required_status_checks contexts by NAME, so a
#                          passing `detect` from one workflow satisfies a requirement that the
#                          `detect` in another workflow never ran for — the gate rots open.
#
# Emits BOTH a human report (STDOUT) and a machine report
# (reports/raw/required-checks-audit.json, per schemas/required-checks-audit.schema.json).
#
# Usage: required-checks-audit.sh [--output <path>] [--registry <path>] [--workflows-dir <dir>]
#   default registry:       config/required-checks.json
#   default workflows-dir:   .github/workflows
#   default output:          reports/raw/required-checks-audit.json
# Exit: 0 = no drift, 1 = drift (fail closed), 2 = config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

ss_require_jq

OUTPUT="reports/raw/required-checks-audit.json"
REGISTRY="config/required-checks.json"
WF_DIR=".github/workflows"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--registry) REGISTRY="${2:?--registry requires a value}"; shift 2 ;;
		--workflows-dir) WF_DIR="${2:?--workflows-dir requires a value}"; shift 2 ;;
		-h | --help)
			printf 'Usage: required-checks-audit.sh [--output <path>] [--registry <path>] [--workflows-dir <dir>]\n'
			exit 0 ;;
		*) log_error "unknown option: $1"; exit 2 ;;
	esac
done

[ -f "$REGISTRY" ] || { log_error "required-checks-audit: registry not found: $REGISTRY"; exit 2; }
jq -e . "$REGISTRY" >/dev/null 2>&1 || { log_error "required-checks-audit: registry is not valid JSON: $REGISTRY"; exit 2; }
[ -d "$WF_DIR" ] || { log_error "required-checks-audit: workflows dir not found: $WF_DIR"; exit 2; }

# --- parse live check names (jobs.<id>.name || <id>) per workflow file --------
# Pure awk job-block walk: under `jobs:`, a value-less 2-space key opens a job;
# a 4-space `name:` (the job display name; step names are deeper, `- name:`)
# overrides the id as the published check name. Emits: <checkname>\t<jobid>.
parse_checks() { # parse_checks <file>
	awk '
		function emit() { if (cur != "") print (jn != "" ? jn : cur) "\t" cur }
		/^jobs:[[:space:]]*$/ { injobs=1; next }
		{
			if (injobs && $0 ~ /^[A-Za-z0-9_.-]+:/) { emit(); cur=""; injobs=0 }
			if (injobs && $0 ~ /^  [A-Za-z0-9_-]+:[[:space:]]*$/) {
				emit()
				line=$0; sub(/^  /,"",line); sub(/:.*/,"",line)
				cur=line; jn=""
			}
			if (injobs && cur != "" && $0 ~ /^    name:[[:space:]]*/) {
				n=$0; sub(/^    name:[[:space:]]*/,"",n)
				sub(/[[:space:]]*$/,"",n)
				sub(/^"/,"",n); sub(/"$/,"",n); sub(/^'\''/,"",n); sub(/'\''$/,"",n)
				jn=n
			}
		}
		END { emit() }
	' "$1"
}

TMP_ACTUAL=$(mktemp)
trap 'rm -f "$TMP_ACTUAL"' EXIT INT TERM

# Build an "actual" JSON object: { "<basename>": ["check", ...(with dups)], ... }
printf '{}' > "$TMP_ACTUAL"
SCANNED=0
for f in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
	[ -f "$f" ] || continue
	SCANNED=$((SCANNED + 1))
	_bn=$(basename "$f")
	# collect check names (may include duplicates) into a JSON array
	_names=$(parse_checks "$f" | cut -f1 | jq -R . | jq -s .)
	[ -n "$_names" ] || _names='[]'
	jq --arg bn "$_bn" --argjson names "$_names" '.[$bn] = $names' "$TMP_ACTUAL" > "$TMP_ACTUAL.next"
	mv "$TMP_ACTUAL.next" "$TMP_ACTUAL"
done

if [ "$SCANNED" -eq 0 ]; then
	log_error "required-checks-audit: no workflow files found under $WF_DIR"
	exit 2
fi

ensure_dir "$(dirname "$OUTPUT")"

# --- diff live vs registry ----------------------------------------------------
REPORT=$(jq -n \
	--slurpfile reg "$REGISTRY" \
	--slurpfile act "$TMP_ACTUAL" \
	--arg ts "$(timestamp_utc)" \
	--argjson scanned "$SCANNED" '
	($reg[0].workflows // {}) as $R
	| $act[0] as $A
	| ([($R | keys[]), ($A | keys[])] | unique) as $files
	| ( [ $files[] as $f
		| ($R[$f] // null) as $rspec
		| ($A[$f] // null) as $araw
		| if $rspec == null then
			# live workflow file not present in the registry
			( ($araw // []) | unique | .[] | {type:"unregistered-workflow", file:$f, name:.} )
		  elif $araw == null then
			{type:"missing-workflow", file:$f, name:null}
		  else
			([ $rspec.checks[].name ] | unique) as $rset
			| ($araw | unique) as $aset
			| ($rset - $aset) as $missing
			| ($aset - $rset) as $added
			| ($araw | group_by(.) | map(select(length > 1) | .[0])) as $dups
			| (
				if ($missing | length) == 1 and ($added | length) == 1 then
					[ {type:"renamed", file:$f, name:$added[0], from:$missing[0]} ]
				else
					([ $missing[] | {type:"missing", file:$f, name:.} ]
					 + [ $added[] | {type:"unregistered", file:$f, name:.} ])
				end
			  )
			+ [ $dups[] | {type:"duplicate", file:$f, name:.} ]
			| .[]
		  end
	  ] | flatten) as $violations
	# CROSS-FILE duplicate check names. The rule above computes duplicates PER FILE, so it only
	# catches two jobs colliding inside one workflow. Four workflows publish a check named
	# `detect` and two publish `workflow-lint`; branch protection matches required contexts BY
	# NAME, so the ci-docker `detect` can satisfy a requirement that the ci-codeql `detect` never
	# ran for — the gate rots open, which is precisely what this registry exists to prevent.
	# docs/branch-protection.md asserts GitHub distinguishes these by originating workflow;
	# that is not how required_status_checks contexts work.
	| ([ $R | to_entries[] | .key as $wf | (.value.checks[]? | {name: .name, file: $wf}) ]
	   | group_by(.name)
	   | map(select(length > 1))
	   | map({type: "cross-workflow-duplicate",
	          name: .[0].name,
	          file: ([ .[].file ] | join(", "))})) as $xdups
	| ($violations + $xdups) as $violations
	| {
		version: "1.0",
		generated_at: $ts,
		tool: "required-checks-audit",
		files_scanned: $scanned,
		checks: ["renamed","missing","unregistered","duplicate","cross-workflow-duplicate","unregistered-workflow","missing-workflow"],
		status: (if ($violations | length) > 0 then "fail" else "pass" end),
		violation_count: ($violations | length),
		violations: ($violations | map(. + {from: (.from // null)}))
	  }
')

printf '%s\n' "$REPORT" > "$OUTPUT"

VIOLATIONS=$(printf '%s' "$REPORT" | jq '.violation_count')

# --- human report -------------------------------------------------------------
printf '\nrequired-checks-audit: scanned %d workflow file(s) in %s\n' "$SCANNED" "$WF_DIR"
if [ "$VIOLATIONS" -gt 0 ]; then
	printf '%s' "$REPORT" | jq -r '.violations[]
		| if .type == "renamed" then
			"VIOLATION: [renamed] \(.file): check \"\(.from)\" -> \"\(.name)\" (update config/required-checks.json + branch protection)"
		  elif .type == "missing" then
			"VIOLATION: [missing] \(.file): registered check \"\(.name)\" no longer exists"
		  elif .type == "unregistered" then
			"VIOLATION: [unregistered] \(.file): live check \"\(.name)\" is not in the registry"
		  elif .type == "duplicate" then
			"VIOLATION: [duplicate] \(.file): check name \"\(.name)\" is published by >1 job"
		  elif .type == "unregistered-workflow" then
			"VIOLATION: [unregistered-workflow] \(.file): workflow (check \"\(.name)\") is not in the registry"
		  elif .type == "cross-workflow-duplicate" then
			"VIOLATION: [cross-workflow-duplicate] check name \"\(.name)\" is published by MORE THAN ONE workflow (\(.file)); branch protection matches required contexts by NAME, so one can satisfy a requirement the other never ran for"
		  else
			"VIOLATION: [missing-workflow] \(.file): registry references a workflow file not on disk"
		  end'
	printf 'required-checks-audit: %d drift finding(s) -> %s\n' "$VIOLATIONS" "$OUTPUT" >&2
	log_error "required-checks-audit: FAIL ($VIOLATIONS drift finding(s))"
	exit 1
fi
printf 'required-checks-audit: PASS (registry in sync with %d workflow file(s)) -> %s\n' "$SCANNED" "$OUTPUT"
log_info "required-checks-audit: PASS"
exit 0
