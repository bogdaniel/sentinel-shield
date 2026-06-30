#!/bin/sh
# tests/prod/20-install-prompt.sh
# Validates prompts/install-sentinel-shield.md is copy-paste-safe from a consumer repo with NO
# Sentinel Shield source tree present.
#
# Asserts:
#   1. NO unsafe bare consumer-root Sentinel script reference: every `scripts/<name>.sh` invocation
#      for a Sentinel script MUST be prefixed with the acquired-checkout variable
#      (`$SENTINEL_SHIELD_PATH/scripts/...`). The acquire bootstrap (acquire-sentinel-shield.sh) is
#      the single documented exception — it CREATES the checkout, so it cannot run from inside it.
#   2. An acquisition step referencing acquire-sentinel-shield.sh appears BEFORE the first
#      install/doctor/pipeline command.
#
# Exit: 0 if all PASS, 1 if any FAIL.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

PROMPT="$ROOT/prompts/install-sentinel-shield.md"
FAILS=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

# --- precondition ---------------------------------------------------------
if [ -f "$PROMPT" ]; then
	pass "install prompt exists"
else
	fail "install prompt exists ($PROMPT missing)"
	exit 1
fi

# --- assertion 1: no unsafe bare Sentinel script references ----------------
# Collect every `scripts/<name>.sh` occurrence together with up to 40 preceding chars so we can tell
# whether it was reached via the acquired-checkout variable.
UNSAFE=$(mktemp)
trap 'rm -f "$UNSAFE"' EXIT

# grep -oE yields one substring per occurrence (non-overlapping, left to right).
grep -oE '.{0,40}scripts/[A-Za-z0-9._-]+\.sh' "$PROMPT" 2>/dev/null | while IFS= read -r chunk; do
	# script name = text after the last "scripts/"
	name=${chunk##*scripts/}
	# acquire bootstrap is the documented exception.
	case "$name" in
	acquire-sentinel-shield.sh) continue ;;
	esac
	# safe iff reached through the acquired-checkout variable.
	case "$chunk" in
	*SENTINEL_SHIELD_PATH/scripts/*) continue ;;
	esac
	printf '%s\n' "scripts/$name" >>"$UNSAFE"
done

if [ -s "$UNSAFE" ]; then
	fail "no unsafe bare consumer-root Sentinel script references"
	while IFS= read -r bad; do printf '       unsafe: %s\n' "$bad"; done <"$UNSAFE"
else
	pass "no unsafe bare consumer-root Sentinel script references"
fi

# Positive control: the acquired-checkout variable form is actually used at least once.
if grep -q 'SENTINEL_SHIELD_PATH/scripts/' "$PROMPT"; then
	pass "Sentinel commands invoked via acquired-checkout variable"
else
	fail "Sentinel commands invoked via acquired-checkout variable"
fi

# --- assertion 2: acquisition precedes first install/doctor/pipeline command
acq_line=$(grep -n 'acquire-sentinel-shield\.sh' "$PROMPT" | head -n1 | cut -d: -f1 || true)

# first line that runs an install / doctor / pipeline command from the checkout.
cmd_line=$(grep -nE 'scripts/(install-baseline|doctor|run-local-pipeline)\.sh' "$PROMPT" |
	head -n1 | cut -d: -f1 || true)

if [ -n "$acq_line" ]; then
	pass "acquisition step references acquire-sentinel-shield.sh"
else
	fail "acquisition step references acquire-sentinel-shield.sh"
fi

if [ -n "$cmd_line" ]; then
	pass "an install/doctor/pipeline command is present"
else
	fail "an install/doctor/pipeline command is present"
fi

if [ -n "$acq_line" ] && [ -n "$cmd_line" ] && [ "$acq_line" -lt "$cmd_line" ]; then
	pass "acquisition appears before first install/doctor/pipeline command"
else
	fail "acquisition appears before first install/doctor/pipeline command (acquire=$acq_line cmd=$cmd_line)"
fi

# --- summary --------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
	exit 0
fi
exit 1
