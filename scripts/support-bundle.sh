#!/bin/sh
# Sentinel Shield — support bundle generator (v1.8.0).
#
# ADDITIVE. Produces a SAFE diagnostics tarball a user can share. By default it EXCLUDES raw
# scanner artifacts (reports/raw), .env files, and secrets, and redacts common token patterns from
# included text. It does NOT change gate behavior.
#
#   exit 0  -> bundle written
#   exit 2  -> invalid invocation / unwritable output
#
# Usage: sh scripts/support-bundle.sh [--target <dir>] [--out <path>] [--include-raw]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

TARGET="."; OUT="sentinel-shield-support-bundle.tar.gz"; INCLUDE_RAW=0
while [ $# -gt 0 ]; do case "$1" in
  --target) TARGET="${2:?--target requires a value}"; shift 2 ;;
  --out) OUT="${2:?--out requires a value}"; shift 2 ;;
  --include-raw) INCLUDE_RAW=1; shift ;;
  -h|--help) echo "Usage: support-bundle.sh [--target <dir>] [--out <path>] [--include-raw]"; exit 0 ;;
  *) log_error "support-bundle: unknown argument: $1"; exit 2 ;;
esac; done
[ -d "$TARGET" ] || { log_error "support-bundle: target not a directory: $TARGET"; exit 2; }
command_exists tar || { log_error "support-bundle: tar is required"; exit 2; }

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ss-support.XXXXXX") || { log_error "cannot create temp dir"; exit 2; }
trap 'rm -rf "$STAGE"' EXIT
B="$STAGE/support-bundle"; mkdir -p "$B"

# redact common secret-shaped tokens from any text we copy in.
# No `i` sed flag (GNU-only; BSD/macOS sed errors) — case folded into the pattern.
# Fail CLOSED: if sed fails, omit the content rather than copying it unredacted.
redact() { sed -E \
  -e 's/(AKIA)[0-9A-Z]{16}/\1<redacted>/g' \
  -e 's/(gh[pousr]_)[A-Za-z0-9]{20,}/\1<redacted>/g' \
  -e 's/([A-Za-z0-9_]*([Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Aa][Pp][Ii]_[Kk][Ee][Yy])[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*).+/\1<redacted>/g' \
  "$1" > "$2" 2>/dev/null || printf '%s\n' "[redaction failed: content omitted]" > "$2"; }

# environment / versions (no secret values)
{ echo "date: (stamp omitted — deterministic bundle)"; echo "uname: $(uname -a 2>/dev/null || true)";
  echo "sh: $(command -v sh)"; echo "jq: $(command -v jq 2>/dev/null || echo absent)";
  echo "git: $(command -v git 2>/dev/null || echo absent)";
  echo "node: $(command -v node 2>/dev/null || echo absent)";
  echo "php: $(command -v php 2>/dev/null || echo absent)";
  echo "docker: $(command -v docker 2>/dev/null || echo absent)";
} > "$B/environment.txt"

# git ref (no remotes/credentials)
( cd "$TARGET" && command_exists git && git rev-parse --short HEAD 2>/dev/null ) > "$B/git-ref.txt" 2>/dev/null || echo "no git ref" > "$B/git-ref.txt"

# config (redacted)
[ -f "$TARGET/.sentinel-shield/profile.yaml" ] && redact "$TARGET/.sentinel-shield/profile.yaml" "$B/profile.yaml"
[ -f "$TARGET/reports/security-summary.json" ] && redact "$TARGET/reports/security-summary.json" "$B/security-summary.json"
[ -f "$TARGET/reports/enforcement.txt" ] && redact "$TARGET/reports/enforcement.txt" "$B/enforcement.txt"

# doctor output
sh "$SCRIPT_DIR/doctor.sh" --target "$TARGET" > "$B/doctor.txt" 2>&1 || true

# NEVER include by default: reports/raw, .env, secrets.
if [ "$INCLUDE_RAW" = 1 ]; then
  log_warn "support-bundle: --include-raw set — raw artifacts MAY contain sensitive findings/paths."
  log_warn "Review $B/raw/ before sharing. Secrets/.env are still excluded."
  if [ -d "$TARGET/reports/raw" ]; then mkdir -p "$B/raw";
    for f in "$TARGET"/reports/raw/*.json; do [ -f "$f" ] && redact "$f" "$B/raw/$(basename "$f")"; done
  fi
else
  echo "raw artifacts excluded (re-run with --include-raw to include redacted copies)" > "$B/raw-EXCLUDED.txt"
fi

( cd "$STAGE" && tar -czf - support-bundle ) > "$OUT" || { log_error "failed to write $OUT"; exit 2; }
log_info "support-bundle written: $OUT (raw $( [ "$INCLUDE_RAW" = 1 ] && echo included-redacted || echo excluded ))"
exit 0
