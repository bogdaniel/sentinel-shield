#!/bin/sh
# Sentinel Shield — doctor / preflight (v1.8.0).
#
# ADDITIVE supportability tool. Diagnoses environment + adoption state, reports the active
# profile's tool-policy ACTIVATION table, and ENFORCES profile-required tools. It does NOT run
# scanners, does NOT change gate behavior, and NEVER prints secret values (the NVD key is checked
# by presence of its VARIABLE only).
#
# Output contract:
#   exit 0  -> informational success (ran; recommended/optional warnings may be printed)
#   exit 1  -> generic error (reserved)
#   exit 2  -> invalid invocation / unreadable config
#   exit 3  -> profile-REQUIRED tool(s) absent (not installed / not configured) — distinct gate
#
# Usage: sh scripts/doctor.sh [--target <dir>] [--profile <name>]... [--tool-mode <mode>] [--quiet]
#   --profile <name>   Active profile name(s) (repeatable). Default: read from
#                      <target>/.sentinel-shield/profile.yaml (the `profiles:` list).
#   --tool-mode <mode> config-only | require-existing | bootstrap-tools (matches
#                      install-baseline.sh). config-only does NOT gate on absent required
#                      tools (warn only); require-existing/bootstrap-tools exit 3 if any are
#                      absent. A tool whose POLICY is `external` is never gated regardless.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compat-resolver.sh
. "$SCRIPT_DIR/lib/compat-resolver.sh"

TARGET="."
QUIET=0
PROFILES_CLI=""
TOOL_MODE=""
while [ $# -gt 0 ]; do case "$1" in
  --target) TARGET="${2:?--target requires a value}"; shift 2 ;;
  --profile) PROFILES_CLI="$PROFILES_CLI ${2:?--profile requires a value}"; shift 2 ;;
  --tool-mode) TOOL_MODE="${2:?--tool-mode requires a value}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  -h|--help) echo "Usage: doctor.sh [--target <dir>] [--profile <name>]... [--tool-mode config-only|require-existing|bootstrap-tools] [--quiet]"; exit 0 ;;
  *) log_error "doctor: unknown argument: $1"; exit 2 ;;
esac; done
[ -d "$TARGET" ] || { log_error "doctor: target not a directory: $TARGET"; exit 2; }
case "$TOOL_MODE" in
  ""|config-only|require-existing|bootstrap-tools) ;;
  *) log_error "doctor: invalid --tool-mode '$TOOL_MODE' (config-only|require-existing|bootstrap-tools)"; exit 2 ;;
esac

WARN=0
ok()   { [ "$QUIET" = 1 ] || printf '  ok    %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf '  WARN  %s\n' "$*"; }
have() { command_exists "$1" && ok "$1 present ($(command -v "$1"))" || warn "$2"; }

# --- profile tool-policy resolution (jq-dependent) ---------------------------
MANIFESTS=""
SEEN=" "
# pt_add_manifest <profile-name> — append the profile's manifest (extends bases first), deduped.
pt_add_manifest() {
  _m="$REPO_ROOT/profiles/$1/profile.manifest.json"
  case "$SEEN" in *" $_m "*) return 0 ;; esac
  if [ ! -f "$_m" ]; then warn "profile '$1': no manifest at profiles/$1/profile.manifest.json (skipped)"; return 0; fi
  if ! jq -e . "$_m" >/dev/null 2>&1; then warn "profile '$1': manifest is not valid JSON (skipped)"; return 0; fi
  for _b in $(jq -r '(.extends // [])[]' "$_m" 2>/dev/null); do pt_add_manifest "$_b"; done
  SEEN="$SEEN$_m "
  MANIFESTS="$MANIFESTS $_m"
}
# pt_installed <target> <composed-manifest> <key> — yes|no|- (- = no executable/package declared).
pt_installed() {
  if cr_tool_detected "$1" "$2" "$3"; then echo yes; return 0; fi
  _exes=$(cr_tool_executables "$2" "$3"); _pk=$(cr_tool_packages "$2" "$3")
  [ -n "$_exes" ] || [ -n "$_pk" ] || { echo "-"; return 0; }
  _lock="$1/composer.lock"
  if [ -f "$_lock" ] && [ -n "$_pk" ]; then
    _oifs=$IFS; IFS='
'
    for _l in $_pk; do IFS=$_oifs
      _n=$(printf '%s' "$_l" | cut -f1)
      if jq -e --arg p "$_n" '[.packages[]?,.["packages-dev"][]?]|any(.name==$p)' "$_lock" >/dev/null 2>&1; then echo yes; return 0; fi
      IFS='
'
    done
    IFS=$_oifs
  fi
  echo no
}
# pt_configured <target> <composed-manifest> <key> — yes|no|- (- = no config declared).
pt_configured() {
  _cfg=$(jq -r --arg k "$3" '.tools[$k].config.path // ""' "$2" 2>/dev/null)
  [ -n "$_cfg" ] || { echo "-"; return 0; }
  [ -f "$1/$_cfg" ] && echo yes || echo no
}
# pt_executed <target> <composed-manifest> <key> — yes|no|- (- = no report declared).
pt_executed() {
  _rep=$(jq -r --arg k "$3" '.tools[$k].report // ""' "$2" 2>/dev/null)
  [ -n "$_rep" ] || { echo "-"; return 0; }
  [ -f "$1/$_rep" ] && echo yes || echo no
}

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

echo "[profile tool-policy] (Policy | Installed | Configured | Executed; enforces required tools)"
REQ_FAIL=0
REQUIRED_MISSING=""
if ! command_exists jq; then
  warn "jq absent — cannot resolve the profile tool-policy table"
else
  # Resolve active profile name(s): --profile wins; else the profile.yaml 'profiles:' list.
  PROFILES_RESOLVED="$PROFILES_CLI"
  if [ -z "$PROFILES_RESOLVED" ] && [ -f "$PF" ]; then
    PROFILES_RESOLVED=$(awk '
      /^profiles:[[:space:]]*$/ {inlist=1; next}
      inlist==1 {
        if ($0 ~ /^[[:space:]]+-[[:space:]]*/) {
          sub(/^[[:space:]]+-[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); sub(/[[:space:]]+$/, "");
          if ($0 != "") print $0
        } else if ($0 ~ /^[^[:space:]#]/) { inlist=0 }
      }' "$PF")
  fi
  if [ -z "$PROFILES_RESOLVED" ]; then
    warn "no active profile resolved (pass --profile or add a 'profiles:' list to $PF) — skipping table"
  else
    for p in $PROFILES_RESOLVED; do pt_add_manifest "$p"; done
    if [ -z "$MANIFESTS" ]; then
      warn "no usable profile manifests for: $PROFILES_RESOLVED"
    else
      # Compose tools{} across profiles/extends; on a key clash keep the higher-precedence policy.
      # shellcheck disable=SC2086
      MERGED=$(jq -s '
        def rank(p): {"required":5,"one-of":4,"recommended":3,"optional":2,"external":1,"disabled":0}[p] // 0;
        reduce .[] as $m ({};
          reduce (($m.tools // {}) | to_entries[]) as $e (.;
            if (has($e.key)|not) or (rank($e.value.policy) > rank(.[$e.key].policy))
            then .[$e.key] = $e.value else . end))' $MANIFESTS)
      TMPM=$(mktemp 2>/dev/null || mktemp -t ssdoctor)
      printf '{"tools":%s}\n' "$MERGED" > "$TMPM"
      ok "active profile(s): $(echo $PROFILES_RESOLVED | tr '\n' ' ')${TOOL_MODE:+ (tool-mode=$TOOL_MODE)}"
      [ "$QUIET" = 1 ] || printf '  %-22s %-12s %-10s %-11s %-9s\n' Tool Policy Installed Configured Executed
      for k in $(jq -r '.tools | keys_unsorted[]' "$TMPM"); do
        pol=$(jq -r --arg k "$k" '.tools[$k].policy // "?"' "$TMPM")
        inst=$(pt_installed "$TARGET" "$TMPM" "$k")
        cfg=$(pt_configured "$TARGET" "$TMPM" "$k")
        exe=$(pt_executed "$TARGET" "$TMPM" "$k")
        [ "$QUIET" = 1 ] || printf '  %-22s %-12s %-10s %-11s %-9s\n' "$k" "$pol" "$inst" "$cfg" "$exe"
        # ponytail: only policy=required gates exit 3; one-of group satisfaction (an absent
        # tool covered by an installed alternative) is shown but not hard-enforced here.
        if [ "$pol" = "required" ]; then
          [ "$inst" = "no" ] && REQUIRED_MISSING="$REQUIRED_MISSING $k(not-installed)"
          [ "$cfg" = "no" ] && REQUIRED_MISSING="$REQUIRED_MISSING $k(not-configured)"
        fi
      done
      rm -f "$TMPM"
      if [ -n "$REQUIRED_MISSING" ]; then
        if [ "$TOOL_MODE" = "config-only" ]; then
          warn "tool-mode=config-only: profile config installed but required tools not provisioned yet; not gating:$REQUIRED_MISSING"
        else
          printf '  FAIL  profile-required tool(s) absent:%s\n' "$REQUIRED_MISSING"
          REQ_FAIL=1
        fi
      else
        ok "all profile-required tools installed + configured"
      fi
    fi
  fi
fi

echo "----"
if [ "$WARN" -eq 0 ]; then echo "doctor: no warnings"; else echo "doctor: $WARN warning(s) — see WARN lines above"; fi
echo "Next: docs/troubleshooting.md ; share diagnostics safely with scripts/support-bundle.sh"
if [ "$REQ_FAIL" -eq 1 ]; then
  echo "doctor: profile-REQUIRED tool(s) missing — see FAIL line above (exit 3)"
  exit 3
fi
exit 0
