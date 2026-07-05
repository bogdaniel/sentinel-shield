#!/bin/sh
# Sentinel Shield production test — indirect env lookup is INJECTION-SAFE (NN=256).
#
# scripts/lib/bounded-process.sh reads timeout-override env vars indirectly BY NAME
# (bp_env_get, reached from bp_timeout's caller-controlled override_env_name argument).
# The lookup uses `eval`, so an unvalidated name could smuggle shell syntax
# (command substitution $(...), backticks, ';', '|', '&', whitespace, delimiters,
# braces, quotes) into the eval and EXECUTE arbitrary code. This suite proves the name
# is strictly validated FIRST (character allowlist ^[A-Z][A-Z0-9_]*$ inside the code-
# owned SENTINEL_SHIELD_ namespace), that every hostile name is REJECTED, and that NO
# injected command ever runs — asserted by a sentinel file that must NEVER be created.
#
# Coverage:
#   (A) positive: a valid SENTINEL_SHIELD_* name still reads its value correctly
#   (B) values containing shell syntax are returned LITERALLY, never executed
#   (C) hostile NAMES ($(...), backticks, ;, |, &, whitespace, braces, quotes, newline)
#       are rejected AND the injected command never runs (sentinel absent)
#   (D) names outside the code-owned namespace (PATH, HOME, IFS) are rejected
#   (E) the same hostile names routed through bp_timeout's override path do NOT execute
#       and bp_timeout falls through to a valid, bounded default (no gate weakened)
#
# A skip is not a pass: every assertion checks a specific value / exit code, and the
# sentinel-absence check runs after EVERY injection attempt.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB_COMMON="$ROOT/scripts/lib/sentinel-shield-common.sh"
LIB_BP="$ROOT/scripts/lib/bounded-process.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# shellcheck source=/dev/null
. "$LIB_COMMON"
# shellcheck source=/dev/null
. "$LIB_BP"

# The sentinel: an injected command would create this file. It must NEVER exist.
SENTINEL="$WORK/PWNED"

# assert_no_exec <label> — fail if the sentinel was created by an injected command,
# then clean up so a later leak is still detected independently.
assert_no_exec() {
	if [ -e "$SENTINEL" ]; then
		fail "$1: INJECTED COMMAND EXECUTED (sentinel '$SENTINEL' was created)"
		rm -f "$SENTINEL" 2>/dev/null || true
	else
		pass "$1: no injected command ran (sentinel absent)"
	fi
}

# --- (A) positive: a valid namespaced name still reads correctly --------------
SENTINEL_SHIELD_INJ_TESTVAL='42'
export SENTINEL_SHIELD_INJ_TESTVAL
rc=0; got=$(bp_env_get SENTINEL_SHIELD_INJ_TESTVAL) || rc=$?
if [ "$rc" -eq 0 ] && [ "$got" = 42 ]; then
	pass "(A) valid SENTINEL_SHIELD_* name reads its value (got '$got')"
else
	fail "(A) valid name lookup broke: rc=$rc got='$got' (expected 42)"
fi

# unset variable in-namespace -> empty string, success (matches ${NAME:-} semantics)
unset SENTINEL_SHIELD_INJ_UNSET 2>/dev/null || true
rc=0; got=$(bp_env_get SENTINEL_SHIELD_INJ_UNSET) || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$got" ]; then
	pass "(A) unset in-namespace name -> empty, success"
else
	fail "(A) unset name lookup wrong: rc=$rc got='$got'"
fi

# --- (B) hostile VALUE is returned literally, never executed ------------------
# The variable NAME is safe; its VALUE embeds command substitution + backticks. The
# result of a parameter expansion must not be re-scanned -> printed literally, not run.
# shellcheck disable=SC2016  # the $(...) / backticks are INTENTIONALLY literal here.
SENTINEL_SHIELD_INJ_VALUE='$(touch '"$SENTINEL"')`touch '"$SENTINEL"'`'
export SENTINEL_SHIELD_INJ_VALUE
rc=0; got=$(bp_env_get SENTINEL_SHIELD_INJ_VALUE) || rc=$?
if [ "$rc" -eq 0 ] && [ "$got" = "$SENTINEL_SHIELD_INJ_VALUE" ]; then
	pass "(B) hostile value returned verbatim (not evaluated)"
else
	fail "(B) hostile value mangled: rc=$rc got='$got'"
fi
assert_no_exec "(B) value with \$(...) and backticks"
unset SENTINEL_SHIELD_INJ_VALUE

# --- (C) hostile NAMES: reject + never execute --------------------------------
# Each entry is a variable NAME carrying shell syntax that, under a naive eval, would
# run `touch $SENTINEL`. bp_env_get must reject (non-zero, empty) and run nothing.
NL='
'
INJ_NAMES="
x}\$(touch $SENTINEL)
x}\`touch $SENTINEL\`
x;touch $SENTINEL
x|touch $SENTINEL
x&touch $SENTINEL
x touch $SENTINEL
SENTINEL_SHIELD_\$(touch $SENTINEL)
SENTINEL_SHIELD_X}\";touch $SENTINEL;:\"
PATH:-\$(touch $SENTINEL)
\$(touch $SENTINEL)
"
# Iterate line by line so names may contain spaces (word-splitting on \n only).
OLDIFS=$IFS
IFS="$NL"
for name in $INJ_NAMES; do
	[ -n "$name" ] || continue
	IFS=$OLDIFS
	rc=0; out=$(bp_env_get "$name") || rc=$?
	if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
		pass "(C) hostile name rejected (non-zero, empty): [$name]"
	else
		fail "(C) hostile name NOT rejected: [$name] rc=$rc out='$out'"
	fi
	assert_no_exec "(C) name [$name]"
	IFS="$NL"
done
IFS=$OLDIFS

# bp_env_name_ok is the underlying gate: it must reject each hostile name outright.
IFS="$NL"
for name in $INJ_NAMES; do
	[ -n "$name" ] || continue
	IFS=$OLDIFS
	if bp_env_name_ok "$name"; then
		fail "(C) bp_env_name_ok ACCEPTED hostile name: [$name]"
	else
		pass "(C) bp_env_name_ok rejects hostile name: [$name]"
	fi
	IFS="$NL"
done
IFS=$OLDIFS

# A NAME containing an embedded newline (whitespace) must also be rejected, both at the
# validator and through bp_env_get, with nothing executed.
NLNAME="SENTINEL_SHIELD_X${NL}touch $SENTINEL"
if bp_env_name_ok "$NLNAME"; then
	fail "(C) bp_env_name_ok ACCEPTED a name with an embedded newline"
else
	pass "(C) bp_env_name_ok rejects a name with an embedded newline"
fi
rc=0; out=$(bp_env_get "$NLNAME") || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
	pass "(C) bp_env_get rejects a name with an embedded newline"
else
	fail "(C) bp_env_get did NOT reject an embedded-newline name: rc=$rc out='$out'"
fi
assert_no_exec "(C) embedded-newline name"

# --- (D) names outside the code-owned namespace are rejected ------------------
for name in PATH HOME IFS SHELL LD_PRELOAD X ABC_DEF lowercase _LEADING 1DIGIT; do
	if bp_env_name_ok "$name"; then
		fail "(D) out-of-namespace / malformed name ACCEPTED: [$name]"
	else
		pass "(D) name rejected (not in SENTINEL_SHIELD_ namespace or malformed): [$name]"
	fi
done
# ...and a correctly-namespaced identifier is accepted (proves it is not vacuously strict).
if bp_env_name_ok SENTINEL_SHIELD_OK_1; then
	pass "(D) well-formed SENTINEL_SHIELD_* name accepted"
else
	fail "(D) well-formed SENTINEL_SHIELD_* name wrongly rejected"
fi

# --- (E) bp_timeout override path: hostile override name never executes -------
# bp_timeout's SECOND argument is a caller-supplied override ENV NAME. A hostile name
# must not be evaluated: bp_timeout validates the name first and FAILS CLOSED with
# BP_RC_INVALID (2), printing nothing, rather than eval it or silently use a default.
# No injected command may run under any of these names. (BP_RC_INVALID is defined by
# the library as 2.)
unset SENTINEL_SHIELD_DOCKER_PROBE_TIMEOUT_SECONDS SENTINEL_SHIELD_PROCESS_TIMEOUT_SECONDS 2>/dev/null || true
IFS="$NL"
for name in $INJ_NAMES; do
	[ -n "$name" ] || continue
	IFS=$OLDIFS
	rc=0; to=$(bp_timeout docker-probe "$name") || rc=$?
	assert_no_exec "(E) bp_timeout override [$name]"
	if [ "$rc" -eq "$BP_RC_INVALID" ] && [ -z "$to" ]; then
		pass "(E) hostile override name rejected fail-closed (rc=$BP_RC_INVALID, no output, no injection): [$name]"
	else
		fail "(E) bp_timeout override path wrong for [$name]: rc=$rc to='$to' (expected rc=$BP_RC_INVALID, empty)"
	fi
	IFS="$NL"
done
IFS=$OLDIFS

# Positive control: a VALID override env name is still honored end-to-end.
SENTINEL_SHIELD_INJ_OVERRIDE=25
export SENTINEL_SHIELD_INJ_OVERRIDE
rc=0; to=$(bp_timeout docker-probe SENTINEL_SHIELD_INJ_OVERRIDE) || rc=$?
if [ "$rc" -eq 0 ] && [ "$to" = 25 ]; then
	pass "(E) valid override env name still applied by bp_timeout (25)"
else
	fail "(E) valid override name not applied: rc=$rc to='$to'"
fi
unset SENTINEL_SHIELD_INJ_OVERRIDE

# Final guard: the sentinel must not exist under any name.
if [ -e "$SENTINEL" ]; then
	fail "final: sentinel exists — an injection executed at some point"
else
	pass "final: sentinel never created across all injection attempts"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
exit 0
