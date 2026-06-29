#!/bin/sh
# Sentinel Shield — upgrade planner. MUTATES NOTHING.
#
# Compares an installed Sentinel Shield baseline against a target version/profile
# and emits a human- or machine-readable upgrade plan: SS version delta, profile
# tool-policy schema drift, managed files that sync will overwrite, project-owned
# files/configs sync will preserve, required-tool changes, dependency
# requirements, workflow changes, and breaking-change / action-item heuristics.
#
# READ-ONLY: the ONLY thing this writes is the optional --output report file.
# It never touches the project, the source tree, or the install record.
#
# Usage:
#   plan-upgrade.sh --from <ver> --to <ver> --profile <name> \
#                   [--format text|markdown|json] [--output <path>] [--target <dir>]
#
#   --from <ver>     Currently installed Sentinel Shield version (e.g. 1.8.0).
#   --to <ver>       Target Sentinel Shield version (e.g. 1.9.1).
#   --profile <name> Profile to plan against (manifest under profiles/).
#   --format <fmt>   Report format: text (default), markdown, or json.
#   --output <path>  Write the report to <path> instead of stdout (the ONLY write).
#   --target <dir>   Optional consuming project dir; if it has
#                    .sentinel-shield/installation.json, its installed
#                    profile_schema + enabled_tools sharpen the diff.
#   -h, --help       Show help.
#
# Exit: 0 plan produced; 2 invalid invocation / missing jq / unknown profile.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/installation-metadata.sh
. "$SCRIPT_DIR/lib/installation-metadata.sh"

FROM=""; TO=""; PROFILE=""; FORMAT="text"; OUTPUT=""; TARGET=""

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: plan-upgrade.sh --from <ver> --to <ver> --profile <name>
                       [--format text|markdown|json] [--output <path>] [--target <dir>]
Read-only upgrade planner. Writes nothing except the optional --output report.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--from)    FROM="${2:?--from requires a value}"; shift 2 ;;
		--to)      TO="${2:?--to requires a value}"; shift 2 ;;
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--format)  FORMAT="${2:?--format requires a value}"; shift 2 ;;
		--output)  OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--target)  TARGET="${2:?--target requires a value}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage; exit 2 ;;
	esac
done

[ -n "$FROM" ]    || { log_error "--from is required"; usage; exit 2; }
[ -n "$TO" ]      || { log_error "--to is required"; usage; exit 2; }
[ -n "$PROFILE" ] || { log_error "--profile is required"; usage; exit 2; }
case "$FORMAT" in text|markdown|json) ;; *) log_error "invalid --format '$FORMAT' (text|markdown|json)"; exit 2 ;; esac
command_exists jq || { log_error "jq is required"; exit 2; }

# Locate the target-version profile manifest (same lookup as sync-baseline.sh).
MANIFEST=""
for cand in "profiles/$PROFILE/profile.manifest.json" "profiles/combinations/$PROFILE.manifest.json"; do
	[ -f "$ROOT/$cand" ] && { MANIFEST="$ROOT/$cand"; break; }
done
[ -n "$MANIFEST" ] || { log_error "no manifest for profile '$PROFILE' (looked in profiles/$PROFILE/ and profiles/combinations/)"; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { log_error "manifest not valid JSON: $MANIFEST"; exit 2; }

# Installed side (optional): read profile_schema + enabled_tools from the record.
INSTALLED_SCHEMA="null"
INSTALLED_ENABLED="[]"
if [ -n "$TARGET" ] && im_exists "$TARGET"; then
	_s=$(im_get_profile_schema "$TARGET" || true)
	[ -n "$_s" ] && INSTALLED_SCHEMA="$_s"
	INSTALLED_ENABLED=$(jq -c '(.enabled_tools // [])' "$(im_path "$TARGET")" 2>/dev/null || echo '[]')
fi

# Major-version bump heuristic (first dotted component).
_from_major=$(printf '%s' "$FROM" | cut -d. -f1)
_to_major=$(printf '%s' "$TO" | cut -d. -f1)
MAJOR_BUMP=false
[ "$_from_major" != "$_to_major" ] && MAJOR_BUMP=true

# --- build the plan JSON from the manifest (pure read) -----------------------
PLAN=$(jq -n \
	--arg from "$FROM" \
	--arg to "$TO" \
	--arg profile "$PROFILE" \
	--argjson major_bump "$MAJOR_BUMP" \
	--argjson installed_schema "$INSTALLED_SCHEMA" \
	--argjson installed_enabled "$INSTALLED_ENABLED" \
	--slurpfile m "$MANIFEST" '
	($m[0]) as $man
	| (($man.files // []) + ($man.workflows // []) + ($man.docs // [])) as $entries
	| ($man.tool_policy_version // 0) as $target_schema
	| ([ $entries[] | select(.mode == "overwrite-if-force" or .mode == "sync-managed-block") | .target ]) as $managed
	| ([ $entries[] | select(.mode == "create-if-missing") | .target ]) as $owned
	| ([ $entries[] | select(.mode == "manual") | .target ]) as $manual
	| (($man.tools // {}) | to_entries) as $tools
	| ([ $tools[] | select(.value.policy == "required") | .key ]) as $required
	| ([ $tools[] | select(.value.config != null) | { path: .value.config.path, classification: (.value.config.classification // "unknown") } ]) as $configs
	| ([ $tools[] as $t | ($t.value.packages // [])[] | { tool: $t.key, name: .name, scope: (.scope // "dev"), compatibility: (.compatibility // "auto") } ]) as $deps
	| ([ $required[] | select(. as $r | ($installed_enabled | index($r)) == null) ]) as $added
	| ([ $installed_enabled[] | select(. as $e | (($man.tools // {}) | has($e)) | not) ]) as $removed
	| ($installed_schema != null and $installed_schema != $target_schema) as $schema_drift
	| {
		sentinel_shield: { from: $from, to: $to, major_bump: $major_bump },
		profile: $profile,
		profile_schema: { installed: $installed_schema, target: $target_schema, drift: $schema_drift },
		managed_files: $managed,
		project_owned_files: ($owned + [ $configs[] | select(.classification == "create-if-missing" or .classification == "never-touch" or .classification == "project-owned") | .path ] | unique),
		manual_files: $manual,
		required_tools: $required,
		tool_changes: { added: $added, removed: $removed },
		project_owned_configs: $configs,
		dependency_requirements: $deps,
		workflow_changes: [ ($man.workflows // [])[] | { source: .source, target: .target, mode: .mode } ],
		breaking_changes: (
			(if $major_bump then ["Major version change \($from) -> \($to): review the CHANGELOG for breaking changes before applying."] else [] end)
			+ (if $schema_drift then ["Profile tool-policy schema changed \($installed_schema) -> \($target_schema): the tool-policy vocabulary may have changed; re-check .sentinel-shield/tool-policy.yaml overrides."] else [] end)
		),
		action_items: (
			(if ($managed | length) > 0 then ["Run scripts/sync-baseline.sh --target <dir> --profile \($profile) --apply --force to update \($managed | length) managed file(s) after review."] else [] end)
			+ (if ($added | length) > 0 then ["Bootstrap newly-required tool(s): " + ($added | join(", ")) + " (scripts/bootstrap-profile-tools.sh)."] else [] end)
			+ (if ($removed | length) > 0 then ["Tool(s) no longer in the profile: " + ($removed | join(", ")) + " — review whether to remove their config/packages."] else [] end)
		)
	}')

# --- render -------------------------------------------------------------------
render_text() { # render_text <markdown:0|1>
	_md="$1"
	if [ "$_md" = "1" ]; then _h1='# '; _h2='## '; _li='- '; else _h1=''; _h2=''; _li='  - '; fi
	printf '%sSentinel Shield upgrade plan\n' "$_h1"
	printf '%sVersion: %s -> %s%s\n' "$_li" \
		"$(printf '%s' "$PLAN" | jq -r '.sentinel_shield.from')" \
		"$(printf '%s' "$PLAN" | jq -r '.sentinel_shield.to')" \
		"$(printf '%s' "$PLAN" | jq -r 'if .sentinel_shield.major_bump then "  (MAJOR bump)" else "" end')"
	printf '%sProfile: %s\n' "$_li" "$(printf '%s' "$PLAN" | jq -r '.profile')"
	printf '%sProfile tool-policy schema: %s -> %s%s\n' "$_li" \
		"$(printf '%s' "$PLAN" | jq -r '.profile_schema.installed // "unknown"')" \
		"$(printf '%s' "$PLAN" | jq -r '.profile_schema.target')" \
		"$(printf '%s' "$PLAN" | jq -r 'if .profile_schema.drift then "  (DRIFT)" else "" end')"
	printf '\n'

	printf '%sManaged files (sync overwrites with --apply --force)\n' "$_h2"
	printf '%s' "$PLAN" | jq -r --arg li "$_li" '(.managed_files[]? | "\($li)\(.)" ) // empty'
	printf '%s' "$PLAN" | jq -e '.managed_files | length > 0' >/dev/null 2>&1 || printf '%s(none)\n' "$_li"
	printf '\n'

	printf '%sProject-owned (preserved, never overwritten)\n' "$_h2"
	printf '%s' "$PLAN" | jq -r --arg li "$_li" '(.project_owned_files[]? | "\($li)\(.)" ) // empty'
	printf '%s' "$PLAN" | jq -e '.project_owned_files | length > 0' >/dev/null 2>&1 || printf '%s(none)\n' "$_li"
	printf '\n'

	printf '%sRequired tools\n' "$_h2"
	printf '%s' "$PLAN" | jq -r --arg li "$_li" '(.required_tools[]? | "\($li)\(.)" ) // empty'
	printf '\n'

	printf '%sTool changes vs installed\n' "$_h2"
	printf '%sadded:   %s\n' "$_li" "$(printf '%s' "$PLAN" | jq -r '(.tool_changes.added | join(", ")) | if . == "" then "(none)" else . end')"
	printf '%sremoved: %s\n' "$_li" "$(printf '%s' "$PLAN" | jq -r '(.tool_changes.removed | join(", ")) | if . == "" then "(none)" else . end')"
	printf '\n'

	printf '%sDependency requirements\n' "$_h2"
	printf '%s' "$PLAN" | jq -r --arg li "$_li" '(.dependency_requirements[]? | "\($li)\(.tool): \(.name) [\(.scope), \(.compatibility)]") // empty'
	printf '%s' "$PLAN" | jq -e '.dependency_requirements | length > 0' >/dev/null 2>&1 || printf '%s(none)\n' "$_li"
	printf '\n'

	printf '%sWorkflow changes\n' "$_h2"
	printf '%s' "$PLAN" | jq -r --arg li "$_li" '(.workflow_changes[]? | "\($li)\(.target) [\(.mode)]") // empty'
	printf '%s' "$PLAN" | jq -e '.workflow_changes | length > 0' >/dev/null 2>&1 || printf '%s(none)\n' "$_li"
	printf '\n'

	printf '%sBreaking changes\n' "$_h2"
	printf '%s' "$PLAN" | jq -r --arg li "$_li" '(.breaking_changes[]? | "\($li)\(.)") // empty'
	printf '%s' "$PLAN" | jq -e '.breaking_changes | length > 0' >/dev/null 2>&1 || printf '%s(none)\n' "$_li"
	printf '\n'

	printf '%sAction items\n' "$_h2"
	printf '%s' "$PLAN" | jq -r --arg li "$_li" '(.action_items[]? | "\($li)\(.)") // empty'
	printf '%s' "$PLAN" | jq -e '.action_items | length > 0' >/dev/null 2>&1 || printf '%s(none)\n' "$_li"
}

# emit — emit a formatted output fragment to stdout.
emit() {
	case "$FORMAT" in
		json)     printf '%s\n' "$PLAN" | jq . ;;
		markdown) render_text 1 ;;
		text)     render_text 0 ;;
	esac
}

if [ -n "$OUTPUT" ]; then
	ensure_dir "$(dirname -- "$OUTPUT")"
	emit > "$OUTPUT"
	log_info "plan-upgrade: wrote $FORMAT report to $OUTPUT"
else
	emit
fi
