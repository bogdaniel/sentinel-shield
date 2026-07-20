#!/bin/sh
# Sentinel Shield — Docker base-image digest audit.
#
# Detects `FROM image:tag` base images that are NOT pinned by an @sha256: digest, across
# all discovered Dockerfiles, and writes reports/raw/docker-base-digest.json (an array of
# findings). The `docker-base-digest` collector maps the count to unsafe_docker. This is
# DISTINCT from Hadolint DL3018 (apk/apt package pinning) — it is about base-image
# reproducibility.
#
# Flags:  FROM php:8.3-fpm-alpine   FROM node:20-alpine   FROM ubuntu:22.04
#         FROM image  (no tag -> implicit :latest)
# Allows: FROM php:8.3-fpm-alpine@sha256:...   FROM ghcr.io/org/image@sha256:...
#         FROM scratch ;  FROM <previous-stage-name> (multi-stage internal refs)
#         FROM $ARG / ${ARG} (build-arg driven — project's responsibility)
#
# Discovery mirrors run-hadolint.sh: ./Dockerfile, ./Dockerfile.*, docker/**, .docker/**.
#
# Usage: audit-docker-base-digest.sh [--output <path>] [files...]
# Exit: 0 always (report is the signal). 2 on config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/docker-base-digest.json"
FILES=""
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: audit-docker-base-digest.sh [--output <path>] [files...]\n'; exit 0 ;;
		*) FILES="$FILES
$1"; shift ;;
	esac
done

if [ -z "$FILES" ]; then
	for f in Dockerfile Dockerfile.*; do [ -f "$f" ] && FILES="$FILES
./$f"; done
	for d in docker .docker; do
		[ -d "$d" ] || continue
		FILES="$FILES
$(find "$d" \
			-type d \( -name node_modules -o -name vendor -o -name .git -o -name dist -o -name build -o -name coverage \) -prune -o \
			-type f \( -name Dockerfile -o -name 'Dockerfile.*' \) -print 2>/dev/null)"
	done
fi
FILES=$(printf '%s\n' "$FILES" | sed '/^$/d' | sort -u)

ensure_dir "$(dirname "$OUTPUT")"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT INT TERM; : > "$TMP"

# Collect declared stage aliases (FROM x AS alias) so `FROM alias` is not flagged.
STAGES=" "
_ss_oifs=$IFS
IFS='
'
_ss_oifs=$IFS
IFS='
'
for f in $FILES; do
	IFS=$_ss_oifs
	IFS=$_ss_oifs
	[ -f "$f" ] || continue
	while IFS= read -r a; do
		[ -n "$a" ] && STAGES="$STAGES$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]') "
	done <<EOF
$(grep -iE '^[[:space:]]*FROM[[:space:]]' "$f" | sed -nE 's/.*[[:space:]][Aa][Ss][[:space:]]+([A-Za-z0-9_.-]+).*/\1/p')
EOF
done

_ss_oifs=$IFS
IFS='
'
for f in $FILES; do
	IFS=$_ss_oifs
	[ -f "$f" ] || continue
	_ln=0
	while IFS= read -r line || [ -n "$line" ]; do
		_ln=$((_ln + 1))
		printf '%s' "$line" | grep -iqE '^[[:space:]]*FROM[[:space:]]' || continue
		# image ref = first token after FROM (drop --platform=... flags and AS alias)
		_rest=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+//; s/--platform=[^[:space:]]+[[:space:]]+//')
		_img=$(printf '%s' "$_rest" | awk '{print $1}')
		[ -n "$_img" ] || continue
		_imgl=$(printf '%s' "$_img" | tr '[:upper:]' '[:lower:]')
		case "$_img" in
			scratch) continue ;;
			*'$'*) continue ;;                     # build-arg driven
			*@sha256:*) continue ;;                # digest-pinned — allow
		esac
		# previous-stage reference?
		case "$STAGES" in *" $_imgl "*) continue ;; esac
		if printf '%s' "$_img" | grep -q ':'; then
			emit_reason="base image '$_img' uses a mutable tag, not an @sha256 digest"
		else
			emit_reason="base image '$_img' has no tag/digest (implicit :latest)"
		fi
		jq -n --arg f "$f" --argjson l "$_ln" --arg i "$_img" --arg m "$emit_reason" \
			'{file:$f, line:$l, image:$i, code:"SS_DOCKER_BASE_DIGEST", reason:$m}' >> "$TMP"
	done < "$f"
done

jq -s '.' "$TMP" > "$OUTPUT"
_n=$(jq 'length' "$OUTPUT")
log_info "audit-docker-base-digest: scanned $(printf '%s\n' "$FILES" | grep -c . 2>/dev/null || true) Dockerfile(s) -> $OUTPUT ($_n un-digested base(s))"
exit 0
