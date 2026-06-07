#!/bin/sh
# Sentinel Shield — gate enforcer.
#
# Consumes the resolved gate flags (reports/sentinel-shield-gates.env) and a
# normalized findings document (reports/security-summary.json), then decides
# pass/fail per the active SENTINEL_SHIELD_FAIL_ON_* flags.
#
# Design goals: strict, boring, explicit, predictable.
#   - POSIX sh only (no Bash arrays / [[ ]] / local).
#   - The gates .env is NEVER blind-sourced. Each line is validated against a
#     strict allow-list pattern; anything suspicious is rejected (exit 2).
#   - JSON is parsed with jq. Sentinel Shield intentionally does NOT parse JSON
#     with fragile shell hacks; jq is required for enforcement (exit 2 if absent).
#
# Exit codes:
#   0  all active gates pass
#   1  one or more active gates fail
#   2  configuration / input / parsing error
#
# See docs/security-summary-schema.md and docs/gate-resolution.md.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

# die_cfg <message...> — configuration/input/parsing error -> exit 2.
die_cfg() {
	log_error "$*"
	exit 2
}

# Canonical gate keys in stable order. Mapping of gate key -> env suffix is the
# uppercase of the key (handled below).
GATE_KEYS="secrets critical_vulnerabilities high_vulnerabilities medium_vulnerabilities architecture_violations type_errors test_failures unsafe_docker unsafe_github_actions missing_sbom missing_release_evidence expired_exceptions third_party_suspicious_code third_party_install_script_risk third_party_obfuscation third_party_network_behavior"

# Integer summary keys that must be present (the two missing_* are booleans and
# are validated separately).
INT_SUMMARY_KEYS="secrets critical_vulnerabilities high_vulnerabilities medium_vulnerabilities architecture_violations type_errors test_failures unsafe_docker unsafe_github_actions expired_exceptions"

# Third-party supply-chain gates (v0.1.5). Evaluated like count gates, but NOT in the
# required INT_SUMMARY_KEYS set: an older summary that omits them is treated as 0
# (absent), not a config error. v1 defaults keep them non-blocking except in
# strict/regulated (see resolve-gates.sh).
THIRD_PARTY_KEYS="third_party_suspicious_code third_party_install_script_risk third_party_obfuscation third_party_network_behavior"

# --- defaults / CLI ----------------------------------------------------------
GATES_ENV_FILE="reports/sentinel-shield-gates.env"
SUMMARY="reports/security-summary.json"
OUTPUT_DIR="reports"
FORMAT="all"
STRICT_SUMMARY=0
ACCEPTED_RISKS_FILE=".sentinel-shield/accepted-risks.json"

# Gates that an approved accepted-risk record MAY suppress (v0.1.3). Deliberately
# narrow. NEVER suppressible: secrets, expired_exceptions, missing_release_evidence,
# missing_sbom, and the critical/high vuln gates.
SUPPRESSIBLE_GATES="unsafe_docker medium_vulnerabilities"

usage() {
	cat <<'EOF'
Usage: enforce-gates.sh [options]

Enforce resolved gate flags against a normalized security-summary.json.

Options:
  --gates-env <path>   Resolved gate flags (default: reports/sentinel-shield-gates.env)
  --summary <path>     Normalized findings (default: reports/security-summary.json)
  --output-dir <path>  Output directory (default: reports)
  --format <fmt>       markdown | json | all   (default: all)
  --strict-summary     Validate optional structure (source, evidence, tool statuses)
  --accepted-risks <path>  Accepted-risk records (default: .sentinel-shield/accepted-risks.json).
                       An APPROVED, unexpired, owned record may suppress a
                       suppressible gate (unsafe_docker, medium_vulnerabilities).
                       Never suppresses secrets/expired_exceptions/missing_release_evidence.
  -h, --help           Show this help

Outputs:
  <output-dir>/sentinel-shield-enforcement.md
  <output-dir>/sentinel-shield-enforcement.json

Exit: 0 pass, 1 fail, 2 configuration/input/parsing error.
Requires jq (JSON is not parsed with fragile shell hacks).
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--gates-env) GATES_ENV_FILE="${2:?--gates-env requires a value}"; shift 2 ;;
		--summary) SUMMARY="${2:?--summary requires a value}"; shift 2 ;;
		--output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
		--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
		--strict-summary) STRICT_SUMMARY=1; shift ;;
		--accepted-risks) ACCEPTED_RISKS_FILE="${2:?--accepted-risks requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die_cfg "unknown argument: $1" ;;
	esac
done

case "$FORMAT" in
	markdown | json | all) ;;
	*) die_cfg "invalid --format '$FORMAT' (expected: markdown | json | all)" ;;
esac

command_exists jq || die_cfg "jq is required for security-summary.json enforcement but was not found. Install jq. (Sentinel Shield does not parse JSON with fragile shell hacks.)"

[ -f "$GATES_ENV_FILE" ] || die_cfg "gates env not found: '$GATES_ENV_FILE' (run scripts/resolve-gates.sh first)"
[ -f "$SUMMARY" ] || die_cfg "security summary not found: '$SUMMARY' (a scanner workflow must produce it; see docs/security-summary-schema.md)"

# --- load the gates env SAFELY (validate; never blind-source) ----------------
# Allowed line shape: SENTINEL_SHIELD_<UPPER_KEY>=<safe-value>
# Safe value characters: A-Z a-z 0-9 . _ -   (no spaces/quotes/`/$/;/&/|/<>/backslash)
GATES_ENV=""
_lineno=0
while IFS= read -r _line || [ -n "$_line" ]; do
	_lineno=$((_lineno + 1))
	case "$_line" in
		'' | '#'*) continue ;;
	esac
	if printf '%s' "$_line" | grep -Eq '^SENTINEL_SHIELD_[A-Z0-9_]+=[A-Za-z0-9._-]*$'; then
		GATES_ENV="${GATES_ENV}${_line}
"
	else
		die_cfg "suspicious or invalid line in gates env ($GATES_ENV_FILE:$_lineno): '$_line'"
	fi
done < "$GATES_ENV_FILE"

# env_get <FULL_KEY> — value from the validated env content, or empty.
env_get() { printf '%s\n' "$GATES_ENV" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }

# gate_flag <gate_key> — resolved fail_on flag (true/false). Absent -> false+warn.
gate_flag() {
	_suffix=$(upper "$1")
	_v=$(env_get "SENTINEL_SHIELD_FAIL_ON_$_suffix")
	if [ -z "$_v" ]; then
		log_warn "gates env missing SENTINEL_SHIELD_FAIL_ON_$_suffix; treating gate '$1' as disabled"
		printf 'false'
	else
		printf '%s' "$_v"
	fi
}

MODE=$(env_get "SENTINEL_SHIELD_MODE"); [ -n "$MODE" ] || MODE="unknown"
PROJ_NAME=$(env_get "SENTINEL_SHIELD_PROJECT_NAME"); [ -n "$PROJ_NAME" ] || PROJ_NAME="unknown"
PROJ_TYPE=$(env_get "SENTINEL_SHIELD_PROJECT_TYPE"); [ -n "$PROJ_TYPE" ] || PROJ_TYPE="unknown"
PROJ_CRIT=$(env_get "SENTINEL_SHIELD_PROJECT_CRITICALITY"); [ -n "$PROJ_CRIT" ] || PROJ_CRIT="unknown"

# --- validate the summary ----------------------------------------------------
jq -e . "$SUMMARY" >/dev/null 2>&1 || die_cfg "security summary is not valid JSON: $SUMMARY"

# jqr <filter> — raw jq read against the summary (no `//` operator: it would treat
# boolean false as empty).
jqr() { jq -r "$1" "$SUMMARY" 2>/dev/null || printf 'null'; }

# Required top-level fields.
[ "$(jqr '.version')" != "null" ] || die_cfg "missing required field: version"
[ "$(jqr '.generated_at')" != "null" ] || die_cfg "missing required field: generated_at"
[ "$(jqr '.summary | type')" = "object" ] || die_cfg "missing or invalid required field: summary (must be an object)"

# Required integer summary keys.
for _k in $INT_SUMMARY_KEYS; do
	_v=$(jqr ".summary.$_k")
	if [ "$_v" = "null" ]; then
		die_cfg "missing required summary key: summary.$_k"
	fi
	case "$_v" in
		'' | *[!0-9]*) die_cfg "summary.$_k must be a non-negative integer, got '$_v'" ;;
	esac
done

# Required boolean summary keys.
for _k in missing_sbom missing_release_evidence; do
	_v=$(jqr ".summary.$_k")
	if [ "$_v" = "null" ]; then
		die_cfg "missing required summary key: summary.$_k"
	fi
	case "$_v" in
		true | false) ;;
		*) die_cfg "summary.$_k must be a boolean, got '$_v'" ;;
	esac
done

# Strict mode: validate optional-but-recommended structure.
if [ "$STRICT_SUMMARY" -eq 1 ]; then
	log_info "strict-summary: validating optional structure (source, evidence, tool statuses)"
	_ver=$(jqr '.version')
	if [ "$_ver" != "1.0" ]; then
		die_cfg "strict-summary: version must be \"1.0\", got '$_ver'"
	fi
	for _f in source evidence; do
		if [ "$(jqr ".$_f | type")" != "object" ]; then
			die_cfg "strict-summary: missing or invalid '$_f' object"
		fi
	done
	# Any present tool status must be one of the allowed enum values.
	_bad=$(jq -r '
		(.tools // {}) | to_entries[]
		| select(.value | type == "object")
		| select((.value.status // "pass") as $s
			| ($s | IN("pass","fail","warn","skipped","unavailable")) | not)
		| .key' "$SUMMARY" 2>/dev/null || true)
	if [ -n "$_bad" ]; then
		die_cfg "strict-summary: invalid tool status for: $(printf '%s' "$_bad" | tr '\n' ' ')"
	fi
fi

# --- accepted-risk suppression (explicit, owner-bound, expiring) -------------
# Load APPROVED, unexpired, owned records that target a suppressible gate. The raw
# count is never reduced; a suppressed gate is reported as "accepted-risk", not
# "pass". pending/expired/invalid records never suppress.
TODAY=$(date -u +%Y-%m-%d)
AR_LOADED=0
AR_PENDING=0
AR_EXPIRED=0
AR_INVALID=0
SUPPRESSED_GATES=" "   # space-padded list of gate keys with a valid approved risk
AR_APPLIED_DETAIL=""   # "gate|id" per applied suppression

if [ -f "$ACCEPTED_RISKS_FILE" ] && [ -s "$ACCEPTED_RISKS_FILE" ]; then
	jq -e . "$ACCEPTED_RISKS_FILE" >/dev/null 2>&1 || die_cfg "accepted-risks file is not valid JSON: $ACCEPTED_RISKS_FILE"
	AR_LOADED=$(jq '(.risks // []) | length' "$ACCEPTED_RISKS_FILE")
	AR_PENDING=$(jq '[(.risks // [])[] | select(.status != "approved")] | length' "$ACCEPTED_RISKS_FILE")
	AR_EXPIRED=$(jq --arg today "$TODAY" '[(.risks // [])[] | select(.status == "approved" and ((.expires_at // "") < $today))] | length' "$ACCEPTED_RISKS_FILE")
	# Records that are approved + unexpired but missing owner/reason or targeting a
	# non-suppressible gate are "invalid" and ignored.
	AR_INVALID=$(jq -r --arg today "$TODAY" --arg ok "$SUPPRESSIBLE_GATES" '
		($ok | split(" ")) as $S
		| [ (.risks // [])[]
			| select(.status == "approved" and ((.expires_at // "") >= $today))
			| select(((.owner // "") == "") or ((.reason // "") == "") or (((.gate // "") | IN($S[])) | not)) ] | length' "$ACCEPTED_RISKS_FILE")
	# Valid approved suppressions: status approved, unexpired, owner+reason set, gate suppressible.
	_valid_gates=$(jq -r --arg today "$TODAY" --arg ok "$SUPPRESSIBLE_GATES" '
		($ok | split(" ")) as $S
		| (.risks // [])[]
		| select(.status == "approved" and ((.expires_at // "") >= $today) and ((.owner // "") != "") and ((.reason // "") != "") and (((.gate // "") | IN($S[]))))
		| "\(.gate)|\(.id // "?")"' "$ACCEPTED_RISKS_FILE" 2>/dev/null || true)
	if [ -n "$_valid_gates" ]; then
		AR_APPLIED_DETAIL="$_valid_gates"
		while IFS='|' read -r _g _id; do
			[ -n "$_g" ] || continue
			case "$SUPPRESSED_GATES" in *" $_g "*) : ;; *) SUPPRESSED_GATES="${SUPPRESSED_GATES}${_g} " ;; esac
		done <<EOF
$_valid_gates
EOF
	fi
	log_info "accepted-risks: loaded $AR_LOADED (pending $AR_PENDING, expired $AR_EXPIRED, invalid $AR_INVALID ignored)"
fi

is_suppressed() {
	case "$SUPPRESSED_GATES" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# --- evaluate gates ----------------------------------------------------------
TS=$(timestamp_utc)
ensure_dir "$OUTPUT_DIR"

FAILED=""        # space-separated failed gate keys
ACCEPTED=""      # space-separated gate keys suppressed by an approved accepted-risk
EVAL_LINES=""    # "key|enabled|value|result" per line

add_eval() {
	# add_eval <key> <enabled-bool> <value-json> <result>
	EVAL_LINES="${EVAL_LINES}$1|$2|$3|$4
"
	if [ "$4" = "fail" ]; then
		FAILED="$FAILED $1"
	fi
}

# Count-based gate: fails when the count is > 0 and the flag is enabled — UNLESS a
# valid approved accepted-risk suppresses this gate, in which case it is reported as
# "accepted-risk" (the raw count is preserved, not zeroed) and does not fail.
eval_count_gate() {
	_key=$1
	_flag=$(gate_flag "$_key")
	_val=$(jqr ".summary.$_key")
	# Null-safe: a key absent from the summary (e.g. third-party keys on an older
	# summary) reads as "null"; treat any non-integer as 0 so we never error here.
	case "$_val" in
		'' | *[!0-9]*) _val=0 ;;
	esac
	if [ "$_flag" = "true" ]; then
		if [ "$_val" -gt 0 ]; then
			if is_suppressed "$_key"; then
				add_eval "$_key" true "$_val" "accepted-risk"
				ACCEPTED="$ACCEPTED $_key"
			else
				add_eval "$_key" true "$_val" fail
			fi
		else
			add_eval "$_key" true "$_val" pass
		fi
	else
		add_eval "$_key" false "$_val" skipped
	fi
}

# Evidence/boolean gate: fails when summary flag is true OR evidence present==false.
eval_missing_gate() {
	_key=$1            # missing_sbom | missing_release_evidence
	_evpath=$2         # evidence.sbom.present | evidence.release_evidence.present
	_flag=$(gate_flag "$_key")
	_missing=$(jqr ".summary.$_key")        # true|false (validated)
	_present=$(jqr ".$_evpath")             # true|false|null
	_trig=false
	if [ "$_missing" = "true" ]; then _trig=true; fi
	if [ "$_present" = "false" ]; then _trig=true; fi
	if [ "$_flag" = "true" ]; then
		if [ "$_trig" = "true" ]; then add_eval "$_key" true "$_trig" fail; else add_eval "$_key" true "$_trig" pass; fi
	else
		add_eval "$_key" false "$_trig" skipped
	fi
}

# Expired-exceptions gate: summary.expired_exceptions > 0 OR exceptions.expired > 0.
eval_expired_gate() {
	_flag=$(gate_flag "expired_exceptions")
	_ee=$(jqr '.summary.expired_exceptions')
	_ex=$(jqr '.exceptions.expired')
	_trig=0
	if [ "$_ee" -gt 0 ]; then _trig=1; fi
	case "$_ex" in
		'' | *[!0-9]*) : ;;
		*) if [ "$_ex" -gt 0 ]; then _trig=1; fi ;;
	esac
	if [ "$_flag" = "true" ]; then
		if [ "$_trig" -eq 1 ]; then add_eval "expired_exceptions" true "$_ee" fail; else add_eval "expired_exceptions" true "$_ee" pass; fi
	else
		add_eval "expired_exceptions" false "$_ee" skipped
	fi
}

eval_count_gate "secrets"
eval_count_gate "critical_vulnerabilities"
eval_count_gate "high_vulnerabilities"
eval_count_gate "medium_vulnerabilities"
eval_count_gate "architecture_violations"
eval_count_gate "type_errors"
eval_count_gate "test_failures"
eval_count_gate "unsafe_docker"
eval_count_gate "unsafe_github_actions"
eval_missing_gate "missing_sbom" "evidence.sbom.present"
eval_missing_gate "missing_release_evidence" "evidence.release_evidence.present"
eval_expired_gate

# Third-party supply-chain gates (separate channel; non-blocking by default in
# report-only/baseline). Evaluated like count gates; absent keys read as 0.
for _tpk in $THIRD_PARTY_KEYS; do
	eval_count_gate "$_tpk"
done

RESULT="pass"
EXIT=0
if [ -n "$FAILED" ]; then
	RESULT="fail"
	EXIT=1
fi

# --- emit human summary to stderr (never hidden) -----------------------------
log_info "Mode: $MODE  Result: $(printf '%s' "$RESULT" | tr '[:lower:]' '[:upper:]')"
if [ -n "$FAILED" ]; then
	for g in $FAILED; do log_info "FAILED gate: $g"; done
fi
if [ -n "$ACCEPTED" ]; then
	for g in $ACCEPTED; do log_info "ACCEPTED-RISK gate (count preserved, not failing): $g"; done
fi

# --- writers -----------------------------------------------------------------
json_eval() {
	_first=1
	printf '%s' "$EVAL_LINES" | while IFS='|' read -r k en val res; do
		[ -n "$k" ] || continue
		if [ "$_first" -eq 1 ]; then _first=0; else printf ',\n'; fi
		printf '    { "key": "%s", "enabled": %s, "value": %s, "result": "%s" }' "$k" "$en" "$val" "$res"
	done
}

json_failed() {
	_first=1
	for g in $FAILED; do
		if [ "$_first" -eq 1 ]; then _first=0; else printf ', '; fi
		printf '"%s"' "$g"
	done
}

json_list() {
	# json_list <space-separated items>
	_first=1
	for g in $1; do
		if [ "$_first" -eq 1 ]; then _first=0; else printf ', '; fi
		printf '"%s"' "$g"
	done
}

write_json() {
	_f="$OUTPUT_DIR/sentinel-shield-enforcement.json"
	{
		printf '{\n'
		printf '  "version": "1.0",\n'
		printf '  "mode": "%s",\n' "$MODE"
		printf '  "result": "%s",\n' "$RESULT"
		printf '  "generated_at": "%s",\n' "$TS"
		printf '  "project": { "name": "%s", "type": "%s", "criticality": "%s" },\n' \
			"$(json_escape "$PROJ_NAME")" "$(json_escape "$PROJ_TYPE")" "$(json_escape "$PROJ_CRIT")"
		printf '  "failed_gates": [%s],\n' "$(json_failed)"
		printf '  "accepted_risks": {\n'
		printf '    "file": "%s",\n' "$(json_escape "$ACCEPTED_RISKS_FILE")"
		printf '    "loaded": %s,\n' "$AR_LOADED"
		printf '    "applied_gates": [%s],\n' "$(json_list "$ACCEPTED")"
		printf '    "pending_ignored": %s,\n' "$AR_PENDING"
		printf '    "expired_ignored": %s,\n' "$AR_EXPIRED"
		printf '    "invalid_ignored": %s\n' "$AR_INVALID"
		printf '  },\n'
		printf '  "evaluated_gates": [\n'
		json_eval
		printf '\n  ]\n'
		printf '}\n'
	} > "$_f"
	log_info "wrote $_f"
}

write_markdown() {
	_f="$OUTPUT_DIR/sentinel-shield-enforcement.md"
	_result_up=$(printf '%s' "$RESULT" | tr '[:lower:]' '[:upper:]')
	{
		printf '# Sentinel Shield — Gate Enforcement\n\n'
		printf -- '- Project: %s (%s, criticality: %s)\n' "$PROJ_NAME" "$PROJ_TYPE" "$PROJ_CRIT"
		printf -- '- Mode: **%s**\n' "$MODE"
		printf -- '- Generated: %s\n' "$TS"
		printf -- '- Gates env: `%s`\n' "$GATES_ENV_FILE"
		printf -- '- Summary: `%s`\n\n' "$SUMMARY"
		printf -- '## Overall result: %s\n\n' "$_result_up"

		printf '## Active gates\n\n'
		printf -- '| Gate | Enabled | Value | Result |\n| --- | --- | --- | --- |\n'
		printf '%s' "$EVAL_LINES" | while IFS='|' read -r k en val res; do
			[ -n "$k" ] || continue
			printf -- '| %s | %s | %s | %s |\n' "$k" "$en" "$val" "$res"
		done
		printf '\n'

		printf '## Findings summary\n\n'
		printf -- '| Key | Count/Flag |\n| --- | --- |\n'
		for k in $INT_SUMMARY_KEYS; do
			printf -- '| %s | %s |\n' "$k" "$(jqr ".summary.$k")"
		done
		printf -- '| missing_sbom | %s |\n' "$(jqr '.summary.missing_sbom')"
		printf -- '| missing_release_evidence | %s |\n\n' "$(jqr '.summary.missing_release_evidence')"

		printf '## Third-party (supply-chain) findings\n\n'
		printf -- '> Separate channel from application SAST. Non-blocking by default in\n'
		printf -- '> report-only/baseline; see docs/third-party-supply-chain-scan.md.\n\n'
		printf -- '| Key | Count |\n| --- | --- |\n'
		for k in $THIRD_PARTY_KEYS; do
			_tv=$(jqr ".summary.$k"); case "$_tv" in ''|null) _tv=0 ;; esac
			printf -- '| %s | %s |\n' "$k" "$_tv"
		done
		printf -- '| tool status | %s |\n\n' "$(jqr '.tools.third_party_semgrep.status')"

		printf '## Failed gates\n\n'
		if [ -n "$FAILED" ]; then
			for g in $FAILED; do printf -- '- %s\n' "$g"; done
			printf '\n'
		else
			printf 'None.\n\n'
		fi

		printf '## Evidence checks\n\n'
		printf -- '| Evidence | Present |\n| --- | --- |\n'
		printf -- '| sbom | %s |\n' "$(jqr '.evidence.sbom.present')"
		printf -- '| release_evidence | %s |\n\n' "$(jqr '.evidence.release_evidence.present')"

		printf '## Exceptions\n\n'
		printf -- '| Field | Value |\n| --- | --- |\n'
		printf -- '| active | %s |\n' "$(jqr '.exceptions.active')"
		printf -- '| expired | %s |\n\n' "$(jqr '.exceptions.expired')"

		printf '## Accepted risks\n\n'
		printf -- '- File: `%s`\n' "$ACCEPTED_RISKS_FILE"
		printf -- '- Loaded: %s | pending ignored: %s | expired ignored: %s | invalid ignored: %s\n' \
			"$AR_LOADED" "$AR_PENDING" "$AR_EXPIRED" "$AR_INVALID"
		if [ -n "$ACCEPTED" ]; then
			printf -- '- Applied (gate marked accepted-risk, **count preserved, not zeroed, does not fail**):\n'
			printf '%s' "$AR_APPLIED_DETAIL" | while IFS='|' read -r _g _id; do
				[ -n "$_g" ] || continue
				printf -- '  - `%s` ← risk id `%s`\n' "$_g" "$_id"
			done
		else
			printf -- '- Applied: none.\n'
		fi
		printf -- '\n> Only APPROVED, unexpired, owner-bound records suppress, and only for\n'
		printf -- '> suppressible gates (unsafe_docker, medium_vulnerabilities). secrets,\n'
		printf -- '> expired_exceptions, and missing_release_evidence are never suppressed.\n\n'

		printf '## Next steps\n\n'
		if [ -n "$FAILED" ]; then
			printf -- '1. Resolve the failed gates above, or record an approved exception\n'
			printf -- '   (policies/exceptions/accepted-risk-template.md).\n'
			printf -- '2. Re-run the producing scanner workflow to refresh `%s`.\n' "$SUMMARY"
			printf -- '3. Re-run enforcement.\n'
		else
			printf -- '1. All active gates pass for mode `%s`.\n' "$MODE"
			printf -- '2. Tighten the mode in .sentinel-shield/profile.yaml as the project matures.\n'
		fi
	} > "$_f"
	log_info "wrote $_f"
}

case "$FORMAT" in
	json) write_json ;;
	markdown) write_markdown ;;
	all) write_json; write_markdown ;;
esac

log_info "Enforcement complete (mode=$MODE, result=$RESULT, exit=$EXIT)."
exit "$EXIT"
