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

# --- Finding 2: verification-mode policy ------------------------------------
# A good engine-only evidence file + a stubbed `gh` so --verify-github succeeds
# hermetically. Two engine_ci core runs at CM on the default branch.
CM=cccccccccccccccccccccccccccccccccccccccc
GOOD_ENGINE="$TMPDIR_T/good-engine.json"
cat >"$GOOD_ENGINE" <<JSON
{ "version":"2.0.0-beta.1","stage":"beta","release_scope":"engine-only","engine_commit":"$CM",
  "engine_ci":[
    {"workflow_name":"ci-self-test","repository":"org/engine","commit":"$CM","event":"push","workflow_run_id":9001,"workflow_url":"https://github.com/org/engine/actions/runs/9001","result":"success","artifacts":[],"artifacts_verified":false,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"},
    {"workflow_name":"ci-pipeline","repository":"org/engine","commit":"$CM","event":"push","workflow_run_id":9002,"workflow_url":"https://github.com/org/engine/actions/runs/9002","result":"success","artifacts":[],"artifacts_verified":false,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"}
  ],
  "consumer_runs":[],
  "required_evidence":{"laravel":false,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false} }
JSON
cat >"$BIN/gh" <<JSON
#!/bin/sh
case "\$2" in
  */actions/runs/9001/artifacts|*/actions/runs/9002/artifacts) echo '{"artifacts":[]}' ;;
  */actions/runs/9001) echo '{"id":9001,"name":"ci-self-test","head_sha":"$CM","head_branch":"master","event":"push","conclusion":"success","html_url":"https://github.com/org/engine/actions/runs/9001","repository":{"full_name":"org/engine"}}' ;;
  */actions/runs/9002) echo '{"id":9002,"name":"ci-pipeline","head_sha":"$CM","head_branch":"master","event":"push","conclusion":"success","html_url":"https://github.com/org/engine/actions/runs/9002","repository":{"full_name":"org/engine"}}' ;;
  repos/org/engine) echo '{"default_branch":"master"}' ;;
  *) echo '{}' ;;
esac
JSON
chmod +x "$BIN/gh"

# (e) beta WITHOUT --verify-github fails closed (structural-only is insufficient).
rc=0; out=$(run selftest-ok --version v2.0.0-beta.1 --stage beta --scope engine-only --evidence "$GOOD_ENGINE") || rc=$?
[ "$rc" -eq 1 ] && ok "(e) beta offline fails closed (exit 1)" || bad "(e) beta offline expected 1, got $rc"
printf '%s' "$out" | grep -q 'requires GitHub-verified' && ok "(e) beta offline states GitHub verification is required" || bad "(e) beta offline missing the requirement message"
printf '%s' "$out" | grep -q 'Evidence verification: structural-only (INSUFFICIENT for beta)' && ok "(e) beta offline labels evidence structural-only INSUFFICIENT" || bad "(e) beta offline missing the structural-only label"

# (f) alpha offline is allowed but labeled structural-only / development-only.
rc=0; out=$(run selftest-ok --version v2.0.0-alpha.1 --stage alpha --scope engine-only --evidence "$GOOD_ENGINE") || rc=$?
[ "$rc" -eq 0 ] && ok "(f) alpha offline exits 0 (development)" || bad "(f) alpha offline expected 0, got $rc"
printf '%s' "$out" | grep -q 'Evidence verification: structural-only' && ok "(f) alpha offline labels evidence structural-only" || bad "(f) alpha offline missing structural-only label"
printf '%s' "$out" | grep -q 'valid for DEVELOPMENT only' && ok "(f) alpha offline is marked development-only (not tag-authorization)" || bad "(f) alpha offline missing development-only note"

# (g) alpha WITH --verify-github (stubbed gh) is GitHub-verified and authorization-eligible.
rc=0; out=$(run selftest-ok --version v2.0.0-alpha.1 --stage alpha --scope engine-only --verify-github --evidence "$GOOD_ENGINE") || rc=$?
[ "$rc" -eq 0 ] && ok "(g) alpha --verify-github exits 0" || bad "(g) alpha --verify-github expected 0, got $rc; out: $out"
printf '%s' "$out" | grep -q 'Evidence verification: GitHub-verified' && ok "(g) alpha --verify-github labels evidence GitHub-verified" || bad "(g) alpha --verify-github missing GitHub-verified label"
printf '%s' "$out" | grep -q 'eligible for alpha tag authorization' && ok "(g) alpha --verify-github is authorization-eligible" || bad "(g) alpha --verify-github missing authorization note"

# (h) beta WITH --verify-github (stubbed gh) passes on valid engine-only evidence.
rc=0; out=$(run selftest-ok --version v2.0.0-beta.1 --stage beta --scope engine-only --verify-github --evidence "$GOOD_ENGINE") || rc=$?
[ "$rc" -eq 0 ] && ok "(h) beta --verify-github exits 0 on valid engine evidence" || bad "(h) beta --verify-github expected 0, got $rc; out: $out"
printf '%s' "$out" | grep -q 'Evidence verification: GitHub-verified' && ok "(h) beta --verify-github labels evidence GitHub-verified" || bad "(h) beta --verify-github missing GitHub-verified label"
printf '%s' "$out" | grep -q 'READY (all required gates met)' && ok "(h) beta --verify-github prints READY" || bad "(h) beta --verify-github missing READY"

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

# (g) SHA-pin gate (#7) anchors to the actual 'uses:' ref token, NOT arbitrary
# trailing text: a tag-pinned action whose COMMENT merely contains a 40-hex
# string must be flagged as NOT SHA-pinned. Exercised against the REAL (fixed)
# script in a throwaway repo root so the fixture drives gate #7 directly.
PINROOT="$TMPDIR_T/pinroot"
mkdir -p "$PINROOT/scripts/lib" "$PINROOT/templates/workflows"
cp "$SCRIPT" "$PINROOT/scripts/check-release-readiness.sh"
cp "$ROOT/scripts/lib/sentinel-shield-common.sh" "$PINROOT/scripts/lib/"
PINSCRIPT="$PINROOT/scripts/check-release-readiness.sh"

# tag-pinned ref with a 40-hex SHA hiding only in the trailing comment -> FAIL.
cat >"$PINROOT/templates/workflows/wf.yml" <<'YML'
name: poison
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: poison
        uses: foo/bar@v1 # 0000000000000000000000000000000000000000
YML
out=$(SELF_TEST="$BIN/selftest-ok" PATH="$BIN:$PATH" sh "$PINSCRIPT" --version v2.0.0 --stage alpha 2>&1 || true)
if printf '%s' "$out" | grep -q 'not pinned to a 40-hex SHA'; then
	ok "(g) pin gate flags a tag-pinned ref with a 40-hex SHA only in the comment"
else bad "(g) pin gate FALSELY accepted a comment-only 40-hex SHA"; fi

# properly SHA-pinned ref (40-hex on the ref itself) -> the pin gate PASSES.
cat >"$PINROOT/templates/workflows/wf.yml" <<'YML'
name: clean
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: clean
        uses: foo/bar@34e114876b0b11c390a56381ad16ebd13914f8d5 # v1
YML
out=$(SELF_TEST="$BIN/selftest-ok" PATH="$BIN:$PATH" sh "$PINSCRIPT" --version v2.0.0 --stage alpha 2>&1 || true)
if printf '%s' "$out" | grep -q 'workflow actions SHA-pinned'; then
	ok "(g) pin gate passes when the ref itself ends with a 40-hex SHA"
else bad "(g) pin gate failed a properly SHA-pinned ref"; fi

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
