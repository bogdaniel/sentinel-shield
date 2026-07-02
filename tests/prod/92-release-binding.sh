#!/bin/sh
# Sentinel Shield production test — release-commit binding (Finding 1) and engine_ci
# GitHub-identity verification (Finding 3), all network-free via a stubbed GH_BIN.
#
# F1: prove the tag target (release_commit) only adds approved METADATA over the
#     CI-validated source (engine_commit); any script/workflow/schema change is
#     rejected; an unknown/diverged release commit fails closed.
# F3: prove --verify-github binds each engine_ci run to the REAL workflow identity:
#     workflow name, event (push/approved dispatch only), default branch, repo, and
#     that artifacts belong to the declared run.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VALIDATOR="$ROOT/scripts/validate-release-evidence.sh"
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssbind)
trap 'rm -rf "$WORK"' EXIT INT TERM

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # engine_commit (release source)
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # release_commit (evidence commit)

# gh stub: env-driven so each case shapes the response. Path is "$2" (gh api <path>).
BIN="$WORK/gh"
cat > "$BIN" <<'EOF'
#!/bin/sh
# Defaults are assigned separately: a brace-containing default inside ${VAR:-...}
# would be mis-parsed by the shell and corrupt the JSON.
p="$2"
cmp="${MOCK_COMPARE:-}"; [ -n "$cmp" ] || cmp='{"status":"ahead","files":[]}'
art="${MOCK_ARTIFACTS:-}"; [ -n "$art" ] || art='{"artifacts":[]}'
case "$p" in
  */compare/*) printf '%s\n' "$cmp" ;;
  */actions/runs/*/artifacts) printf '%s\n' "$art" ;;
  */actions/runs/*) [ -n "${FAIL_RUN:-}" ] && exit 1
     printf '{"id":%s,"name":"%s","head_sha":"%s","head_branch":"%s","event":"%s","conclusion":"%s","html_url":"%s","repository":{"full_name":"%s"}}\n' \
       "${RID:-5001}" "${RUN_NAME:-ci-self-test}" "${RUN_SHA:-$A}" "${RUN_BRANCH:-master}" "${RUN_EVENT:-push}" "${RUN_CONCL:-success}" "${RUN_URL:-https://github.com/org/engine/actions/runs/5001}" "${RUN_REPO:-org/engine}" ;;
  repos/*) [ -n "${FAIL_REPOMETA:-}" ] && exit 1
     printf '{"default_branch":"%s"}\n' "${DEF_BRANCH:-master}" ;;
  *) printf '{}\n' ;;
esac
EOF
# The stub references $A via the parent env; export it.
export A
chmod +x "$BIN"

# base engine-only evidence: one push engine_ci run at engine_commit A.
mkev() { # mkev <file> <release_commit-or-empty> <artifacts-json>
  cat > "$1" <<EOF
{ "version":"2.0.0-beta.1","stage":"beta","release_scope":"engine-only",
  "engine_commit":"$A"$( [ -n "$2" ] && printf ',"release_commit":"%s"' "$2" ),
  "engine_ci":[{"workflow_name":"ci-self-test","repository":"org/engine","commit":"$A","event":"push","workflow_run_id":5001,"workflow_url":"https://github.com/org/engine/actions/runs/5001","result":"success","artifacts":${3:-[]},"artifacts_verified":$( [ "${3:-[]}" = "[]" ] && echo false || echo true ),"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"}],
  "consumer_runs":[],
  "required_evidence":{"laravel":false,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false} }
EOF
}

# expect <code> <desc> <mode-args...> with env already exported by caller
expect() {
  _exp="$1"; _desc="$2"; shift 2
  _rc=0; GH_BIN="$BIN" sh "$VALIDATOR" "$@" >/dev/null 2>&1 || _rc=$?
  if [ "$_rc" = "$_exp" ]; then pass "$_desc (exit $_rc)"; else fail "$_desc (expected $_exp, got $_rc)"; fi
}

# ---------- Finding 1: commit binding (--verify-binding) ----------
EV="$WORK/ev.json"

mkev "$EV" "" "[]"
expect 0 "F1 no release_commit => binding OK" --file "$EV" --verify-binding

mkev "$EV" "$A" "[]"        # release_commit == engine_commit
expect 0 "F1 release_commit == engine_commit => OK" --file "$EV" --verify-binding

mkev "$EV" "$B" "[]"        # differ: diff must be metadata-only
MOCK_COMPARE='{"status":"ahead","files":[{"filename":"evidence/releases/v2.0.0-beta.1.json"},{"filename":"CHANGELOG.md"}]}' \
  expect 0 "F1 metadata-only evidence commit accepted" --file "$EV" --verify-binding
MOCK_COMPARE='{"status":"ahead","files":[{"filename":"docs/v2.0.0-release-notes.md"}]}' \
  expect 0 "F1 release-notes doc accepted" --file "$EV" --verify-binding
MOCK_COMPARE='{"status":"ahead","files":[{"filename":"scripts/doctor.sh"}]}' \
  expect 2 "F1 script change between commits rejected" --file "$EV" --verify-binding
MOCK_COMPARE='{"status":"ahead","files":[{"filename":".github/workflows/ci-zap.yml"}]}' \
  expect 2 "F1 workflow change rejected" --file "$EV" --verify-binding
MOCK_COMPARE='{"status":"ahead","files":[{"filename":"schemas/release-evidence.schema.json"}]}' \
  expect 2 "F1 schema change rejected" --file "$EV" --verify-binding
MOCK_COMPARE='{"status":"behind","files":[]}' \
  expect 2 "F1 diverged/behind release commit rejected" --file "$EV" --verify-binding
# unknown release commit: compare endpoint 404s (a separate stub that fails compare)
cat > "$WORK/gh-nocompare" <<'EOF'
#!/bin/sh
case "$2" in */compare/*) exit 1 ;; *) printf '{}\n' ;; esac
EOF
chmod +x "$WORK/gh-nocompare"
_rc=0; GH_BIN="$WORK/gh-nocompare" sh "$VALIDATOR" --file "$EV" --verify-binding >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] && pass "F1 unknown release commit (compare 404) fails closed (exit 1)" || fail "F1 unknown release commit expected 1, got $_rc"

# mismatched: release_commit set but engine_commit unknown => structural exit 2
cat > "$WORK/mm.json" <<EOF
{ "version":"2.0.0-beta.1","stage":"beta","release_scope":"engine-only","engine_commit":"unknown","release_commit":"$B","engine_ci":[],"consumer_runs":[],"required_evidence":{"laravel":false,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false} }
EOF
expect 2 "F1 release_commit with engine_commit=unknown rejected" --file "$WORK/mm.json" --verify-binding

# ---------- Finding 3: engine_ci GitHub identity (--verify-github, no stage gate) ----------
mkev "$EV" "" "[]"
expect 0 "F3 correct named push run on default branch accepted" --file "$EV" --verify-github
RUN_NAME=ci-docker   expect 1 "F3 wrong workflow name rejected" --file "$EV" --verify-github
RUN_EVENT=pull_request expect 1 "F3 PR run labeled push rejected (api event mismatch)" --file "$EV" --verify-github
RUN_BRANCH=feature-x expect 1 "F3 non-default-branch run rejected" --file "$EV" --verify-github
DEF_BRANCH=develop   expect 1 "F3 default-branch mismatch rejected" --file "$EV" --verify-github
RUN_REPO=org/other   expect 1 "F3 repository.full_name mismatch rejected" --file "$EV" --verify-github
FAIL_REPOMETA=1      expect 1 "F3 missing repository metadata rejected" --file "$EV" --verify-github
FAIL_RUN=1           expect 1 "F3 nonexistent run rejected" --file "$EV" --verify-github

# declared event = schedule => rejected before API (must be push/workflow_dispatch)
cat > "$WORK/sched.json" <<EOF
{ "version":"2.0.0-beta.1","stage":"beta","release_scope":"engine-only","engine_commit":"$A",
  "engine_ci":[{"workflow_name":"ci-self-test","repository":"org/engine","commit":"$A","event":"schedule","workflow_run_id":5001,"workflow_url":"https://github.com/org/engine/actions/runs/5001","result":"success","artifacts":[],"artifacts_verified":false,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"}],
  "consumer_runs":[],"required_evidence":{"laravel":false,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false} }
EOF
expect 1 "F3 scheduled run rejected as release push evidence" --file "$WORK/sched.json" --verify-github

# artifact belonging to a different run rejected: declare artifact id 77, mock lists none
mkev "$EV" "" '[{"id":77,"name":"reports","verified":true}]'
MOCK_ARTIFACTS='{"artifacts":[{"id":999,"name":"reports"}]}' \
  expect 1 "F3 artifact not owned by the run rejected" --file "$EV" --verify-github

if [ "$FAILS" -gt 0 ]; then printf '\n%d assertion(s) failed\n' "$FAILS" >&2; exit 1; fi
exit 0
