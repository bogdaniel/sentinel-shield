#!/bin/sh
# tests/prod/260-compatibility-policy.sh — deterministic tests for the production
# compatibility & support matrix: the canonical policy (config/compatibility-policy.json),
# its schema (schemas/compatibility-policy.schema.json), the classification library
# (scripts/lib/compatibility-policy.sh) and the fail-closed gate (scripts/health.sh).
#
# NETWORK-FREE + DETERMINISTIC. Every scenario injects a synthetic host environment via
# SENTINEL_SHIELD_COMPAT_* overrides (never probes the real host), so the SAME assertions
# hold on any runner. It proves the documented exit contract and STABLE diagnostics:
#
#   POSITIVE          (1) minimum-supported env and (2) latest-supported env -> exit 0.
#   NEGATIVE          (3) one below-minimum per mandatory tool; (4) unsupported shell;
#                     (5) unsupported package-manager major; (6) unsupported PHP;
#                     (7) unsupported Node; (9) Docker-required action with no Docker;
#                     (11) unsupported architecture; (12) missing network in an online-only
#                     op -> exit 3 with a stable reason= diagnostic.
#   TOLERATED         (8) no Docker under a Docker-optional profile -> exit 0;
#                     (10) case-insensitive filesystem -> exit 1 (warning, not failure).
#   FAILURE-INJECTION missing / malformed / non-conformant policy -> exit 2 (fail-closed);
#                     an unparseable MANDATORY tool version -> exit 3 (unknown, fail-closed).
#   SCHEMA            schema + policy are valid JSON; policy conforms (jq-structural).
#
# Self-contained; jq is a hard dependency. Auto-discovered by
# `sh scripts/self-test.sh production-readiness`. Prints "PASS: x" / "FAIL: x"; exits
# nonzero if any assertion fails.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HEALTH="$ROOT/scripts/health.sh"
POLICY="$ROOT/config/compatibility-policy.json"
SCHEMA="$ROOT/schemas/compatibility-policy.schema.json"
LIB="$ROOT/scripts/lib/compatibility-policy.sh"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n' >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
# assert_diag <label> <file> <pattern>... — pass iff EVERY pattern is present in <file>.
assert_diag() {
	_lbl=$1; _f=$2; shift 2
	for _p in "$@"; do
		if ! grep -q "$_p" "$_f"; then fail "$_lbl (missing /$_p/ in output)"; return 0; fi
	done
	pass "$_lbl"
}

# reset_baseline — export a SUPPORTED host snapshot so that, absent a single deliberate
# mutation, health.sh exits 0. Called at the top of EVERY scenario so no override leaks
# into the next (a `VAR=val func` prefix persists in POSIX sh, so we never rely on it).
reset_baseline() {
	export SENTINEL_SHIELD_COMPAT_OS=linux
	export SENTINEL_SHIELD_COMPAT_ARCH=x86_64
	export SENTINEL_SHIELD_COMPAT_SHELL=bash
	export SENTINEL_SHIELD_COMPAT_GIT_VERSION=2.39.0
	export SENTINEL_SHIELD_COMPAT_JQ_VERSION=1.7
	export SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.2.0
	export SENTINEL_SHIELD_COMPAT_NODE_VERSION=20.11.0
	export SENTINEL_SHIELD_COMPAT_NPM_VERSION=10.9.0
	export SENTINEL_SHIELD_COMPAT_PNPM_VERSION=9.12.0
	export SENTINEL_SHIELD_COMPAT_YARN_VERSION=4.5.0
	export SENTINEL_SHIELD_COMPAT_COMPOSER_VERSION=2.7.0
	export SENTINEL_SHIELD_COMPAT_DOCKER_PRESENT=no
	export SENTINEL_SHIELD_COMPAT_DOCKER_VERSION=27.0.0
	export SENTINEL_SHIELD_COMPAT_FS_CASE=sensitive
	export SENTINEL_SHIELD_COMPAT_NETWORK=unknown
	export SENTINEL_SHIELD_COMPAT_ONLINE_ONLY=no
}

# run_health <extra-args...> — run the gate against the canonical policy; set globals RC + OUT.
OUT=""
RC=0
run_health() {
	OUT="$WORK/health.out"
	RC=0
	sh "$HEALTH" --policy "$POLICY" "$@" >"$OUT" 2>&1 || RC=$?
}

# --- SCHEMA / policy structural conformance ----------------------------------
if jq -e . "$SCHEMA" >/dev/null 2>&1; then pass "schema is valid JSON"; else fail "schema is not valid JSON"; fi
if jq -e . "$POLICY" >/dev/null 2>&1; then pass "policy is valid JSON"; else fail "policy is not valid JSON"; fi

# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$ROOT/scripts/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compatibility-policy.sh
. "$LIB"
if cp_validate_policy "$POLICY" >/dev/null 2>&1; then pass "policy conforms to compatibility-policy.schema.json (cp_validate_policy)"; else fail "policy does not conform (cp_validate_policy)"; fi

# supported majors from spec are exactly as required (npm 8-11, pnpm 8-10, yarn 1-4).
assert_eq "npm supported majors 8-11" "$(jq -c '.components.npm.supported_majors' "$POLICY")" "[8,9,10,11]"
assert_eq "pnpm supported majors 8-10" "$(jq -c '.components.pnpm.supported_majors' "$POLICY")" "[8,9,10]"
assert_eq "yarn supported majors 1-4" "$(jq -c '.components.yarn.supported_majors' "$POLICY")" "[1,2,3,4]"

# --- library version-compare unit checks -------------------------------------
assert_eq "cmp 2.10 < 2.20" "$(cp_cmp_version 2.10 2.20)" "-1"
assert_eq "cmp 2.20 == 2.20" "$(cp_cmp_version 2.20 2.20)" "0"
assert_eq "cmp 1.8.2 > 1.6" "$(cp_cmp_version 1.8.2 1.6)" "1"

# ============================================================================
# (1) minimum supported environment -> exit 0
# ============================================================================
reset_baseline
export SENTINEL_SHIELD_COMPAT_SHELL=sh
export SENTINEL_SHIELD_COMPAT_GIT_VERSION=2.20
export SENTINEL_SHIELD_COMPAT_JQ_VERSION=1.6
export SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.1
export SENTINEL_SHIELD_COMPAT_NODE_VERSION=18.0
export SENTINEL_SHIELD_COMPAT_NPM_VERSION=8.0
export SENTINEL_SHIELD_COMPAT_PNPM_VERSION=8.0
export SENTINEL_SHIELD_COMPAT_YARN_VERSION=1.22
export SENTINEL_SHIELD_COMPAT_COMPOSER_VERSION=2.2
run_health
assert_eq "(1) minimum supported env -> exit 0" "$RC" "0"

# ============================================================================
# (2) latest supported environment -> exit 0
# ============================================================================
reset_baseline
export SENTINEL_SHIELD_COMPAT_GIT_VERSION=2.45
export SENTINEL_SHIELD_COMPAT_JQ_VERSION=1.7.1
export SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.4
export SENTINEL_SHIELD_COMPAT_NODE_VERSION=22.11
export SENTINEL_SHIELD_COMPAT_NPM_VERSION=11.0
export SENTINEL_SHIELD_COMPAT_PNPM_VERSION=10.0
export SENTINEL_SHIELD_COMPAT_YARN_VERSION=4.5
export SENTINEL_SHIELD_COMPAT_COMPOSER_VERSION=2.8
export SENTINEL_SHIELD_COMPAT_DOCKER_PRESENT=yes
export SENTINEL_SHIELD_COMPAT_DOCKER_VERSION=27.0
run_health
assert_eq "(2) latest supported env -> exit 0" "$RC" "0"

# ============================================================================
# (3) one below-minimum for every mandatory tool -> exit 3, stable diagnostic
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_GIT_VERSION=2.10; run_health
assert_eq "(3) git below minimum -> exit 3" "$RC" "3"
assert_diag "(3) git below-minimum carries stable reason UNSUPPORTED_GIT_VERSION" "$OUT" '\[compat:git\].*below-minimum' 'UNSUPPORTED_GIT_VERSION'
reset_baseline; export SENTINEL_SHIELD_COMPAT_JQ_VERSION=1.4; run_health
assert_eq "(3) jq below minimum -> exit 3" "$RC" "3"
assert_diag "(3) jq below-minimum carries stable reason UNSUPPORTED_JQ_VERSION" "$OUT" '\[compat:jq\].*below-minimum' 'UNSUPPORTED_JQ_VERSION'

# ============================================================================
# (4) unsupported shell -> exit 3
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_SHELL=fish; run_health
assert_eq "(4) unsupported shell -> exit 3" "$RC" "3"
assert_diag "(4) unsupported shell carries stable reason UNSUPPORTED_SHELL" "$OUT" '\[compat:shell\].*unsupported' 'UNSUPPORTED_SHELL'

# ============================================================================
# (5) unsupported package-manager major -> exit 3
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_NPM_VERSION=7.5.0; run_health
assert_eq "(5) npm major below range -> exit 3" "$RC" "3"
assert_diag "(5) unsupported npm carries stable reason UNSUPPORTED_NPM_VERSION" "$OUT" '\[compat:npm\]' 'UNSUPPORTED_NPM_VERSION'
reset_baseline; export SENTINEL_SHIELD_COMPAT_YARN_VERSION=5.0.0; run_health
assert_eq "(5b) yarn 5 unsupported -> exit 3" "$RC" "3"
assert_diag "(5b) yarn 5 reported unsupported" "$OUT" '\[compat:yarn\].*unsupported'

# ============================================================================
# (6) unsupported PHP -> exit 3
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_PHP_VERSION=7.4.0; run_health
assert_eq "(6) unsupported PHP -> exit 3" "$RC" "3"
assert_diag "(6) unsupported PHP carries stable reason UNSUPPORTED_PHP_VERSION" "$OUT" '\[compat:php\]' 'UNSUPPORTED_PHP_VERSION'

# ============================================================================
# (7) unsupported Node -> exit 3
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_NODE_VERSION=16.20.0; run_health
assert_eq "(7) unsupported Node -> exit 3" "$RC" "3"
assert_diag "(7) unsupported Node carries stable reason UNSUPPORTED_NODE_VERSION" "$OUT" '\[compat:node\]' 'UNSUPPORTED_NODE_VERSION'

# ============================================================================
# (8) no Docker under a Docker-OPTIONAL profile -> exit 0 (tolerated)
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_DOCKER_PRESENT=no; run_health --docker optional
assert_eq "(8) no Docker + optional profile -> exit 0" "$RC" "0"
assert_diag "(8) docker-optional absence reported as ok, not a failure" "$OUT" '\[compat:docker\].*not present'

# ============================================================================
# (9) no Docker with a Docker-REQUIRED action -> exit 3
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_DOCKER_PRESENT=no; run_health --docker required
assert_eq "(9) no Docker + required action -> exit 3" "$RC" "3"
assert_diag "(9) docker-required absence carries stable reason DOCKER_REQUIRED_ABSENT" "$OUT" '\[compat:docker\]' 'DOCKER_REQUIRED_ABSENT'

# ============================================================================
# (10) case-insensitive filesystem -> exit 1 (warning, not a failure)
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_FS_CASE=insensitive; run_health
assert_eq "(10) case-insensitive FS -> exit 1 (warning)" "$RC" "1"
assert_diag "(10) case-insensitive FS warns (not fails) with reason CASE_INSENSITIVE_FS" "$OUT" '  WARN  \[compat:filesystem\]' 'CASE_INSENSITIVE_FS'

# ============================================================================
# (11) unsupported architecture -> exit 3
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_ARCH=s390x; run_health
assert_eq "(11) unsupported architecture -> exit 3" "$RC" "3"
assert_diag "(11) unsupported arch carries stable reason UNSUPPORTED_ARCH" "$OUT" '\[compat:arch\].*unsupported' 'UNSUPPORTED_ARCH'

# ============================================================================
# (12) missing network in an online-only operation -> exit 3
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_NETWORK=offline; run_health --require-network
assert_eq "(12) offline + online-only op -> exit 3" "$RC" "3"
assert_diag "(12) offline online-only op carries stable reason NETWORK_REQUIRED_OFFLINE" "$OUT" '\[compat:network\]' 'NETWORK_REQUIRED_OFFLINE'
reset_baseline; export SENTINEL_SHIELD_COMPAT_NETWORK=online; run_health --require-network
assert_eq "(12b) online + online-only op -> exit 0" "$RC" "0"

# ============================================================================
# FAILURE-INJECTION: policy problems fail closed (exit 2)
# ============================================================================
reset_baseline
MISSING="$WORK/nope.json"
RC=0; sh "$HEALTH" --policy "$MISSING" >/dev/null 2>&1 || RC=$?
assert_eq "fail-closed: missing policy -> exit 2" "$RC" "2"

MAL="$WORK/malformed.json"; printf '{ this is not json\n' > "$MAL"
RC=0; sh "$HEALTH" --policy "$MAL" >/dev/null 2>&1 || RC=$?
assert_eq "fail-closed: malformed policy -> exit 2" "$RC" "2"

NONCONF="$WORK/nonconf.json"; jq 'del(.components.git)' "$POLICY" > "$NONCONF"
RC=0; sh "$HEALTH" --policy "$NONCONF" >/dev/null 2>&1 || RC=$?
assert_eq "fail-closed: non-conformant policy (missing git component) -> exit 2" "$RC" "2"

RC=0; sh "$HEALTH" --policy "$POLICY" --docker maybe >/dev/null 2>&1 || RC=$?
assert_eq "fail-closed: invalid --docker value -> exit 2" "$RC" "2"

# ============================================================================
# FAILURE-INJECTION: an unparseable MANDATORY tool version fails closed (exit 3)
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_GIT_VERSION=not-a-version; run_health
assert_eq "fail-closed: unparseable mandatory git version -> exit 3" "$RC" "3"
assert_diag "fail-closed: unparseable git version reported status=unknown" "$OUT" '\[compat:git\].*unknown'

# ============================================================================
# BONUS: unsupported OS -> exit 3 (enum, mandatory)
# ============================================================================
reset_baseline; export SENTINEL_SHIELD_COMPAT_OS=solaris; run_health
assert_eq "unsupported OS -> exit 3" "$RC" "3"
assert_diag "unsupported OS carries stable reason UNSUPPORTED_OS" "$OUT" 'UNSUPPORTED_OS'

printf '\n260-compatibility-policy: %d failure(s)\n' "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
printf 'All compatibility-policy assertions passed.\n'
exit 0
