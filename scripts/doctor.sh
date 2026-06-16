#!/bin/sh
# Sentinel Shield — doctor / preflight (v1.8.0).
#
# ADDITIVE supportability tool. Diagnoses environment + adoption state and prints actionable
# warnings. It does NOT run scanners, does NOT change gate behavior, and NEVER prints secret values
# (the NVD key is checked by presence of its VARIABLE only).
#
# Output contract:
#   exit 0  -> informational success (ran; warnings may be printed)
#   exit 2  -> invalid invocation / unreadable config
#
# Usage: sh scripts/doctor.sh [--target <dir>] [--quiet]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

TARGET="."
QUIET=0
while [ $# -gt 0 ]; do case "$1" in
  --target) TARGET="${2:?--target requires a value}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  -h|--help) echo "Usage: doctor.sh [--target <dir>] [--quiet]"; exit 0 ;;
  *) log_error "doctor: unknown argument: $1"; exit 2 ;;
esac; done
[ -d "$TARGET" ] || { log_error "doctor: target not a directory: $TARGET"; exit 2; }

WARN=0
ok()   { [ "$QUIET" = 1 ] || printf '  ok    %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf '  WARN  %s\n' "$*"; }
have() { command_exists "$1" && ok "$1 present ($(command -v "$1"))" || warn "$2"; }

echo "Sentinel Shield doctor — target: $TARGET"

echo "[tooling]"
have sh   "POSIX sh not found (required)"
have git  "git not found (version/ref checks degraded)"
have jq   "jq not found — REQUIRED for the engine/self-test"
# stack-conditional (informational; absence is only a warning if that stack is used)
command_exists node    && ok "node present"    || warn "node absent (Node/React profiles need it)"
command_exists php     && ok "php present"     || warn "php absent (PHP profiles / Deptrac need it)"
command_exists composer&& ok "composer present"|| warn "composer absent (PHP dependency scans need it)"
command_exists docker  && ok "docker present"  || warn "docker absent (container-backed scanners need it)"

echo "[adoption state] (relative to $TARGET)"
PF="$TARGET/.sentinel-shield/profile.yaml"
[ -f "$PF" ] && ok "profile.yaml present" || warn "no .sentinel-shield/profile.yaml — run install-baseline"
AR="$TARGET/.sentinel-shield/accepted-risks.json"
if [ -f "$AR" ]; then
  if command_exists jq && jq -e . "$AR" >/dev/null 2>&1; then ok "accepted-risks.json valid JSON"
  else warn "accepted-risks.json present but NOT valid JSON"; fi
else ok "no accepted-risks.json (optional; created only when you accept a risk)"; fi
[ -d "$TARGET/reports/raw" ] && ok "reports/raw present" || ok "no reports/raw yet (created by scanners)"
SS="$TARGET/reports/security-summary.json"
if [ -f "$SS" ]; then
  if command_exists jq && jq -e . "$SS" >/dev/null 2>&1; then ok "security-summary.json valid JSON"
  else warn "security-summary.json present but NOT valid JSON"; fi
else ok "no security-summary.json yet (produced by build-security-summary.sh)"; fi
ls "$TARGET"/.github/workflows/*.y*ml >/dev/null 2>&1 && ok "workflow(s) present" || warn "no .github/workflows — wire the PR-fast gate"

echo "[secrets] (names only — values are NEVER printed)"
if [ -n "${SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY:-}" ]; then
  ok "NVD key variable is set (value hidden)"
else
  ok "NVD key variable not set (only needed for Dependency-Check live runs)"
fi

echo "[permissions]"
[ -w "$TARGET" ] && ok "target writable" || warn "target not writable — install/sync will fail"

echo "----"
if [ "$WARN" -eq 0 ]; then echo "doctor: no warnings"; else echo "doctor: $WARN warning(s) — see WARN lines above"; fi
echo "Next: docs/troubleshooting.md ; share diagnostics safely with scripts/support-bundle.sh"
exit 0
