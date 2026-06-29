#!/bin/sh
# Sentinel Shield — gate resolver.
#
# Reads a consuming project's .sentinel-shield/profile.yaml and resolves it into
# normalized, machine-readable gate thresholds that CI can enforce.
#
# Design goals: strict, boring, explicit, predictable.
#   - POSIX sh only (no Bash arrays / [[ ]] / local).
#   - No hard dependency on jq/yq/Python. Uses mikefarah `yq` v4 if present,
#     otherwise a limited awk/sed parser for the CANONICAL profile format only.
#   - Resolution order: built-in mode defaults -> profile overrides.
#   - Invalid mode or invalid boolean values fail with a clear error.
#
# See docs/gate-resolution.md for full documentation.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

# die_cfg <message...> — configuration/input/parsing error -> exit 2 (the STABLE engine convention,
# matching enforce-gates.sh / build-security-summary.sh / select-security-summary.sh). v1.0.0-rc.1
# soak fix: resolve-gates previously exited 1 on config errors, contradicting product-contract §1
# ("2 = config-or-input error, across the engine scripts").
die_cfg() {
	log_error "$*"
	exit 2
}

# Canonical fail_on keys, in stable output order.
FAIL_ON_KEYS="secrets critical_vulnerabilities high_vulnerabilities medium_vulnerabilities architecture_violations type_errors test_failures unsafe_docker unsafe_github_actions missing_sbom missing_release_evidence expired_exceptions third_party_suspicious_code third_party_install_script_risk third_party_obfuscation third_party_network_behavior php_syntax_errors style_violations dependency_policy_violations iac_violations container_image_violations dast_findings repository_health_warnings ai_review_findings"

VALID_MODES="report-only baseline strict regulated"

# --- defaults / CLI ----------------------------------------------------------
PROFILE=".sentinel-shield/profile.yaml"
MODE_CLI=""
OUTPUT_DIR_CLI=""
FORMAT="all"
REQUIRE_PROFILE=0

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: resolve-gates.sh [options]

Resolve .sentinel-shield/profile.yaml into machine-readable gate thresholds.

Options:
  --profile <path>     Path to profile.yaml (default: .sentinel-shield/profile.yaml)
  --mode <mode>        Force adoption mode: report-only | baseline | strict | regulated
                       (overrides the profile's gates.mode)
  --output-dir <path>  Output directory for generated artifacts (default: reports,
                       or reports.output_dir from the profile)
  --format <fmt>       markdown | env | json | all   (default: all)
  --require-profile    Fail if the profile file is missing (default: fall back to
                       report-only defaults when absent)
  -h, --help           Show this help

Generated artifacts (depending on --format):
  <output-dir>/sentinel-shield-gates.env
  <output-dir>/sentinel-shield-gates.json
  <output-dir>/sentinel-shield-gates.md

Exit: 0 success, 2 config-or-input error (invalid mode, invalid boolean values, an
unparseable profile, a missing profile when --require-profile is set, or a bad flag).
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--mode) MODE_CLI="${2:?--mode requires a value}"; shift 2 ;;
		--output-dir) OUTPUT_DIR_CLI="${2:?--output-dir requires a value}"; shift 2 ;;
		--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
		--require-profile) REQUIRE_PROFILE=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die_cfg "unknown argument: $1" ;;
	esac
done

case "$FORMAT" in
	markdown | env | json | all) ;;
	*) die_cfg "invalid --format '$FORMAT' (expected: markdown | env | json | all)" ;;
esac

# --- profile presence + parser selection ------------------------------------
PROFILE_EXISTS=0
if [ -f "$PROFILE" ]; then
	PROFILE_EXISTS=1
elif [ "$REQUIRE_PROFILE" -eq 1 ]; then
	die_cfg "profile not found: '$PROFILE' (and --require-profile was set)"
else
	log_warn "profile '$PROFILE' not found; using report-only defaults"
fi

# Prefer mikefarah yq v4 only. Other 'yq' implementations differ; use the fallback.
USE_YQ=0
if [ "$PROFILE_EXISTS" -eq 1 ] && command_exists yq; then
	if yq --version 2>/dev/null | grep -Eq 'mikefarah|version v4'; then
		USE_YQ=1
	fi
fi

FLATTENED=""
if [ "$PROFILE_EXISTS" -eq 1 ] && [ "$USE_YQ" -eq 0 ]; then
	# Fallback mode: detect unsupported YAML features before trusting the parser.
	# Scan non-comment lines for anchors, aliases, flow collections, block scalars,
	# and quoted booleans. If found, mikefarah yq v4 is required.
	if grep -v '^[[:space:]]*#' "$PROFILE" \
		| grep -Eq '(^|[[:space:]])&[A-Za-z0-9_]|:[[:space:]]*\*[A-Za-z0-9_]|:[[:space:]]*[{[]|:[[:space:]]*[|>]([[:space:]]|$)|:[[:space:]]*["'"'"'](true|false|yes|no|on|off)["'"'"']'; then
		die_cfg "profile uses advanced YAML (anchors/aliases/inline collections/block scalars/quoted booleans). Install mikefarah yq v4 to parse it, or simplify to the canonical format (see templates/profile.yaml)."
	fi

	# Flatten the canonical YAML to dotted path=value lines (and parent.[]=value for
	# list items). awk arrays are fine; the POSIX-sh constraint applies to the shell.
	FLATTENED=$(awk '
		function joinpath(last,    i, p) {
			p = ""
			for (i = 0; i <= last; i++) {
				if (stack[i] == "") continue
				p = (p == "") ? stack[i] : p "." stack[i]
			}
			return p
		}
		{
			line = $0
			if (line ~ /^[[:space:]]*#/) next
			if (line ~ /^[[:space:]]*$/) next
			match(line, /^ */); indent = RLENGTH; depth = int(indent / 2)
			content = substr(line, indent + 1)
			if (substr(content, 1, 2) == "- ") {
				val = substr(content, 3)
				sub(/[[:space:]]+#.*$/, "", val)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
				print joinpath(depth - 1) ".[]=" val
				next
			}
			ci = index(content, ":")
			if (ci == 0) next
			key = substr(content, 1, ci - 1)
			val = substr(content, ci + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
			sub(/[[:space:]]+#.*$/, "", val)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
			for (k = depth; k <= 50; k++) stack[k] = ""
			stack[depth] = key
			if (val != "") print joinpath(depth) "=" val
		}
	' "$PROFILE")
fi

# --- value accessors ---------------------------------------------------------
# get_scalar <dotted.path> — echo the scalar value, or empty string if absent.
get_scalar() {
	if [ "$PROFILE_EXISTS" -eq 0 ]; then
		return 0
	fi
	if [ "$USE_YQ" -eq 1 ]; then
		# NOTE: do not use yq's `// ""` alternative operator — it treats a boolean
		# `false` as empty and would drop legitimate `false` gate values. Read the
		# path directly and map the literal `null` (missing key) to empty.
		_v=$(yq e ".$1" "$PROFILE" 2>/dev/null || true)
		[ "$_v" = "null" ] && _v=""
		printf '%s' "$_v"
	else
		printf '%s\n' "$FLATTENED" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}'
	fi
}

# get_list <dotted.path> — echo list items (one per line), or nothing if absent.
get_list() {
	if [ "$PROFILE_EXISTS" -eq 0 ]; then
		return 0
	fi
	if [ "$USE_YQ" -eq 1 ]; then
		yq e ".$1[]?" "$PROFILE" 2>/dev/null || true
	else
		printf '%s\n' "$FLATTENED" | awk -F= -v k="$1.[]" '$1==k{sub(/^[^=]*=/,"");print}'
	fi
}

# --- mode resolution ---------------------------------------------------------
MODE_PROFILE=""
if [ "$PROFILE_EXISTS" -eq 1 ]; then
	MODE_PROFILE=$(get_scalar "gates.mode")
fi

if [ -n "$MODE_CLI" ]; then
	MODE="$MODE_CLI"
elif [ -n "$MODE_PROFILE" ]; then
	MODE="$MODE_PROFILE"
else
	MODE="report-only"
fi

# Validate mode against the allow-list.
_mode_ok=0
for _m in $VALID_MODES; do
	[ "$_m" = "$MODE" ] && _mode_ok=1
done
[ "$_mode_ok" -eq 1 ] || die_cfg "invalid mode '$MODE' (expected one of: $VALID_MODES)"

# mode_description — human-readable description of an adoption mode.
mode_description() {
	case "$1" in
		report-only) printf 'Legacy visibility mode. Only leaked secrets and expired exceptions block.' ;;
		baseline) printf 'Migration mode. Existing debt may remain, but new high-risk issues do not enter.' ;;
		strict) printf 'Production mode. Security, quality, architecture, and SBOM evidence are release requirements.' ;;
		regulated) printf 'Compliance-heavy mode. Release evidence and SBOM are mandatory.' ;;
	esac
}

# default_for <mode> <key> — built-in default boolean for a gate.
default_for() {
	case "$1" in
		report-only)
			case "$2" in
				secrets | expired_exceptions) printf 'true' ;;
				*) printf 'false' ;;
			esac
			;;
		baseline)
			case "$2" in
				# v1: third-party supply-chain findings are visible but non-blocking
				# in baseline (and report-only) — they need triage tuning first.
				# v0.1.12: in baseline, php_syntax_errors + dependency_policy_violations DO
				# block (fall through to *); style/IaC/container/DAST/repo-health/AI stay
				# visible but non-blocking (listed false below), as do third-party signals.
				medium_vulnerabilities | missing_sbom | missing_release_evidence \
				| third_party_suspicious_code | third_party_install_script_risk \
				| third_party_obfuscation | third_party_network_behavior \
				| style_violations | iac_violations | dast_findings \
				| container_image_violations | repository_health_warnings | ai_review_findings) printf 'false' ;;
				*) printf 'true' ;;
			esac
			;;
		strict)
			case "$2" in
				# strict blocks higher-confidence third-party signals + (v0.1.12) style,
				# IaC, and container-image checks (fall through to *). DAST + repo-health
				# remain regulated-only; AI review is never gating by default.
				missing_release_evidence | third_party_suspicious_code | third_party_obfuscation \
				| dast_findings | repository_health_warnings | ai_review_findings) printf 'false' ;;
				*) printf 'true' ;;
			esac
			;;
		regulated)
			case "$2" in
				# v0.1.12: AI review findings stay NON-gating even in regulated unless the
				# profile explicitly sets gates.fail_on.ai_review_findings: true.
				ai_review_findings) printf 'false' ;;
				*) printf 'true' ;;
			esac
			;;
	esac
}

# resolve_key <key> — resolved boolean (default overridden by profile). Dies on
# an invalid boolean override value.
resolve_key() {
	_def=$(default_for "$MODE" "$1")
	_p=$(get_scalar "gates.fail_on.$1")
	if [ -n "$_p" ]; then
		_n=$(bool_value "$_p") || die_cfg "invalid boolean for gates.fail_on.$1: '$_p' (use true/false)"
		printf '%s' "$_n"
	else
		printf '%s' "$_def"
	fi
}

# Compute the override list once: "key|resolved|default" per line (only differences).
OVERRIDES=""
for key in $FAIL_ON_KEYS; do
	_def=$(default_for "$MODE" "$key")
	_p=$(get_scalar "gates.fail_on.$key")
	if [ -n "$_p" ]; then
		_n=$(bool_value "$_p") || die_cfg "invalid boolean for gates.fail_on.$key: '$_p' (use true/false)"
		if [ "$_n" != "$_def" ]; then
			OVERRIDES="${OVERRIDES}${key}|${_n}|${_def}
"
		fi
	fi
done

# --- project + output metadata ----------------------------------------------
P_NAME=$(get_scalar "project.name"); [ -n "$P_NAME" ] || P_NAME="unknown"
P_TYPE=$(get_scalar "project.type"); [ -n "$P_TYPE" ] || P_TYPE="unknown"
P_CRIT=$(get_scalar "project.criticality"); [ -n "$P_CRIT" ] || P_CRIT="unknown"
P_OWNER=$(get_scalar "project.owner"); [ -n "$P_OWNER" ] || P_OWNER="unknown"
PROFILES_LIST=$(get_list "profiles" | tr '\n' ' ' | sed 's/[[:space:]]*$//')

if [ -n "$OUTPUT_DIR_CLI" ]; then
	OUTPUT_DIR="$OUTPUT_DIR_CLI"
else
	_od=$(get_scalar "reports.output_dir")
	if [ -n "$_od" ]; then OUTPUT_DIR="$_od"; else OUTPUT_DIR="reports"; fi
fi

TS=$(timestamp_utc)
ensure_dir "$OUTPUT_DIR"

# --- human summary to stderr (overrides are never hidden) --------------------
log_info "Mode: $MODE"
log_info "Profile: $PROFILE (exists=$PROFILE_EXISTS, yq=$USE_YQ)"
if [ -n "$OVERRIDES" ]; then
	printf '%s' "$OVERRIDES" | while IFS='|' read -r k v d; do
		[ -n "$k" ] || continue
		log_info "Override: $k=$v (default $d)"
	done
else
	log_info "Overrides: none"
fi

# --- writers -----------------------------------------------------------------
write_env() {
	_f="$OUTPUT_DIR/sentinel-shield-gates.env"
	{
		printf 'SENTINEL_SHIELD_MODE=%s\n' "$MODE"
		printf 'SENTINEL_SHIELD_PROJECT_NAME=%s\n' "$P_NAME"
		printf 'SENTINEL_SHIELD_PROJECT_TYPE=%s\n' "$P_TYPE"
		printf 'SENTINEL_SHIELD_PROJECT_CRITICALITY=%s\n' "$P_CRIT"
		printf 'SENTINEL_SHIELD_PROJECT_OWNER=%s\n' "$P_OWNER"
		for key in $FAIL_ON_KEYS; do
			printf 'SENTINEL_SHIELD_FAIL_ON_%s=%s\n' "$(upper "$key")" "$(resolve_key "$key")"
		done
	} > "$_f"
	log_info "wrote $_f"
}

# write_json — write the json output report.
write_json() {
	_f="$OUTPUT_DIR/sentinel-shield-gates.json"
	# Count keys without clobbering the script's positional parameters.
	_total=$(printf '%s\n' $FAIL_ON_KEYS | wc -l | tr -d ' ')
	{
		printf '{\n'
		printf '  "mode": "%s",\n' "$MODE"
		printf '  "generated": "%s",\n' "$TS"
		printf '  "project": {\n'
		printf '    "name": "%s",\n' "$(json_escape "$P_NAME")"
		printf '    "type": "%s",\n' "$(json_escape "$P_TYPE")"
		printf '    "criticality": "%s",\n' "$(json_escape "$P_CRIT")"
		printf '    "owner": "%s"\n' "$(json_escape "$P_OWNER")"
		printf '  },\n'
		printf '  "fail_on": {\n'
		_i=0
		for key in $FAIL_ON_KEYS; do
			_i=$((_i + 1))
			if [ "$_i" -lt "$_total" ]; then _sep=","; else _sep=""; fi
			printf '    "%s": %s%s\n' "$key" "$(resolve_key "$key")" "$_sep"
		done
		printf '  },\n'
		printf '  "overrides": ['
		if [ -n "$OVERRIDES" ]; then
			printf '\n'
			_first=1
			printf '%s' "$OVERRIDES" | (
				_out=""
				while IFS='|' read -r k v d; do
					[ -n "$k" ] || continue
					if [ "$_first" -eq 1 ]; then _first=0; else printf ',\n'; fi
					printf '    { "key": "%s", "value": %s, "default": %s }' "$k" "$v" "$d"
				done
				printf '\n'
			)
			printf '  ]\n'
		else
			printf ']\n'
		fi
		printf '}\n'
	} > "$_f"
	log_info "wrote $_f"
}

# write_markdown — write the markdown output report.
write_markdown() {
	_f="$OUTPUT_DIR/sentinel-shield-gates.md"
	{
		printf '# Sentinel Shield — Resolved Gates\n\n'
		printf -- '- Generated: %s\n' "$TS"
		printf -- '- Mode: **%s**\n' "$MODE"
		printf -- '- Mode description: %s\n' "$(mode_description "$MODE")"
		printf -- '- Profile: `%s` (present: %s, yq: %s)\n\n' "$PROFILE" "$PROFILE_EXISTS" "$USE_YQ"

		printf '## Project\n\n'
		printf -- '| Field | Value |\n| --- | --- |\n'
		printf -- '| name | %s |\n' "$P_NAME"
		printf -- '| type | %s |\n' "$P_TYPE"
		printf -- '| criticality | %s |\n' "$P_CRIT"
		printf -- '| owner | %s |\n' "$P_OWNER"
		printf -- '| profiles | %s |\n\n' "${PROFILES_LIST:-(none)}"

		printf '## Resolved fail_on\n\n'
		printf -- '| Gate | Blocks build? |\n| --- | --- |\n'
		for key in $FAIL_ON_KEYS; do
			printf -- '| %s | %s |\n' "$key" "$(resolve_key "$key")"
		done
		printf '\n'

		printf '## Overrides detected\n\n'
		if [ -n "$OVERRIDES" ]; then
			printf -- '| Gate | Resolved | Mode default |\n| --- | --- | --- |\n'
			printf '%s' "$OVERRIDES" | while IFS='|' read -r k v d; do
				[ -n "$k" ] || continue
				printf -- '| %s | %s | %s |\n' "$k" "$v" "$d"
			done
			printf '\n'
		else
			printf 'None. All gates use the `%s` mode defaults.\n\n' "$MODE"
		fi

		printf '## Next steps\n\n'
		printf -- '1. CI loads `%s/sentinel-shield-gates.env` and enforces each `true` gate.\n' "$OUTPUT_DIR"
		printf -- '2. Map scanner results to these gates (see github/workflows/ci-release-gate.yml).\n'
		printf -- '3. Tighten the mode in `%s` as the project matures (docs/adoption-guide.md).\n' "$PROFILE"
	} > "$_f"
	log_info "wrote $_f"
}

case "$FORMAT" in
	env) write_env ;;
	json) write_json ;;
	markdown) write_markdown ;;
	all) write_env; write_json; write_markdown ;;
esac

log_info "Gate resolution complete (mode=$MODE, output-dir=$OUTPUT_DIR)."
