#!/bin/sh
# Sentinel Shield — release-promotion readiness gate (v2.0.0).
#
# Decides whether the repository may be promoted to a given release STAGE
# (alpha -> beta -> rc -> ga). Gates COMPOSE: each stage requires every gate of
# the stage(s) below it plus its own. STRUCTURAL gates (self-tests, workflow /
# schema validity, no tracked secrets/runtime artifacts, local fixtures) are
# checked HERE; the REAL consumer-CI / bootstrap / soak EVIDENCE gates are
# delegated to scripts/validate-release-evidence.sh (which owns evidence shape).
#
# This is a READ-ONLY auditor: it never installs, never mutates, never hits the
# network, never fabricates evidence. Missing evidence => FAIL CLOSED (nonzero).
# Promotion may only be FORCED with an explicit, documented --override-reason,
# which is printed LOUDLY and still records the unmet gates.
#
# Usage:
#   sh scripts/check-release-readiness.sh --version <vX> --stage <alpha|beta|rc|ga>
#                                         [--evidence <dir>] [--override-reason "<text>"]
#   --version <vX>          Release version label being promoted (free text; recorded).
#   --stage <s>             alpha | beta | rc | ga (gates compose upward).
#   --evidence <file>       Evidence file passed to the evidence validator
#                           (default: <repo>/evidence/releases/<version>.json).
#   --override-reason "..." Documented justification to BYPASS unmet gates. Printed
#                           loudly; the script then exits 0 despite failures.
#
# Exit:
#   0 = READY (all required gates met) — or unmet gates were force-overridden.
#   1 = NOT READY (one or more required gates unmet; fail closed).
#   2 = invalid invocation / missing required tool (jq, yq).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# usage — print CLI usage to stdout.
usage() {
	printf 'Usage: check-release-readiness.sh --version <vX> --stage <alpha|beta|rc|ga> [--evidence <file>] [--override-reason "<text>"]\n'
}

VERSION=""
STAGE=""
OVERRIDE_REASON=""
EVIDENCE_FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--version) VERSION="${2:?--version requires a value}"; shift 2 ;;
		--stage) STAGE="${2:?--stage requires a value}"; shift 2 ;;
		--evidence) EVIDENCE_FILE="${2:?--evidence requires a value}"; shift 2 ;;
		--override-reason) OVERRIDE_REASON="${2:?--override-reason requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "check-release-readiness: unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

[ -n "$VERSION" ] || { log_error "--version is required"; usage >&2; exit 2; }
[ -n "$STAGE" ] || { log_error "--stage is required"; usage >&2; exit 2; }
case "$STAGE" in
	alpha | beta | rc | ga) ;;
	*) log_error "--stage must be one of: alpha|beta|rc|ga"; usage >&2; exit 2 ;;
esac
command_exists jq || { log_error "jq is required but was not found. Install jq."; exit 2; }
command_exists yq || { log_error "yq is required (workflow structural parse) but was not found. Install yq."; exit 2; }

# Default evidence file is keyed by the version label (matches the validator's
# evidence/releases/<version>.json convention) unless overridden via --evidence.
[ -n "$EVIDENCE_FILE" ] || EVIDENCE_FILE="$REPO_ROOT/evidence/releases/$VERSION.json"

FAILURES=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$*"; }

printf 'Sentinel Shield — release-readiness check\n'
printf 'Version:  %s\n' "$VERSION"
printf 'Stage:    %s (gates compose: alpha < beta < rc < ga)\n' "$STAGE"
printf 'Evidence: %s\n' "$EVIDENCE_FILE"
printf '\n'

# --- alpha gate (always evaluated; the floor for every stage) ----------------
printf '[alpha] structural readiness\n'

# 1) self-tests pass (delegate to the canonical syntax self-test).
if sh "$REPO_ROOT/scripts/self-test.sh" syntax >/dev/null 2>&1; then
	pass "self-test 'syntax' passes"
else
	fail "self-test 'syntax' failed (run: sh scripts/self-test.sh syntax)"
fi

# 2) workflow templates are structurally valid YAML (yq parse).
_wf_seen=0
_wf_bad=0
for _f in "$REPO_ROOT"/templates/workflows/*.yml; do
	[ -e "$_f" ] || continue
	_wf_seen=1
	yq -e '.' "$_f" >/dev/null 2>&1 || { fail "workflow not parseable: templates/workflows/${_f##*/}"; _wf_bad=1; }
done
if [ "$_wf_seen" = 0 ]; then
	fail "no workflow templates found under templates/workflows/*.yml"
elif [ "$_wf_bad" = 0 ]; then
	pass "workflow templates parse (yq)"
fi

# 3) schemas are valid JSON (jq parse).
_sc_seen=0
_sc_bad=0
for _f in "$REPO_ROOT"/schemas/*.json; do
	[ -e "$_f" ] || continue
	_sc_seen=1
	jq -e . "$_f" >/dev/null 2>&1 || { fail "schema invalid JSON: schemas/${_f##*/}"; _sc_bad=1; }
done
if [ "$_sc_seen" = 0 ]; then
	fail "no schemas found under schemas/*.json"
elif [ "$_sc_bad" = 0 ]; then
	pass "schemas valid JSON (jq)"
fi

# 4) no tracked secrets / runtime scanner artifacts (git ls-files greps).
_tracked=$( (cd "$REPO_ROOT" && git ls-files 2>/dev/null) || true)
_leak=0
for _pat in '^\.claude/' '^reports/raw/' '(^|/)security-summary\.json$' 'dependency-check-consumer\.json' '(^|/)\.env$' '\.pem$'; do
	if printf '%s\n' "$_tracked" | grep -Eq "$_pat"; then
		fail "tracked secret/runtime artifact matches: $_pat"
		_leak=1
	fi
done
[ "$_leak" = 0 ] && pass "no tracked secrets/runtime artifacts"

# 5) local fixtures present (the self-test corpus must be committed).
if [ -d "$REPO_ROOT/tests/fixtures" ] && [ -d "$REPO_ROOT/tests/fixtures/wf-good" ]; then
	pass "local fixtures present (tests/fixtures/)"
else
	fail "local fixtures missing (tests/fixtures/ incl. wf-good)"
fi

# --- evidence gate (beta/rc/ga): delegate to the evidence validator ----------
# The validator owns evidence SHAPE and the cumulative beta->rc->ga ladder
# (real Laravel/Symfony/library/Node CI runs, bootstrap-apply, update/migration,
# rollback, soak, open-finding posture, prompt + docs-contract + workflow-security
# checks). We FAIL CLOSED if it is absent or reports the stage unmet.
if [ "$STAGE" != alpha ]; then
	printf '\n[%s] real consumer/evidence validation (delegated to validate-release-evidence.sh)\n' "$STAGE"
	_validator="$REPO_ROOT/scripts/validate-release-evidence.sh"
	if [ ! -f "$_validator" ]; then
		fail "evidence validator not found: scripts/validate-release-evidence.sh — cannot prove '$STAGE' evidence (fail closed)"
	elif sh "$_validator" --file "$EVIDENCE_FILE" --require-stage "$STAGE"; then
		pass "release evidence satisfies --require-stage $STAGE"
	else
		fail "release evidence does NOT satisfy --require-stage $STAGE (see output above / scripts/validate-release-evidence.sh)"
	fi
fi

# --- verdict -----------------------------------------------------------------
printf '\n----\n'
if [ "$FAILURES" -eq 0 ]; then
	printf 'release-readiness: %s stage=%s — READY (all required gates met)\n' "$VERSION" "$STAGE"
	exit 0
fi

if [ -n "$OVERRIDE_REASON" ]; then
	log_warn "RELEASE-READINESS OVERRIDE: $FAILURES unmet gate(s) BYPASSED for $VERSION stage=$STAGE"
	printf '\n'
	printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
	printf '!! RELEASE-READINESS OVERRIDE IN EFFECT\n'
	printf '!! %d gate(s) were UNMET and FORCE-BYPASSED.\n' "$FAILURES"
	printf '!! version=%s stage=%s\n' "$VERSION" "$STAGE"
	printf '!! reason: %s\n' "$OVERRIDE_REASON"
	printf '!! This release was NOT verified clean. Promotion proceeds AT YOUR OWN RISK.\n'
	printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
	exit 0
fi

printf 'release-readiness: %s stage=%s — NOT READY (%d unmet gate(s)); fail closed\n' "$VERSION" "$STAGE" "$FAILURES"
printf 'To force promotion anyway, re-run with --override-reason "<documented justification>".\n'
exit 1
