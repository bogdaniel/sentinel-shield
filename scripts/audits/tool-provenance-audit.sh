#!/bin/sh
# Sentinel Shield — scanner tool-execution PROVENANCE audit.
#
# The scanner wrappers (scripts/audits/*.sh) EXECUTE a tool by preferring a binary
# found on PATH, else a Docker image named by an env var. This audit verifies what
# is actually executed — it never acquires the tool itself. For each tool it records
# how the tool resolves (local-binary | docker-image | unresolved) with
# version / path / digest / platform, and it REJECTS unverifiable or forged provenance:
#
#   checksum-mismatch       — the PATH-resolved executable's SHA-256 != the declared value.
#   image-digest-unverified — a configured image resolved to no immutable @sha256 digest
#                             while --require-image-digest was set (release-authoritative).
#
# Per tool <T> (uppercased, non-alnum -> '_') it reads, mirroring the wrappers:
#   SENTINEL_SHIELD_<T>_SHA256  expected SHA-256 for the PATH-resolved binary
#                               (verified; reject on mismatch)
#   SENTINEL_SHIELD_<T>_IMAGE   Docker image ref (recorded; immutable digest resolved
#                               from an @sha256 pin or `docker inspect` when possible)
#
# Binary mode resolves the scanner from PATH only (command -v), matching the wrappers.
# Container mode records configured_reference / resolved_digest / verification_status;
# verification_status is "verified" only when an immutable digest was resolved. Normal
# runs record an "unverified" image without failing; pass --require-image-digest to
# reject mutable-only provenance (fail closed) for RELEASE-AUTHORITATIVE runs.
#
# Emits a human report (STDOUT) and a machine report
# (reports/raw/tool-provenance-audit.json, per schemas/tool-provenance-audit.schema.json).
#
# Usage: tool-provenance-audit.sh [--output <path>] [--require-image-digest] [tool ...]
#   default tools:  osv-scanner grype
#   default output: reports/raw/tool-provenance-audit.json
# Exit: 0 = clean, 1 = one or more violations (fail closed), 2 = config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/isolated-tools.sh
. "$SCRIPT_DIR/../lib/isolated-tools.sh"

ss_require_jq

OUTPUT="reports/raw/tool-provenance-audit.json"
REQUIRE_IMAGE_DIGEST=false
TOOLS=""
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--require-image-digest) REQUIRE_IMAGE_DIGEST=true; shift ;;
		-h | --help)
			printf 'Usage: tool-provenance-audit.sh [--output <path>] [--require-image-digest] [tool ...]\n'
			exit 0 ;;
		--*) log_error "unknown option: $1"; exit 2 ;;
		*) TOOLS="$TOOLS $1"; shift ;;
	esac
done
[ -n "$TOOLS" ] || TOOLS="osv-scanner grype"

PLATFORM=$(isolated_tool_platform)
ensure_dir "$(dirname "$OUTPUT")"
TMPV=$(mktemp); TMPR=$(mktemp)
trap 'rm -f "$TMPV" "$TMPR"' EXIT INT TERM
: > "$TMPV"; : > "$TMPR"

# env_key <tool> — uppercase, non-alnum -> '_' (e.g. osv-scanner -> OSV_SCANNER).
env_key() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_' | sed 's/_*$//'; }

# env_get <FULLNAME> — indirect read of an env var by name (POSIX, no bashisms).
env_get() { eval "printf '%s' \"\${$1:-}\""; }

# best_effort_version <binary> — first line of `<bin> --version`, else `<bin> version`.
best_effort_version() {
	_v=$("$1" --version 2>/dev/null | head -n1) || _v=""
	[ -n "$_v" ] || { _v=$("$1" version 2>/dev/null | head -n1) || _v=""; }
	printf '%s' "$_v"
	unset _v
}

# add_violation <tool> <check> <message>
add_violation() {
	printf 'VIOLATION: [%s] %s: %s\n' "$2" "$1" "$3" >&2
	jq -n --arg t "$1" --arg c "$2" --arg m "$3" '{tool:$t, check:$c, message:$m}' >> "$TMPV"
}

CHECKED=0
for tool in $TOOLS; do
	CHECKED=$((CHECKED + 1))
	EK=$(env_key "$tool")
	SHA=$(env_get "SENTINEL_SHIELD_${EK}_SHA256")
	IMG=$(env_get "SENTINEL_SHIELD_${EK}_IMAGE")

	# Resolve the executable from PATH ONLY (command -v), exactly as the wrappers do.
	RES_BIN=""
	if command_exists "$tool"; then
		RES_BIN=$(command -v "$tool")
	fi

	if [ -n "$RES_BIN" ]; then
		# --- local-binary (PATH-resolved) -------------------------------------
		VER=$(best_effort_version "$RES_BIN"); [ -n "$VER" ] || VER="unknown"
		ACT=$(isolated_tool_sha256 "$RES_BIN") || ACT=""
		CV=""
		if [ -n "$SHA" ]; then
			if isolated_tool_verify_checksum "$RES_BIN" "$SHA"; then
				CV="true"
			else
				CV="false"
				add_violation "$tool" "checksum-mismatch" \
					"PATH-resolved binary '$RES_BIN' SHA-256 does not match declared SENTINEL_SHIELD_${EK}_SHA256"
			fi
		fi
		isolated_tool_provenance_record "$tool" "local-binary" "$VER" "" "" "$RES_BIN" "$ACT" "$SHA" "$CV" "" "$PLATFORM" >> "$TMPR"
	elif [ -n "$IMG" ]; then
		# --- docker-image -----------------------------------------------------
		# Resolve an immutable digest: an @sha256 pin, else `docker inspect` RepoDigests.
		DIG=""
		case "$IMG" in
			*@sha256:*) DIG="sha256:${IMG##*@sha256:}" ;;
			*) if command_exists docker; then
					DIG=$(docker inspect --format '{{index .RepoDigests 0}}' "$IMG" 2>/dev/null || true)
					case "$DIG" in *@sha256:*) DIG="sha256:${DIG##*@sha256:}" ;; *) DIG="" ;; esac
				fi ;;
		esac
		# verification_status is "unverified" when no immutable digest was resolved.
		# Only fail closed on that when the caller demands it (release-authoritative).
		if [ -z "$DIG" ] && [ "$REQUIRE_IMAGE_DIGEST" = "true" ]; then
			add_violation "$tool" "image-digest-unverified" \
				"configured image '$IMG' (SENTINEL_SHIELD_${EK}_IMAGE) resolved to no immutable @sha256 digest and --require-image-digest is set"
		fi
		isolated_tool_provenance_record "$tool" "docker-image" "" "$IMG" "$DIG" "" "" "" "" "" "$PLATFORM" >> "$TMPR"
	else
		# --- unresolved -------------------------------------------------------
		log_warn "tool-provenance-audit: '$tool' unresolved (no binary on PATH and no image configured)"
		isolated_tool_provenance_record "$tool" "unresolved" "" "" "" "" "" "" "" "" "$PLATFORM" >> "$TMPR"
	fi
done

VIOLATIONS=$(jq -s 'length' "$TMPV")
STATUS=pass
[ "$VIOLATIONS" -gt 0 ] && STATUS=fail

jq -n \
	--arg v "1.0" --arg ts "$(timestamp_utc)" --arg plat "$PLATFORM" --arg st "$STATUS" \
	--argjson checked "$CHECKED" \
	--slurpfile viol "$TMPV" \
	--slurpfile recs "$TMPR" '
	{ version:$v, generated_at:$ts, tool:"tool-provenance-audit", platform:$plat,
	  status:$st, checked:$checked,
	  violation_count:($viol|length), violations:$viol, records:$recs }' > "$OUTPUT"

printf '\ntool-provenance-audit: checked %d tool(s), %d violation(s) -> %s\n' \
	"$CHECKED" "$VIOLATIONS" "$OUTPUT"

if [ "$VIOLATIONS" -gt 0 ]; then
	log_error "tool-provenance-audit: FAIL ($VIOLATIONS violation(s))"
	exit 1
fi
log_info "tool-provenance-audit: PASS ($CHECKED tool(s) recorded)"
exit 0
