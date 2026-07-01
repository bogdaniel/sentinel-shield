#!/bin/sh
# Sentinel Shield — doctor / preflight (v1.8.0).
#
# ADDITIVE supportability tool. Diagnoses environment + adoption state, reports the active
# profile's tool-policy ACTIVATION table, and ENFORCES profile-required tools. It does NOT run
# scanners, does NOT change gate behavior, and NEVER prints secret values (the NVD key is checked
# by presence of its VARIABLE only).
#
# Output contract (canonical exit codes):
#   exit 0  -> healthy: ran clean; only informational/environment notes printed.
#   exit 1  -> warnings only: a non-blocking DEGRADED production condition (an in-progress
#              operation-lock, or a managed/project-owned file missing). Adoption is usable
#              but should be reviewed. Plain environment WARNs alone do NOT raise this
#              (backward-compatible with the v1.8 informational-success contract).
#   exit 2  -> invalid configuration: bad invocation, unreadable / MALFORMED control-waivers,
#              an INVALID installation.json, a non-immutable (moving-branch) source ref, or a
#              pinned-ref/resolved-commit MISMATCH.
#   exit 3  -> profile-REQUIRED tool(s) / one-of group(s) absent under an enforced tool-mode.
#   exit 4  -> execution/evidence problem: a STALE operation-lock, or present-but-invalid
#              local-pipeline / CI evidence.
# Precedence when several apply: 3 > 2 > 4 > 1 > 0.
#
# Usage: sh scripts/doctor.sh [--target <dir>] [--profile <name>]... [--tool-mode <mode>]
#                             [--control-waivers <path>] [--quiet]
#   --profile <name>   Active profile name(s) (repeatable). Default: read from
#                      <target>/.sentinel-shield/profile.yaml (the `profiles:` list).
#   --tool-mode <mode> config-only | require-existing | bootstrap-tools (matches
#                      install-baseline.sh). config-only does NOT gate on absent required
#                      tools (warn only); require-existing/bootstrap-tools exit 3 if any are
#                      absent. A tool whose POLICY is `external` is never gated regardless.
#   --control-waivers <path>  Required-tool control-waivers file (default:
#                      <target>/.sentinel-shield/control-waivers.json). Validated via the
#                      shared lib (scripts/lib/control-waivers.sh): a malformed file => exit 2.
#                      A valid, UNEXPIRED waiver lets a missing REQUIRED tool — or an
#                      UNSATISFIED required one-of GROUP — report WAIVED instead of hard-failing
#                      exit 3. A one-of group is keyed by the GROUP name (e.g. `tests`).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compat-resolver.sh
. "$SCRIPT_DIR/lib/compat-resolver.sh"
# shellcheck source=scripts/lib/control-waivers.sh
. "$SCRIPT_DIR/lib/control-waivers.sh"
# shellcheck source=scripts/lib/installation-metadata.sh
. "$SCRIPT_DIR/lib/installation-metadata.sh"

TARGET="."
QUIET=0
PROFILES_CLI=""
TOOL_MODE=""
WAIVERS_CLI=""
while [ $# -gt 0 ]; do case "$1" in
  --target) TARGET="${2:?--target requires a value}"; shift 2 ;;
  --profile) PROFILES_CLI="$PROFILES_CLI ${2:?--profile requires a value}"; shift 2 ;;
  --tool-mode) TOOL_MODE="${2:?--tool-mode requires a value}"; shift 2 ;;
  --control-waivers) WAIVERS_CLI="${2:?--control-waivers requires a value}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  -h|--help) echo "Usage: doctor.sh [--target <dir>] [--profile <name>]... [--tool-mode config-only|require-existing|bootstrap-tools] [--control-waivers <path>] [--quiet]"; exit 0 ;;
  *) log_error "doctor: unknown argument: $1"; exit 2 ;;
esac; done
[ -d "$TARGET" ] || { log_error "doctor: target not a directory: $TARGET"; exit 2; }
case "$TOOL_MODE" in
  ""|config-only|require-existing|bootstrap-tools) ;;
  *) log_error "doctor: invalid --tool-mode '$TOOL_MODE' (config-only|require-existing|bootstrap-tools)"; exit 2 ;;
esac

# Control-waivers file: explicit --control-waivers wins, else the target default.
# Validate up front via the SHARED lib (full schema + real-date + self-approval);
# a MALFORMED file is a configuration failure -> exit 2 (fail closed, before any table).
# WAIVED_KEYS holds the tool/group keys covered by a VALID, UNEXPIRED waiver.
if [ -n "$WAIVERS_CLI" ]; then WAIVERS_FILE="$WAIVERS_CLI"; else WAIVERS_FILE="$TARGET/.sentinel-shield/control-waivers.json"; fi
WAIVED_KEYS=""
# Validate the waivers file UNCONDITIONALLY (Issue 4): the shared validator handles
# absent => ok, present-but-jq-missing => fail closed, malformed => fail closed. A
# malformed waiver must never skip validation just because jq is absent.
cw_validate_file "$WAIVERS_FILE" || { log_error "doctor: control-waivers file invalid: $WAIVERS_FILE (see errors above)"; exit 2; }
# Key extraction needs jq; the validity DECISION above does not depend on it.
if command_exists jq; then
  WAIVED_KEYS=$(cw_valid_keys "$WAIVERS_FILE" 2>/dev/null || true)
fi
# is_waived <key> — 0 if <key> (tool or one-of group) has a valid, unexpired waiver.
is_waived() {
  case "
$WAIVED_KEYS
" in *"
$1
"*) return 0 ;; *) return 1 ;; esac
}

WARN=0
WAIVED_COUNT=0
DEGRADED=0        # non-blocking production warnings -> exit 1
CONFIG_INVALID=0  # invalid configuration -> exit 2
EXEC_PROBLEM=0    # execution/evidence problem -> exit 4
ok()   { [ "$QUIET" = 1 ] || printf '  ok    %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf '  WARN  %s\n' "$*"; }
# degraded: a production WARN that is non-blocking but should gate exit 1.
degraded() { DEGRADED=$((DEGRADED+1)); WARN=$((WARN+1)); printf '  WARN  %s\n' "$*"; }
cfgfail()  { CONFIG_INVALID=1; printf '  FAIL  %s\n' "$*"; }
execfail() { EXEC_PROBLEM=1; printf '  FAIL  %s\n' "$*"; }
waived() { WAIVED_COUNT=$((WAIVED_COUNT+1)); printf '  WAIVED  %s\n' "$*"; }
have() { command_exists "$1" && ok "$1 present ($(command -v "$1"))" || warn "$2"; }
# is_hex40 <str> — true if <str> is a full 40-char lowercase hex commit SHA.
is_hex40() { _h=$1; case "$_h" in ""|*[!0-9a-f]*) return 1 ;; esac; [ "${#_h}" -eq 40 ]; }

# --- profile tool-policy resolution (jq-dependent) ---------------------------
# Composition / inheritance / override / applicability / one-of are ALL delegated
# to the canonical resolver (scripts/resolve-effective-profile.sh); doctor never
# merges manifests itself. The helpers below read the resolver's composed
# {"tools":...} map written to a temp file.
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

echo "[installation integrity] (v2 production checks, relative to $TARGET)"
SS_DIR="$TARGET/.sentinel-shield"
IM_FILE="$SS_DIR/installation.json"
REF_FILE="$SS_DIR/.sentinel-shield-ref"
LOCK_FILE="$SS_DIR/operation-lock.json"

# (1) installation metadata valid (schema-shape via the shared lib).
if [ -f "$IM_FILE" ]; then
  if ! command_exists jq; then
    warn "installation.json present but jq absent — cannot validate metadata"
  elif im_validate "$IM_FILE" >/dev/null 2>&1; then
    ok "installation.json valid (version=$(im_get_version "$TARGET"), profile=$(im_get_profile "$TARGET"), tool_mode=$(im_get_tool_mode "$TARGET"))"
  else
    cfgfail "installation.json present but INVALID (does not conform to schemas/installation.schema.json)"
  fi
else
  warn "no .sentinel-shield/installation.json — project not yet adopted (run install-baseline)"
fi

# (2) immutable source-ref configured; resolved commit matches the pinned ref. The ref
#     record (written by acquire-sentinel-shield.sh) holds {repository, ref, resolved_commit}.
#     A moving branch is never immutable; when the pinned ref IS a full 40-hex SHA it MUST
#     equal resolved_commit (integrity), else the recorded install is inconsistent.
if [ -f "$REF_FILE" ]; then
  if ! command_exists jq; then
    warn "source-ref record present but jq absent — cannot verify immutability"
  elif ! jq -e . "$REF_FILE" >/dev/null 2>&1; then
    cfgfail "source-ref record present but not valid JSON: $REF_FILE"
  else
    _ref=$(jq -r '.ref // ""' "$REF_FILE")
    _rcommit=$(jq -r '.resolved_commit // ""' "$REF_FILE")
    if [ -z "$_ref" ] || [ -z "$_rcommit" ]; then
      cfgfail "source-ref record incomplete (ref and/or resolved_commit missing): $REF_FILE"
    elif ! is_hex40 "$_rcommit"; then
      cfgfail "source-ref resolved_commit is not a full 40-hex commit SHA: $_rcommit"
    elif is_hex40 "$_ref"; then
      if [ "$_ref" = "$_rcommit" ]; then
        ok "immutable ref configured: pinned to commit $_rcommit"
      else
        cfgfail "source-ref MISMATCH: pinned ref $_ref != resolved_commit $_rcommit"
      fi
    else
      # Not a 40-hex SHA. Accept ONLY when acquisition recorded an authoritative
      # ref_kind=tag (acquire-sentinel-shield.sh classifies the ref at clone time).
      # Name-spelling heuristics can never PROVE a name is a tag rather than a
      # moving branch (e.g. 'release','stable'), so anything unproven fails closed.
      _rkind=$(jq -r '.ref_kind // ""' "$REF_FILE")
      if [ "$_rkind" = "tag" ]; then
        ok "immutable ref configured: tag '$_ref' -> commit $_rcommit"
      else
        cfgfail "source-ref '$_ref' is not provably immutable (acquisition recorded no ref_kind=tag) — refusing as a possible moving branch"
      fi
    fi
  fi
else
  warn "no immutable source-ref record (.sentinel-shield/.sentinel-shield-ref) — install provenance unverified"
fi

# (3) stale operation-lock: install/sync/bootstrap record a lock here and remove it on
#     completion. A lock OLDER than the stale threshold means a prior mutating op was
#     interrupted (execution problem -> exit 4); a FRESH lock means an op may be running
#     (degraded -> exit 1).
STALE_LOCK_MIN=${SENTINEL_SHIELD_LOCK_STALE_MINUTES:-120}
case "$STALE_LOCK_MIN" in ''|*[!0-9]*) STALE_LOCK_MIN=120 ;; esac
if [ -f "$LOCK_FILE" ]; then
  if [ -n "$(find "$LOCK_FILE" -mmin +"$STALE_LOCK_MIN" 2>/dev/null)" ]; then
    execfail "STALE operation-lock (> ${STALE_LOCK_MIN} min old): $LOCK_FILE — a prior operation did not finish; remove it once you confirm none is running"
  else
    degraded "operation-lock present (an install/sync/bootstrap may be in progress): $LOCK_FILE"
  fi
else
  ok "no stale operation-lock"
fi

# (4) project-owned files preserved + managed-files present (missing-file drift signal).
#     Content drift is out of scope here (needs the engine source); sync-baseline owns it.
if [ -f "$IM_FILE" ] && command_exists jq; then
  _owned_missing=0
  for _f in $(im_list_project_owned_files "$TARGET" 2>/dev/null); do
    [ -e "$TARGET/$_f" ] || { degraded "project-owned file missing (expected preserved): $_f"; _owned_missing=1; }
  done
  [ "$_owned_missing" -eq 0 ] && ok "project-owned files preserved"
  _managed_missing=0
  for _f in $(im_list_managed_files "$TARGET" 2>/dev/null); do
    [ -e "$TARGET/$_f" ] || { degraded "managed file missing (drift — run sync-baseline): $_f"; _managed_missing=1; }
  done
  [ "$_managed_missing" -eq 0 ] && ok "managed files present (run sync-baseline to compare content)"
fi

# (5) GitHub Actions pin hygiene (informational): every `uses:` SHOULD pin a 40-hex commit
#     SHA. Non-SHA refs are flagged; audit-github-actions-pins.sh is the authoritative gate.
if ls "$TARGET"/.github/workflows/*.y*ml >/dev/null 2>&1; then
  _unpinned=$(grep -hoE "uses:[[:space:]]*[^[:space:]\"']+" "$TARGET"/.github/workflows/*.y*ml 2>/dev/null \
    | sed -E 's/^uses:[[:space:]]*//' | grep '@' | grep -v '^\./' | grep -Ev '@[0-9a-f]{40}$' | sort -u || true)
  if [ -n "$_unpinned" ]; then
    warn "GitHub Action(s) not pinned to a commit SHA (use audit-github-actions-pins.sh):"
    [ "$QUIET" = 1 ] || printf '%s\n' "$_unpinned" | sed 's/^/        - /'
  else
    ok "GitHub Actions pinned to commit SHAs"
  fi
fi

# (6) package manager unambiguous: multiple competing JS lockfiles is ambiguous.
_pm=""
_pmn=0
for _lf in package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lockb; do
  [ -f "$TARGET/$_lf" ] && { _pmn=$((_pmn+1)); _pm="$_pm $_lf"; }
done
if [ "$_pmn" -gt 1 ]; then
  warn "ambiguous JS package manager — multiple lockfiles present:$_pm (keep exactly one)"
elif [ "$_pmn" -eq 1 ]; then
  ok "package manager unambiguous:$_pm"
fi

# (7) last local-pipeline / CI evidence (only if present): validate JSON shape; an
#     unreadable/invalid evidence file is an execution/evidence problem (exit 4).
for _ev in "$SS_DIR/last-local-pipeline.json" "$SS_DIR/last-ci.json"; do
  [ -f "$_ev" ] || continue
  if ! command_exists jq; then
    warn "evidence present but jq absent — cannot validate: $_ev"
  elif jq -e . "$_ev" >/dev/null 2>&1; then
    ok "evidence valid JSON: $_ev"
  else
    execfail "evidence present but INVALID JSON: $_ev"
  fi
done

echo "[profile tool-policy] (Policy | Installed | Configured | Executed; enforces required tools)"
REQ_FAIL=0
REQUIRED_MISSING=""
if ! command_exists jq; then
  # Fail closed under enforced modes: without jq we cannot verify required tools, so
  # require-existing / bootstrap-tools must NOT silently pass (exit 3). config-only
  # (or no mode) only warns, matching its non-gating contract.
  case "$TOOL_MODE" in
    require-existing|bootstrap-tools)
      log_error "doctor: jq absent — cannot verify profile-required tools under --tool-mode=$TOOL_MODE (failing closed)"; exit 3 ;;
  esac
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
    # Resolve each active profile through the canonical resolver; the resolver
    # owns ALL composition (extends), override, applicability and one-of. Pass
    # --target so applicability + one-of satisfaction are computed.
    RESOLVER="$SCRIPT_DIR/resolve-effective-profile.sh"
    EFF_DOCS=""
    for p in $PROFILES_RESOLVED; do
      if _eff=$(sh "$RESOLVER" --profile "$p" --target "$TARGET" --format json 2>/dev/null); then
        EFF_DOCS="$EFF_DOCS$_eff
"
      else
        warn "profile '$p': effective-profile resolution failed (skipped)"
      fi
    done
    if [ -z "$(printf '%s' "$EFF_DOCS" | tr -d '[:space:]')" ]; then
      warn "no usable profile manifests for: $PROFILES_RESOLVED"
    else
      # UNION sibling top-level profiles by the documented policy ladder (strongest
      # wins). This is a union of already-composed profiles, NOT extends-composition
      # (the resolver did that). ponytail: the resolver takes one profile, but
      # doctor's --profile is repeatable, so the union lives here.
      MERGED=$(printf '%s' "$EFF_DOCS" | jq -s '
        def rank(p): {"required":5,"one-of":4,"recommended":3,"optional":2,"external":1,"disabled":0}[p] // 0;
        reduce .[] as $d ({};
          reduce (($d.tools // {}) | to_entries[]) as $e (.;
            if (has($e.key)|not) or (rank($e.value.policy) > rank(.[$e.key].policy))
            then .[$e.key] = $e.value else . end))')
      ONEOF=$(printf '%s' "$EFF_DOCS" | jq -s 'reduce .[] as $d ({}; . + ($d.one_of_groups // {}))')
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
        # policy=required gates exit 3 (one-of GROUP satisfaction is enforced separately
        # below). A required tool that is missing but covered by a VALID control-waiver
        # reports WAIVED and is NOT accumulated into REQUIRED_MISSING (C2).
        if [ "$pol" = "required" ] && { [ "$inst" = "no" ] || [ "$cfg" = "no" ]; }; then
          _why=""
          [ "$inst" = "no" ] && _why="not-installed"
          [ "$cfg" = "no" ] && _why="${_why:+$_why,}not-configured"
          if is_waived "$k"; then
            waived "required tool '$k' ($_why) — covered by valid control-waiver ($WAIVERS_FILE)"
          else
            REQUIRED_MISSING="$REQUIRED_MISSING $k($_why)"
          fi
        fi
      done
      # one-of group satisfaction (from the resolver): a required GROUP (e.g. tests) is
      # satisfied when any alternative is installed. An effective required one-of GROUP is
      # GATING like a required tool (B6): an UNSATISFIED group is accumulated into
      # REQUIRED_MISSING so doctor exits 3 under require-existing/bootstrap-tools (config-only
      # warns only, via the same accumulator handling below). A VALID control-waiver keyed by
      # the GROUP name (e.g. `tests`) downgrades an unsatisfied group to WAIVED (C2).
      for g in $(printf '%s' "$ONEOF" | jq -r 'keys[]' 2>/dev/null); do
        gstatus=$(printf '%s' "$ONEOF" | jq -r --arg g "$g" '.[$g].status // "unknown"')
        gsel=$(printf '%s' "$ONEOF" | jq -r --arg g "$g" '.[$g].selected // "none"')
        galt=$(printf '%s' "$ONEOF" | jq -r --arg g "$g" '(.[$g].alternatives // []) | join("|")')
        [ "$QUIET" = 1 ] || printf '  one-of %-15s %-12s selected=%s (alts: %s)\n' "$g" "$gstatus" "${gsel:-none}" "$galt"
        if [ "$gstatus" = "unsatisfied" ]; then
          if is_waived "$g"; then
            waived "required one-of group '$g' (unsatisfied; alts: $galt) — covered by valid control-waiver ($WAIVERS_FILE)"
          else
            REQUIRED_MISSING="$REQUIRED_MISSING $g(one-of-unsatisfied)"
          fi
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
      elif [ "$WAIVED_COUNT" -gt 0 ]; then
        ok "all profile-required tools installed + configured (with $WAIVED_COUNT active control-waiver(s) — see WAIVED lines above)"
      else
        ok "all profile-required tools installed + configured"
      fi
    fi
  fi
fi

echo "----"
[ "$WAIVED_COUNT" -gt 0 ] && echo "doctor: $WAIVED_COUNT active control-waiver(s) — see WAIVED lines above (file: $WAIVERS_FILE)"
if [ "$WARN" -eq 0 ]; then echo "doctor: no warnings"; else echo "doctor: $WARN warning(s) — see WARN lines above"; fi
echo "Next: docs/troubleshooting.md ; share diagnostics safely with scripts/support-bundle.sh"
# Exit precedence: 3 > 2 > 4 > 1 > 0 (see header). Required-tool gating is checked FIRST so
# the established exit-3 behavior is never masked by a new config/exec/degraded condition.
if [ "$REQ_FAIL" -eq 1 ]; then
  echo "doctor: profile-REQUIRED tool(s) missing — see FAIL line above (exit 3)"
  exit 3
fi
if [ "$CONFIG_INVALID" -eq 1 ]; then
  echo "doctor: invalid configuration — see FAIL line(s) above (exit 2)"
  exit 2
fi
if [ "$EXEC_PROBLEM" -eq 1 ]; then
  echo "doctor: execution/evidence problem — see FAIL line(s) above (exit 4)"
  exit 4
fi
if [ "$DEGRADED" -gt 0 ]; then
  echo "doctor: $DEGRADED degraded condition(s) — warnings only (exit 1)"
  exit 1
fi
exit 0
