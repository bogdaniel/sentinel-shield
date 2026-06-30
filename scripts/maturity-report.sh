#!/bin/sh
# Sentinel Shield — maturity / adoption report (v1.8.0).
#
# ADDITIVE, offline. Emits the scanner maturity matrix as markdown (default) or JSON.
# This is a REPORT of the canonical state in docs/product-status.md + main-gate-live-evidence.md;
# it changes nothing. Keep it in sync when a maturity label changes (guarded by self-test v180).
#
# It distinguishes PRODUCT support ("Sentinel Shield supports X") from PROJECT activation
# ("this project enforces X"). The product columns (maturity/gating/...) are always present.
# When a profile + target can be resolved (via --profile, or the target's
# .sentinel-shield/profile.yaml), each tool also carries activation fields:
#   product_support, profile_policy, installed, configured, executed (local), executed_ci,
#   gate_enforced, last_result, report.
# Without a resolvable profile these activation fields report "unknown"/"not-declared" — they are
# NEVER conflated with product support.
#
# The report surfaces TEN distinct states per tool so none is conflated with another:
#   product support | profile policy | installed | configured | executed locally |
#   executed in CI | gate enforced | live validated | last evidence date | evidence run ID.
# CRITICAL HONESTY: `live_validated` is driven ONLY by REAL evidence — a populated
# evidence/releases/*.json consumer_run with a non-empty workflow_run_id, result=success and
# artifacts_verified=true. The static product `maturity` column (which may read "live-validated"
# as a PRODUCT claim) NEVER flips `live_validated` on; fixture/empty evidence reports
# live_validated=no. The verified evidence run ID + date come from that real run, else "—".
#
# Usage: sh scripts/maturity-report.sh [--format md|json] [--target <dir>] [--profile <name>]...
#          [--control-waivers <path>] [--evidence-dir <dir>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compat-resolver.sh
. "$SCRIPT_DIR/lib/compat-resolver.sh"
# shellcheck source=scripts/lib/control-waivers.sh
. "$SCRIPT_DIR/lib/control-waivers.sh"

TAB=$(printf '\t')
FORMAT="md"
TARGET="."
PROFILES_CLI=""
WAIVERS_CLI=""
EVIDENCE_DIR="$REPO_ROOT/evidence/releases"
while [ $# -gt 0 ]; do case "$1" in
  --format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
  --target) TARGET="${2:?--target requires a value}"; shift 2 ;;
  --profile) PROFILES_CLI="$PROFILES_CLI ${2:?--profile requires a value}"; shift 2 ;;
  --control-waivers) WAIVERS_CLI="${2:?--control-waivers requires a value}"; shift 2 ;;
  --evidence-dir) EVIDENCE_DIR="${2:?--evidence-dir requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: maturity-report.sh [--format md|json] [--target <dir>] [--profile <name>]... [--control-waivers <path>] [--evidence-dir <dir>]"; exit 0 ;;
  *) log_error "maturity-report: unknown argument: $1"; exit 2 ;;
esac; done
case "$FORMAT" in md|json) ;; *) log_error "maturity-report: --format must be md or json"; exit 2 ;; esac

# key|tool|category|maturity|evidence_run|artifact|caveat|default|gating
# 'key' maps the display tool to a TOOL_TABLE key for activation lookups (best-effort for
# multi-tool rows such as ZAP/Nuclei -> zap).
ROWS='engine|engine|core|proven|self-test (this repo CI)|security-summary.json|deterministic|yes|gating
deptrac|Deptrac|architecture|live-validated|27633798174 (silver-potato)|deptrac.json|binary severity (count)|opt-in|gating
dependency-check|OWASP Dependency-Check|dependencies|live-validated|27530386965 / 27573703800|dependency-check.json|coarse severity|main|gating
codeql|CodeQL|SAST|live-validated|27214865086|codeql.json|SARIF level->severity (coarse)|main|gating
osv-scanner|OSV-Scanner|dependencies|live-validated|27214865086|osv-scanner.json|severity coarse (all->high)|main|gating
trivy|Trivy-fs|dependencies|live-validated|27214865086|trivy.json|fs-mode only|main|gating
syft|Syft (SBOM)|sbom|live-validated|27214865086|sbom.spdx.json|presence/validity only|main|gating
grype|Grype|dependencies|live-validated|27239206382|grype.json|severity-mapped|main|gating
dockle|Dockle|container|live-validated|27239206382|dockle.json|built-image only|nightly|gating
checkov|Checkov|iac|ci-validated (evidence-fixture)|27636439883|checkov.json|engineered findings; NOT live-validated|if IaC|gating
terrascan|Terrascan|iac|ci-validated (evidence-fixture)|27636439883|terrascan.json|no hcloud policies; NOT live-validated|if IaC|gating
conftest|Conftest|iac|ci-validated (evidence-fixture)|27636439883|conftest-report.json|namespace/plan-JSON; NOT live-validated|if IaC|gating
zap|ZAP / Nuclei|dast|manual|—|zap.json / nuclei.json|target allowlist + approval|off|manual
ai-security-review|Claude Code review / Kuzushi|ai|non-gating|—|ai-security-review.json|non-deterministic; advisory|off|non-gating
scorecard|Scorecard / TruffleHog / Trivy-image|misc|experimental|—|*.json|coarse / nightly|nightly|advisory'

# --- project-activation context (optional; resolved only when a profile is available) --------
RESOLVE=0
TMPM=""
SUMMARY="$TARGET/reports/security-summary.json"
# Control-waivers: explicit --control-waivers wins, else the target default. Validated via the
# SHARED lib (full schema + real-date + self-approval); a MALFORMED file => exit 2 (fail closed).
# WAIVED_KEYS holds tool/group keys with a VALID, UNEXPIRED waiver; surfaced per-tool as a flag
# WITHOUT converting the tool to pass/optional (C2).
if [ -n "$WAIVERS_CLI" ]; then WAIVERS_FILE="$WAIVERS_CLI"; else WAIVERS_FILE="$TARGET/.sentinel-shield/control-waivers.json"; fi
WAIVED_KEYS=""
# Validate UNCONDITIONALLY (Issue 5) — same fail-closed decision as doctor/gate even
# when jq is absent. Key extraction (needs jq) stays conditional below.
cw_validate_file "$WAIVERS_FILE" || { log_error "maturity-report: control-waivers file invalid: $WAIVERS_FILE (see errors above)"; exit 2; }
if command_exists jq; then
  WAIVED_KEYS=$(cw_valid_keys "$WAIVERS_FILE" 2>/dev/null || true)
fi
# mr_is_waived <key> — 0 if <key> has a valid, unexpired control-waiver.
mr_is_waived() {
  case "
$WAIVED_KEYS
" in *"
$1
"*) return 0 ;; *) return 1 ;; esac
}
if command_exists jq; then
  PROFILES_RESOLVED="$PROFILES_CLI"
  PF="$TARGET/.sentinel-shield/profile.yaml"
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
  if [ -n "$PROFILES_RESOLVED" ]; then
    # Composition / inheritance / override / applicability are delegated to the
    # canonical resolver; maturity-report never merges manifests itself. Sibling
    # top-level profiles are union'd by the policy ladder (strongest wins).
    # ponytail: the resolver takes one profile, but --profile is repeatable here.
    RESOLVER="$SCRIPT_DIR/resolve-effective-profile.sh"
    EFF_DOCS=""
    for p in $PROFILES_RESOLVED; do
      if _eff=$(sh "$RESOLVER" --profile "$p" --target "$TARGET" --format json 2>/dev/null); then
        EFF_DOCS="$EFF_DOCS$_eff
"
      fi
    done
    if [ -n "$(printf '%s' "$EFF_DOCS" | tr -d '[:space:]')" ]; then
      MERGED=$(printf '%s' "$EFF_DOCS" | jq -s '
        def rank(p): {"required":5,"one-of":4,"recommended":3,"optional":2,"external":1,"disabled":0}[p] // 0;
        reduce .[] as $d ({};
          reduce (($d.tools // {}) | to_entries[]) as $e (.;
            if (has($e.key)|not) or (rank($e.value.policy) > rank(.[$e.key].policy))
            then .[$e.key] = $e.value else . end))')
      TMPM=$(mktemp 2>/dev/null || mktemp -t ssmaturity)
      printf '{"tools":%s}\n' "$MERGED" > "$TMPM"
      RESOLVE=1
    fi
  fi
fi

# resolve_activation <key> — echo 8 TAB-separated, always-non-empty fields:
#   profile_policy installed configured executed gate_enforced last_result report waived
# `waived` reflects a valid control-waiver for this tool key; it is informational and does
# NOT change the tool's policy/last_result (the tool stays required, not pass/optional).
resolve_activation() {
  _pol="not-declared"; _inst="unknown"; _cfg="unknown"; _exe="unknown"
  _ge="unknown"; _lr="none"; _rep="reports/raw/$1.json"
  if mr_is_waived "$1"; then _wv="yes"; else _wv="no"; fi
  if [ "$RESOLVE" = 1 ]; then
    if jq -e --arg k "$1" '.tools | has($k)' "$TMPM" >/dev/null 2>&1 \
       && [ "$(jq -r --arg k "$1" '.tools | has($k)' "$TMPM")" = "true" ]; then
      _pol=$(jq -r --arg k "$1" '.tools[$k].policy // "not-declared"' "$TMPM")
      _r=$(jq -r --arg k "$1" '.tools[$k].report // ""' "$TMPM"); [ -n "$_r" ] && _rep="$_r"
      # installed: executable detected, else composer.lock package present, else no/-.
      if cr_tool_detected "$TARGET" "$TMPM" "$1"; then _inst="yes"
      else
        _exes=$(cr_tool_executables "$TMPM" "$1"); _pk=$(cr_tool_packages "$TMPM" "$1")
        if [ -z "$_exes" ] && [ -z "$_pk" ]; then _inst="-"; else _inst="no"; fi
      fi
      _cp=$(jq -r --arg k "$1" '.tools[$k].config.path // ""' "$TMPM")
      if [ -z "$_cp" ]; then _cfg="-"; elif [ -f "$TARGET/$_cp" ]; then _cfg="yes"; else _cfg="no"; fi
      if [ -n "$_r" ] && [ -f "$TARGET/$_r" ]; then _exe="yes"; elif [ -n "$_r" ]; then _exe="no"; else _exe="-"; fi
      [ "$_pol" = "required" ] && _ge="yes" || _ge="no"
      if [ -f "$SUMMARY" ]; then
        _s=$(jq -r --arg k "$1" '(.tools[$k].status) // "none"' "$SUMMARY" 2>/dev/null) || _s="none"
        [ -n "$_s" ] && _lr="$_s"
      fi
    else
      _pol="not-declared"; _inst="-"; _cfg="-"; _exe="-"; _ge="no"
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$_pol" "$_inst" "$_cfg" "$_exe" "$_ge" "$_lr" "$_rep" "$_wv"
}

# --- LIVE-VALIDATION evidence (fail-closed, REAL evidence only) -------------------------------
# Scan evidence/releases/*.json for a consumer_run that genuinely proves a live CI validation:
# non-empty workflow_run_id AND result=="success" AND artifacts_verified==true (the SAME bar the
# release-evidence validator enforces). Empty consumer_runs[], unbacked flags, or fixture-only
# runs (no real workflow_run_id / not success / artifacts unverified) DO NOT count — so the
# shipped honest-but-empty evidence reports live_validated=no for every tool.
# evidence_date_of <file> — YYYY-MM-DD of the file's mtime (portable GNU/BSD), else "—".
evidence_date_of() {
  _d=$(date -r "$1" +%Y-%m-%d 2>/dev/null) || _d=""
  [ -n "$_d" ] || { _d=$(stat -f '%Sm' -t '%Y-%m-%d' "$1" 2>/dev/null) || _d=""; }
  [ -n "$_d" ] && printf '%s' "$_d" || printf '%s' "—"
}
LIVE_EVIDENCE=0
EVIDENCE_RUN_ID="—"
EVIDENCE_DATE="—"
if command_exists jq && [ -d "$EVIDENCE_DIR" ]; then
  for _ef in "$EVIDENCE_DIR"/*.json; do
    [ -f "$_ef" ] || continue
    _rid=$(jq -r '
      (.consumer_runs // [])
      | map(select(((.workflow_run_id // "") | length > 0)
                   and (.result == "success")
                   and (.artifacts_verified == true)))
      | (.[0].workflow_run_id // "")' "$_ef" 2>/dev/null) || _rid=""
    if [ -n "$_rid" ]; then
      LIVE_EVIDENCE=1; EVIDENCE_RUN_ID="$_rid"; EVIDENCE_DATE=$(evidence_date_of "$_ef")
      break
    fi
  done
fi
# live_validated_of <product_maturity> — "yes" ONLY when the product claims live-validated AND
# real evidence backs it; "no" otherwise (incl. fixture/experimental/manual tiers).
live_validated_of() {
  if [ "$1" = "live-validated" ] && [ "$LIVE_EVIDENCE" = 1 ]; then printf 'yes'; else printf 'no'; fi
}
# executed_ci_of <gating> <default> — real CI execution signal: "yes"/"no" from REAL evidence for
# CI-capable tools; "-" for manual/off tools that never run in the gating CI lanes.
executed_ci_of() {
  case "$1" in manual) printf '-'; return ;; esac
  case "$2" in off) printf '-'; return ;; esac
  [ "$LIVE_EVIDENCE" = 1 ] && printf 'yes' || printf 'no'
}

if [ "$FORMAT" = "json" ]; then
  printf '{"generated_by":"scripts/maturity-report.sh","release":"v1.8.0","resolved_activation":%s,"live_validated":%s,"evidence_run_id":"%s","last_evidence_date":"%s","tools":[' \
    "$([ "$RESOLVE" = 1 ] && echo true || echo false)" \
    "$([ "$LIVE_EVIDENCE" = 1 ] && echo true || echo false)" "$EVIDENCE_RUN_ID" "$EVIDENCE_DATE"
  first=1
  printf '%s\n' "$ROWS" | while IFS='|' read -r key t c m r a v d g; do
    act=$(resolve_activation "$key")
    # (Issue 9) Tab-aware unpack with NO word-splitting/glob expansion (set -- $act
    # would expand * ? in a field against the CWD). Here-doc keeps it in this shell.
    IFS="$TAB" read -r pol inst cfg exe ge lr rep wv <<EOF
$act
EOF
    lv=$(live_validated_of "$m"); eci=$(executed_ci_of "$g" "$d")
    [ "$first" = 1 ] || printf ','; first=0
    printf '{"tool":"%s","key":"%s","category":"%s","maturity":"%s","evidence_run":"%s","artifact":"%s","caveat":"%s","default":"%s","gating":"%s","product_support":"%s","profile_policy":"%s","installed":"%s","configured":"%s","executed":"%s","executed_local":"%s","executed_ci":"%s","gate_enforced":"%s","live_validated":"%s","evidence_run_id":"%s","last_evidence_date":"%s","last_result":"%s","report":"%s","waived":"%s"}' \
      "$t" "$key" "$c" "$m" "$r" "$a" "$v" "$d" "$g" "$m" "$pol" "$inst" "$cfg" "$exe" "$exe" "$eci" "$ge" "$lv" "$EVIDENCE_RUN_ID" "$EVIDENCE_DATE" "$lr" "$rep" "$wv"
  done
  printf ']}\n'
else
  echo "# Sentinel Shield — Scanner Maturity Report (v1.8.0)"
  echo
  echo "Generated by \`scripts/maturity-report.sh\`. Canonical source: \`docs/product-status.md\` +"
  echo "\`docs/main-gate-live-evidence.md\`. **IaC is \`ci-validated (evidence-fixture)\`, NOT \`live-validated\`.**"
  echo
  echo "PRODUCT support (\`maturity\`) is NOT this project's activation. Activation columns report"
  echo "\`unknown\`/\`not-declared\` unless a profile + target is resolvable (\`resolved_activation=$([ "$RESOLVE" = 1 ] && echo true || echo false)\`)."
  echo
  echo "**Live validated** is driven ONLY by REAL evidence (a backed \`evidence/releases/*.json\` consumer_run);"
  echo "the product \`maturity\` column NEVER flips it on. Repo live-evidence: \`live_validated=$([ "$LIVE_EVIDENCE" = 1 ] && echo true || echo false)\` (run \`$EVIDENCE_RUN_ID\`, date \`$EVIDENCE_DATE\`)."
  echo
  echo "| Tool | Category | Maturity (product) | Evidence run (claimed) | Caveat | Default | Gating | Policy | Installed | Configured | Executed (local) | Executed (CI) | Gate enforced | Live validated | Evidence run ID | Last evidence date | Last result | Waived |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  printf '%s\n' "$ROWS" | while IFS='|' read -r key t c m r a v d g; do
    act=$(resolve_activation "$key")
    # (Issue 9) Tab-aware unpack; no word-splitting/glob expansion.
    IFS="$TAB" read -r pol inst cfg exe ge lr rep wv <<EOF
$act
EOF
    lv=$(live_validated_of "$m"); eci=$(executed_ci_of "$g" "$d")
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$t" "$c" "$m" "$r" "$v" "$d" "$g" "$pol" "$inst" "$cfg" "$exe" "$eci" "$ge" "$lv" "$EVIDENCE_RUN_ID" "$EVIDENCE_DATE" "$lr" "$wv"
  done
fi
[ -n "$TMPM" ] && rm -f "$TMPM"
exit 0
