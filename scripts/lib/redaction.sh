#!/bin/sh
# Sentinel Shield — unified redaction + sensitive-value classification (POSIX sh; SOURCE, do not execute).
#
# The SINGLE choke point every diagnostic, journal line, JSON intermediate, report, and release
# artifact passes through before it is DISPLAYED or PERSISTED. It removes credentials and
# repo-local identity from untrusted text and proves, on demand, that a produced artifact carries
# no confirmed secret before it is uploaded.
#
# Two complementary layers, in this order:
#   1. LITERAL sensitive-value registry — a caller registers exact secret VALUES it knows (a token
#      read from the environment, a password parsed from a URL, a signing-key path). These are
#      redacted as LITERAL substrings (never as regex), longest-value-first, so a secret containing
#      regex metacharacters, '/', '#', '&', backslashes, or Unicode can never (a) inject a pattern
#      or (b) break the redactor's own delimiters. Overlapping values collapse cleanly because the
#      longest match is consumed first.
#   2. STRUCTURAL pattern redaction — shape-based masking for secrets whose literal value is not
#      known in advance: GitHub tokens, Authorization headers, URL userinfo credentials, npm /
#      Composer / registry / docker auth, JWTs, AWS keys, sensitive query parameters, and generic
#      NAME=VALUE pairs whose NAME ends in a sensitive suffix. Plus path relativization (HOME -> ~,
#      the run's --target root -> <target>, the repo root -> <repo>, temp roots -> <tmp>) and
#      email masking.
#
# PATH-ROOT REGISTRATION CONTRACT (delimiter-safe)
#   RD_TMP_ROOTS is a NEWLINE-DELIMITED list of absolute temp-root prefixes: exactly ONE root per
#   line, taken VERBATIM (a root may contain spaces, '#', '[' ']', other glob/regex metacharacters,
#   backslashes, or Unicode — it is NEVER word-split or glob-expanded). RD_TARGET_ROOT /
#   RD_REPO_ROOT / RD_HOME are single absolute roots. Every root is validated FAIL-CLOSED before it
#   becomes a replacement rule: an empty root, a non-absolute root, a root that carries a tab (which
#   would corrupt the internal record) and the root "/" itself (which would relativize the whole
#   filesystem) are REJECTED and simply produce no rule. A root containing a newline cannot occur —
#   the newline is the delimiter. All surviving roots are sorted LONGEST-FIRST and de-duplicated, so
#   a nested/overlapping root is consumed by its most specific (longest) match and a broad root can
#   never swallow a path that a longer root owns. When RD_TMP_ROOTS is UNSET the default roots are
#   /tmp, /var/tmp, /var/folders and $TMPDIR (when set).
#
# HARDENING CONTRACT
#   * Redaction happens BEFORE persistence, not only before display: callers pipe intermediate
#     JSON and journal writes through rd_redact_stream, so secret values never reach a file.
#   * Secrets are treated as LITERALS (awk index/substr), never compiled into a regex.
#   * The literal registry is CAPPED in count (RD_MAX_SECRETS) and per-value size
#     (RD_MAX_SECRET_BYTES); an over-cap or over-size value is refused, never silently truncated
#     into a partial match.
#   * Extremely long untrusted lines are bounded (RD_MAX_LINE) AFTER literal redaction, so a secret
#     anywhere in the line is removed before the line is capped.
#   * Sensitive temp files (the materialised registry) are created 0600 under a restrictive umask.
#   * xtrace is disabled inside every secret-handling function so `set -x` cannot echo a value.
#   * rd_run_isolated runs an external tool under an ALLOWLISTED environment (env -i + named vars),
#     so a child process never inherits an ambient secret; the full environment is NEVER printed.
#   * rd_scan_paths screens a produced artifact for CONFIRMED, high-confidence credential shapes and
#     FAILS CLOSED (returns 1) if any is present — the release-readiness gate before upload.
#   * The machine-readable redaction report (rd_report_json / rd_scan_paths) carries COUNTS and
#     CATEGORY names only — NEVER a secret value. Conforms to schemas/redaction-report.schema.json.
#
# This file only DEFINES functions; it does not enable `set -eu`, use Bash arrays, `local`,
# `[[ ]]`, or process substitution. It sources sentinel-shield-common.sh (log_*) with an include
# guard so double-sourcing is safe.
#
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
#   . "$SCRIPT_DIR/lib/redaction.sh"

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_REDACTION_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_REDACTION_LOADED=1

# Pull in log_* if the caller has not already. __rd_dir resolves THIS library's directory.
__rd_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/lib/sentinel-shield-common.sh" ]; then
		# shellcheck source=scripts/lib/sentinel-shield-common.sh
		. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
	elif [ -f "$__rd_dir/sentinel-shield-common.sh" ]; then
		# shellcheck source=scripts/lib/sentinel-shield-common.sh
		. "$__rd_dir/sentinel-shield-common.sh"
	fi
fi

# --- tunables (overridable by the caller BEFORE first use) -------------------
: "${RD_MAX_SECRETS:=256}"          # cap on registered literal secret values.
: "${RD_MAX_SECRET_BYTES:=8192}"    # cap on the byte-length of a single registered value.
: "${RD_MIN_SECRET_BYTES:=4}"       # refuse a value this short (would over-redact ordinary text).
: "${RD_MAX_LINE:=8192}"            # bound an untrusted diagnostic line to this many bytes.

# Placeholders (stable strings a machine consumer / test may grep for).
RD_PH_SECRET='***REDACTED-SECRET***'
RD_PH_GH='***REDACTED-GH-TOKEN***'
RD_PH_AWS='***REDACTED-AWS-KEY***'
RD_PH_JWT='***REDACTED-JWT***'
RD_PH_KEYPATH='***REDACTED-KEY-PATH***'
RD_PH_GNUPG='***REDACTED-GNUPG-PATH***'
RD_PH_NPM='***REDACTED-NPM-TOKEN***'
RD_PH_EMAIL='***REDACTED-EMAIL***'
RD_TRUNC_MARK=' [TRUNCATED]'

RD_TAB=$(printf '\t')

# Registry state (newline-separated literal values; deduped). RD__SECRETS_CAPPED records whether
# any add was refused for exceeding a bound so the report can state it honestly.
RD__SECRETS=""
RD__SECRETS_N=0
RD__SECRETS_CAPPED=0

# _rd_harden — disable xtrace so `set -x` never echoes a secret, and tighten the umask for any
# temp file this library creates. Called at the top of every secret-handling function. xtrace is
# intentionally NOT restored: these are leaf helpers and re-enabling would re-open the leak.
_rd_harden() {
	{ set +x; } 2>/dev/null
	umask 077
}

# rd_secret_reset — clear the literal sensitive-value registry.
rd_secret_reset() {
	RD__SECRETS=""
	RD__SECRETS_N=0
	RD__SECRETS_CAPPED=0
}

# rd_urlencode <string> — percent-encode every byte that is not an RFC-3986 unreserved character.
# Used to also register the ENCODED form of a secret so a token that appears percent-encoded in a
# URL/query is redacted too. Byte-wise (LC_ALL=C) so multibyte input is encoded, not mangled.
rd_urlencode() {
	_rd_harden
	printf '%s' "$1" | LC_ALL=C awk '
		BEGIN{ for(i=0;i<256;i++) ord[sprintf("%c",i)]=i }
		{
			s=$0; out=""
			for(i=1;i<=length(s);i++){
				c=substr(s,i,1)
				if (c ~ /[A-Za-z0-9._~-]/) out=out c
				else out=out sprintf("%%%02X", ord[c])
			}
			printf "%s", out
		}'
}

# rd_secret_add <value> — register a LITERAL secret value for redaction. Refuses (fail-closed,
# recorded as capped) an empty value, one shorter than RD_MIN_SECRET_BYTES (would over-redact),
# one longer than RD_MAX_SECRET_BYTES, or a value beyond RD_MAX_SECRETS. Deduplicates. Also
# registers the value's percent-encoded form when it differs (encoded-form coverage). Returns 0
# when at least the raw value is registered (or already present); 1 when the value is refused.
rd_secret_add() {
	_rd_harden
	_rd_v="${1:-}"
	# Reject an empty value.
	[ -n "$_rd_v" ] || { unset _rd_v; return 1; }
	# Reject a value carrying a newline: the registry is line-oriented; only the first line would
	# be honoured, silently leaking the rest. Refuse rather than partially redact. The case pattern
	# holds a LITERAL newline (a command-substituted '\n' would be stripped to empty and match all).
	case "$_rd_v" in
		*"
"*) RD__SECRETS_CAPPED=1; log_warn "rd_secret_add: refusing a multi-line value"; unset _rd_v; return 1 ;;
	esac
	if [ "${#_rd_v}" -lt "$RD_MIN_SECRET_BYTES" ]; then
		RD__SECRETS_CAPPED=1; unset _rd_v; return 1
	fi
	if [ "${#_rd_v}" -gt "$RD_MAX_SECRET_BYTES" ]; then
		RD__SECRETS_CAPPED=1; log_warn "rd_secret_add: refusing an over-size value (> $RD_MAX_SECRET_BYTES bytes)"; unset _rd_v; return 1
	fi
	_rd_added=1
	_rd_enc=$(rd_urlencode "$_rd_v")
	for _rd_cand in "$_rd_v" "$_rd_enc"; do
		# Skip an encoded form equal to the raw value, or one below the min length.
		[ -n "$_rd_cand" ] || continue
		[ "${#_rd_cand}" -ge "$RD_MIN_SECRET_BYTES" ] || continue
		case "$RD_TAB$RD__SECRETS$RD_TAB" in
			*"$RD_TAB$_rd_cand$RD_TAB"*) continue ;;   # already present (exact line)
		esac
		# Use a line-scan dedup that tolerates values without surrounding tabs.
		if printf '%s\n' "$RD__SECRETS" | grep -Fxq -- "$_rd_cand" 2>/dev/null; then
			continue
		fi
		if [ "$RD__SECRETS_N" -ge "$RD_MAX_SECRETS" ]; then
			RD__SECRETS_CAPPED=1; _rd_added=0
			log_warn "rd_secret_add: sensitive-value registry is at its cap ($RD_MAX_SECRETS); refusing more"
			break
		fi
		RD__SECRETS="${RD__SECRETS:+$RD__SECRETS
}$_rd_cand"
		RD__SECRETS_N=$((RD__SECRETS_N + 1))
	done
	unset _rd_v _rd_enc _rd_cand
	[ "$_rd_added" = 1 ] && { unset _rd_added; return 0; }
	unset _rd_added; return 1
}

# rd_secret_count — print the number of registered literal values.
rd_secret_count() { printf '%s' "$RD__SECRETS_N"; }

# rd_mktemp [dir] — create a fresh 0600 temp file (under a restrictive umask). Prints its path and
# returns 0; prints nothing and returns 1 on failure. Prefers [dir] (or $TMPDIR) but never leaks.
rd_mktemp() {
	_rd_harden
	_rd_d="${1:-${TMPDIR:-/tmp}}"
	_rd_f=$(mktemp "$_rd_d/.ss-rd.XXXXXX" 2>/dev/null || mktemp 2>/dev/null || mktemp -t ssrd) || {
		unset _rd_d _rd_f; return 1; }
	chmod 600 "$_rd_f" 2>/dev/null || { rm -f -- "$_rd_f" 2>/dev/null; unset _rd_d _rd_f; return 1; }
	printf '%s' "$_rd_f"
	unset _rd_d _rd_f
	return 0
}

# _rd_esc <string> — escape ERE metacharacters, the '#' sed delimiter, and backslash so a fixed
# root path can be used safely on the LEFT of an s#...#...# without acting as a pattern.
_rd_esc() { printf '%s' "$1" | sed 's/[][#.^$*+?(){}|\\]/\\&/g'; }

# _rd_root_emit <kind> <root> — validate ONE replacement root and, if it survives, print a single
# LONGEST-FIRST-sortable record "<rawlen><TAB><kind><TAB><escaped-root>" to STDOUT. FAILS CLOSED
# (emits nothing) for an empty root, a root carrying a tab (would corrupt the TAB-delimited record),
# a non-absolute root, or the root "/" (which would relativize the entire filesystem). Trailing
# slashes are trimmed so "/foo/" and "/foo" dedupe; a root that collapses to empty is rejected.
_rd_root_emit() {
	_rd_ek="$1"; _rd_er="$2"
	[ -n "$_rd_er" ] || { unset _rd_ek _rd_er; return 0; }
	case "$_rd_er" in *"$RD_TAB"*) unset _rd_ek _rd_er; return 0 ;; esac
	case "$_rd_er" in
		/) unset _rd_ek _rd_er; return 0 ;;   # reject "/" as a replacement root
		/*) : ;;                              # absolute — ok
		*) unset _rd_ek _rd_er; return 0 ;;   # reject a non-absolute (malformed) root
	esac
	while : ; do
		case "$_rd_er" in */) _rd_er="${_rd_er%/}" ;; *) break ;; esac
	done
	[ -n "$_rd_er" ] || { unset _rd_ek _rd_er; return 0; }
	case "$_rd_er" in /) unset _rd_ek _rd_er; return 0 ;; esac
	printf '%s\t%s\t%s\n' "${#_rd_er}" "$_rd_ek" "$(_rd_esc "$_rd_er")"
	unset _rd_ek _rd_er
}

# _rd_root_records <home> — emit one _rd_root_emit record per replacement root: the target root, the
# repo root, every RD_TMP_ROOTS entry (NEWLINE-DELIMITED, never word-split), and HOME. Consumed by
# _rd_pattern_stage, which dedupes and sorts these LONGEST-FIRST.
_rd_root_records() {
	_rd_rr_home="$1"
	_rd_root_emit target "${RD_TARGET_ROOT:-}"
	_rd_root_emit repo "${RD_REPO_ROOT:-}"
	if [ -n "${RD_TMP_ROOTS+x}" ]; then
		# Newline-delimited contract: one root per line, taken verbatim (no splitting, no globbing).
		printf '%s\n' "$RD_TMP_ROOTS" | while IFS= read -r _rd_rr_t; do
			_rd_root_emit tmp "$_rd_rr_t"
		done
	else
		for _rd_rr_d in /tmp /var/tmp /var/folders ${TMPDIR:+"$TMPDIR"}; do
			_rd_root_emit tmp "$_rd_rr_d"
		done
	fi
	_rd_root_emit home "$_rd_rr_home"
	unset _rd_rr_home _rd_rr_t _rd_rr_d
}

# _rd_pattern_stage — read STDIN, apply STRUCTURAL (shape-based) redaction + path relativization,
# write to STDOUT. No secret VALUE is ever compiled into these patterns — they match shapes only.
# Path roots come from RD_TARGET_ROOT / RD_REPO_ROOT / RD_TMP_ROOTS / RD_HOME (all optional).
_rd_pattern_stage() {
	_rd_home="${RD_HOME:-$HOME}"
	# Secret-bearing key WORDS, case-insensitive via bracket classes (sed has no portable
	# /I). Used by the JSON key/value rules below (v2.0.1 hotfix): the previous generic
	# rule's value class excluded the double-quote character, so in JSON — where the byte
	# after `": "` IS a quote — it could never match. `{"GITHUB_TOKEN": "..."}` passed
	# through untouched, and JSON is the format security-summary.json, reports/raw/* and
	# the event journal are all persisted in.
	#
	# The three JSON rules deliberately require a WORD BOUNDARY (name starts with the
	# word, or it follows _ / -, or a camelCase hump) so ordinary data is not corrupted:
	# "monkey" and "donkeys" contain "key" but are not secrets, and silently mangling
	# real evidence is its own integrity failure.
	_rd_sw='[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll]'

	# Build path-relativization rules delimiter-safely: gather every replacement root as a validated
	# record, DEDUPLICATE exact repeats, then order LONGEST-FIRST (numeric on the raw path length) so
	# a nested/overlapping root is consumed by its most specific match and a broad root never swallows
	# a path a longer root owns. Roots are read WITHOUT word-splitting or globbing (see the PATH-ROOT
	# REGISTRATION CONTRACT); "/" and non-absolute/empty roots were already rejected in _rd_root_emit.
	_rd_rules=$(_rd_root_records "$_rd_home" | awk '!seen[$0]++' | LC_ALL=C sort -t "$RD_TAB" -k1,1nr -s)

	set --
	# A here-doc (not a pipe) feeds the loop so `set --` mutates THIS shell, not a subshell.
	while IFS="$RD_TAB" read -r _rd_len _rd_kind _rd_ce; do
		[ -n "$_rd_kind" ] || continue
		case "$_rd_kind" in
			target) set -- "$@" -e "s#${_rd_ce}#<target>#g" ;;
			repo) set -- "$@" -e "s#${_rd_ce}#<repo>#g" ;;
			home) set -- "$@" -e "s#${_rd_ce}#~#g" ;;
			tmp) set -- "$@" -e "s#${_rd_ce}/[^[:space:]\"']*#<tmp>#g" ;;
		esac
	done <<RD_ROOT_RULES
$_rd_rules
RD_ROOT_RULES

	sed -E \
		-e "s#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+@#\\1***REDACTED***@#g" \
		-e "s/(gh[pousra]_)[A-Za-z0-9]{20,}/\\1***REDACTED***/g" \
		-e "s/github_pat_[A-Za-z0-9_]{20,}/${RD_PH_GH}/g" \
		-e "s/(AKIA|ASIA)[0-9A-Z]{16}/${RD_PH_AWS}/g" \
		-e "s/eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}/${RD_PH_JWT}/g" \
		-e "s/([Aa]uthorization:[[:space:]]*)[A-Za-z]+[[:space:]]+[^[:space:]]+/\\1***REDACTED***/g" \
		-e "s/([Aa]uthorization:[[:space:]]*)[^[:space:]]+/\\1***REDACTED***/g" \
		-e "s/([Bb]earer[[:space:]]+)[A-Za-z0-9._~+/=-]{8,}/\\1***REDACTED***/g" \
		-e "s/([Bb]asic[[:space:]]+)[A-Za-z0-9+/=]{8,}/\\1***REDACTED***/g" \
		-e "s#(_authToken=)[^[:space:]\"']+#\\1***REDACTED***#g" \
		-e "s/(npm_)[A-Za-z0-9]{20,}/${RD_PH_NPM}/g" \
		-e "s#(_password=)[^[:space:]\"']+#\\1***REDACTED***#g" \
		-e "s#(_auth=)[^[:space:]\"']+#\\1***REDACTED***#g" \
		-e "s/(\"auth\"[[:space:]]*:[[:space:]]*\")[^*\"][^\"]*\"/\\1***REDACTED***\"/g" \
		-e "s#(--homedir[[:space:]]+)[^[:space:]]+#\\1${RD_PH_GNUPG}#g" \
		-e "s#(GNUPGHOME=)[^[:space:]]+#\\1${RD_PH_GNUPG}#g" \
		-e "s#[^[:space:]\"':=]*/\\.gnupg[^[:space:]\"']*#${RD_PH_GNUPG}#g" \
		-e "s#[^[:space:]\"':=]*/(id_rsa|id_dsa|id_ecdsa|id_ed25519)([.][A-Za-z0-9]+)?#${RD_PH_KEYPATH}#g" \
		-e "s#[^[:space:]\"':=]*[.](pem|key|p12|pfx)#${RD_PH_KEYPATH}#g" \
		-e "s#([?&](sig|signature|token|access_token|access_key|api_key|apikey|password|passwd|pwd|secret|auth|se|sv|st|x-amz-security-token)=)[^&[:space:]\"']+#\\1***REDACTED***#g" \
		-e "s/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD|AUTH))[=:][[:space:]]*[^[:space:]\"']+/\\1=***REDACTED***/g" \
		-e "s/(\"($_rd_sw)([_-][A-Za-z0-9_-]*)?\"[[:space:]]*:[[:space:]]*\")[^*\"][^\"]*\"/\\1***REDACTED***\"/g" \
		-e "s/(\"[A-Za-z0-9]+[_-]($_rd_sw)([_-][A-Za-z0-9_-]*)?\"[[:space:]]*:[[:space:]]*\")[^*\"][^\"]*\"/\\1***REDACTED***\"/g" \
		-e "s/(\"[A-Za-z0-9]*[a-z](Key|Token|Secret|Password|Passwd|Credential)([A-Z][A-Za-z0-9_]*)?\"[[:space:]]*:[[:space:]]*\")[^*\"][^\"]*\"/\\1***REDACTED***\"/g" \
		-e "s/(^|[[:space:]])(($_rd_sw)([_-][A-Za-z0-9_-]*)?)[=:][[:space:]]*[^*[:space:]\"',;}][^[:space:]\"',;}]*/\\1\\2=***REDACTED***/g" \
		-e "s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/${RD_PH_EMAIL}/g" \
		"$@"
	unset _rd_home _rd_rules _rd_len _rd_kind _rd_ce _rd_sw
}

# rd_redact_stream — read STDIN, write fully-redacted STDOUT. Runs the LITERAL registry stage
# (longest-value-first, treated as literals; extremely long lines bounded) then the STRUCTURAL
# pattern stage. Fails CLOSED (returns 1, emits nothing) when literal secrets are registered but
# their registry file cannot be materialised — it never passes secret-bearing text through
# unredacted.
rd_redact_stream() {
	_rd_harden
	if [ "$RD__SECRETS_N" -eq 0 ]; then
		# No literal values: only bound the line length, then pattern-redact.
		awk -v MAX="$RD_MAX_LINE" -v MARK="$RD_TRUNC_MARK" '
			{ line=$0; if (MAX+0>0 && length(line)>MAX+0) line=substr(line,1,MAX+0) MARK; print line }' \
			| _rd_pattern_stage
		return 0
	fi
	_rd_secfile=$(rd_mktemp) || { log_error "rd_redact_stream: cannot materialise the secret registry; failing closed"; return 1; }
	# Longest value first so an overlapping/substring secret cannot fragment a longer one.
	printf '%s\n' "$RD__SECRETS" | sed '/^$/d' \
		| awk '{ print length($0) "\t" $0 }' | LC_ALL=C sort -rn -s -k1,1 | cut -f2- > "$_rd_secfile" || {
			rm -f -- "$_rd_secfile" 2>/dev/null; unset _rd_secfile
			log_error "rd_redact_stream: cannot build the sorted registry; failing closed"; return 1; }
	awk -v SF="$_rd_secfile" -v PH="$RD_PH_SECRET" -v MAX="$RD_MAX_LINE" -v MARK="$RD_TRUNC_MARK" '
		BEGIN{
			n=0
			if (SF != "") { while ((getline s < SF) > 0) { if (s != "") sec[++n]=s } ; close(SF) }
		}
		{
			line=$0
			for (i=1;i<=n;i++){
				s=sec[i]; if (s=="") continue
				out=""; L=length(s)
				while ((p=index(line,s))>0){ out=out substr(line,1,p-1) PH; line=substr(line,p+L) }
				line=out line
			}
			if (MAX+0>0 && length(line)>MAX+0) line=substr(line,1,MAX+0) MARK
			print line
		}' | _rd_pattern_stage
	_rd_rc=$?
	rm -f -- "$_rd_secfile" 2>/dev/null
	unset _rd_secfile
	return "$_rd_rc"
}

# rd_redact_value <string> — redact a single string; print the result (no trailing newline added
# beyond what the input carried). Convenience over rd_redact_stream for one value.
rd_redact_value() {
	printf '%s' "$1" | rd_redact_stream
}

# --- artifact credential scanning (confirmed-secret gate) --------------------
# rd_scan_categories — the CLOSED set of HIGH-CONFIDENCE credential categories the artifact scanner
# screens for, one "<name><TAB><ERE>" per line. Only unambiguous shapes are here: a match is a
# CONFIRMED secret that must fail release readiness. Kept in lockstep with the enum in
# schemas/redaction-report.schema.json; tests/prod/253-redaction-security.sh cross-checks the two.
rd_scan_categories() {
	printf '%s\t%s\n' 'github-token' '(gh[pousra]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
	printf '%s\t%s\n' 'aws-access-key' '(AKIA|ASIA)[0-9A-Z]{16}'
	printf '%s\t%s\n' 'jwt' 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
	printf '%s\t%s\n' 'private-key-block' '-----BEGIN( [A-Z]+)? PRIVATE KEY-----'
	printf '%s\t%s\n' 'npm-token' '(npm_[A-Za-z0-9]{20,}|_authToken=[^[:space:]]{8,})'
	printf '%s\t%s\n' 'slack-token' 'xox[baprs]-[A-Za-z0-9-]{10,}'
	printf '%s\t%s\n' 'google-api-key' 'AIza[0-9A-Za-z_-]{35}'
}

# rd_scan_category_names — just the category names (for the schema-drift cross-check).
rd_scan_category_names() { rd_scan_categories | cut -f1; }

# rd_report_json <files_scanned> <files_with_secrets> <total_findings> <by_category_json> <confirmed:true|false>
# Emit the machine-readable redaction report (schemas/redaction-report.schema.json). It carries
# COUNTS + CATEGORY names + registry metadata ONLY — never a secret value. Requires jq.
rd_report_json() {
	command_exists jq || { log_error "rd_report_json: jq is required"; return 2; }
	_rd_cats_json=$(rd_scan_category_names | jq -R . | jq -sc .)
	_rd_capped=false; [ "$RD__SECRETS_CAPPED" = 1 ] && _rd_capped=true
	jq -n \
		--arg generated_at "$(timestamp_utc)" \
		--argjson registered "$RD__SECRETS_N" \
		--argjson capped "$_rd_capped" \
		--argjson cap_count "$RD_MAX_SECRETS" \
		--argjson cap_bytes "$RD_MAX_SECRET_BYTES" \
		--argjson categories "$_rd_cats_json" \
		--argjson files_scanned "${1:-0}" \
		--argjson files_with_secrets "${2:-0}" \
		--argjson total_findings "${3:-0}" \
		--argjson by_category "${4:-{\}}" \
		--argjson confirmed "${5:-false}" '
		{
			schema: "redaction-report",
			generated_at: $generated_at,
			sensitive_values: {
				registered: $registered,
				capped: $capped,
				cap_count: $cap_count,
				cap_bytes: $cap_bytes
			},
			categories: $categories,
			scan: {
				files_scanned: $files_scanned,
				files_with_secrets: $files_with_secrets,
				total_findings: $total_findings,
				by_category: $by_category
			},
			confirmed_secret_present: $confirmed
		}'
	unset _rd_cats_json _rd_capped
}

# rd_scan_paths <path>... — scan every regular file under the given files/dirs for CONFIRMED,
# high-confidence credential shapes. Emit the redaction report (counts + categories, NEVER values)
# to STDOUT. Returns 1 when ANY confirmed secret is present (fail-closed release gate), 0 when
# clean, 2 when a required tool is missing. Text-only (grep -I) so binary blobs are skipped.
rd_scan_paths() {
	command_exists jq || { log_error "rd_scan_paths: jq is required"; return 2; }
	_rd_harden
	_rd_work=$(rd_mktemp) || { log_error "rd_scan_paths: cannot create scratch state; failing closed"; return 2; }
	_rd_list="$_rd_work.list"; _rd_cats="$_rd_work.cats"; _rd_counts="$_rd_work.counts"
	rd_scan_categories > "$_rd_cats"
	: > "$_rd_counts"
	# Resolve the path arguments to a de-duplicated regular-file list.
	: > "$_rd_list"
	for _rd_p in "$@"; do
		if [ -d "$_rd_p" ]; then
			find "$_rd_p" -type f 2>/dev/null >> "$_rd_list"
		elif [ -f "$_rd_p" ]; then
			printf '%s\n' "$_rd_p" >> "$_rd_list"
		fi
	done
	if ! LC_ALL=C sort -u "$_rd_list" -o "$_rd_list" 2>/dev/null; then
		log_warn "rd_scan_paths: could not de-duplicate the file list; scanning as-is"
	fi
	_rd_files=0; _rd_withsec=0; _rd_total=0
	while IFS= read -r _rd_f; do
		[ -n "$_rd_f" ] || continue
		_rd_files=$((_rd_files + 1))
		_rd_fhit=0
		while IFS="$RD_TAB" read -r _rd_cat _rd_ere; do
			[ -n "$_rd_cat" ] || continue
			if _rd_c=$(grep -EIc -- "$_rd_ere" "$_rd_f" 2>/dev/null); then
				:
			else
				_rd_grc=$?
				[ "$_rd_grc" -gt 1 ] && log_warn "rd_scan_paths: could not read a file during scan"
				_rd_c=0
			fi
			case "$_rd_c" in ''|*[!0-9]*) _rd_c=0 ;; esac
			if [ "$_rd_c" -gt 0 ]; then
				printf '%s\t%s\n' "$_rd_cat" "$_rd_c" >> "$_rd_counts"
				_rd_total=$((_rd_total + _rd_c))
				_rd_fhit=1
			fi
		done < "$_rd_cats"
		[ "$_rd_fhit" = 1 ] && _rd_withsec=$((_rd_withsec + 1))
	done < "$_rd_list"

	# Aggregate per-category counts into a JSON object (counts only — never a value).
	_rd_bycat=$(LC_ALL=C awk -F"$RD_TAB" '{ c[$1]+=$2 } END{ for (k in c) print k "\t" c[k] }' "$_rd_counts" \
		| jq -R -s 'split("\n") | map(select(length>0) | split("\t") | {(.[0]): (.[1]|tonumber)}) | add // {}')
	[ -n "$_rd_bycat" ] || _rd_bycat='{}'
	_rd_confirmed=false; [ "$_rd_total" -gt 0 ] && _rd_confirmed=true

	rd_report_json "$_rd_files" "$_rd_withsec" "$_rd_total" "$_rd_bycat" "$_rd_confirmed"
	_rd_rc=0; [ "$_rd_total" -gt 0 ] && _rd_rc=1
	rm -f -- "$_rd_work" "$_rd_list" "$_rd_cats" "$_rd_counts" 2>/dev/null
	unset _rd_work _rd_list _rd_cats _rd_counts _rd_p _rd_files _rd_withsec _rd_total _rd_f _rd_fhit _rd_cat _rd_ere _rd_c _rd_grc _rd_bycat _rd_confirmed
	return "$_rd_rc"
}

# --- allowlisted-environment external execution ------------------------------
# rd_run_isolated <ALLOWED_VAR>... -- <cmd> [args...] — run <cmd> with a CLEAN environment that
# carries ONLY an operational allowlist (PATH/HOME/LANG/locale/TMPDIR) plus the named ALLOWED_VARs
# that are actually set. Every other ambient variable — a token, a signing passphrase — is dropped,
# so an external tool can never inherit a secret it was not explicitly granted. The full environment
# is NEVER printed. Returns the command's exit status; 2 on misuse.
rd_run_isolated() {
	_rd_harden
	_rd_allow="PATH HOME LANG LC_ALL LC_CTYPE TMPDIR"
	while [ $# -gt 0 ]; do
		case "$1" in
			--) shift; break ;;
			*) _rd_allow="$_rd_allow $1"; shift ;;
		esac
	done
	[ "$#" -ge 1 ] || { log_error "rd_run_isolated: missing command after '--'"; unset _rd_allow; return 2; }
	# Prepend each SET allowed var as a NAME=VALUE positional arg (values preserved verbatim; no
	# re-splitting), leaving the command last for `env -i` to exec.
	# shellcheck disable=SC2086  # _rd_allow is a deliberately word-split allowlist of names.
	for _rd_n in $_rd_allow; do
		if eval "[ -n \"\${$_rd_n+x}\" ]"; then
			# _rd_val is assigned via eval (indirect expansion); shellcheck cannot see it.
			# shellcheck disable=SC2154
			eval "_rd_val=\${$_rd_n}"
			set -- "$_rd_n=$_rd_val" "$@"
		fi
	done
	unset _rd_allow _rd_n _rd_val
	env -i "$@"
}
