# Sentinel Shield — shared POSIX shell library.
#
# Source this file; do not execute it. It defines helper functions only and does
# not enable `set -eu` itself (the caller decides). All functions are POSIX sh
# compatible: no Bash arrays, no `local`, no `[[ ]]`, no process substitution.
#
#   SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_COMMON_LOADED=1

# --- logging -----------------------------------------------------------------
# Informational output goes to stderr so stdout can carry machine-readable data.
log_info() { printf '%s\n' "[sentinel-shield] $*" >&2; }
log_warn() { printf '%s\n' "[sentinel-shield][warn] $*" >&2; }
log_error() { printf '%s\n' "[sentinel-shield][error] $*" >&2; }

# die <message...> — log an error and exit non-zero.
die() {
	log_error "$*"
	exit 1
}

# --- environment -------------------------------------------------------------
# command_exists <name> — true if the command is on PATH.
command_exists() { command -v "$1" >/dev/null 2>&1; }

# ensure_dir <path> — create a directory (and parents) if it does not exist.
ensure_dir() {
	[ -n "${1:-}" ] || die "ensure_dir: missing path argument"
	if [ ! -d "$1" ]; then
		mkdir -p "$1" || die "ensure_dir: cannot create '$1'"
	fi
}

# write_file <path> — write stdin to <path>, creating parent directories.
# Usage:  printf '%s\n' "content" | write_file out.txt
write_file() {
	[ -n "${1:-}" ] || die "write_file: missing path argument"
	ensure_dir "$(dirname -- "$1")"
	cat > "$1" || die "write_file: cannot write '$1'"
}

# --- values ------------------------------------------------------------------
# bool_value <value> — normalise a boolean; echo true|false; return 1 if invalid.
# Accepts a small, explicit set; anything else is rejected so callers can fail.
bool_value() {
	case "${1:-}" in
		true | True | TRUE | yes | Yes | YES | on | On | ON | 1) printf 'true' ;;
		false | False | FALSE | no | No | NO | off | Off | OFF | 0) printf 'false' ;;
		*) return 1 ;;
	esac
}

# upper <string> — uppercase using tr (portable).
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# json_escape <string> — escape backslash and double-quote for JSON string values.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# timestamp_utc — ISO-8601 UTC timestamp. `date` is POSIX.
timestamp_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# utc_timestamp — backward-compatible alias for timestamp_utc.
utc_timestamp() { timestamp_utc; }
