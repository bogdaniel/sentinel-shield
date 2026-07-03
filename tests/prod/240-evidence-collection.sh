#!/bin/sh
# Sentinel Shield production test — release-evidence COLLECTION (NN=240).
#
# Exercises scripts/collect-release-evidence.sh, the GENERATOR that produces a
# candidate engine_ci[] evidence document from the GitHub Actions API. The GitHub
# API is fully MOCKED through a stubbed GH_BIN (network-free, per the tests/prod/92
# pattern). Covers the required cases: match, missing-run, ambiguous-rerun,
# wrong-branch, failed-conclusion — plus cancelled, wrong-event, wrong-repo, and a
# multi-workflow all-green collection whose candidate validates offline.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
COLLECT="$ROOT/scripts/collect-release-evidence.sh"
VALIDATOR="$ROOT/scripts/validate-release-evidence.sh"
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t sscollect)
trap 'rm -rf "$WORK"' EXIT INT TERM

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # engine commit under collection

# gh stub: env-driven. Defaults are assigned on separate lines because a
# brace-containing default inside ${VAR:-...} is mis-parsed by the shell and would
# corrupt the JSON (see tests/prod/92-release-binding.sh for the same caveat).
BIN="$WORK/gh"
cat > "$BIN" <<'EOF'
#!/bin/sh
p="$2"
runs="${MOCK_RUNS:-}"; [ -n "$runs" ] || runs='{"workflow_runs":[]}'
case "$p" in
  */actions/runs\?*|*/actions/runs) printf '%s\n' "$runs" ;;
  repos/*) [ -n "${FAIL_REPO:-}" ] && exit 1
     printf '{"default_branch":"%s"}\n' "${DEF_BRANCH:-master}" ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$BIN"
export A

# mkrun <id> [name] [branch] [event] [conclusion] [status] [repo] — one run object.
mkrun() {
  printf '{"id":%s,"name":"%s","head_sha":"%s","head_branch":"%s","event":"%s","status":"%s","conclusion":"%s","html_url":"https://github.com/org/engine/actions/runs/%s","repository":{"full_name":"%s"}}' \
    "$1" "${2:-ci-self-test}" "$A" "${3:-master}" "${4:-push}" "${6:-completed}" "${5:-success}" "$1" "${7:-org/engine}"
}
runs_doc() { printf '{"workflow_runs":[%s]}' "$1"; }

# collect <extra-args...> — run the collector with the stub; MOCK_RUNS from env.
collect() {
  GH_BIN="$BIN" sh "$COLLECT" --repo org/engine --commit "$A" \
    --version 2.0.0-beta.2 --stage beta --scope engine-only "$@"
}

# expect_reject <exit> <reason> <desc> <workflow> — collection UNMET with a reason.
expect_reject() {
  _exp="$1"; _reason="$2"; _desc="$3"; _wf="$4"
  _out="$WORK/o.json"; _err="$WORK/e.txt"; _rc=0
  collect --workflow "$_wf" --output "$_out" >/dev/null 2>"$_err" || _rc=$?
  if [ "$_rc" != "$_exp" ]; then fail "$_desc (expected exit $_exp, got $_rc)"; return; fi
  if grep -q "$_reason" "$_err"; then pass "$_desc"; else fail "$_desc (reason '$_reason' not reported)"; fi
}

# ---------- MATCH: one green push run on the default branch ----------
MOCK_RUNS=$(runs_doc "$(mkrun 5001)")
export MOCK_RUNS
OUT="$WORK/match.json"; RC=0
collect --workflow ci-self-test --output "$OUT" >/dev/null 2>&1 || RC=$?
if [ "$RC" = 0 ]; then pass "match: collector exits 0"; else fail "match: expected 0, got $RC"; fi
if [ "$(jq -r '.engine_ci[0].workflow_run_id' "$OUT")" = 5001 ] \
   && [ "$(jq -r '.engine_ci[0].result' "$OUT")" = success ] \
   && [ "$(jq -r '.engine_ci[0].commit' "$OUT")" = "$A" ] \
   && [ "$(jq '.engine_ci[0].artifacts|length' "$OUT")" = 0 ]; then
  pass "match: candidate engine_ci entry is well-formed (empty, unverified artifacts)"
else
  fail "match: candidate engine_ci entry malformed -> $(jq -c '.engine_ci[0]' "$OUT")"
fi
# The generated candidate must independently pass the offline validator.
if sh "$VALIDATOR" --file "$OUT" >/dev/null 2>&1; then
  pass "match: generated candidate validates offline"
else
  fail "match: generated candidate does NOT validate offline"
fi
# It must NOT have written any evidence/releases/*.json (generator, not writer).
if [ -z "$(git -C "$ROOT" status --porcelain evidence/releases 2>/dev/null)" ]; then
  pass "match: no evidence/releases file was mutated by collection"
else
  fail "match: collection mutated evidence/releases (must be a pure generator)"
fi

# ---------- MISSING-RUN: no runs at all for the commit ----------
MOCK_RUNS='{"workflow_runs":[]}'; export MOCK_RUNS
expect_reject 1 missing-run "missing-run: no run present is rejected" ci-self-test

# ---------- WRONG-BRANCH: green success but on a feature branch ----------
MOCK_RUNS=$(runs_doc "$(mkrun 5001 ci-self-test feature-x)"); export MOCK_RUNS
expect_reject 1 wrong-branch "wrong-branch: non-default-branch run is rejected" ci-self-test

# ---------- FAILED-CONCLUSION: completed but conclusion=failure ----------
MOCK_RUNS=$(runs_doc "$(mkrun 5001 ci-self-test master push failure)"); export MOCK_RUNS
expect_reject 1 failed-conclusion "failed-conclusion: a failed run is rejected" ci-self-test

# ---------- CANCELLED: completed but conclusion=cancelled ----------
MOCK_RUNS=$(runs_doc "$(mkrun 5001 ci-self-test master push cancelled)"); export MOCK_RUNS
expect_reject 1 cancelled "cancelled: a cancelled run is rejected" ci-self-test

# ---------- AMBIGUOUS-RERUN: two DISTINCT successful runs, same wf+commit ----------
MOCK_RUNS=$(runs_doc "$(mkrun 5001),$(mkrun 5002)"); export MOCK_RUNS
expect_reject 1 ambiguous-rerun "ambiguous-rerun: two successful runs are rejected (no guessing)" ci-self-test

# ---------- WRONG-EVENT: a pull_request run is not release push evidence ----------
MOCK_RUNS=$(runs_doc "$(mkrun 5001 ci-self-test master pull_request)"); export MOCK_RUNS
expect_reject 1 missing-run "wrong-event: a pull_request run does not count (missing-run)" ci-self-test

# ---------- WRONG-REPO: run belongs to a different repository ----------
MOCK_RUNS=$(runs_doc "$(mkrun 5001 ci-self-test master push success completed org/other)"); export MOCK_RUNS
expect_reject 1 missing-run "wrong-repo: run from another repo does not count (missing-run)" ci-self-test

# ---------- MULTI-WORKFLOW all-green: candidate carries every run and validates ----------
MOCK_RUNS=$(runs_doc "$(mkrun 5001 ci-self-test),$(mkrun 5002 ci-pipeline)"); export MOCK_RUNS
OUT="$WORK/multi.json"; RC=0
collect --workflow ci-self-test --workflow ci-pipeline --output "$OUT" >/dev/null 2>&1 || RC=$?
if [ "$RC" = 0 ] && [ "$(jq '.engine_ci|length' "$OUT")" = 2 ] \
   && sh "$VALIDATOR" --file "$OUT" >/dev/null 2>&1; then
  pass "multi-workflow: both runs collected and candidate validates offline"
else
  fail "multi-workflow: expected 2 valid runs (rc=$RC, n=$(jq '.engine_ci|length' "$OUT" 2>/dev/null))"
fi

# ---------- PARTIAL: one workflow green, one missing => UNMET (exit 1) ----------
MOCK_RUNS=$(runs_doc "$(mkrun 5001 ci-self-test)"); export MOCK_RUNS
RC=0
collect --workflow ci-self-test --workflow ci-pipeline --output "$WORK/partial.json" >/dev/null 2>&1 || RC=$?
if [ "$RC" = 1 ]; then pass "partial: a missing required workflow makes collection UNMET (exit 1)"; else fail "partial: expected exit 1, got $RC"; fi

# ---------- DEF-BRANCH override: default branch = develop ----------
# NOTE: `VAR=val func` may leak VAR into the current shell after the function
# returns (POSIX-unspecified; several shells persist it), so DEF_BRANCH is set with
# an explicit export/unset rather than a command prefix on the collect() function.
MOCK_RUNS=$(runs_doc "$(mkrun 5001 ci-self-test develop)"); export MOCK_RUNS
export DEF_BRANCH=develop
RC=0
collect --workflow ci-self-test --output "$WORK/dev.json" >/dev/null 2>&1 || RC=$?
if [ "$RC" = 0 ]; then pass "default-branch: a develop-default repo accepts its develop run"; else fail "default-branch: expected 0, got $RC"; fi
unset DEF_BRANCH
# ...and the SAME develop run is rejected when the repo default is master.
MOCK_RUNS=$(runs_doc "$(mkrun 5001 ci-self-test develop)"); export MOCK_RUNS
expect_reject 1 wrong-branch "default-branch: a develop run is rejected when default=master" ci-self-test

# ---------- INVOCATION: repo-meta fetch failure => exit 2 ----------
MOCK_RUNS='{"workflow_runs":[]}'; export MOCK_RUNS
RC=0
FAIL_REPO=1 collect --workflow ci-self-test >/dev/null 2>&1 || RC=$?
if [ "$RC" = 2 ]; then pass "invocation: unreachable repo metadata fails as exit 2"; else fail "invocation: expected 2, got $RC"; fi

# ---------- INVOCATION: bad commit format => exit 2 (no network) ----------
RC=0
GH_BIN="$BIN" sh "$COLLECT" --repo org/engine --commit not-a-sha --workflow ci-self-test --version v --stage beta >/dev/null 2>&1 || RC=$?
if [ "$RC" = 2 ]; then pass "invocation: malformed --commit rejected as exit 2"; else fail "invocation: expected 2, got $RC"; fi

if [ "$FAILS" -gt 0 ]; then printf '\n%d assertion(s) failed\n' "$FAILS" >&2; exit 1; fi
exit 0
