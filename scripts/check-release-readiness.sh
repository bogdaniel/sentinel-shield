#!/bin/sh
# Sentinel Shield — release-promotion readiness gate (v2.0.0).
#
# Decides whether the repository may be promoted to a given release STAGE
# (alpha -> beta -> rc -> ga). Gates COMPOSE: each stage requires every gate of
# the stage(s) below it plus its own. STRUCTURAL gates (self-tests, workflow /
# schema validity, no tracked secrets/runtime artifacts, local fixtures, action
# pinning, static validators) are checked HERE; the REAL consumer-CI / bootstrap
# / soak EVIDENCE gates are delegated to scripts/validate-release-evidence.sh
# (which owns evidence shape).
#
# BLOCKER 3 — the alpha STRUCTURAL gate must EXECUTE the self-tests, not merely
# assert fixtures exist. It runs and reports, as SEPARATE gates, the self-test
# groups 'syntax', 'production-readiness' and 'e2e', and finally 'all' as the
# authoritative check. The self-test invocation is overridable via $SELF_TEST so
# tests can stub it. Fixture-existence ALONE can never pass — the tests run.
#
# FINDING 5 — override governance. Free-text --override-reason is NOT a blanket
# bypass:
#   * alpha     : a free-text --override-reason MAY remain, printed LOUDLY.
#   * beta      : requires a version-controlled --override-file governance RECORD
#                 (schemas/release-override.schema.json): schema-valid, matching
#                 this --version AND --stage, unexpired, requested_by!=approved_by.
#   * rc / ga   : override is PROHIBITED by default; permitted ONLY via the same
#                 strict, signed/approved record (rc/ga overrides are exceptional).
# An override can NEVER waive: tracked secrets / hygiene (checked here, marked
# NON-WAIVABLE), malformed evidence (validator exit 2 => non-overridable), failed
# rollback integrity or destructive path-safety (those surface as validator exit
# 2 — a genuine integrity/safety violation — not as a mere "not proven yet").
#
# This is a READ-ONLY auditor: it never installs, never mutates, never hits the
# network, never fabricates evidence. Missing evidence => FAIL CLOSED (nonzero).
#
# Usage:
#   sh scripts/check-release-readiness.sh --version <vX> --stage <alpha|beta|rc|ga>
#       [--evidence <file>] [--override-reason "<text>"] [--override-file <record>]
#   --version <vX>          Release version label being promoted (recorded; matched).
#   --stage <s>             alpha | beta | rc | ga (gates compose upward).
#   --evidence <file>       Evidence file passed to the evidence validator
#                           (default: <repo>/evidence/releases/<version>.json).
#   --override-reason "..." alpha-only free-text bypass; printed loudly.
#   --override-file <f>     Governance override record (CONTRACT 3); REQUIRED to
#                           override at beta/rc/ga.
#
# Env:
#   SELF_TEST   Self-test invocation (default: "sh scripts/self-test.sh"); the
#               stage name is appended. Overridable so tests can stub it.
#
# Exit:
#   0 = READY (all required gates met) — or unmet WAIVABLE gates were governed-override.
#   1 = NOT READY (required gate unmet, or override rejected/insufficient/non-waivable).
#   2 = invalid invocation / missing required tool (jq, yq) / malformed override or
#       evidence (non-overridable).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# Self-test invocation — overridable so tests can stub it with a fast fake.
SELF_TEST="${SELF_TEST:-sh $REPO_ROOT/scripts/self-test.sh}"

# usage — print CLI usage to stdout.
usage() {
	printf 'Usage: check-release-readiness.sh --version <vX> --stage <alpha|beta|rc|ga> [--scope <engine-only|framework-validated|full-platform>] [--evidence <file>] [--override-reason "<text>"] [--override-file <record>]\n'
}

VERSION=""
STAGE=""
SCOPE=""
OVERRIDE_REASON=""
OVERRIDE_FILE=""
EVIDENCE_FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--version) VERSION="${2:?--version requires a value}"; shift 2 ;;
		--stage) STAGE="${2:?--stage requires a value}"; shift 2 ;;
		--scope) SCOPE="${2:?--scope requires a value}"; shift 2 ;;
		--evidence) EVIDENCE_FILE="${2:?--evidence requires a value}"; shift 2 ;;
		--override-reason) OVERRIDE_REASON="${2:?--override-reason requires a value}"; shift 2 ;;
		--override-file) OVERRIDE_FILE="${2:?--override-file requires a value}"; shift 2 ;;
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
# --scope selects the evidence requirement matrix (validate-release-evidence.sh
# owns the matrix). Empty => let the evidence file's release_scope decide (which
# itself defaults to framework-validated). engine-only NEVER claims framework proof.
case "$SCOPE" in
	"" | engine-only | framework-validated | full-platform) ;;
	*) log_error "--scope must be one of: engine-only|framework-validated|full-platform"; usage >&2; exit 2 ;;
esac
command_exists jq || { log_error "jq is required but was not found. Install jq."; exit 2; }
command_exists yq || { log_error "yq is required (workflow structural parse) but was not found. Install yq."; exit 2; }

# Default evidence file is keyed by the version label (matches the validator's
# evidence/releases/<version>.json convention) unless overridden via --evidence.
[ -n "$EVIDENCE_FILE" ] || EVIDENCE_FILE="$REPO_ROOT/evidence/releases/$VERSION.json"

NOW=$(date -u +%s)

FAILURES=0
NONWAIVABLE=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$*"; }
# failx — a NON-WAIVABLE failure: counts toward FAILURES and can never be overridden.
failx() { FAILURES=$((FAILURES + 1)); NONWAIVABLE=$((NONWAIVABLE + 1)); printf '  FAIL  %s [NON-WAIVABLE]\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }

# run_selftest_gate <group> — execute one self-test group via $SELF_TEST and
# report it as its own pass/fail gate. Fixture-existence alone cannot satisfy
# this: the suite must actually run and exit 0.
run_selftest_gate() {
	# shellcheck disable=SC2086
	if $SELF_TEST "$1" >/dev/null 2>&1; then
		pass "self-test '$1' executed and passed"
	else
		fail "self-test '$1' failed or did not run (try: $SELF_TEST $1)"
	fi
}

printf 'Sentinel Shield — release-readiness check\n'
printf 'Version:  %s\n' "$VERSION"
printf 'Stage:    %s (gates compose: alpha < beta < rc < ga)\n' "$STAGE"
printf 'Scope:    %s\n' "${SCOPE:-<from evidence file (default framework-validated)>}"
printf 'Evidence: %s\n' "$EVIDENCE_FILE"
printf '\n'

# --- alpha gate (always evaluated; the floor for every stage) ----------------
printf '[alpha] structural readiness\n'

# 1) The self-tests must EXECUTE and pass — reported as SEPARATE gates, with
#    'all' as the authoritative check (it subsumes the others, but each is run
#    and reported so a regression is attributed precisely).
run_selftest_gate syntax
run_selftest_gate production-readiness
run_selftest_gate e2e
run_selftest_gate all

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

# 4) every SHIPPED JSON fixture (templates/ and profiles/) parses. Test corpora
#    under tests/ deliberately include malformed inputs for negative tests and
#    are NOT covered here.
_fx_seen=0
_fx_bad=0
if _tracked_json=$( (cd "$REPO_ROOT" && git ls-files 'templates/*.json' 'profiles/*.json') 2>/dev/null); then
	for _rel in $_tracked_json; do
		[ -f "$REPO_ROOT/$_rel" ] || continue
		_fx_seen=1
		jq -e . "$REPO_ROOT/$_rel" >/dev/null 2>&1 || { fail "shipped JSON invalid: $_rel"; _fx_bad=1; }
	done
	if [ "$_fx_seen" = 0 ]; then
		warn "no shipped JSON fixtures under templates/ or profiles/"
	elif [ "$_fx_bad" = 0 ]; then
		pass "shipped JSON fixtures valid (templates/, profiles/)"
	fi
else
	fail "could not enumerate shipped JSON fixtures (git ls-files failed)"
fi

# 5) no tracked secrets / runtime scanner artifacts / vendored deps (hygiene).
#    NON-WAIVABLE: a tracked secret can NEVER be overridden. Patterns are
#    root-anchored so committed fixture trees (tests/, examples/) are not flagged.
#    FAIL CLOSED if the inventory cannot be enumerated: an enumeration failure is
#    NOT proof of "no tracked secrets".
if _tracked=$( (cd "$REPO_ROOT" && git ls-files) 2>/dev/null); then
	_leak=0
	for _pat in '^\.claude/' '^reports/raw/' '^vendor/' '^node_modules/' '(^|/)security-summary\.json$' 'dependency-check-consumer\.json' '(^|/)\.env$' '\.pem$'; do
		if printf '%s\n' "$_tracked" | grep -Eq "$_pat"; then
			failx "tracked secret/runtime/vendored artifact matches: $_pat"
			_leak=1
		fi
	done
	[ "$_leak" = 0 ] && pass "no tracked secrets/runtime/vendored artifacts (hygiene)"
else
	failx "could not enumerate tracked files (git ls-files failed); cannot prove no tracked secrets (fail closed)"
fi

# 6) local fixtures present (the self-test corpus must be committed).
if [ -d "$REPO_ROOT/tests/fixtures" ] && [ -d "$REPO_ROOT/tests/fixtures/wf-good" ]; then
	pass "local fixtures present (tests/fixtures/)"
else
	fail "local fixtures missing (tests/fixtures/ incl. wf-good)"
fi

# 7) shipped workflow templates pin every third-party action to a 40-hex SHA
#    (local ./ actions are exempt). Anchor the check to the actual 'uses:' ref
#    token (strip any trailing ' # comment' and surrounding quotes) so a 40-hex
#    string in a COMMENT can never falsely satisfy the pin: the ref itself must
#    END with '@<40-hex>'.
_pin_bad=$(grep -hE '^[[:space:]]*uses:[[:space:]]' "$REPO_ROOT"/templates/workflows/*.yml 2>/dev/null \
	| sed -E 's/^[[:space:]]*uses:[[:space:]]*//; s/[[:space:]].*$//; s/^["'\'']//; s/["'\'']$//' \
	| grep -vE '^\./' \
	| grep -cvE '@[0-9a-fA-F]{40}$' || true)
[ -n "$_pin_bad" ] || _pin_bad=0
if [ "$_pin_bad" -eq 0 ]; then
	pass "workflow actions SHA-pinned (templates/workflows)"
else
	fail "$_pin_bad workflow 'uses:' ref(s) not pinned to a 40-hex SHA"
fi

# 8) static validators. POLICY: when present they are RUN; when absent,
#    actionlint and zizmor only WARN at alpha but are MANDATORY at beta+ (fail
#    closed). shellcheck is recommended (warn if absent at any stage).
printf '\n[%s] static validators\n' "$STAGE"
if command_exists shellcheck; then
	if shellcheck -x -S error "$REPO_ROOT"/scripts/*.sh >/dev/null 2>&1; then
		pass "shellcheck clean (scripts/*.sh)"
	else
		fail "shellcheck reported errors in scripts/*.sh"
	fi
else
	warn "shellcheck not installed (recommended)"
fi
if command_exists actionlint; then
	if actionlint "$REPO_ROOT"/templates/workflows/*.yml >/dev/null 2>&1; then
		pass "actionlint clean (templates/workflows)"
	else
		fail "actionlint reported problems (templates/workflows)"
	fi
elif [ "$STAGE" = alpha ]; then
	warn "actionlint not installed — WARN at alpha, MANDATORY at beta+"
else
	fail "actionlint is REQUIRED at stage '$STAGE' but is not installed (fail closed)"
fi
if command_exists zizmor; then
	if zizmor "$REPO_ROOT"/templates/workflows >/dev/null 2>&1; then
		pass "zizmor clean (templates/workflows)"
	else
		fail "zizmor reported problems (templates/workflows)"
	fi
elif [ "$STAGE" = alpha ]; then
	warn "zizmor not installed — WARN at alpha, MANDATORY at beta+"
else
	fail "zizmor is REQUIRED at stage '$STAGE' but is not installed (fail closed)"
fi

# --- evidence gate (beta/rc/ga): delegate to the evidence validator ----------
# The validator owns evidence SHAPE and the cumulative beta->rc->ga ladder. We
# FAIL CLOSED if it is absent or reports the stage unmet. A validator exit of 2
# (malformed evidence / integrity / path-safety violation) is NON-OVERRIDABLE.
if [ "$STAGE" != alpha ]; then
	printf '\n[%s] real consumer/evidence validation (delegated to validate-release-evidence.sh)\n' "$STAGE"
	_validator="$REPO_ROOT/scripts/validate-release-evidence.sh"
	if [ ! -f "$_validator" ]; then
		fail "evidence validator not found: scripts/validate-release-evidence.sh — cannot prove '$STAGE' evidence (fail closed)"
	else
		_vrc=0
		if [ -n "$SCOPE" ]; then
			sh "$_validator" --file "$EVIDENCE_FILE" --require-stage "$STAGE" --scope "$SCOPE" || _vrc=$?
		else
			sh "$_validator" --file "$EVIDENCE_FILE" --require-stage "$STAGE" || _vrc=$?
		fi
		if [ "$_vrc" -eq 0 ]; then
			pass "release evidence satisfies --require-stage $STAGE"
		elif [ "$_vrc" -eq 1 ]; then
			fail "release evidence does NOT satisfy --require-stage $STAGE (see output above)"
		else
			log_error "release evidence is MALFORMED/invalid (validator exit $_vrc); this is NON-overridable — fail closed"
			exit 2
		fi
	fi
fi

# --- override governance helpers ---------------------------------------------
# validate_override_record <file> — validate a governance override record.
#   return 0: valid (schema-valid + matches version/stage + unexpired + 2-person)
#   return 1: schema-valid but governance-rejected (mismatch/expired/self-approval)
#   return 2: missing / not JSON / schema-invalid (malformed => non-overridable)
validate_override_record() {
	_f="$1"
	if [ ! -f "$_f" ]; then log_error "override record not found: $_f"; return 2; fi
	if ! jq -e . "$_f" >/dev/null 2>&1; then log_error "override record is not valid JSON: $_f"; return 2; fi
	_serr=$(jq -r '
		def nestr: type == "string" and (length > 0);
		def isodt: (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
		def keys_ok: ["schema_version","version","stage","controls","reason","requested_by","approved_by","created_at","expires_at"];
		. as $d
		| [
			(if ($d|type) == "object" then empty else "root: not an object" end),
			(if ($d.schema_version) == "1" then empty else "schema_version: must be the string \"1\"" end),
			(if ($d.version|nestr) then empty else "version: missing or empty" end),
			(if (["alpha","beta","rc","ga"]|index($d.stage // null)) then empty else "stage: not one of alpha|beta|rc|ga" end),
			(if (($d.controls|type) == "array" and ($d.controls|length) > 0 and (all($d.controls[]; nestr))) then empty else "controls: must be a non-empty array of non-empty strings" end),
			(if ($d.reason|nestr) then empty else "reason: missing or empty" end),
			(if ($d.requested_by|nestr) then empty else "requested_by: missing or empty" end),
			(if ($d.approved_by|nestr) then empty else "approved_by: missing or empty" end),
			(if ($d.created_at|isodt) then empty else "created_at: not ISO-8601 UTC (YYYY-MM-DDTHH:MM:SSZ)" end),
			(if ($d.expires_at|isodt) then empty else "expires_at: not ISO-8601 UTC (YYYY-MM-DDTHH:MM:SSZ)" end),
			(($d|keys[]) as $k | select((keys_ok|index($k)) | not) | "unexpected key: \($k)")
		  ]
		| .[]
	' "$_f" 2>/dev/null) || { log_error "override record failed structural validation: $_f"; return 2; }
	if [ -n "$_serr" ]; then
		log_error "override record is schema-invalid: $_f"
		printf '%s\n' "$_serr" >&2
		return 2
	fi
	_gerr=$(jq -r --arg version "$VERSION" --arg stage "$STAGE" --argjson now "$NOW" '
		. as $d
		| [
			(if $d.version == $version then empty else "version mismatch: record=\($d.version) promoting=\($version)" end),
			(if $d.stage == $stage then empty else "stage mismatch: record=\($d.stage) promoting=\($stage)" end),
			(if ($d.requested_by != $d.approved_by) then empty else "self-approval FORBIDDEN: requested_by==approved_by (\($d.requested_by))" end),
			(if (($d.expires_at|fromdateiso8601) > $now) then empty else "EXPIRED: expires_at=\($d.expires_at) is not in the future" end)
		  ]
		| .[]
	' "$_f" 2>/dev/null) || { log_error "override record governance check failed to evaluate: $_f"; return 2; }
	if [ -n "$_gerr" ]; then
		log_error "override record REJECTED (governance): $_f"
		printf '%s\n' "$_gerr" >&2
		return 1
	fi
	return 0
}

# print_override_banner <desc> [exceptional] — loud, unmistakable banner.
print_override_banner() {
	log_warn "RELEASE-READINESS OVERRIDE: $FAILURES unmet gate(s) BYPASSED for $VERSION stage=$STAGE"
	printf '\n'
	printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
	printf '!! RELEASE-READINESS OVERRIDE IN EFFECT\n'
	[ -n "${2:-}" ] && printf '!! *** EXCEPTIONAL %s OVERRIDE — rc/ga promotions are NOT routinely overridden ***\n' "$STAGE"
	printf '!! %d gate(s) were UNMET and FORCE-BYPASSED.\n' "$FAILURES"
	printf '!! version=%s stage=%s\n' "$VERSION" "$STAGE"
	printf '!! %s\n' "$1"
	printf '!! This release was NOT verified clean. Promotion proceeds AT YOUR OWN RISK.\n'
	printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
}

# --- verdict -----------------------------------------------------------------
printf '\n----\n'
if [ "$FAILURES" -eq 0 ]; then
	printf 'release-readiness: %s stage=%s — READY (all required gates met)\n' "$VERSION" "$STAGE"
	exit 0
fi

_override_requested=no
if [ -n "$OVERRIDE_REASON" ] || [ -n "$OVERRIDE_FILE" ]; then _override_requested=yes; fi

# Non-waivable failures (tracked secrets / hygiene) can NEVER be overridden.
if [ "$NONWAIVABLE" -gt 0 ]; then
	log_error "RELEASE-READINESS: $NONWAIVABLE non-waivable failure(s) present (tracked secrets / hygiene)."
	[ "$_override_requested" = yes ] && log_error "An override was supplied but is REFUSED: non-waivable failures cannot be bypassed."
	printf 'release-readiness: %s stage=%s — NOT READY (%d unmet gate(s); %d non-waivable); fail closed\n' "$VERSION" "$STAGE" "$FAILURES" "$NONWAIVABLE"
	exit 1
fi

# Only WAIVABLE failures remain — apply stage-specific override governance.
case "$STAGE" in
	alpha)
		if [ "$_override_requested" = yes ]; then
			if [ -n "$OVERRIDE_FILE" ]; then
				_orc=0; validate_override_record "$OVERRIDE_FILE" || _orc=$?
				if [ "$_orc" -eq 2 ]; then exit 2; fi
				if [ "$_orc" -ne 0 ]; then
					printf 'release-readiness: %s stage=%s — NOT READY (override record rejected); fail closed\n' "$VERSION" "$STAGE"
					exit 1
				fi
				print_override_banner "record: $OVERRIDE_FILE"
			else
				print_override_banner "reason: $OVERRIDE_REASON"
			fi
			exit 0
		fi
		;;
	beta | rc | ga)
		if [ -n "$OVERRIDE_FILE" ]; then
			_orc=0; validate_override_record "$OVERRIDE_FILE" || _orc=$?
			if [ "$_orc" -eq 2 ]; then exit 2; fi
			if [ "$_orc" -eq 0 ]; then
				case "$STAGE" in
					rc | ga) print_override_banner "record: $OVERRIDE_FILE" exceptional ;;
					*) print_override_banner "record: $OVERRIDE_FILE" ;;
				esac
				exit 0
			fi
			# _orc == 1: governance-rejected — fall through to NOT READY.
		elif [ -n "$OVERRIDE_REASON" ]; then
			log_error "stage '$STAGE' does NOT accept a free-text --override-reason; a version-controlled --override-file governance record is REQUIRED."
		fi
		;;
esac

printf 'release-readiness: %s stage=%s — NOT READY (%d unmet gate(s)); fail closed\n' "$VERSION" "$STAGE" "$FAILURES"
case "$STAGE" in
	alpha) printf 'To force promotion anyway, re-run with --override-reason "<documented justification>".\n' ;;
	*) printf 'To override, supply a valid governance record: --override-file <release-override.json> (CONTRACT 3).\n' ;;
esac
exit 1
