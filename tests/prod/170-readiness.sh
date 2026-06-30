#!/bin/sh
# tests/prod/170-readiness.sh — WS17 release-promotion readiness gate.
#
# Asserts the contract of scripts/check-release-readiness.sh:
#   (a) --stage alpha PASSES structurally today (exit 0).
#   (b) --stage beta FAILS today (no real consumer evidence) — fail closed (exit 1).
#   (c) bad args -> exit 2.
#   (d) --override-reason is honored (exit 0) but prints a LOUD warning.
# Self-contained, no network. Run via: sh tests/prod/170-readiness.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/check-release-readiness.sh"

FAILED=0
ok()   { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; FAILED=1; }

[ -f "$SCRIPT" ] || { bad "check-release-readiness.sh exists"; exit 1; }

# Use an explicit, honest no-evidence fixture (empty consumer_runs, all flags
# false) for the evidence-gated cases so the fail-closed beta path and override
# behaviour stay testable regardless of whatever real evidence later lands in
# evidence/releases/. The fixture is schema-VALID but satisfies no stage gate.
TMPDIR_T=$(mktemp -d "${TMPDIR:-/tmp}/170-readiness.XXXXXX")
trap 'rm -rf "$TMPDIR_T"' EXIT INT TERM
EMPTY_EVIDENCE="$TMPDIR_T/empty-evidence.json"
cat >"$EMPTY_EVIDENCE" <<'JSON'
{
  "version": "0.0.0-test",
  "stage": "beta",
  "engine_commit": "unknown",
  "consumer_runs": [],
  "required_evidence": {
    "laravel": false,
    "symfony": false,
    "php_library": false,
    "node_react": false,
    "combined_profile": false,
    "bootstrap_apply": false,
    "rollback_npm": false,
    "rollback_pnpm": false,
    "rollback_yarn": false
  }
}
JSON

# (a) alpha passes structurally.
rc=0
out=$(sh "$SCRIPT" --version v2.0.0 --stage alpha 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then ok "(a) --stage alpha exits 0 (structurally ready)"
else bad "(a) --stage alpha expected exit 0, got $rc; output: $out"; fi

# (b) beta fails against the empty-evidence fixture (real consumer evidence is
# UNMET) — fail closed, independent of real evidence/releases/ state.
rc=0
out=$(sh "$SCRIPT" --version v2.0.0 --stage beta --evidence "$EMPTY_EVIDENCE" 2>&1) || rc=$?
if [ "$rc" -eq 1 ]; then ok "(b) --stage beta exits 1 (no real consumer evidence; fail closed)"
else bad "(b) --stage beta expected exit 1, got $rc"; fi
if printf '%s' "$out" | grep -q 'NOT READY'; then ok "(b) beta prints NOT READY"
else bad "(b) beta output missing 'NOT READY'"; fi

# (c) bad args -> exit 2 (missing --version).
rc=0
sh "$SCRIPT" --stage alpha >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "(c) missing --version exits 2"
else bad "(c) missing --version expected exit 2, got $rc"; fi

# (c) bad args -> exit 2 (invalid --stage value).
rc=0
sh "$SCRIPT" --version v2.0.0 --stage bogus >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "(c) invalid --stage exits 2"
else bad "(c) invalid --stage expected exit 2, got $rc"; fi

# (c) bad args -> exit 2 (unknown flag).
rc=0
sh "$SCRIPT" --version v2.0.0 --stage alpha --nope >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "(c) unknown flag exits 2"
else bad "(c) unknown flag expected exit 2, got $rc"; fi

# (d) override honored (exit 0) on a failing stage, but prints a loud warning.
rc=0
out=$(sh "$SCRIPT" --version v2.0.0 --stage beta --evidence "$EMPTY_EVIDENCE" --override-reason "exec sign-off ticket SEC-123" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then ok "(d) override makes a failing stage exit 0"
else bad "(d) override expected exit 0, got $rc"; fi
if printf '%s' "$out" | grep -q 'OVERRIDE IN EFFECT'; then ok "(d) override prints loud 'OVERRIDE IN EFFECT' banner"
else bad "(d) override output missing loud banner"; fi
if printf '%s' "$out" | grep -q 'exec sign-off ticket SEC-123'; then ok "(d) override echoes the documented reason"
else bad "(d) override output missing reason text"; fi

# Sanity: override WITHOUT a failing gate (alpha) still exits 0 and does NOT
# print the override banner (nothing to bypass).
rc=0
out=$(sh "$SCRIPT" --version v2.0.0 --stage alpha --override-reason "unused" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'OVERRIDE IN EFFECT'; then
	ok "(d) override is inert when no gate is unmet"
else bad "(d) override on a passing stage misbehaved (rc=$rc)"; fi

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
