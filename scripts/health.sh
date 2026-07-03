#!/bin/sh
# Sentinel Shield — health / compatibility GATE (v1.0).
#
# Fail-closed production-compatibility gate. It classifies THIS host environment against the
# canonical support matrix (config/compatibility-policy.json, schemas/compatibility-policy.schema.json)
# and exits NON-ZERO with a STABLE diagnostic when the environment is unsupported — never an
# incidental command error. Unlike scripts/doctor.sh (a supportability REPORT), health.sh is the
# authoritative gate a consumer/CI runs to prove the runner is on a supported OS, CPU architecture,
# shell, and toolchain before doing real work. It does NOT run scanners and NEVER prints secrets.
#
# Output contract (canonical exit codes):
#   exit 0  -> supported: every component is on a supported/tested version.
#   exit 1  -> degraded: warnings only (e.g. case-insensitive filesystem, an unverifiable OPTIONAL
#              component). Usable, review advised.
#   exit 2  -> invalid configuration: bad invocation, or a missing/malformed/non-conformant policy.
#   exit 3  -> UNSUPPORTED environment: a below-minimum / unsupported / absent MANDATORY component,
#              an unsupported shell/arch/os, an unsupported package-manager major, an unsupported
#              PHP/Node version, a Docker-required action with no Docker, or a missing network in an
#              online-only operation. Fail-closed with a stable reason= diagnostic.
#   exit 4  -> probe timeout: a bounded version probe timed out, so the environment is UNVERIFIABLE.
# Precedence when several apply: 2 > 4 > 3 > 1 > 0 (a broken policy/invocation is reported first;
# an unverifiable probe outranks a specific unsupported finding; warnings never mask a failure).
#
# Usage: sh scripts/health.sh [--policy <path>] [--docker required|optional]
#                             [--require-network] [--quiet] [--output json]
#   --policy <path>    Compatibility policy (default: config/compatibility-policy.json under the repo).
#   --docker <mode>    Declare Docker's requirement for THIS run: 'required' fails closed when Docker
#                      is absent (a container-backed action); 'optional' (default) tolerates absence.
#   --require-network  Mark this run as an online-only operation: an offline host then fails exit 3.
#   --quiet            Suppress ok lines (WARN/FAIL always print).
#
# The environment snapshot is normally auto-detected. Any SENTINEL_SHIELD_COMPAT_* variable overrides
# the corresponding probe (documented in scripts/lib/compatibility-policy.sh) — this is how the test
# suite injects a deterministic environment without touching the host.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compatibility-policy.sh
. "$SCRIPT_DIR/lib/compatibility-policy.sh"
# Opt-in machine-readable envelope (a no-op unless `--output json` is passed). Sourced
# defensively so health still works if the lib is absent (e.g. a minimal copied tree).
if [ -f "$SCRIPT_DIR/lib/output-contract.sh" ]; then
  # shellcheck source=scripts/lib/output-contract.sh
  . "$SCRIPT_DIR/lib/output-contract.sh"
  oc_intercept "health" "$0" "$@"
fi

POLICY="$REPO_ROOT/config/compatibility-policy.json"
DOCKER_MODE="optional"
REQUIRE_NETWORK=0
QUIET=0
while [ $# -gt 0 ]; do case "$1" in
  --policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
  --docker) DOCKER_MODE="${2:?--docker requires a value}"; shift 2 ;;
  --require-network) REQUIRE_NETWORK=1; shift ;;
  --quiet) QUIET=1; shift ;;
  -h|--help)
    echo "Usage: health.sh [--policy <path>] [--docker required|optional] [--require-network] [--quiet] [--output json]"; exit 0 ;;
  *) log_error "health: unknown argument: $1"; exit 2 ;;
esac; done

case "$DOCKER_MODE" in
  required|optional) ;;
  *) log_error "health: invalid --docker '$DOCKER_MODE' (required|optional)"; exit 2 ;;
esac

# jq is a hard dependency for reading the policy — fail closed (config-invalid) if absent.
command_exists jq || { log_error "health: jq is required to evaluate the compatibility policy (install jq)"; exit 2; }

# Validate the policy up front; a missing / malformed / non-conformant policy is a
# configuration failure (exit 2), never a silent pass.
cp_validate_policy "$POLICY" || { log_error "health: compatibility policy invalid or missing: $POLICY"; exit 2; }

echo "Sentinel Shield health — compatibility gate (policy: $(basename -- "$POLICY"), version $(jq -r '.policy_version' "$POLICY"))"
echo "[compatibility]"

# Seed caller-driven snapshot fields before detection fills the rest. These globals are
# consumed by the sourced compatibility-policy.sh (cp_detect_into_env / cp_evaluate) in THIS
# same shell, so shellcheck cannot see the cross-file use.
# shellcheck disable=SC2034
CP_ENV_DOCKER_PROFILE="$DOCKER_MODE"
# shellcheck disable=SC2034
CP_QUIET="$QUIET"
# shellcheck disable=SC2034
if [ "$REQUIRE_NETWORK" = 1 ]; then CP_ENV_ONLINE_ONLY=yes; else CP_ENV_ONLINE_ONLY=no; fi

CP_PROBE_TIMEOUT=0
cp_detect_into_env

# strict=1: unknown MANDATORY components fail closed.
cp_evaluate "$POLICY" 1

echo "----"
if [ "$CP_PROBE_TIMEOUT" = 1 ]; then
  echo "health: a bounded version probe timed out — environment UNVERIFIABLE (exit 4)"
  exit 4
fi
if [ "$CP_FAIL" -gt 0 ]; then
  echo "health: $CP_FAIL unsupported/incompatible component(s) — see FAIL line(s) above (exit 3)"
  exit 3
fi
if [ "$CP_WARN" -gt 0 ]; then
  echo "health: $CP_WARN warning(s) — supported but degraded (exit 1)"
  exit 1
fi
echo "health: environment supported (all components within policy)"
exit 0
