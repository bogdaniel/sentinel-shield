#!/bin/sh
# Sentinel Shield — security-summary fallback policy.
#
# Decides whether enforcement may proceed given the resolved adoption mode and
# whether a REAL security-summary.json is present. The all-zero example template is
# NOT acceptable evidence in baseline/strict/regulated.
#
# Rule:
#   report-only            : real summary used if present; otherwise the example is
#                            copied in as a clearly-marked NON-PRODUCTION fallback.
#   baseline/strict/regulated : a real summary MUST be present, else fail (exit 1).
#
# "Real" = the summary file exists, is valid JSON, is NOT byte-identical (after
# canonicalization) to templates/security-summary.example.json, and does NOT carry the
# non-production fallback marker this script writes. A real builder run always differs
# (generated_at/source/evidence), so the only way to look like the example is to literally
# use the example — which is exactly what we reject.
#
# STAGING THE FALLBACK IS STILL A WRITE TO A SECURITY-SENSITIVE EVIDENCE PATH. It used to be
# a bare `cp`: the destination was never checked for symlink/FIFO/device/directory conditions
# (so a symlinked summary path redirected the write), an existing valid summary was destroyed
# before a complete copy was guaranteed, readers could observe a half-written file, and a
# concurrent real builder could be overwritten. The fallback is now validated, staged in a
# destination-local temporary file, marked as non-production, and published by atomic rename —
# and it refuses to overwrite a real summary that appeared while it was staging.
#
# Exit codes: 0 proceed, 1 missing-real-summary in a strict-enough mode, 2 config.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

die_cfg() { log_error "$*"; exit 2; }

SUMMARY="reports/security-summary.json"
EXAMPLE="templates/security-summary.example.json"
GATES_ENV="reports/sentinel-shield-gates.env"
MODE=""
VALID_MODES="report-only baseline strict regulated"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: select-security-summary.sh [options]

Apply the security-summary fallback policy for the resolved adoption mode.

Options:
  --summary <path>     Real/expected summary (default: reports/security-summary.json)
  --example <path>     Example template (default: templates/security-summary.example.json)
  --gates-env <path>   Read mode from here if --mode is absent
                       (default: reports/sentinel-shield-gates.env)
  --mode <mode>        Force mode: report-only | baseline | strict | regulated
  -h, --help           Show this help

Exit: 0 proceed (summary in place), 1 real summary required but missing, 2 config.
Requires jq.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--summary) SUMMARY="${2:?--summary requires a value}"; shift 2 ;;
		--example) EXAMPLE="${2:?--example requires a value}"; shift 2 ;;
		--gates-env) GATES_ENV="${2:?--gates-env requires a value}"; shift 2 ;;
		--mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die_cfg "unknown argument: $1" ;;
	esac
done

command_exists jq || die_cfg "jq is required but was not found."

# Resolve mode: explicit flag wins, else read SENTINEL_SHIELD_MODE from the gates env
# (validated, not sourced).
if [ -z "$MODE" ]; then
	if [ -f "$GATES_ENV" ]; then
		# ONE parser, shared with the enforcer and the report generator. `head -n1` made a
		# duplicated key first-wins here while the enforcer rejected it — the same policy
		# file read two different ways by two tools.
		_genv=$(ss_gates_env_read "$GATES_ENV") || die_cfg "gates env is not usable: $GATES_ENV (see errors above)"
		MODE=$(ss_gates_env_value "$_genv" SENTINEL_SHIELD_MODE)
	fi
fi
[ -n "$MODE" ] || die_cfg "cannot determine mode (pass --mode or provide $GATES_ENV)"

_ok=0
for _m in $VALID_MODES; do [ "$_m" = "$MODE" ] && _ok=1; done
[ "$_ok" -eq 1 ] || die_cfg "invalid mode '$MODE' (expected one of: $VALID_MODES)"

# is_real_summary <path> — true when the file is a REAL summary: a regular file, valid JSON,
# not the example, and not a previously staged non-production fallback. Symlinks are refused
# here too: evidence that arrives through a symlink is not evidence about this run.
is_real_summary() {
	[ -e "$1" ] || return 1
	if [ -L "$1" ]; then
		log_warn "summary path '$1' is a symlink; refusing to treat it as real evidence"
		return 1
	fi
	[ -f "$1" ] || return 1
	jq -e . "$1" >/dev/null 2>&1 || return 1
	if jq -e '(.fallback.non_production // false) == true' "$1" >/dev/null 2>&1; then
		log_warn "summary at '$1' carries the NON-PRODUCTION fallback marker (treated as NOT real)"
		return 1
	fi
	if [ -f "$EXAMPLE" ] && [ "$(jq -S -c . "$1")" = "$(jq -S -c . "$EXAMPLE")" ]; then
		log_warn "provided summary is byte-identical to the example template (treated as NOT real)"
		return 1
	fi
	return 0
}

# stage_fallback — publish the example as an explicitly non-production summary, atomically.
stage_fallback() {
	_dest="$SUMMARY"
	_dir=$(dirname -- "$_dest")

	# (1) source must be a readable, regular, valid-JSON example.
	[ -f "$EXAMPLE" ] && [ ! -L "$EXAMPLE" ] || die_cfg "fallback source is not a regular file: $EXAMPLE"
	jq -e . "$EXAMPLE" >/dev/null 2>&1 || die_cfg "fallback source is not valid JSON: $EXAMPLE"

	# (2) destination must be a safe place to write. A symlink, FIFO, device or directory at
	#     the destination redirects or corrupts the write instead of replacing a file.
	ensure_dir "$_dir"
	[ -d "$_dir" ] || die_cfg "fallback destination directory does not exist: $_dir"
	[ -L "$_dir" ] && die_cfg "fallback destination directory is a symlink: $_dir"
	if [ -e "$_dest" ] || [ -L "$_dest" ]; then
		[ -L "$_dest" ] && die_cfg "refusing to write the fallback through a symlink: $_dest"
		[ -d "$_dest" ] && die_cfg "fallback destination is a directory: $_dest"
		[ -f "$_dest" ] || die_cfg "fallback destination is not a regular file (FIFO/device?): $_dest"
	fi

	# (3) stage destination-local, so the rename below is atomic (same filesystem) and a
	#     failure never destroys an existing summary.
	_tmp=$(mktemp "$_dir/.sentinel-shield-fallback.XXXXXX") || die_cfg "could not create a staging file in $_dir"
	# Clean the staging file on every exit path, including signals.
	trap 'rm -f -- "$_tmp" 2>/dev/null || true' EXIT INT TERM HUP
	chmod 0644 "$_tmp" 2>/dev/null || true
	if ! jq --arg mode "$MODE" --arg ts "$(timestamp_utc)" --arg src "$EXAMPLE" '
		. + { fallback: { non_production: true, reason: "no real security-summary was produced",
		                  mode: $mode, staged_at: $ts, source: $src,
		                  generator: "select-security-summary" } }' "$EXAMPLE" > "$_tmp"; then
		rm -f -- "$_tmp"
		die_cfg "could not stage the fallback summary in $_dir"
	fi
	# (4) validate what will be published, before it replaces anything.
	jq -e '(.version != null) and (.summary | type == "object") and (.fallback.non_production == true)' \
		"$_tmp" >/dev/null 2>&1 || { rm -f -- "$_tmp"; die_cfg "staged fallback failed validation; leaving $_dest untouched"; }

	# (5) COMMIT BY CREATE-EXCLUSIVE, not check-then-rename. `is_real_summary` followed by
	#     `mv` is two operations: a real builder can publish in the gap and the fallback then
	#     overwrites real evidence. `ln` fails atomically when the destination already exists,
	#     so the fallback can only ever CREATE the file, never replace one. There is no window
	#     to lose, and no second stat to race.
	if ln -- "$_tmp" "$_dest" 2>/dev/null; then
		rm -f -- "$_tmp"
	else
		if [ -e "$_dest" ] || [ -L "$_dest" ]; then
			rm -f -- "$_tmp"
			log_warn "a summary appeared at $_dest while the fallback was staging; keeping it and discarding the fallback (the fallback never replaces an existing summary)"
			return 0
		fi
		rm -f -- "$_tmp"
		die_cfg "could not publish the fallback summary at $_dest"
	fi
	trap - EXIT INT TERM HUP
	log_warn "staged a NON-PRODUCTION fallback summary at $_dest (marked .fallback.non_production=true)"
	return 0
}

# Determine whether a REAL summary is present.
real=false
if is_real_summary "$SUMMARY"; then real=true; fi

case "$MODE" in
	report-only)
		if [ "$real" = "true" ]; then
			log_info "report-only: using provided security-summary.json"
		else
			log_warn "NON-PRODUCTION FALLBACK: no real security-summary found."
			log_warn "report-only mode: using the all-zero EXAMPLE. This is NOT evidence."
			stage_fallback
		fi
		exit 0
		;;
	baseline | strict | regulated)
		if [ "$real" = "true" ]; then
			log_info "$MODE: real security-summary.json present."
			exit 0
		fi
		log_error "mode '$MODE' requires a REAL security-summary.json produced from scanner"
		log_error "artifacts. The all-zero example is not acceptable evidence. Failing the gate."
		exit 1
		;;
esac
