#!/bin/sh
# tests/prod/170-readiness.sh — BLOCKER 3: release-readiness runs the full
# structural contract (it EXECUTES the self-tests, it does not merely check that
# fixtures exist).
#
# Asserts scripts/check-release-readiness.sh:
#   (a) --stage alpha PASSES (exit 0) only when the stubbed self-test gates pass.
#   (b) --stage alpha FAILS CLOSED (exit 1) when ANY self-test gate fails — so
#       fixture-existence alone can never make it green.
#   (c) --stage beta FAILS (exit 1) today even structurally (no real evidence).
#   (d) bad args -> exit 2.
#   (e) the alpha free-text --override-reason is honored but printed LOUDLY.
#   (f) the alpha override is inert when nothing is unmet.
#
# Hermetic: $SELF_TEST is stubbed (fast) and the static validators are shadowed
# by passing fakes on PATH so the result is host-independent. NETWORK-FREE.
# Run via: sh tests/prod/170-readiness.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/check-release-readiness.sh"

FAILED=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

[ -f "$SCRIPT" ] || { bad "check-release-readiness.sh exists"; exit 1; }

TMPDIR_T=$(mktemp -d "${TMPDIR:-/tmp}/170-readiness.XXXXXX")
trap 'rm -rf "$TMPDIR_T"' EXIT INT TERM

# Fake-bin: passing self-test + passing static validators. Real jq/yq/git remain.
BIN="$TMPDIR_T/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "$BIN/selftest-ok"
# Fail self-test only for the 'all' group (the authoritative check).
printf '#!/bin/sh\ncase "$1" in all) exit 1 ;; *) exit 0 ;; esac\n' > "$BIN/selftest-failall"
for v in shellcheck actionlint zizmor; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$v"; done
chmod +x "$BIN"/*

# Honest no-evidence fixture: schema-VALID but satisfies no stage gate, so the
# beta fail-closed path is testable regardless of real evidence/releases/ state.
EMPTY_EVIDENCE="$TMPDIR_T/empty-evidence.json"
cat >"$EMPTY_EVIDENCE" <<'JSON'
{
  "version": "0.0.0-test",
  "stage": "beta",
  "engine_commit": "unknown",
  "consumer_runs": [],
  "required_evidence": {
    "laravel": false, "symfony": false, "php_library": false,
    "node_react": false, "combined_profile": false, "bootstrap_apply": false,
    "rollback_npm": false, "rollback_pnpm": false, "rollback_yarn": false
  }
}
JSON

run() { # run <selftest-stub> <args...>
	_st="$BIN/$1"; shift
	SELF_TEST="$_st" PATH="$BIN:$PATH" sh "$SCRIPT" "$@" 2>&1
}

# (a) alpha passes when the stubbed self-tests pass.
rc=0; out=$(run selftest-ok --version v2.0.0 --stage alpha) || rc=$?
if [ "$rc" -eq 0 ]; then ok "(a) alpha exits 0 when self-test stub passes"
else bad "(a) alpha expected exit 0, got $rc; out: $out"; fi

# (b) alpha FAILS CLOSED when a self-test gate fails — fixtures exist, but the
# tests did not pass, so it must NOT be ready.
rc=0; out=$(run selftest-failall --version v2.0.0 --stage alpha) || rc=$?
if [ "$rc" -eq 1 ]; then ok "(b) alpha exits 1 when a self-test gate fails (fail closed)"
else bad "(b) alpha expected exit 1, got $rc"; fi
if printf '%s' "$out" | grep -q "self-test 'all' failed"; then ok "(b) alpha reports the failing self-test gate by name"
else bad "(b) alpha missing the named self-test failure"; fi
if printf '%s' "$out" | grep -q 'NOT READY'; then ok "(b) alpha prints NOT READY"
else bad "(b) alpha output missing 'NOT READY'"; fi

# (c) beta fails structurally today (no real consumer evidence), even with the
# self-tests stubbed green — fail closed.
rc=0; out=$(run selftest-ok --version v2.0.0 --stage beta --evidence "$EMPTY_EVIDENCE") || rc=$?
if [ "$rc" -eq 1 ]; then ok "(c) beta exits 1 (no real consumer evidence; fail closed)"
else bad "(c) beta expected exit 1, got $rc"; fi
if printf '%s' "$out" | grep -q 'NOT READY'; then ok "(c) beta prints NOT READY"
else bad "(c) beta output missing 'NOT READY'"; fi

# (d) bad args -> exit 2 (missing --version / invalid --stage / unknown flag).
rc=0; run selftest-ok --stage alpha >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "(d) missing --version exits 2" || bad "(d) missing --version expected 2, got $rc"
rc=0; run selftest-ok --version v2.0.0 --stage bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "(d) invalid --stage exits 2" || bad "(d) invalid --stage expected 2, got $rc"
rc=0; run selftest-ok --version v2.0.0 --stage alpha --nope >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "(d) unknown flag exits 2" || bad "(d) unknown flag expected 2, got $rc"

# (e) alpha free-text override is honored (exit 0) on a failing stage, LOUDLY.
rc=0; out=$(run selftest-failall --version v2.0.0 --stage alpha --override-reason "exec sign-off SEC-123") || rc=$?
if [ "$rc" -eq 0 ]; then ok "(e) alpha override makes a failing stage exit 0"
else bad "(e) alpha override expected exit 0, got $rc"; fi
if printf '%s' "$out" | grep -q 'OVERRIDE IN EFFECT'; then ok "(e) alpha override prints the loud banner"
else bad "(e) alpha override missing loud banner"; fi
if printf '%s' "$out" | grep -q 'exec sign-off SEC-123'; then ok "(e) alpha override echoes the documented reason"
else bad "(e) alpha override missing reason text"; fi

# (f) override is inert when nothing is unmet (alpha all-green).
rc=0; out=$(run selftest-ok --version v2.0.0 --stage alpha --override-reason "unused") || rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'OVERRIDE IN EFFECT'; then
	ok "(f) override is inert when no gate is unmet"
else bad "(f) override on a passing stage misbehaved (rc=$rc)"; fi

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
