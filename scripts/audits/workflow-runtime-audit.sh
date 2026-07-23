#!/bin/sh
# Sentinel Shield — GitHub Actions workflow-RUNTIME hardening audit.
#
# A deterministic, fail-CLOSED gate over the engine CI (.github/workflows/*.yml)
# AND the consumer-facing templates (templates/workflows/*.yml). It complements
# actionlint/zizmor (syntax + generic CI smells) and audit-github-actions-pins.sh
# (report-only pin inventory) by asserting the RUNTIME invariants that keep a
# workflow bounded, least-privileged and self-cancelling:
#
#   1. uses-sha-pin        — every `uses:` is a full 40-hex commit SHA (or a
#                            @sha256: digest, or a local ./ ref). @vN/@main/
#                            @master/truncated SHAs FAIL.
#   2. job-permissions     — every job runs under an explicit `permissions:`
#                            block. Satisfied by a workflow-level `permissions:`
#                            (which applies to all jobs) OR a job-level one.
#   3. job-timeout         — every job sets an explicit `timeout-minutes:`
#                            (else it inherits GitHub's 6-hour default).
#   4. workflow-concurrency — the workflow declares a top-level `concurrency:`
#                            group (so superseded runs are cancelled, not piled).
#   5. upload-artifact-if-no-files-found — every actions/upload-artifact step
#                            sets `if-no-files-found:` (never silently upload
#                            nothing and mask a broken producer).
#
# It emits BOTH a human report (STDOUT) and a machine report
# (reports/raw/workflow-runtime-audit.json, per schemas/workflow-runtime-audit.schema.json).
#
# ALLOWLIST: temporary, documented exceptions with a hard expiry may be added to
# ALLOW below (format documented there). An entry whose expiry is in the past is
# IGNORED — the violation fires again — so exemptions cannot rot silently.
#
# Usage: workflow-runtime-audit.sh [--output <path>] [--dir <dir> ...] [files...]
#   default dirs: .github/workflows templates/workflows
#   default output: reports/raw/workflow-runtime-audit.json
# Exit: 0 = clean, 1 = one or more violations (fail closed), 2 = config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

ss_require_jq

OUTPUT="reports/raw/workflow-runtime-audit.json"
DIRS=""
FILES=""
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--dir) DIRS="$DIRS ${2:?--dir requires a value}"; shift 2 ;;
		-h | --help)
			printf 'Usage: workflow-runtime-audit.sh [--output <path>] [--dir <dir> ...] [files...]\n'
			exit 0 ;;
		--*) log_error "unknown option: $1"; exit 2 ;;
		*) FILES="$FILES $1"; shift ;;
	esac
done

# Default scan set: the shipped engine CI + consumer templates.
if [ -z "$FILES" ] && [ -z "$DIRS" ]; then
	DIRS=".github/workflows templates/workflows"
fi
for _d in $DIRS; do
	if [ -d "$_d" ]; then
		FILES="$FILES $(find "$_d" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)"
	fi
done

# --- allowlist ---------------------------------------------------------------
# Temporary, documented exemptions. One entry per line, whitespace-separated:
#     <file-basename> <check> <key> <expiry-YYYY-MM-DD>
# where <check> is one of the check ids above and <key> is the offending job
# name, artifact line number, or "*" to match any key for that file+check.
# Entries whose expiry is < today are ignored (the violation is re-raised).
# NONE today — keep this empty unless a hard, dated exception is truly needed.
ALLOW=""
TODAY=$(date -u +%Y-%m-%d)

is_allowed() { # is_allowed <basename> <check> <key>
	_ia_bn=$1; _ia_ck=$2; _ia_ky=$3
	[ -n "$ALLOW" ] || return 1
	printf '%s\n' "$ALLOW" | {
		_hit=1
		while IFS= read -r _entry; do
			[ -n "$_entry" ] || continue
			# shellcheck disable=SC2086
			set -- $_entry
			[ "$#" -eq 4 ] || continue
			_af=$1; _ac=$2; _ak=$3; _ax=$4
			# match file + check + (key or wildcard) + not expired (expiry >= today).
			# Compare as YYYYMMDD integers: `[ x \> y ]` is a non-POSIX bashism that errors on
			# dash (Linux CI /bin/sh), which would make exemptions never match (fail-open).
			_axn=$(printf '%s' "$_ax" | tr -cd '0-9')
			_tdn=$(printf '%s' "$TODAY" | tr -cd '0-9')
			if [ "$_af" = "$_ia_bn" ] && [ "$_ac" = "$_ia_ck" ] \
				&& { [ "$_ak" = "*" ] || [ "$_ak" = "$_ia_ky" ]; } \
				&& [ -n "$_axn" ] && [ -n "$_tdn" ] && [ "$_axn" -ge "$_tdn" ]; then
				_hit=0
			fi
		done
		return $_hit
	}
}

ensure_dir "$(dirname "$OUTPUT")"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT INT TERM
: > "$TMP"

VIOLATIONS=0
SCANNED=0

# emit <file> <line> <job> <check> <ref> <message>
emit() {
	_bn=$(basename "$1"); _ck=$4; _ky=$3
	[ -z "$_ky" ] && _ky="$2"
	if is_allowed "$_bn" "$_ck" "$_ky"; then
		printf 'ALLOW (unexpired exemption): %s:%s [%s] job=%s %s\n' "$1" "$2" "$4" "$3" "$6"
		return 0
	fi
	VIOLATIONS=$((VIOLATIONS + 1))
	printf 'VIOLATION: %s:%s [%s] job=%s %s\n' "$1" "$2" "$4" "${3:--}" "$6"
	jq -n --arg f "$1" --argjson l "$2" --arg j "$3" --arg c "$4" --arg r "$5" --arg m "$6" \
		'{file:$f, line:$l, job:$j, check:$c, ref:$r, message:$m}' >> "$TMP"
}

is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

# --- per-file checks ---------------------------------------------------------
for f in $FILES; do
	[ -f "$f" ] || continue
	SCANNED=$((SCANNED + 1))

	# (4) workflow-level concurrency present (top-level key, column 0).
	if ! grep -qE '^concurrency:' "$f"; then
		emit "$f" 1 "" "workflow-concurrency" "" "no top-level concurrency: group (superseded runs will not cancel)"
	fi

	# Does a workflow-level permissions block exist? It applies to every job.
	if grep -qE '^permissions:' "$f"; then
		_wf_perms=1
	else
		_wf_perms=0
	fi

	# (2)+(3) per-job permissions + timeout. Pure awk job-block walk: under
	# `jobs:`, a 2-space key opens a job; 4-space keys are its properties. A
	# 0-indent key after jobs ends the section.
	_jobs=$(awk '
		/^jobs:[[:space:]]*$/ { injobs=1; next }
		{
			if (injobs && $0 ~ /^[A-Za-z0-9_.-]+:/) {
				if (cur != "") printf "%s\t%d\t%d\t%d\n", cur, ln, hp, ht
				cur=""; injobs=0
			}
			if (injobs && $0 ~ /^  [A-Za-z0-9_-]+:[[:space:]]*$/) {
				if (cur != "") printf "%s\t%d\t%d\t%d\n", cur, ln, hp, ht
				line=$0; sub(/^  /,"",line); sub(/:.*/,"",line)
				cur=line; ln=NR; hp=0; ht=0
			}
			if (injobs && $0 ~ /^    permissions:/) hp=1
			if (injobs && $0 ~ /^    timeout-minutes:[[:space:]]*/) ht=1
		}
		END { if (cur != "") printf "%s\t%d\t%d\t%d\n", cur, ln, hp, ht }
	' "$f")

	_jobcount=0
	# read job records
	printf '%s\n' "$_jobs" | while IFS='	' read -r _job _line _hp _ht; do
		[ -n "$_job" ] || continue
		if [ "$_ht" != "1" ]; then
			emit "$f" "$_line" "$_job" "job-timeout" "" "job '$_job' has no timeout-minutes (inherits the 6h default)"
		fi
		if [ "$_hp" != "1" ] && [ "$_wf_perms" != "1" ]; then
			emit "$f" "$_line" "$_job" "job-permissions" "" "job '$_job' has no explicit permissions and the workflow sets none"
		fi
	done
	# The while-subshell above cannot mutate VIOLATIONS; re-tally from $TMP below.

	# (1) every `uses:` pinned to a 40-hex SHA (or @sha256: digest, or local ./).
	_ln=0
	while IFS= read -r line || [ -n "$line" ]; do
		_ln=$((_ln + 1))
		_code=$(printf '%s' "$line" | sed 's/[[:space:]]*#.*$//')
		_key=$(printf '%s' "$_code" | sed -e 's/^[[:space:]]*//' -e 's/^-[[:space:]]*//')
		case "$_key" in
			uses:*)
				_ref=$(printf '%s' "$_key" | sed -n 's/^uses:[[:space:]]*//p' | tr -d '"'"'"' ')
				[ -n "$_ref" ] || continue
				case "$_ref" in
					./*|.\\*) : ;;
					*@sha256:*) : ;;
					*@*)
						_after=${_ref##*@}
						if is_sha "$_after"; then :; else
							emit "$f" "$_ln" "" "uses-sha-pin" "$_ref" "uses '@$_after' is a tag/branch/short-SHA, not a full 40-hex commit SHA"
						fi ;;
					*)
						emit "$f" "$_ln" "" "uses-sha-pin" "$_ref" "uses has no @ref (defaults to a moving default branch)" ;;
				esac ;;
		esac
	done < "$f"

	# (5) every upload-artifact step sets if-no-files-found. Step-block walk: a
	# list item ('- ') opens a step; the whole block (incl. an inline flow-map
	# `with: { ..., if-no-files-found: ... }` or a nested with: key) is searched.
	_arts=$(awk '
		function flush() {
			if (have && block ~ /uses:[[:space:]]*actions\/upload-artifact@/) {
				if (block ~ /if-no-files-found/) printf "%d\t1\n", sline
				else printf "%d\t0\n", sline
			}
		}
		# A real step starts with "- <key>:" (e.g. "- uses:", "- name:"). Plain
		# list scalars like a nested "with.path:" item ("- dist/**") are NOT step
		# boundaries and must not flush the block early.
		/^[[:space:]]*-[[:space:]]+[A-Za-z0-9_-]+:/ { flush(); block=""; have=1; sline=NR }
		{ block = block "\n" $0 }
		END { flush() }
	' "$f")
	printf '%s\n' "$_arts" | while IFS='	' read -r _sl _has; do
		[ -n "$_sl" ] || continue
		if [ "$_has" != "1" ]; then
			emit "$f" "$_sl" "" "upload-artifact-if-no-files-found" "" "upload-artifact step does not set if-no-files-found"
		fi
	done
done

# The per-job / per-artifact loops run in subshells (piped while), so VIOLATIONS
# incremented there is lost. The authoritative count is the JSON records that
# emit() appended to $TMP (which persists across subshells).
VIOLATIONS=$(jq -s 'length' "$TMP")

if [ "$SCANNED" -eq 0 ]; then
	log_error "workflow-runtime-audit: no workflow files found to scan"
	exit 2
fi

_status=pass
[ "$VIOLATIONS" -gt 0 ] && _status=fail

jq -s --arg v "1.0" --arg ts "$(timestamp_utc)" --arg st "$_status" \
	--argjson scanned "$SCANNED" \
	'{version:$v, generated_at:$ts, tool:"workflow-runtime-audit",
	  files_scanned:$scanned,
	  checks:["uses-sha-pin","job-permissions","job-timeout","workflow-concurrency","upload-artifact-if-no-files-found"],
	  status:$st, violation_count:(.|length), violations:.}' "$TMP" > "$OUTPUT"

printf '\nworkflow-runtime-audit: scanned %d file(s), %d violation(s) -> %s\n' \
	"$SCANNED" "$VIOLATIONS" "$OUTPUT"

if [ "$VIOLATIONS" -gt 0 ]; then
	log_error "workflow-runtime-audit: FAIL ($VIOLATIONS violation(s))"
	exit 1
fi
log_info "workflow-runtime-audit: PASS ($SCANNED file(s) clean)"
exit 0
