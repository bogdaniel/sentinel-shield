#!/bin/sh
# Sentinel Shield prod test — canonical local pipeline (scripts/run-local-pipeline.sh).
#
# Asserts, against a copy of the existing php-library fixture (network-free, no scanners
# required):
#   (a) a stale prior security summary does NOT satisfy the run — a seeded bogus summary
#       is cleared before execution (and never stands in for a fresh one);
#   (b) an invalid --stage is rejected with exit 2 (invalid config/input);
#   (c) --help lists every documented flag;
#   plus the honest required-tool-unavailable path: with required scanners absent the
#   pipeline exits 3 (NOT a false pass), and a non-fail-fast run still produces a FRESH
#   summary + enforcement report while preserving the distinct exit 3.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

PIPELINE="$ROOT/scripts/run-local-pipeline.sh"
FIXTURE="$ROOT/tests/fixtures/projects/php-library"
FAILED=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

command -v jq >/dev/null 2>&1 || { fail "jq is required to run this test"; exit 1; }
[ -f "$PIPELINE" ] || { fail "missing $PIPELINE"; exit 1; }
[ -d "$FIXTURE" ] || { fail "missing fixture $FIXTURE"; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss40)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

TARGET="$WORK/target"
OUT="$WORK/out"
mkdir -p "$TARGET" "$OUT"
cp -R "$FIXTURE/." "$TARGET/"

# --- hermetic PATH: required scanners absent BY CONSTRUCTION ------------------
# The exit-3 assertions below require gitleaks/semgrep/trivy/osv-scanner to be
# UNAVAILABLE. Relying on the host PATH makes the outcome depend on whichever
# scanners happen to be installed (a host with all four would NOT exit 3). Mirror
# tests/prod/50-sweep.sh's isolated-PATH approach: build a bin dir that links every
# host utility (jq/yq/date/sed/git/... — all the chained engine scripts need them)
# EXCEPT those scanners, so the missing-tool condition is controlled by the test.
ISOBIN="$WORK/isobin"
mkdir -p "$ISOBIN"
_oifs=$IFS
IFS=:
for _d in $PATH; do
	[ -d "$_d" ] || continue
	for _p in "$_d"/*; do
		[ -f "$_p" ] || continue
		_n=${_p##*/}
		case "$_n" in
			gitleaks | semgrep | trivy | osv-scanner) continue ;;
		esac
		[ -e "$ISOBIN/$_n" ] && continue
		ln -s "$_p" "$ISOBIN/$_n" 2>/dev/null || cp -- "$_p" "$ISOBIN/$_n" 2>/dev/null || true
	done
done
IFS=$_oifs

# --- (b) invalid --stage -> exit 2 -------------------------------------------
rc=0
sh "$PIPELINE" --profile php-library --target "$TARGET" --stage bogus >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
	pass "invalid --stage rejected with exit 2"
else
	fail "invalid --stage should exit 2, got $rc"
fi

# --- (c) --help lists every flag ---------------------------------------------
HELP=$(sh "$PIPELINE" --help 2>&1 || true)
_missing=""
for _flag in --profile --target --stage --mode --output-dir --keep-raw --format --fail-fast --non-interactive; do
	case "$HELP" in
		*"$_flag"*) ;;
		*) _missing="$_missing $_flag" ;;
	esac
done
if [ -z "$_missing" ]; then
	pass "--help lists all documented flags"
else
	fail "--help missing flags:$_missing"
fi

# --- (a) stale summary is cleared; honest exit 3 with --fail-fast -------------
# Seed a bogus prior summary at the path the pipeline writes/judges. It must NOT survive.
printf '{"version":"1.0","STALE_BOGUS_MARKER":true}' > "$OUT/security-summary.json"
rc=0
PATH="$ISOBIN" sh "$PIPELINE" --profile php-library --target "$TARGET" --stage pr \
	--output-dir "$OUT" --fail-fast --non-interactive >/dev/null 2>&1 || rc=$?

# Honest required-tool-unavailable path (gitleaks/semgrep/etc. absent in a network-free
# env): the pipeline MUST report exit 3 (required tool unavailable), never a false 0.
if [ "$rc" -eq 3 ]; then
	pass "required-tool absence reported honestly (exit 3, not a false pass)"
else
	fail "expected honest required-tool-unavailable exit 3, got $rc"
fi

# The seeded stale summary must NOT survive the run: either removed, or it must NOT carry
# the stale marker (i.e. it was regenerated). A surviving stale summary would be a bug.
if [ ! -f "$OUT/security-summary.json" ]; then
	pass "stale prior summary was cleared before execution (no file remains to satisfy the run)"
elif ! grep -q 'STALE_BOGUS_MARKER' "$OUT/security-summary.json"; then
	pass "stale prior summary was overwritten with a fresh summary (stale marker gone)"
else
	fail "stale summary survived the run (its old content could falsely satisfy the gate)"
fi

# The pipeline report reflects ONLY this execution and records the honest tool-unavailable result.
if [ -f "$OUT/pipeline-report.json" ] \
	&& [ "$(jq -r '.exit' "$OUT/pipeline-report.json")" = "3" ] \
	&& [ "$(jq -r '.result' "$OUT/pipeline-report.json")" = "tool-unavailable" ]; then
	pass "pipeline report records the current run's honest result (tool-unavailable, exit 3)"
else
	fail "pipeline report did not record the honest tool-unavailable result"
fi

# --- non-fail-fast: a FRESH summary is generated, exit 3 stays DISTINCT -------
# Re-seed the bogus summary, run WITHOUT --fail-fast so the pipeline continues through
# build-security-summary + enforce-gates. The summary judged by the gate must be freshly
# generated (no stale marker, carries policy counters), and the execution-honest exit 3
# must NOT be downgraded to a findings/gate code (1).
OUT2="$WORK/out2"
mkdir -p "$OUT2"
printf '{"version":"1.0","STALE_BOGUS_MARKER":true}' > "$OUT2/security-summary.json"
rc=0
PATH="$ISOBIN" sh "$PIPELINE" --profile php-library --target "$TARGET" --stage pr \
	--output-dir "$OUT2" --mode baseline --non-interactive >/dev/null 2>&1 || rc=$?

if [ "$rc" -eq 3 ]; then
	pass "non-fail-fast run keeps the distinct exit 3 (not downgraded to a findings code)"
else
	fail "non-fail-fast run should exit 3 (distinct), got $rc"
fi

if [ -f "$OUT2/security-summary.json" ] \
	&& ! grep -q 'STALE_BOGUS_MARKER' "$OUT2/security-summary.json" \
	&& [ "$(jq -r 'has("generated_at")' "$OUT2/security-summary.json")" = "true" ]; then
	pass "a fresh security summary is generated this run (stale content does not satisfy it)"
else
	fail "expected a freshly generated security summary without the stale marker"
fi

# The fresh summary surfaces the required-tool absence as a policy counter (honest, not faked).
_reqf=$(jq -r '.summary.required_tool_failures // 0' "$OUT2/security-summary.json" 2>/dev/null || printf 0)
case "$_reqf" in
	''|*[!0-9]*) _reqf=0 ;;
esac
if [ "$_reqf" -gt 0 ]; then
	pass "fresh summary honestly records required_tool_failures=$_reqf (absence not turned into a pass)"
else
	fail "fresh summary should record required_tool_failures > 0 when scanners are absent"
fi

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
