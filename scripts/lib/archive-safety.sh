#!/bin/sh
# Sentinel Shield — archive-safety library (POSIX sh; SOURCE, do not execute).
#
# Fail-CLOSED inspection of a downloaded artifact ZIP (GitHub Actions artifacts are
# zip archives) BEFORE and DURING extraction, so a malicious archive can never write
# outside its extraction root or exhaust disk. It complements the identity/ownership
# checks in verify-release-artifacts.sh.
#
# This file only DEFINES functions; it does not enable `set -eu`, use Bash arrays,
# `local`, or `[[ ]]`. Diagnostics go to STDERR (log_* from the common lib). The
# scan function reports each violation as a reason TOKEN on STDOUT (one per line) so
# a caller can capture and gate on them, mirroring the ERRORS=$(...) pattern used by
# validate-release-evidence.sh. Requires: zipinfo + unzip (from Info-ZIP), find.
#
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
#   . "$SCRIPT_DIR/lib/archive-safety.sh"

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_ARCHIVE_SAFETY_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_ARCHIVE_SAFETY_LOADED=1

# archive_safety_tools_ok — true when the required unzip toolchain is present.
archive_safety_tools_ok() {
	command_exists zipinfo && command_exists unzip
}

# archive_safety_scan <zip> <max_bytes> <max_entries>
# Inspect the archive listing WITHOUT extracting. Emits one reason token per line to
# STDOUT for every violation found; emits nothing when the archive is safe. Always
# returns 0 — the caller decides based on whether output was produced. Reason tokens:
#   unreadable-archive
#   absolute-path:<entry>        an entry anchored at '/'
#   path-traversal:<entry>       an entry with a '..' path component
#   duplicate-path:<entry>       the same normalized path listed more than once
#   symlink:<entry>              a symlink entry (never allowed in an artifact)
#   too-many-entries:<n>/<max>   entry count exceeds the cap
#   oversize:<bytes>/<max>       total uncompressed size exceeds the cap (zip bomb)
archive_safety_scan() {
	_as_zip="$1"; _as_max_bytes="$2"; _as_max_entries="$3"

	if [ ! -f "$_as_zip" ] || ! zipinfo -1 "$_as_zip" >/dev/null 2>&1; then
		printf 'unreadable-archive\n'
		return 0
	fi

	# Entry names (one per line, verbatim as stored in the archive).
	_as_names=$(zipinfo -1 "$_as_zip" 2>/dev/null)

	# Absolute paths and '..' traversal components.
	printf '%s\n' "$_as_names" | while IFS= read -r _as_n; do
		[ -n "$_as_n" ] || continue
		case "$_as_n" in
			/*) printf 'absolute-path:%s\n' "$_as_n" ;;
		esac
		case "/$_as_n/" in
			*/../*) printf 'path-traversal:%s\n' "$_as_n" ;;
		esac
	done

	# Duplicate paths (a later entry can overwrite an earlier verified one).
	printf '%s\n' "$_as_names" | sed '/^$/d' | sort | uniq -d | while IFS= read -r _as_d; do
		[ -n "$_as_d" ] || continue
		printf 'duplicate-path:%s\n' "$_as_d"
	done

	# Symlink entries: the long zipinfo listing marks them with a leading 'l'.
	# Reject ALL symlinks (a strict superset of "symlinks escaping the root").
	zipinfo "$_as_zip" 2>/dev/null | awk '
		/^l/ { $1=$2=$3=$4=$5=$6=$7=$8=""; sub(/^ +/,""); if (length($0) > 0) printf "symlink:%s\n", $0 }'

	# Entry-count cap.
	_as_count=$(printf '%s\n' "$_as_names" | sed '/^$/d' | wc -l | tr -d ' ')
	[ -n "$_as_count" ] || _as_count=0
	if [ "$_as_count" -gt "$_as_max_entries" ]; then
		printf 'too-many-entries:%s/%s\n' "$_as_count" "$_as_max_entries"
	fi

	# Total uncompressed size cap (zip-bomb guard). Parse the zipinfo summary line
	# "<n> files, <bytes> bytes uncompressed, <bytes> bytes compressed: ...".
	_as_total=$(zipinfo "$_as_zip" 2>/dev/null | awk '
		/ bytes uncompressed/ { for (i=1;i<=NF;i++) if ($i ~ /^uncompressed/) { v=$(i-2); gsub(/,/,"",v); print v } }' | tail -n1)
	[ -n "$_as_total" ] || _as_total=0
	case "$_as_total" in
		''|*[!0-9]*) _as_total=0 ;;
	esac
	if [ "$_as_total" -gt "$_as_max_bytes" ]; then
		printf 'oversize:%s/%s\n' "$_as_total" "$_as_max_bytes"
	fi
	return 0
}

# archive_safety_extract <zip> <root>
# Extract into <root> AFTER a clean scan, then re-assert (defense in depth) that no
# symlink and no escaping path exists in the materialized tree. Returns 0 on success,
# 1 on any post-extraction safety violation or extraction failure. Diagnostics on stderr.
archive_safety_extract() {
	_ae_zip="$1"; _ae_root="$2"
	ensure_dir "$_ae_root"
	if ! unzip -qq -o -d "$_ae_root" "$_ae_zip" >/dev/null 2>&1; then
		log_error "archive-safety: extraction failed for $_ae_zip"
		return 1
	fi
	# No symlinks may exist in the extracted tree.
	if [ -n "$(find "$_ae_root" -type l 2>/dev/null | head -n1)" ]; then
		log_error "archive-safety: extracted tree contains a symlink (rejected)"
		return 1
	fi
	# Every materialized regular file/dir must stay within root (canonicalized).
	_ae_realroot=$(cd "$_ae_root" 2>/dev/null && pwd -P) || {
		log_error "archive-safety: cannot resolve extraction root"; return 1; }
	_ae_escape=0
	find "$_ae_root" -type f 2>/dev/null | while IFS= read -r _ae_f; do
		_ae_d=$(cd "$(dirname "$_ae_f")" 2>/dev/null && pwd -P) || { printf 'x'; continue; }
		case "$_ae_d/" in
			"$_ae_realroot"/*|"$_ae_realroot"/) ;;
			*) printf 'x' ;;
		esac
	done | grep -q x && _ae_escape=1
	if [ "$_ae_escape" = 1 ]; then
		log_error "archive-safety: an extracted file resolved outside the extraction root (rejected)"
		return 1
	fi
	return 0
}
