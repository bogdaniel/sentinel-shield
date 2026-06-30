#!/bin/sh
# tests/prod/80-command-contract.sh — WS8 documentation command-contract test.
#
# Guards the docs↔CLI contract: every Sentinel Shield script that the prompts and
# key onboarding docs tell a consumer to run MUST actually exist in the repo, and a
# safe subset of the long-flags those docs spell out MUST be understood by the
# referenced script's own arg-parser. This catches doc drift (renamed/removed
# scripts, renamed flags) before it reaches a consumer copy-pasting a command.
#
# What it asserts:
#   1. A mandated baseline of scripts/<name>.sh files exist (the v2 command surface).
#   2. Every scripts/<name>.sh invocation extracted from the doc set exists on disk
#      (prose-tolerant: only the `scripts/<name>.sh` token is matched; any
#      $SENTINEL_SHIELD_PATH/ or ${SENTINEL_SHIELD_PATH}/ prefix is stripped).
#   3. A safe subset of documented long-flags appears in the referenced script.
#
# FAILS (exit 1) if a documented script is missing or a documented flag is
# unsupported. Self-contained, network-free. Run via: sh tests/prod/80-command-contract.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

FAILED=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

# Doc sources that document Sentinel Shield commands. Missing ones are skipped
# (a missing doc is another workstream's concern, not this contract's).
DOC_SET="
prompts/install-sentinel-shield.md
prompts/update-sentinel-shield.md
docs/upgrading.md
docs/tool-provisioning.md
docs/v2-migration-guide.md
docs/ai-assisted-install.md
docs/ai-assisted-update.md
README.md
"

SOURCES=""
for rel in $DOC_SET; do
	if [ -f "$ROOT/$rel" ]; then
		SOURCES="$SOURCES $ROOT/$rel"
	else
		bad "doc source present: $rel"
	fi
done
[ -n "$SOURCES" ] || { bad "at least one doc source present"; exit 1; }

# --- assertion 1: mandated v2 command surface exists -----------------------
# These scripts form the documented v2 contract; each MUST exist regardless of
# whether the regex below happens to capture it.
REQUIRED="
install-baseline sync-baseline plan-upgrade resolve-tool-plan resolve-workflow-plan
bootstrap-profile-tools doctor maturity-report run-tool-plan build-security-summary
resolve-gates enforce-gates run-local-pipeline run-local-scanner-sweep
acquire-sentinel-shield check-release-readiness validate-release-evidence
"
for name in $REQUIRED; do
	if [ -f "$ROOT/scripts/$name.sh" ]; then
		ok "required script exists: scripts/$name.sh"
	else
		bad "required script exists: scripts/$name.sh"
	fi
done

# --- assertion 2: every documented script reference resolves to a file -----
# grep -oE emits only the matched `scripts/<name>.sh` token, so any
# $SENTINEL_SHIELD_PATH/ prefix and trailing prose/punctuation are discarded.
DOCREFS=$(mktemp)
trap 'rm -f "$DOCREFS"' EXIT
# shellcheck disable=SC2086  # SOURCES is an intentional whitespace-split file list.
grep -hoE 'scripts/[A-Za-z0-9._-]+\.sh' $SOURCES 2>/dev/null |
	sed 's#^scripts/##' | sort -u >"$DOCREFS"

if [ -s "$DOCREFS" ]; then
	ok "extracted documented script references from doc set"
else
	bad "extracted documented script references from doc set"
fi

while IFS= read -r name; do
	[ -n "$name" ] || continue
	if [ -f "$ROOT/scripts/$name" ]; then
		ok "documented script resolves: scripts/$name"
	else
		bad "documented script MISSING: scripts/$name (referenced in docs)"
	fi
done <"$DOCREFS"

# --- assertion 3: safe subset of documented long-flags is supported --------
# Each line: "<script-basename> <flag>". Every pair below is documented in the
# doc set; assert the script's own source mentions the flag token (arg-parser
# or usage text). Conservative subset — stable, unambiguous flags only.
FLAG_PAIRS="
install-baseline.sh --target
install-baseline.sh --profile
install-baseline.sh --apply
install-baseline.sh --tool-mode
sync-baseline.sh --target
sync-baseline.sh --profile
sync-baseline.sh --apply
sync-baseline.sh --force
sync-baseline.sh --emit-plan
doctor.sh --target
doctor.sh --profile
resolve-tool-plan.sh --profile
resolve-tool-plan.sh --target
resolve-tool-plan.sh --format
resolve-workflow-plan.sh --profile
resolve-workflow-plan.sh --target
resolve-workflow-plan.sh --format
resolve-gates.sh --mode
resolve-gates.sh --format
enforce-gates.sh --format
bootstrap-profile-tools.sh --profile
bootstrap-profile-tools.sh --target
build-security-summary.sh --project-name
build-security-summary.sh --project-type
check-release-readiness.sh --version
check-release-readiness.sh --stage
maturity-report.sh --target
run-tool-plan.sh --target
run-local-scanner-sweep.sh --target
plan-upgrade.sh --target
"
# Stage the pairs in a file and read via redirect so the loop runs in THIS shell
# (a pipe would fork a subshell and lose FAILED).
PAIRS=$(mktemp)
printf '%s\n' "$FLAG_PAIRS" >"$PAIRS"
while IFS=' ' read -r script flag; do
	[ -n "$script" ] || continue
	path="$ROOT/scripts/$script"
	if [ ! -f "$path" ]; then
		bad "flag-check skipped, script missing: scripts/$script"
		continue
	fi
	if grep -qF -- "$flag" "$path"; then
		ok "documented flag supported: $script $flag"
	else
		bad "documented flag UNSUPPORTED: $script $flag (not found in script)"
	fi
done <"$PAIRS"
rm -f "$PAIRS"

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
