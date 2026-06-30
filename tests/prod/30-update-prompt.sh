#!/bin/sh
# tests/prod/30-update-prompt.sh
# Validates the AI-assisted UPDATE prompt (prompts/update-sentinel-shield.md) is safe:
#   (a) no hardcoded future-GA default ref (no 'v2.0.0' as a default value);
#   (b) no bare consumer-root engine-script refs — every engine script runs from
#       ${SENTINEL_SHIELD_PATH};
#   (c) acquisition (acquire-sentinel-shield.sh) precedes the planner / sync / bootstrap /
#       doctor / pipeline steps;
#   (d) no invalid 'run-local-security.sh --target' usage remains.
# Standalone POSIX sh: prints PASS/FAIL per assertion; exit 1 if any FAIL else 0.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

PROMPT="$ROOT/prompts/update-sentinel-shield.md"
FAILS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

# Engine scripts that MUST be invoked from the acquired checkout (${SENTINEL_SHIELD_PATH}).
# acquire-sentinel-shield.sh is deliberately EXCLUDED — it is the bootstrap that creates the path.
ENGINE='plan-upgrade|sync-baseline|bootstrap-profile-tools|doctor|run-local-pipeline|resolve-tool-plan|enforce-gates|install-baseline|run-local-security|run-main-gate-validation|build-security-summary'

# Pre-flight: the prompt must exist.
if [ -f "$PROMPT" ]; then
	pass "update prompt exists at prompts/update-sentinel-shield.md"
else
	fail "update prompt exists at prompts/update-sentinel-shield.md"
	echo "FAIL: cannot continue without the prompt file"
	exit 1
fi

# (a) No hardcoded future-GA default ref. 'v2.0.0' (or any vN.N.N) must not appear as a
#     literal default ref value anywhere in the reusable doc.
if grep -Eq 'v2\.0\.0' "$PROMPT"; then
	fail "(a) no hardcoded future-GA 'v2.0.0' literal in the prompt"
else
	pass "(a) no hardcoded future-GA 'v2.0.0' literal in the prompt"
fi

# (a) No 'SENTINEL_SHIELD_REF=<version>' assignment hardcoding a concrete tag/SHA as a default.
#     The placeholder export must use a <...> placeholder, not a baked-in version.
if grep -Eq 'SENTINEL_SHIELD_REF=["'\'']?v?[0-9]' "$PROMPT"; then
	fail "(a) SENTINEL_SHIELD_REF is not assigned a hardcoded concrete version default"
else
	pass "(a) SENTINEL_SHIELD_REF is not assigned a hardcoded concrete version default"
fi

# (a) The placeholder export must be present (immutable tag or full SHA, supplied by the user).
if grep -Eq 'export SENTINEL_SHIELD_REF="<.*(tag|SHA).*>"' "$PROMPT"; then
	pass "(a) SENTINEL_SHIELD_REF shown as an explicit user-supplied placeholder"
else
	fail "(a) SENTINEL_SHIELD_REF shown as an explicit user-supplied placeholder"
fi

# (b) SENTINEL_SHIELD_PATH is pinned to .sentinel-shield-tools.
if grep -Eq 'export SENTINEL_SHIELD_PATH="\.sentinel-shield-tools"' "$PROMPT"; then
	pass "(b) SENTINEL_SHIELD_PATH exported as .sentinel-shield-tools"
else
	fail "(b) SENTINEL_SHIELD_PATH exported as .sentinel-shield-tools"
fi

# (b) Every 'scripts/<engine>.sh' reference is prefixed with ${SENTINEL_SHIELD_PATH}/.
#     Count total engine-script refs vs those that are path-prefixed; they must match.
TOTAL=$(grep -oE "scripts/($ENGINE)\.sh" "$PROMPT" | wc -l | tr -d ' ')
VIAPATH=$(grep -oE "SENTINEL_SHIELD_PATH\}/scripts/($ENGINE)\.sh" "$PROMPT" | wc -l | tr -d ' ')
if [ "$TOTAL" -gt 0 ] && [ "$TOTAL" = "$VIAPATH" ]; then
	pass "(b) all $TOTAL engine-script refs run via \${SENTINEL_SHIELD_PATH}"
else
	fail "(b) bare consumer-root engine-script ref(s) found ($VIAPATH/$TOTAL via \${SENTINEL_SHIELD_PATH})"
	grep -nE "scripts/($ENGINE)\.sh" "$PROMPT" | grep -vE 'SENTINEL_SHIELD_PATH\}/scripts/' || true
fi

# (b) The acquisition bootstrap is NOT referenced under a consumer 'scripts/' dir.
if grep -Eq 'scripts/acquire-sentinel-shield\.sh' "$PROMPT"; then
	fail "(b) acquire-sentinel-shield.sh is the bootstrap, not a consumer scripts/ ref"
else
	pass "(b) acquire-sentinel-shield.sh referenced as bootstrap (no scripts/ prefix)"
fi

# (c) Acquisition precedes planner / sync / bootstrap / doctor / pipeline.
line_of() { grep -nE "$1" "$PROMPT" | head -n1 | cut -d: -f1; }
ACQ=$(line_of 'acquire-sentinel-shield\.sh.*--verify')
if [ -n "$ACQ" ]; then
	pass "(c) acquisition step with --verify is present"
else
	fail "(c) acquisition step with --verify is present"
	ACQ=999999
fi
for step in plan-upgrade sync-baseline bootstrap-profile-tools doctor run-local-pipeline; do
	SL=$(line_of "scripts/$step\.sh")
	if [ -n "$SL" ] && [ "$ACQ" -lt "$SL" ]; then
		pass "(c) acquisition (line $ACQ) precedes $step.sh (line $SL)"
	else
		fail "(c) acquisition (line $ACQ) precedes $step.sh (line ${SL:-absent})"
	fi
done

# (d) No invalid 'run-local-security.sh --target' usage remains.
if grep -Eq 'run-local-security\.sh[[:space:]]+--target' "$PROMPT"; then
	fail "(d) invalid 'run-local-security.sh --target' usage removed"
	grep -nE 'run-local-security\.sh[[:space:]]+--target' "$PROMPT" || true
else
	pass "(d) invalid 'run-local-security.sh --target' usage removed"
fi

# (d) The authoritative local check uses run-local-pipeline.sh instead.
if grep -Eq 'SENTINEL_SHIELD_PATH\}/scripts/run-local-pipeline\.sh' "$PROMPT"; then
	pass "(d) authoritative local check uses run-local-pipeline.sh"
else
	fail "(d) authoritative local check uses run-local-pipeline.sh"
fi

if [ "$FAILS" -gt 0 ]; then
	echo "RESULT: $FAILS assertion(s) failed"
	exit 1
fi
echo "RESULT: all assertions passed"
exit 0
