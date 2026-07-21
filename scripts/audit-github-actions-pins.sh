#!/bin/sh
# Sentinel Shield — GitHub Actions pin audit.
#
# Scans workflow files for third-party references that are NOT pinned to an immutable
# identifier and writes reports/raw/github-actions-pins.json (an array of findings). The
# `github-actions-pins` collector maps the count to unsafe_github_actions. Complementary
# to actionlint/zizmor (does not replace them).
#
# Flags:
#   uses: owner/action@v1 | @v4 | @main | @master | @<tag> | (no @ref)
#   uses: docker://image:tag        (no @sha256: digest)
#   container: image:tag            (no @sha256:)
#   image: image:tag                (services.<svc>.image; no @sha256:)
# Allows:
#   uses: owner/action@<full 40-char hex SHA>
#   uses: ./local-action            (local actions are not third-party refs)
#   any ref pinned by @sha256:<digest>
#
# Usage: audit-github-actions-pins.sh [--output <path>] [--dir <workflows-dir>] [files...]
#   default dir: .github/workflows ; default output: reports/raw/github-actions-pins.json
# Exit: 0 always (the report is the signal; emptiness = clean). 2 on config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/github-actions-pins.json"
DIR=".github/workflows"
FILES=""
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--dir) DIR="${2:?--dir requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: audit-github-actions-pins.sh [--output <path>] [--dir <dir>] [files...]\n'; exit 0 ;;
		*) FILES="$FILES
$1"; shift ;;
	esac
done

# Resolve the file list.
if [ -z "$FILES" ]; then
	if [ -d "$DIR" ]; then
		FILES=$(find "$DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
	fi
fi

ensure_dir "$(dirname "$OUTPUT")"

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT INT TERM
: > "$TMP"

emit() { # emit <file> <line> <type> <ref> <reason>
	jq -n --arg f "$1" --argjson l "$2" --arg t "$3" --arg r "$4" --arg m "$5" \
		'{file:$f, line:$l, type:$t, ref:$r, reason:$m}' >> "$TMP"
}

is_sha() { # 40-char lowercase hex
	printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

_ss_oifs=$IFS
IFS='
'
for f in $FILES; do
	IFS=$_ss_oifs
	[ -f "$f" ] || continue
	_ln=0
	while IFS= read -r line || [ -n "$line" ]; do
		_ln=$((_ln + 1))
		# strip trailing inline comment for ref extraction (keep the # vTag comment out)
		_code=$(printf '%s' "$line" | sed 's/[[:space:]]*#.*$//')
		# Only treat uses:/container:/image: as a YAML KEY when it begins the
		# (optionally list-marked) line. Matching them as a substring anywhere on
		# the line false-positives on `run:` shell blocks that merely mention the
		# words — e.g. a grep pattern like `grep -E 'image:...:latest'`. Strip the
		# leading indent and an optional `- ` list marker, then prefix-match.
		_key=$(printf '%s' "$_code" | sed -e 's/^[[:space:]]*//' -e 's/^-[[:space:]]*//')
		case "$_key" in
			uses:*)
				_ref=$(printf '%s' "$_key" | sed -n 's/^uses:[[:space:]]*//p' | tr -d '"'"'"' ' )
				[ -n "$_ref" ] || continue
				case "$_ref" in
					./*|.\\*) : ;;                                  # local action — allow
					docker://*)
						case "$_ref" in
							*@sha256:*) : ;;
							*) emit "$f" "$_ln" "image" "$_ref" "docker:// image not pinned by @sha256 digest" ;;
						esac ;;
					*@*)
						_after=${_ref##*@}
						case "$_after" in
							sha256:*) : ;;                              # digest-pinned — allow
							*) if is_sha "$_after"; then :; else emit "$f" "$_ln" "action" "$_ref" "action ref '@$_after' is a tag/branch, not a full 40-char commit SHA"; fi ;;
						esac ;;
					*)
						emit "$f" "$_ln" "action" "$_ref" "action ref has no @version (defaults to a moving branch)" ;;
				esac ;;
			container:*)
				_img=$(printf '%s' "$_key" | sed -n 's/^container:[[:space:]]*//p' | tr -d '"'"'"' ')
				case "$_img" in
					''|'{'*) : ;;                                   # empty or a map (image: under it handled below)
					*@sha256:*) : ;;
					*:*) emit "$f" "$_ln" "image" "$_img" "container image not pinned by @sha256 digest" ;;
				esac ;;
			image:*)
				_img=$(printf '%s' "$_key" | sed -n 's/^image:[[:space:]]*//p' | tr -d '"'"'"' ')
				case "$_img" in
					''|*'${{'*) : ;;                                # interpolated — skip (project env)
					*@sha256:*) : ;;
					*:*) emit "$f" "$_ln" "image" "$_img" "service image not pinned by @sha256 digest" ;;
				esac ;;
		esac
	done < "$f"
done

jq -s '.' "$TMP" > "$OUTPUT"
_n=$(jq 'length' "$OUTPUT")
log_info "audit-github-actions-pins: scanned $(printf '%s\n' "$FILES" | grep -c . 2>/dev/null || true) file(s) -> $OUTPUT ($_n unpinned ref(s))"
exit 0
