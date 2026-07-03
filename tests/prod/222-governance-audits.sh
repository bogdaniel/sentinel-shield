#!/bin/sh
# Sentinel Shield production test — governance audits (NN=222).
#
# Exercises the two fail-closed governance gates wired into ci-workflow-lint.yml:
#
#   scripts/audits/required-checks-audit.sh — registry drift: the live
#     jobs.<id>.name across .github/workflows/*.yml must stay in lockstep with
#     config/required-checks.json (renamed / missing / unregistered / duplicate /
#     unregistered-workflow / missing-workflow).
#   scripts/audits/merge-safety-audit.sh — unsafe workflow patterns across the
#     engine CI AND consumer templates (privileged pull_request_target checkout,
#     write perms / secret exposure on fork-reachable jobs, mutable action refs,
#     release on unprotected refs).
#
# POSITIVE: the shipped repo passes both audits clean (exit 0, status=pass).
# NEGATIVE: purpose-built fixtures/temp inputs each trip EXACTLY their intended
# check (a skip is not a pass — the specific check id must fire, non-zero exit).
# SCHEMA: both audit reports match their schema contract; both schemas jq-valid.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RC_AUDIT="$ROOT/scripts/audits/required-checks-audit.sh"
MS_AUDIT="$ROOT/scripts/audits/merge-safety-audit.sh"
REGISTRY="$ROOT/config/required-checks.json"
UFX="$ROOT/tests/fixtures/workflows/unsafe"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

[ -x "$RC_AUDIT" ] || fail "required-checks-audit not executable: $RC_AUDIT"
[ -x "$MS_AUDIT" ] || fail "merge-safety-audit not executable: $MS_AUDIT"
[ -f "$REGISTRY" ] && jq -e . "$REGISTRY" >/dev/null 2>&1 \
	&& pass "config/required-checks.json is present and jq-valid" \
	|| fail "config/required-checks.json missing or not jq-valid"

# ============================================================================
# required-checks-audit
# ============================================================================

# --- POSITIVE: real registry vs real .github/workflows passes clean ----------
OUT_RC="$WORK/rc-positive.json"
if ( cd "$ROOT" && sh "$RC_AUDIT" --output "$OUT_RC" >/dev/null 2>&1 ); then
	if [ "$(jq -r '.status' "$OUT_RC")" = "pass" ] && [ "$(jq '.violation_count' "$OUT_RC")" = "0" ]; then
		pass "required-checks: shipped registry in sync with .github/workflows"
	else
		fail "required-checks: shipped repo not clean -> $(jq -c '{status,violation_count}' "$OUT_RC")"
	fi
else
	fail "required-checks: shipped repo audit exited non-zero -> $(jq -c '.violations' "$OUT_RC" 2>/dev/null || echo '?')"
fi

# --- NEGATIVE: isolated temp registry+workflows, one defect each -------------
# Each scenario uses a self-contained temp registry + temp workflows dir so the
# ONLY drift present is the intended one.
mk_wf() { # mk_wf <dir> <file> <job-id> [job-name]
	mkdir -p "$1"
	{
		printf 'name: t\non: [push]\njobs:\n  %s:\n    runs-on: ubuntu-latest\n' "$3"
		[ -n "${4:-}" ] && printf '    name: %s\n' "$4"
		printf '    steps: [{ run: echo hi }]\n'
	} > "$1/$2"
}
mk_reg() { # mk_reg <path> <file> <check1> [check2]
	_c="[{\"name\":\"$3\",\"classification\":\"always-required\"}"
	[ -n "${4:-}" ] && _c="$_c,{\"name\":\"$4\",\"classification\":\"always-required\"}"
	_c="$_c]"
	printf '{"version":"1.0","workflows":{"%s":{"checks":%s}}}\n' "$2" "$_c" > "$1"
}

rc_negative() { # rc_negative <label> <want-type> <regfile> <wfdir>
	_lbl=$1; _want=$2; _reg=$3; _wfd=$4
	_o="$WORK/rc-$_lbl.json"
	if sh "$RC_AUDIT" --registry "$_reg" --workflows-dir "$_wfd" --output "$_o" >/dev/null 2>&1; then
		fail "required-checks[$_lbl]: audit exited 0 but drift '$_want' was expected"
		return
	fi
	_got=$(jq -r '[.violations[].type]|unique|join(",")' "$_o")
	if [ "$_got" = "$_want" ]; then
		pass "required-checks[$_lbl]: fail-closed on '$_want'"
	else
		fail "required-checks[$_lbl]: expected only '$_want', got '[$_got]'"
	fi
}

# renamed: registry check 'alpha', workflow job renamed to 'beta'
D="$WORK/n-renamed"; mk_wf "$D/wf" f.yml build beta; mk_reg "$D/reg.json" f.yml alpha
rc_negative renamed renamed "$D/reg.json" "$D/wf"

# missing: registry has alpha+beta, workflow only alpha
D="$WORK/n-missing"; mk_wf "$D/wf" f.yml alpha; mk_reg "$D/reg.json" f.yml alpha beta
rc_negative missing missing "$D/reg.json" "$D/wf"

# unregistered: registry has only alpha, workflow adds a second (unmatched) job
D="$WORK/n-unreg"
mkdir -p "$D/wf"
cat > "$D/wf/f.yml" <<'EOF'
name: t
on: [push]
jobs:
  alpha:
    runs-on: ubuntu-latest
    steps: [{ run: echo hi }]
  extra:
    runs-on: ubuntu-latest
    steps: [{ run: echo hi }]
EOF
mk_reg "$D/reg.json" f.yml alpha
rc_negative unregistered unregistered "$D/reg.json" "$D/wf"

# duplicate: two jobs publish the SAME check name via job-level name:
D="$WORK/n-dup"
mkdir -p "$D/wf"
cat > "$D/wf/f.yml" <<'EOF'
name: t
on: [push]
jobs:
  j1:
    name: alpha
    runs-on: ubuntu-latest
    steps: [{ run: echo hi }]
  j2:
    name: alpha
    runs-on: ubuntu-latest
    steps: [{ run: echo hi }]
EOF
mk_reg "$D/reg.json" f.yml alpha
rc_negative duplicate duplicate "$D/reg.json" "$D/wf"

# unregistered-workflow: a live workflow file absent from the registry
D="$WORK/n-unregwf"; mk_wf "$D/wf" f.yml alpha
printf '{"version":"1.0","workflows":{}}\n' > "$D/reg.json"
rc_negative unregistered-workflow unregistered-workflow "$D/reg.json" "$D/wf"

# missing-workflow: registry references a file not present on disk
D="$WORK/n-missingwf"; mk_wf "$D/wf" present.yml alpha; mk_reg "$D/reg.json" present.yml alpha
# add a phantom file entry to the registry
jq '.workflows["ghost.yml"] = {"checks":[{"name":"x","classification":"always-required"}]}' \
	"$D/reg.json" > "$D/reg2.json"
rc_negative missing-workflow missing-workflow "$D/reg2.json" "$D/wf"

# --- SCHEMA conformance (required-checks-audit) ------------------------------
RC_SCHEMA="$ROOT/schemas/required-checks-audit.schema.json"
if [ -f "$RC_SCHEMA" ] && jq -e . "$RC_SCHEMA" >/dev/null 2>&1; then
	pass "required-checks-audit schema present and jq-valid"
else
	fail "required-checks-audit schema missing or not jq-valid"
fi
if jq -e '
	(["version","generated_at","tool","files_scanned","checks","status","violation_count","violations"]
	   | all(. as $k | ($in|has($k))))
	and ($in.tool == "required-checks-audit")
	and ($in.status == "pass")
	and ($in.violation_count == 0)
	and ($in.violations|type == "array")
' --argjson in "$(cat "$OUT_RC")" -n >/dev/null 2>&1; then
	pass "required-checks positive report conforms to schema contract"
else
	fail "required-checks positive report does not conform to schema contract"
fi

# ============================================================================
# merge-safety-audit
# ============================================================================

# --- POSITIVE: shipped .github/workflows + templates/workflows pass clean ----
OUT_MS="$WORK/ms-positive.json"
if ( cd "$ROOT" && sh "$MS_AUDIT" --output "$OUT_MS" >/dev/null 2>&1 ); then
	if [ "$(jq -r '.status' "$OUT_MS")" = "pass" ] && [ "$(jq '.violation_count' "$OUT_MS")" = "0" ]; then
		pass "merge-safety: shipped engine CI + templates pass clean"
	else
		fail "merge-safety: shipped repo not clean -> $(jq -c '{status,violation_count}' "$OUT_MS")"
	fi
else
	fail "merge-safety: shipped repo audit exited non-zero -> $(jq -c '.violations' "$OUT_MS" 2>/dev/null || echo '?')"
fi

# --- POSITIVE control fixture ------------------------------------------------
OUT_MSG="$WORK/ms-good.json"
if sh "$MS_AUDIT" "$ROOT/tests/fixtures/workflows/good.yml" --output "$OUT_MSG" >/dev/null 2>&1; then
	[ "$(jq '.violation_count' "$OUT_MSG")" = "0" ] \
		&& pass "merge-safety: good.yml fixture is clean" \
		|| fail "merge-safety: good.yml expected clean, got $(jq '.violation_count' "$OUT_MSG")"
else
	fail "merge-safety: good.yml fixture exited non-zero (should be clean)"
fi

# --- NEGATIVE: each unsafe fixture trips exactly its intended check ----------
ms_negative() { # ms_negative <fixture-basename> <expected-check>
	_fx=$1; _want=$2
	_o="$WORK/ms-$_fx.json"
	if sh "$MS_AUDIT" "$UFX/$_fx.yml" --output "$_o" >/dev/null 2>&1; then
		fail "merge-safety[$_fx]: audit exited 0 but '$_want' was expected"
		return
	fi
	_got=$(jq -r '[.violations[].check]|unique|join(",")' "$_o")
	if [ "$_got" = "$_want" ]; then
		pass "merge-safety[$_fx]: fail-closed on '$_want'"
	else
		fail "merge-safety[$_fx]: expected only '$_want', got '[$_got]'"
	fi
}

ms_negative unsafe-ppt-checkout    pull-request-target-checkout
ms_negative unsafe-pr-write-perms  fork-pr-write-permission
ms_negative unsafe-ppt-secret      pull-request-target-secret
ms_negative unsafe-mutable-ref     mutable-action-ref
ms_negative unsafe-release-on-pr   release-on-unprotected-ref

# --- SCHEMA conformance (merge-safety-audit) ---------------------------------
MS_SCHEMA="$ROOT/schemas/merge-safety-audit.schema.json"
if [ -f "$MS_SCHEMA" ] && jq -e . "$MS_SCHEMA" >/dev/null 2>&1; then
	pass "merge-safety-audit schema present and jq-valid"
else
	fail "merge-safety-audit schema missing or not jq-valid"
fi
if jq -e '
	(["version","generated_at","tool","files_scanned","checks","status","violation_count","violations"]
	   | all(. as $k | ($in|has($k))))
	and ($in.tool == "merge-safety-audit")
	and (($in.checks|sort) == ["fork-pr-write-permission","mutable-action-ref","pull-request-target-checkout","pull-request-target-secret","release-on-unprotected-ref"])
	and ($in.status == "pass")
	and ($in.violation_count == 0)
' --argjson in "$(cat "$OUT_MS")" -n >/dev/null 2>&1; then
	pass "merge-safety positive report conforms to schema contract"
else
	fail "merge-safety positive report does not conform to schema contract"
fi
# A failing merge-safety report has well-formed violation objects.
if jq -e '.violations|length>0 and all(has("file") and has("line") and has("check") and has("ref") and has("message"))' \
	"$WORK/ms-unsafe-mutable-ref.json" >/dev/null 2>&1; then
	pass "merge-safety failing report has well-formed violation objects"
else
	fail "merge-safety failing report violation objects malformed"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
exit 0
