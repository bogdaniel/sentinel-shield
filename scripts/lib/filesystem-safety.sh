#!/bin/sh
# Sentinel Shield — filesystem-safety library (POSIX sh; SOURCE, do not execute).
#
# The SINGLE choke point every project mutation passes through to enforce filesystem TRUST
# BOUNDARIES: a canonical, symlink-free, length-bounded path that physically stays inside a
# verified operation-owned root, is the kind of object we expect (a regular file — never a
# device/FIFO/socket/unexpected hard link), carries restrictive default permissions, and is
# never group/world-writable when it holds sensitive metadata. It generalises the physical
# containment validator proven for transactions (scripts/lib/transaction.sh :: _tx_contained)
# to EVERY mutable surface: .sentinel-shield metadata, operation locks, journals, snapshots,
# managed files, release evidence, downloaded artifacts, extracted archives, generated
# security reports, ref records, and temp work dirs.
#
# This file only DEFINES functions; it does not enable `set -eu`, use Bash arrays, `local`,
# `[[ ]]`, or process substitution. It sources sentinel-shield-common.sh (log_*) with an
# include guard so double-sourcing is safe.
#
# CONTRACT — validators print a STABLE reason TOKEN (fs_reason_codes lists them all) to STDOUT
# and return 1 on failure; they print nothing (or, for fs_canonical_root/fs_mktemp_*, the
# resolved path) and return 0 on success. Callers gate on the return code and surface the token
# in a fail-closed diagnostic. Advisory notes go to STDERR via log_*. Every reason token is
# also cataloged in schemas/filesystem-safety-reasons.schema.json (jq-validated).
#
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
#   . "$SCRIPT_DIR/lib/filesystem-safety.sh"

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_FS_SAFETY_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_FS_SAFETY_LOADED=1

# Pull in log_* if the caller has not already. __fs_dir resolves THIS library's directory.
__fs_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/lib/sentinel-shield-common.sh" ]; then
		. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
	elif [ -f "$__fs_dir/sentinel-shield-common.sh" ]; then
		. "$__fs_dir/sentinel-shield-common.sh"
	fi
fi

# Bounds (overridable by the caller BEFORE first use). A hostile or corrupt manifest cannot
# blow past these; both are conservative and well under common kernel limits.
: "${FS_MAX_PATH_LEN:=4096}"
: "${FS_MAX_NAME_LEN:=255}"

# fs_reason_codes — the canonical, STABLE set of reason tokens this library can emit, one per
# line. Kept in lockstep with schemas/filesystem-safety-reasons.schema.json; the test cross-
# checks the two so a new/renamed token can never drift out of the machine-readable catalog.
fs_reason_codes() {
	cat <<'EOF'
FS_INVALID_PATH
FS_PATH_TOO_LONG
FS_NAME_TOO_LONG
FS_ROOT_SYMLINK
FS_ROOT_NOT_DIR
FS_SYMLINK_COMPONENT
FS_ESCAPES_ROOT
FS_IS_SYMLINK
FS_NOT_REGULAR
FS_SPECIAL_FILE
FS_UNEXPECTED_HARDLINK
FS_LINK_COUNT_UNAVAILABLE
FS_GROUP_WORLD_WRITABLE
FS_OWNER_MISMATCH
FS_CASE_COLLISION
FS_PATH_COLLISION
FS_TEMP_OUTSIDE_ROOT
FS_REFUSE_DELETE
FS_RACE_DETECTED
FS_MKDIR_FAILED
FS_WRITE_FAILED
FS_MODE_FAILED
EOF
}

# --- lexical + length gates --------------------------------------------------
# _fs_rel_safe <relpath> — accept only a project-relative path (no absolute root, no '..'
# traversal, no empty). Mirrors transaction.sh :: _tx_rel_safe.
_fs_rel_safe() {
	case "$1" in
		"" | /* | .. | ../* | */.. | */../*) return 1 ;;
		*) return 0 ;;
	esac
}

# fs_check_lengths <path> — bound the full path AND each component. Prints FS_PATH_TOO_LONG /
# FS_NAME_TOO_LONG and returns 1 on violation.
fs_check_lengths() {
	_fl_p="$1"
	if [ "${#_fl_p}" -gt "$FS_MAX_PATH_LEN" ]; then
		printf 'FS_PATH_TOO_LONG'; unset _fl_p; return 1
	fi
	_fl_rest="$_fl_p"
	while [ -n "$_fl_rest" ]; do
		case "$_fl_rest" in
			*/*) _fl_comp=${_fl_rest%%/*}; _fl_rest=${_fl_rest#*/} ;;
			*)   _fl_comp=$_fl_rest; _fl_rest="" ;;
		esac
		if [ "${#_fl_comp}" -gt "$FS_MAX_NAME_LEN" ]; then
			printf 'FS_NAME_TOO_LONG'; unset _fl_p _fl_rest _fl_comp; return 1
		fi
	done
	unset _fl_p _fl_rest _fl_comp
	return 0
}

# --- canonical root + physical containment -----------------------------------
# fs_canonical_root <path> — validate a TRUST ROOT (a target project, a workspace, an owned
# temp root). The final component must NOT be a symlink (a symlinked root would let every
# "contained" write escape), the path must resolve to a real directory, and it must satisfy the
# length bound. On success prints the canonical absolute path (cd -P/pwd -P) and returns 0; on
# failure prints a reason token and returns 1.
#   FS_INVALID_PATH   empty / control-char / unresolvable.
#   FS_ROOT_SYMLINK   the final component is a symlink.
#   FS_ROOT_NOT_DIR   resolves but is not a directory.
fs_canonical_root() {
	_cr_p="$1"
	[ -n "$_cr_p" ] || { printf 'FS_INVALID_PATH'; unset _cr_p; return 1; }
	case "$_cr_p" in *[[:cntrl:]]*) printf 'FS_INVALID_PATH'; unset _cr_p; return 1 ;; esac
	_cr_len=$(fs_check_lengths "$_cr_p") || { printf '%s' "$_cr_len"; unset _cr_p _cr_len; return 1; }
	if [ -L "$_cr_p" ]; then printf 'FS_ROOT_SYMLINK'; unset _cr_p _cr_len; return 1; fi
	if [ ! -d "$_cr_p" ]; then printf 'FS_ROOT_NOT_DIR'; unset _cr_p _cr_len; return 1; fi
	_cr_real=$(CDPATH= cd -P -- "$_cr_p" 2>/dev/null && pwd -P) \
		|| { printf 'FS_INVALID_PATH'; unset _cr_p _cr_len _cr_real; return 1; }
	printf '%s' "$_cr_real"
	unset _cr_p _cr_len _cr_real
	return 0
}

# fs_contained <base> <relpath> — verify that <base>/<relpath> stays PHYSICALLY within <base>,
# following NO symlinked component and NOT requiring the final component to exist (a brand-new
# file is fine). Mirrors transaction.sh :: _tx_contained so both agree byte-for-byte on what is
# in-bounds. On failure prints a reason and returns 1:
#   FS_INVALID_PATH     empty / absolute / '..' / control-char / '.'-or-empty component /
#                       length bound / unresolvable base.
#   FS_SYMLINK_COMPONENT a parent or the final component is a symlink.
#   FS_ESCAPES_ROOT     the nearest existing parent resolves outside <base>.
fs_contained() {
	_fc_base="$1"; _fc_rel="$2"
	_fs_rel_safe "$_fc_rel" || { printf 'FS_INVALID_PATH'; unset _fc_base _fc_rel; return 1; }
	case "$_fc_rel" in *[[:cntrl:]]*) printf 'FS_INVALID_PATH'; unset _fc_base _fc_rel; return 1 ;; esac
	_fc_len=$(fs_check_lengths "$_fc_rel") || { printf '%s' "$_fc_len"; unset _fc_base _fc_rel _fc_len; return 1; }
	_fc_basereal=$(CDPATH= cd -P -- "$_fc_base" 2>/dev/null && pwd -P) \
		|| { printf 'FS_INVALID_PATH'; unset _fc_base _fc_rel _fc_len; return 1; }
	_fc_cur="$_fc_base"; _fc_deepest="$_fc_base"; _fc_rest="$_fc_rel"
	while [ -n "$_fc_rest" ]; do
		case "$_fc_rest" in
			*/*) _fc_comp=${_fc_rest%%/*}; _fc_rest=${_fc_rest#*/} ;;
			*)   _fc_comp=$_fc_rest; _fc_rest="" ;;
		esac
		case "$_fc_comp" in
			"" | . | ..) printf 'FS_INVALID_PATH'; unset _fc_base _fc_rel _fc_len _fc_basereal _fc_cur _fc_deepest _fc_rest _fc_comp; return 1 ;;
		esac
		_fc_cur="$_fc_cur/$_fc_comp"
		if [ -L "$_fc_cur" ]; then printf 'FS_SYMLINK_COMPONENT'; unset _fc_base _fc_rel _fc_len _fc_basereal _fc_cur _fc_deepest _fc_rest _fc_comp; return 1; fi
		[ -e "$_fc_cur" ] || break
		[ -d "$_fc_cur" ] && _fc_deepest="$_fc_cur"
	done
	_fc_real=$(CDPATH= cd -P -- "$_fc_deepest" 2>/dev/null && pwd -P) \
		|| { printf 'FS_ESCAPES_ROOT'; unset _fc_base _fc_rel _fc_len _fc_basereal _fc_cur _fc_deepest _fc_rest _fc_comp _fc_real; return 1; }
	if [ "$_fc_real" = "$_fc_basereal" ]; then
		unset _fc_base _fc_rel _fc_len _fc_basereal _fc_cur _fc_deepest _fc_rest _fc_comp _fc_real; return 0
	fi
	_fc_after=${_fc_real#"$_fc_basereal"/}
	[ "$_fc_after" != "$_fc_real" ] || { printf 'FS_ESCAPES_ROOT'; unset _fc_base _fc_rel _fc_len _fc_basereal _fc_cur _fc_deepest _fc_rest _fc_comp _fc_real _fc_after; return 1; }
	unset _fc_base _fc_rel _fc_len _fc_basereal _fc_cur _fc_deepest _fc_rest _fc_comp _fc_real _fc_after
	return 0
}

# --- object-shape expectations (no-follow, regular-only) ---------------------
# POSIX sh has no O_NOFOLLOW; we approximate a no-follow open with an lstat-style `[ -L ]`
# guard BEFORE any read/write, combined with fs_contained on the parent path so a symlinked
# component can never be traversed.
#
# fs_assert_not_symlink <path> — the path itself must not be a symlink. FS_IS_SYMLINK.
fs_assert_not_symlink() {
	if [ -L "$1" ]; then printf 'FS_IS_SYMLINK'; return 1; fi
	return 0
}

# fs_assert_no_special <path> — reject a device (block/char), FIFO, or socket. These must never
# stand in for a metadata/managed file. FS_SPECIAL_FILE. (A missing path is not special.)
fs_assert_no_special() {
	if [ -p "$1" ] || [ -S "$1" ] || [ -b "$1" ] || [ -c "$1" ]; then
		printf 'FS_SPECIAL_FILE'; return 1
	fi
	return 0
}

# fs_assert_regular <path> — the path must EXIST and be a plain regular file, not a symlink,
# directory, or special file. FS_IS_SYMLINK / FS_SPECIAL_FILE / FS_NOT_REGULAR.
fs_assert_regular() {
	if [ -L "$1" ]; then printf 'FS_IS_SYMLINK'; return 1; fi
	if [ -p "$1" ] || [ -S "$1" ] || [ -b "$1" ] || [ -c "$1" ]; then printf 'FS_SPECIAL_FILE'; return 1; fi
	if [ ! -f "$1" ]; then printf 'FS_NOT_REGULAR'; return 1; fi
	return 0
}

# _fs_nlink <path> — hard-link count from `ls -ldn` (numeric), or "" when unobtainable.
# POSIX sh has no `stat`; parsing `ls -ldn` is the portable way to read the link count.
# shellcheck disable=SC2012
_fs_nlink() { ls -ldn -- "$1" 2>/dev/null | awk 'NR==1{print $2}'; }

# fs_assert_single_link <path> [mode] — a metadata/managed regular file must have EXACTLY one
# hard link; an extra link is an out-of-band alias to the same inode (an attacker keeping a
# handle, or a planted link that mutates a file outside the trust root). The object must be a
# regular file first (checked).
#
# HARD-LINK INSPECTION MAY BE UNAVAILABLE — `ls` may be missing/shadowed, emit malformed output,
# or (on an unsupported platform) print a link-count field this parser cannot read. Because the
# count is SECURITY-SENSITIVE, an undeterminable count must NEVER silently pass on a trust
# surface. Two explicit modes govern that case:
#   strict  (DEFAULT, and the value every security-sensitive caller MUST pass — operation locks,
#           transaction journals, release evidence, source-ref records, security reports,
#           authorization records): an undeterminable count FAILS CLOSED with a distinct token
#           FS_LINK_COUNT_UNAVAILABLE. It never fabricates a passing count.
#   advisory: an undeterminable count logs a warning to STDERR and returns 0 (best-effort probe
#           on a non-security surface). ONLY an exact "advisory" downgrades; any other value
#           (including a typo) is treated as strict — the safe default.
# A DETERMINABLE count >= 2 is always rejected with FS_UNEXPECTED_HARDLINK in BOTH modes.
# Reasons: FS_IS_SYMLINK / FS_SPECIAL_FILE / FS_NOT_REGULAR (via fs_assert_regular) /
# FS_UNEXPECTED_HARDLINK / FS_LINK_COUNT_UNAVAILABLE.
fs_assert_single_link() {
	_al_p="$1"
	_al_mode="${2:-strict}"
	_al_r=$(fs_assert_regular "$_al_p") || { printf '%s' "$_al_r"; unset _al_p _al_mode _al_r; return 1; }
	_al_n=$(_fs_nlink "$_al_p")
	case "$_al_n" in
		1 )
			unset _al_p _al_mode _al_r _al_n; return 0 ;;
		'' | 0 | *[!0-9]* )
			# Link count could not be determined (ls missing/shadowed, empty, malformed, an
			# impossible 0 for an existing regular file, or an unsupported-platform format).
			if [ "$_al_mode" = "advisory" ]; then
				if command -v log_warn >/dev/null 2>&1; then
					log_warn "fs_assert_single_link: hard-link count unavailable for '$_al_p' (advisory mode: passing)"
				else
					printf '%s\n' "[sentinel-shield][warn] fs_assert_single_link: hard-link count unavailable for '$_al_p' (advisory mode: passing)" >&2
				fi
				unset _al_p _al_mode _al_r _al_n; return 0
			fi
			printf 'FS_LINK_COUNT_UNAVAILABLE'; unset _al_p _al_mode _al_r _al_n; return 1 ;;
		* )
			# A determinable count >= 2: an out-of-band alias to the same inode. Reject in BOTH modes.
			printf 'FS_UNEXPECTED_HARDLINK'; unset _al_p _al_mode _al_r _al_n; return 1 ;;
	esac
}

# --- permission + ownership boundaries ---------------------------------------
# _fs_mode_str <path> — the 10-char `ls -ld` mode string (e.g. -rw-------), or "".
# No POSIX `stat`; `ls -ld` mode parsing is the portable read of the permission bits.
# shellcheck disable=SC2012
_fs_mode_str() { ls -ld -- "$1" 2>/dev/null | awk 'NR==1{print $1}'; }

# fs_assert_not_group_world_writable <path> — sensitive metadata (locks, journals, evidence,
# ref records) must not be writable by group or other; otherwise another local user could
# tamper with the trust state. FS_GROUP_WORLD_WRITABLE. Fails closed when the mode cannot be
# read (an unreadable object is not provably safe).
fs_assert_not_group_world_writable() {
	_gw=$(_fs_mode_str "$1")
	[ -n "$_gw" ] || { printf 'FS_GROUP_WORLD_WRITABLE'; unset _gw; return 1; }
	# positions (1-based): 1 type, 2-4 user, 5-7 group, 8-10 other. group-w=6, other-w=9.
	_gw_g=$(printf '%s' "$_gw" | cut -c6)
	_gw_o=$(printf '%s' "$_gw" | cut -c9)
	if [ "$_gw_g" = "w" ] || [ "$_gw_o" = "w" ]; then
		printf 'FS_GROUP_WORLD_WRITABLE'; unset _gw _gw_g _gw_o; return 1
	fi
	unset _gw _gw_g _gw_o
	return 0
}

# fs_assert_owner <path> — the object must be owned by the current effective user, where the
# platform exposes both `id -u` and a numeric `ls -ldn` uid. FS_OWNER_MISMATCH. Degrades to
# success (documented) only when neither identity can be read — never fabricates a match.
fs_assert_owner() {
	command_exists id || return 0
	_ao_me=$(id -u 2>/dev/null || printf '')
	[ -n "$_ao_me" ] || { unset _ao_me; return 0; }
	# shellcheck disable=SC2012  # no POSIX stat; ls -ldn is the portable numeric-uid read.
	_ao_u=$(ls -ldn -- "$1" 2>/dev/null | awk 'NR==1{print $3}')
	case "$_ao_u" in
		'' | *[!0-9]* ) unset _ao_me _ao_u; return 0 ;;      # uid unavailable: documented degrade
	esac
	if [ "$_ao_u" != "$_ao_me" ]; then
		printf 'FS_OWNER_MISMATCH'; unset _ao_me _ao_u; return 1
	fi
	unset _ao_me _ao_u
	return 0
}

# fs_apply_secret_mode <path> — 0600 (owner-only) for a sensitive metadata file. FS_MODE_FAILED.
fs_apply_secret_mode() {
	chmod 600 "$1" 2>/dev/null || { printf 'FS_MODE_FAILED'; return 1; }
	return 0
}

# fs_apply_file_mode <path> <exec:0|1> — a restrictive default that PRESERVES an intended
# executable bit: 0755 when <exec>=1, else 0644. FS_MODE_FAILED.
fs_apply_file_mode() {
	if [ "${2:-0}" = "1" ]; then
		chmod 755 "$1" 2>/dev/null || { printf 'FS_MODE_FAILED'; return 1; }
	else
		chmod 644 "$1" 2>/dev/null || { printf 'FS_MODE_FAILED'; return 1; }
	fi
	return 0
}

# fs_preserve_exec <src> <dst> — copy ONLY the intended executable intent: if <src> is
# user-executable, <dst> becomes 0755, else 0644. Lets an atomic replace keep a managed
# script runnable while never granting exec to plain data. FS_MODE_FAILED.
fs_preserve_exec() {
	if [ -x "$1" ] && [ ! -d "$1" ]; then
		fs_apply_file_mode "$2" 1
	else
		fs_apply_file_mode "$2" 0
	fi
}

# --- case-insensitive FS + collision detection -------------------------------
# fs_fs_case_insensitive <dir> — probe whether <dir> lives on a case-insensitive filesystem
# (common on default macOS/APFS and Windows volumes). Returns 0 (insensitive) / 1 (sensitive
# or undeterminable). Used to decide whether case-fold collisions are actually dangerous.
fs_fs_case_insensitive() {
	_ci_d="$1"; [ -d "$_ci_d" ] || { unset _ci_d; return 1; }
	_ci_probe="$_ci_d/.ss-case-probe.$$"
	: > "$_ci_probe.a" 2>/dev/null || { rm -f "$_ci_probe.a" 2>/dev/null; unset _ci_d _ci_probe; return 1; }
	if [ -e "$_ci_probe.A" ]; then
		rm -f "$_ci_probe.a" 2>/dev/null; unset _ci_d _ci_probe; return 0
	fi
	rm -f "$_ci_probe.a" 2>/dev/null
	unset _ci_d _ci_probe
	return 1
}

# fs_casefold <string> — the case-folded (lowercased) form used for collision comparison.
fs_casefold() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# fs_casefold_collisions — read candidate paths on STDIN (one per line), emit each DISTINCT
# path that participates in a case-fold collision (two entries equal only after lowercasing).
# Returns 1 when any collision exists, 0 when the set is case-fold-unique. A caller writing
# into a case-insensitive tree MUST reject on a non-zero return (FS_CASE_COLLISION): otherwise
# one entry silently overwrites the other. Deterministic (LC_ALL=C sort).
fs_casefold_collisions() {
	_cc_tmp=$(fs_casefold_collisions_impl)
	if [ -n "$_cc_tmp" ]; then printf '%s\n' "$_cc_tmp"; unset _cc_tmp; return 1; fi
	unset _cc_tmp; return 0
}
# Implementation split so the outer function can both print and signal via return code.
fs_casefold_collisions_impl() {
	# Build "<folded>\t<original>", find folded keys with >1 distinct original, print originals.
	_ci_in=$(cat)
	printf '%s\n' "$_ci_in" | sed '/^$/d' | while IFS= read -r _cc_l; do
		printf '%s\t%s\n' "$(fs_casefold "$_cc_l")" "$_cc_l"
	done | LC_ALL=C sort -u | awk -F'\t' '
		{ if ($1 == prevk) { if (!pshown) { print prevv; pshown=1 } print $2 }
		  else { prevk=$1; prevv=$2; pshown=0 } }'
	unset _ci_in _cc_l
}

# fs_path_collisions — read candidate paths on STDIN, normalise each (collapse repeated
# slashes, drop './' segments, strip a trailing '/') and emit any path sharing a normalised
# form with another. Returns 1 when a post-normalisation collision exists. FS_PATH_COLLISION.
fs_path_collisions() {
	_pc_out=$(cat | sed '/^$/d' | while IFS= read -r _pc_l; do
		# Drop './' segments (leading and mid-path) and a trailing '/'. BRE alternation (\|) is a
		# GNU extension unsupported by BSD/macOS sed, so use branch loops that fully collapse
		# repeated './././' runs portably rather than a single overlapping /g pass.
		_pc_n=$(printf '%s' "$_pc_l" | sed -e 's#//*#/#g' -e ':t' -e 's#^\./##' -e 't t' -e ':u' -e 's#/\./#/#g' -e 't u' -e 's#/$##')
		printf '%s\t%s\n' "$_pc_n" "$_pc_l"
	done | LC_ALL=C sort | awk -F'\t' '
		{ if ($1 == prevk) { if (!pshown) { print prevv; pshown=1 } print $2 }
		  else { prevk=$1; prevv=$2; pshown=0 } }')
	if [ -n "$_pc_out" ]; then printf '%s\n' "$_pc_out"; unset _pc_out _pc_l _pc_n; return 1; fi
	unset _pc_out _pc_l _pc_n; return 0
}

# --- safe directory / atomic file operations --------------------------------
# fs_safe_mkdir <base> <relpath> [mode] — create <base>/<relpath> (and parents) ONLY when the
# whole path is physically contained in <base>; then set a restrictive mode (default 0700). On
# a containment failure prints the fs_contained reason; on a mkdir/chmod failure prints
# FS_MKDIR_FAILED / FS_MODE_FAILED. Returns 1 on any failure.
fs_safe_mkdir() {
	_sm_base="$1"; _sm_rel="$2"; _sm_mode="${3:-700}"
	_sm_r=$(fs_contained "$_sm_base" "$_sm_rel") || { printf '%s' "$_sm_r"; unset _sm_base _sm_rel _sm_mode _sm_r; return 1; }
	mkdir -p -- "$_sm_base/$_sm_rel" 2>/dev/null || { printf 'FS_MKDIR_FAILED'; unset _sm_base _sm_rel _sm_mode _sm_r; return 1; }
	chmod "$_sm_mode" "$_sm_base/$_sm_rel" 2>/dev/null || { printf 'FS_MODE_FAILED'; unset _sm_base _sm_rel _sm_mode _sm_r; return 1; }
	unset _sm_base _sm_rel _sm_mode _sm_r
	return 0
}

# fs_atomic_replace <src> <dst> — durably, atomically replace <dst> with the bytes of <src>:
# the destination directory must resolve to a real (non-symlinked) directory; <dst> itself must
# not be an existing symlink or special file (never write THROUGH a link, e.g. a report
# destination swapped to a symlink); write to a same-dir in-flight temp; flush; rename over
# <dst>; then apply the caller-preserved executable intent. Reasons: FS_IS_SYMLINK /
# FS_SPECIAL_FILE / FS_SYMLINK_COMPONENT / FS_WRITE_FAILED / FS_MODE_FAILED. Returns 1 on any
# failure WITHOUT leaving a partial destination.
fs_atomic_replace() {
	_ar_src="$1"; _ar_dst="$2"
	_ar_dir=$(dirname -- "$_ar_dst")
	# The destination directory must be real and symlink-free (canonicalised).
	_ar_realdir=$(CDPATH= cd -P -- "$_ar_dir" 2>/dev/null && pwd -P) \
		|| { printf 'FS_SYMLINK_COMPONENT'; unset _ar_src _ar_dst _ar_dir _ar_realdir; return 1; }
	# Never replace THROUGH an existing symlink or a special file at the destination.
	if [ -L "$_ar_dst" ]; then printf 'FS_IS_SYMLINK'; unset _ar_src _ar_dst _ar_dir _ar_realdir; return 1; fi
	if [ -p "$_ar_dst" ] || [ -S "$_ar_dst" ] || [ -b "$_ar_dst" ] || [ -c "$_ar_dst" ]; then
		printf 'FS_SPECIAL_FILE'; unset _ar_src _ar_dst _ar_dir _ar_realdir; return 1
	fi
	_ar_tmp="$_ar_realdir/.ss-fs-inflight.$$.$(basename -- "$_ar_dst")"
	if ! cp -- "$_ar_src" "$_ar_tmp" 2>/dev/null; then
		rm -f -- "$_ar_tmp" 2>/dev/null
		printf 'FS_WRITE_FAILED'; unset _ar_src _ar_dst _ar_dir _ar_realdir _ar_tmp; return 1
	fi
	command -v sync >/dev/null 2>&1 && sync 2>/dev/null
	if ! mv -- "$_ar_tmp" "$_ar_realdir/$(basename -- "$_ar_dst")" 2>/dev/null; then
		rm -f -- "$_ar_tmp" 2>/dev/null
		printf 'FS_WRITE_FAILED'; unset _ar_src _ar_dst _ar_dir _ar_realdir _ar_tmp; return 1
	fi
	if ! fs_preserve_exec "$_ar_src" "$_ar_realdir/$(basename -- "$_ar_dst")" >/dev/null 2>&1; then
		printf 'FS_MODE_FAILED'; unset _ar_src _ar_dst _ar_dir _ar_realdir _ar_tmp; return 1
	fi
	command -v sync >/dev/null 2>&1 && sync 2>/dev/null
	unset _ar_src _ar_dst _ar_dir _ar_realdir _ar_tmp
	return 0
}

# --- trusted temp creation ---------------------------------------------------
# fs_assert_temp_root <workspace> <candidate> — the candidate temp root MUST resolve INSIDE the
# trusted <workspace> (never $TMPDIR, never a sibling escape). Prints FS_TEMP_OUTSIDE_ROOT and
# returns 1 otherwise. Both are canonicalised so a symlinked candidate cannot masquerade.
fs_assert_temp_root() {
	_tr_ws="$1"; _tr_cand="$2"
	_tr_wsr=$(CDPATH= cd -P -- "$_tr_ws" 2>/dev/null && pwd -P) \
		|| { printf 'FS_TEMP_OUTSIDE_ROOT'; unset _tr_ws _tr_cand _tr_wsr; return 1; }
	_tr_cr=$(CDPATH= cd -P -- "$_tr_cand" 2>/dev/null && pwd -P) \
		|| { printf 'FS_TEMP_OUTSIDE_ROOT'; unset _tr_ws _tr_cand _tr_wsr _tr_cr; return 1; }
	if [ "$_tr_cr" = "$_tr_wsr" ]; then unset _tr_ws _tr_cand _tr_wsr _tr_cr; return 0; fi
	_tr_after=${_tr_cr#"$_tr_wsr"/}
	if [ "$_tr_after" = "$_tr_cr" ]; then
		printf 'FS_TEMP_OUTSIDE_ROOT'; unset _tr_ws _tr_cand _tr_wsr _tr_cr _tr_after; return 1
	fi
	unset _tr_ws _tr_cand _tr_wsr _tr_cr _tr_after
	return 0
}

# fs_mktemp_dir <trusted_root> — create a fresh 0700 temp directory INSIDE <trusted_root> (a
# canonical, non-symlinked dir), verify the result is physically contained, and print its path.
# Never consults $TMPDIR. FS_ROOT_* / FS_MKDIR_FAILED / FS_ESCAPES_ROOT on failure.
fs_mktemp_dir() {
	_md_root=$(fs_canonical_root "$1") || { printf '%s' "$_md_root"; unset _md_root; return 1; }
	_md_d=$(mktemp -d "$_md_root/.ss-tmp.XXXXXX" 2>/dev/null) \
		|| { printf 'FS_MKDIR_FAILED'; unset _md_root _md_d; return 1; }
	chmod 700 "$_md_d" 2>/dev/null || { rm -rf -- "$_md_d" 2>/dev/null; printf 'FS_MODE_FAILED'; unset _md_root _md_d; return 1; }
	_md_real=$(CDPATH= cd -P -- "$_md_d" 2>/dev/null && pwd -P) || { rm -rf -- "$_md_d" 2>/dev/null; printf 'FS_ESCAPES_ROOT'; unset _md_root _md_d _md_real; return 1; }
	case "$_md_real/" in
		"$_md_root"/*) ;;
		*) rm -rf -- "$_md_d" 2>/dev/null; printf 'FS_ESCAPES_ROOT'; unset _md_root _md_d _md_real; return 1 ;;
	esac
	printf '%s' "$_md_real"
	unset _md_root _md_d _md_real
	return 0
}

# fs_mktemp_file <trusted_root> — create a fresh 0600 temp FILE inside <trusted_root> and print
# its path. Same trust guarantees as fs_mktemp_dir.
fs_mktemp_file() {
	_mf_root=$(fs_canonical_root "$1") || { printf '%s' "$_mf_root"; unset _mf_root; return 1; }
	_mf_f=$(mktemp "$_mf_root/.ss-tmp.XXXXXX" 2>/dev/null) \
		|| { printf 'FS_WRITE_FAILED'; unset _mf_root _mf_f; return 1; }
	chmod 600 "$_mf_f" 2>/dev/null || { rm -f -- "$_mf_f" 2>/dev/null; printf 'FS_MODE_FAILED'; unset _mf_root _mf_f; return 1; }
	printf '%s' "$_mf_root/$(basename -- "$_mf_f")"
	unset _mf_root _mf_f
	return 0
}

# --- race detection (validation vs. mutation) --------------------------------
# fs_identity <path> — a compact identity token (inode[:size]) used to detect that a path was
# swapped/rewritten BETWEEN validation and use (a TOCTOU race). An atomic replace changes the
# inode; an in-place rewrite changes the size — either breaks the match. Prints "" when the
# object is absent/unreadable.
fs_identity() {
	# shellcheck disable=SC2012  # no POSIX stat; ls -di is the portable inode read.
	_id_ino=$(ls -di -- "$1" 2>/dev/null | awk 'NR==1{print $1}')
	[ -n "$_id_ino" ] || { unset _id_ino; return 0; }
	if [ -f "$1" ] && [ ! -L "$1" ]; then
		_id_sz=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
		printf '%s:%s' "$_id_ino" "${_id_sz:-0}"
	else
		printf '%s' "$_id_ino"
	fi
	unset _id_ino _id_sz
}

# fs_verify_unchanged <path> <prev-identity> — recompute fs_identity and confirm it still
# matches the value captured at validation time. Prints FS_RACE_DETECTED and returns 1 when the
# object changed (swapped inode, resized, or vanished). Returns 0 only on an exact match.
fs_verify_unchanged() {
	_vu_now=$(fs_identity "$1")
	if [ -z "$_vu_now" ] || [ "$_vu_now" != "$2" ]; then
		printf 'FS_RACE_DETECTED'; unset _vu_now; return 1
	fi
	unset _vu_now
	return 0
}

# --- safe recursive deletion -------------------------------------------------
# fs_safe_rmtree <owned_root> <target> — recursively delete <target> ONLY when it is a real
# directory PHYSICALLY contained in the verified operation-owned <owned_root> (or is that root
# itself), is not a symlink, and is not one of the always-forbidden roots (/, $HOME). Every
# other case — an empty argument, a dangerous root, an UNOWNED path outside <owned_root>, or a
# symlinked target — is REFUSED with FS_REFUSE_DELETE and nothing is removed. This is the ONLY
# sanctioned `rm -rf` wrapper; it must never be unguarded.
fs_safe_rmtree() {
	_rt_root="$1"; _rt_tgt="$2"
	# Empty operands -> refuse (a bare `rm -rf ""`/"$UNSET/" is how catastrophes happen).
	{ [ -n "$_rt_root" ] && [ -n "$_rt_tgt" ]; } || { printf 'FS_REFUSE_DELETE'; unset _rt_root _rt_tgt; return 1; }
	# The owned root must itself be a real, safe, canonical directory.
	_rt_rootc=$(fs_canonical_root "$_rt_root") || { printf 'FS_REFUSE_DELETE'; unset _rt_root _rt_tgt _rt_rootc; return 1; }
	# Never follow a symlinked target into an unowned tree.
	if [ -L "$_rt_tgt" ]; then printf 'FS_REFUSE_DELETE'; unset _rt_root _rt_tgt _rt_rootc; return 1; fi
	# The target must exist as a directory to be canonicalised (a non-dir/absent target is refused
	# rather than guessed at — deletion is not idempotent-by-accident here).
	[ -d "$_rt_tgt" ] || { printf 'FS_REFUSE_DELETE'; unset _rt_root _rt_tgt _rt_rootc; return 1; }
	_rt_tgtc=$(CDPATH= cd -P -- "$_rt_tgt" 2>/dev/null && pwd -P) \
		|| { printf 'FS_REFUSE_DELETE'; unset _rt_root _rt_tgt _rt_rootc _rt_tgtc; return 1; }
	# Always-forbidden roots, regardless of ownership claims.
	case "$_rt_tgtc" in
		"/" | "" ) printf 'FS_REFUSE_DELETE'; unset _rt_root _rt_tgt _rt_rootc _rt_tgtc; return 1 ;;
	esac
	if [ -n "${HOME:-}" ]; then
		_rt_homec=$(CDPATH= cd -P -- "$HOME" 2>/dev/null && pwd -P || printf '')
		if [ -n "$_rt_homec" ] && [ "$_rt_tgtc" = "$_rt_homec" ]; then
			printf 'FS_REFUSE_DELETE'; unset _rt_root _rt_tgt _rt_rootc _rt_tgtc _rt_homec; return 1
		fi
	fi
	# Containment: target must be the owned root itself or strictly below it.
	if [ "$_rt_tgtc" != "$_rt_rootc" ]; then
		_rt_after=${_rt_tgtc#"$_rt_rootc"/}
		if [ "$_rt_after" = "$_rt_tgtc" ]; then
			printf 'FS_REFUSE_DELETE'; unset _rt_root _rt_tgt _rt_rootc _rt_tgtc _rt_homec _rt_after; return 1
		fi
	fi
	rm -rf -- "$_rt_tgtc" 2>/dev/null || { printf 'FS_REFUSE_DELETE'; unset _rt_root _rt_tgt _rt_rootc _rt_tgtc _rt_homec _rt_after; return 1; }
	unset _rt_root _rt_tgt _rt_rootc _rt_tgtc _rt_homec _rt_after
	return 0
}
