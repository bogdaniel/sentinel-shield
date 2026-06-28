#!/bin/sh
# Sentinel Shield — LOCAL end-to-end harness (NOT real CI).
#
# Proves the full policy->gate path against minimal fixture projects under tests/e2e/:
#
#   run-tool-plan.sh --stage pr            (resolve canonical profile + run/verify tools)
#     -> build-security-summary.sh --profile <p> --target <fixture>   (overlay tool policy)
#       -> resolve-gates.sh + enforce-gates.sh                        (mechanical gate)
#
# For every fixture it runs the chain TWICE and asserts the gate outcome matches the
# profile's policy contract:
#   * PASS variant — every required tool's report present + clean   => gate PASS (exit 0)
#   * FAIL variant — one required tool's report removed (honest-absent / unavailable)
#                    => gate FAIL (exit 1), because an unavailable REQUIRED tool is
#                       NEVER rewritten as a clean 0.
#
# Each fixture prints a one-line evidence record:
#   {profile, stage, required_executed, unavailable, gate_result}
# The harness exits non-zero if ANY fixture's path is broken (a PASS variant that does
# not pass, or a FAIL variant that does not fail), so a regression in the policy->gate
# wiring fails loudly.
#
# This is a LOCAL HARNESS (no live GitHub Actions runner this session). It exercises
# the SAME scripts CI runs; it does not exercise the GitHub workflow YAML itself.
#
# Usage: e2e-harness.sh [--keep]
#   --keep   Do not delete the per-fixture temp workdirs (for debugging).
#
# Exit codes (shared v2 contract — docs/workflow-execution-model.md#exit-codes):
#   0  every fixture's policy->gate path behaved as its policy requires
#   1  one or more fixtures' paths are broken (PASS did not pass / FAIL did not fail)
#   2  invalid invocation / configuration (bad args, missing jq, missing fixtures)
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

KEEP=0
while [ $# -gt 0 ]; do
	case "$1" in
		--keep) KEEP=1; shift ;;
		-h | --help) printf 'Usage: e2e-harness.sh [--keep]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done

command_exists jq || { log_error "e2e-harness: jq is required"; exit 2; }
E2E_DIR="$ROOT/tests/e2e"
[ -d "$E2E_DIR" ] || { log_error "e2e-harness: fixtures dir not found: $E2E_DIR"; exit 2; }
PROFILE_YAML="$ROOT/templates/profile.yaml"
[ -f "$PROFILE_YAML" ] || { log_error "e2e-harness: missing $PROFILE_YAML"; exit 2; }

FAILS=0

# eh_seed_required <profile> <target> — seed a clean ('{}') raw report for every
# required+applicable tool and the selected one-of group, idempotently (it never
# overwrites an existing report). Keeps fixtures robust to profile drift: the
# AUTHORITATIVE required set comes from the canonical resolver, not a frozen list.
eh_seed_required() {
	_p="$1"; _t="$2"
	_eff=$(sh "$SCRIPT_DIR/resolve-effective-profile.sh" --profile "$_p" --target "$_t" --format json 2>/dev/null) || {
		log_error "e2e-harness: could not resolve profile '$_p'"; return 1; }
	ensure_dir "$_t/reports/raw"
	for _rep in $(printf '%s' "$_eff" | jq -r '
		( [ .tools|to_entries[]
		    | select(.value.policy=="required" and (.value.applicability//"unknown")!="not-applicable")
		    | (.value.report // empty) ]
		+ [ (.one_of_groups|to_entries[]) as $g
		    | select($g.value.selected != null)
		    | (.tools[$g.key].report // "reports/raw/tests.json") ] )
		| unique[] | sub(".*/";"")'); do
		[ -f "$_t/reports/raw/$_rep" ] || printf '{}\n' > "$_t/reports/raw/$_rep"
	done
}

# eh_required_report <profile> <target> — print one required+applicable tool report
# basename (the FAIL variant removes it to force an unavailable required tool).
eh_required_report() {
	sh "$SCRIPT_DIR/resolve-effective-profile.sh" --profile "$1" --target "$2" --format json 2>/dev/null \
		| jq -r '[ .tools|to_entries[]
		           | select(.value.policy=="required" and (.value.applicability//"unknown")!="not-applicable")
		           | (.value.report // empty | sub(".*/";"")) ] | sort | .[0] // empty'
}

# eh_override_arg <workdir> — echo "--override <path>" when the fixture carries a
# committed project tool-policy override (.sentinel-shield/tool-policy.json), else "".
# The node-derived fixtures use one to declassify the reportless `deps-install` SETUP
# tool to `external` (it is provisioned out-of-band by `npm ci`, not a report-bearing
# gate control). This mirrors a real project's .sentinel-shield/ override.
eh_override_arg() {
	if [ -f "$1/.sentinel-shield/tool-policy.json" ]; then
		printf -- '--override %s/.sentinel-shield/tool-policy.json' "$1"
	fi
}

# eh_build_and_gate <profile> <type> <workdir> — build summary (+policy overlay) then
# enforce gates. Prints the gate result word (pass|fail|error) on stdout; returns the
# enforce-gates exit code.
eh_build_and_gate() {
	_p="$1"; _ty="$2"; _w="$3"
	# shellcheck disable=SC2046
	sh "$SCRIPT_DIR/build-security-summary.sh" \
		--raw-dir "$_w/reports/raw" --output "$_w/reports/security-summary.json" \
		--profile "$_p" --target "$_w" $(eh_override_arg "$_w") \
		--project-name "e2e-$_p" --project-type "$_ty" --commit e2e --workflow e2e-harness \
		>/dev/null 2>&1 || { printf 'error'; return 4; }
	sh "$SCRIPT_DIR/resolve-gates.sh" --profile "$PROFILE_YAML" --mode baseline \
		--output-dir "$_w/reports" --format env >/dev/null 2>&1 \
		|| { printf 'error'; return 4; }
	_rc=0
	sh "$SCRIPT_DIR/enforce-gates.sh" \
		--gates-env "$_w/reports/sentinel-shield-gates.env" \
		--summary "$_w/reports/security-summary.json" \
		--output-dir "$_w/reports" --format json >/dev/null 2>&1 || _rc=$?
	_res=$(jq -r '.result // "error"' "$_w/reports/sentinel-shield-enforcement.json" 2>/dev/null || printf 'error')
	printf '%s' "$_res"
	return "$_rc"
}

# eh_run_fixture <name> <profile> <type>
eh_run_fixture() {
	_name="$1"; _profile="$2"; _type="$3"
	_fx="$E2E_DIR/$_name"
	if [ ! -d "$_fx" ]; then
		log_error "e2e-harness: fixture missing: $_fx"; FAILS=$((FAILS + 1)); return 0
	fi

	# --- PASS variant: full chain, all required reports present + clean ----------
	_wp=$(mktemp -d)
	cp -R "$_fx/." "$_wp/"
	eh_seed_required "$_profile" "$_wp" || { FAILS=$((FAILS + 1)); [ "$KEEP" -eq 1 ] || rm -rf "$_wp"; return 0; }

	_tp_rc=0
	# shellcheck disable=SC2046
	sh "$SCRIPT_DIR/run-tool-plan.sh" --profile "$_profile" --target "$_wp" --stage pr $(eh_override_arg "$_wp") >/dev/null 2>&1 || _tp_rc=$?

	_manifest="$_wp/reports/pr-execution.json"
	_req_exec=0; _unavail=0
	if [ -f "$_manifest" ]; then
		_req_exec=$(jq '[ (.tools // {})|to_entries[] | select(.value.policy=="required" and (.value.status=="ran" or .value.status=="findings")) ] | length' "$_manifest" 2>/dev/null || echo 0)
		_unavail=$(jq '[ (.tools // {})|to_entries[] | select(.value.status=="unavailable") ] | length' "$_manifest" 2>/dev/null || echo 0)
	fi

	# Capture both the gate result word AND enforce-gates' exit code in one run.
	_pass_rc=0
	_pass_res=$(eh_build_and_gate "$_profile" "$_type" "$_wp") || _pass_rc=$?

	printf '{"profile":"%s","stage":"pr","required_executed":%s,"unavailable":%s,"gate_result":"%s"}\n' \
		"$_profile" "$_req_exec" "$_unavail" "$_pass_res"

	if [ "$_pass_res" != "pass" ] || [ "$_pass_rc" -ne 0 ]; then
		log_error "e2e-harness[$_name]: PASS variant did NOT pass (result=$_pass_res exit=$_pass_rc, run-tool-plan exit=$_tp_rc)"
		FAILS=$((FAILS + 1))
	else
		log_info "e2e-harness[$_name]: PASS variant OK (required_executed=$_req_exec, gate=pass)"
	fi
	[ "$KEEP" -eq 1 ] || rm -rf "$_wp"

	# --- FAIL variant: remove one required report -> unavailable -> gate FAIL ----
	_wf=$(mktemp -d)
	cp -R "$_fx/." "$_wf/"
	eh_seed_required "$_profile" "$_wf" || { FAILS=$((FAILS + 1)); [ "$KEEP" -eq 1 ] || rm -rf "$_wf"; return 0; }
	_omit=$(eh_required_report "$_profile" "$_wf")
	if [ -z "$_omit" ]; then
		log_error "e2e-harness[$_name]: could not determine a required report to omit"; FAILS=$((FAILS + 1))
		[ "$KEEP" -eq 1 ] || rm -rf "$_wf"; return 0
	fi
	rm -f "$_wf/reports/raw/$_omit"

	_fail_rc=0
	_fail_res=$(eh_build_and_gate "$_profile" "$_type" "$_wf") || _fail_rc=$?

	if [ "$_fail_res" != "fail" ] || [ "$_fail_rc" -eq 0 ]; then
		log_error "e2e-harness[$_name]: FAIL variant did NOT fail with '$_omit' removed (result=$_fail_res exit=$_fail_rc) — an unavailable required tool MUST fail the gate"
		FAILS=$((FAILS + 1))
	else
		log_info "e2e-harness[$_name]: FAIL variant OK (omitted=$_omit -> gate=fail exit=$_fail_rc)"
	fi
	[ "$KEEP" -eq 1 ] || rm -rf "$_wf"
}

log_info "e2e-harness: LOCAL policy->gate proof over tests/e2e/ (label: local-harness, NOT real CI)"

# fixture-name  profile  project-type
eh_run_fixture laravel               laravel               laravel
eh_run_fixture symfony               symfony               symfony
eh_run_fixture js-only               node                  node
eh_run_fixture typescript            node                  node
eh_run_fixture laravel-react-docker  laravel-react-docker  laravel

if [ "$FAILS" -ne 0 ]; then
	log_error "e2e-harness: $FAILS fixture path(s) broken"
	exit 1
fi
log_info "e2e-harness: OK — all fixtures' policy->gate paths behaved as their policy requires (local-harness)"
exit 0
