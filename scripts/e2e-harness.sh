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
#   * PASS variant — every required tool actually EXECUTES and produces a clean report
#                    => run-tool-plan exit 0, no required tool/group regresses, gate PASS.
#   * FAIL variant — the SELECTED one-of member's report is removed (and the member
#                    cannot reproduce it) => the one-of GROUP is unavailable, run-tool-plan
#                    exits non-zero; a separate ordinary required report removal => gate FAIL.
#
# DETERMINISTIC EXECUTION (B8). run-tool-plan now DELETES each report-writing runner's
# expected report BEFORE invoking the runner and derives status ONLY from what THIS run
# produced — so a pre-seeded report can never mask a no-op/failed execution. The harness
# therefore does NOT rely on pre-seeded report-writing-tool reports; instead it points the
# report-WRITING runners (scripts/runners/*) at deterministic FAKE TOOLS on PATH / via the
# SENTINEL_SHIELD_*_BIN env hooks, so those runners genuinely PRODUCE clean reports during
# the actual run-tool-plan invocation. The harness then ASSERTS run-tool-plan recreated
# every such report. Reports owned by READER runners (scripts/collectors/*, which normalise
# an externally-produced raw report) and by verify-only setup tools (no runner) ARE seeded:
# they have no producing runner, so the seed legitimately stands in for the upstream tool.
#
# The PASS variant FAILS the harness (B8) on ANY execution regression: run-tool-plan exit
# != 0, missing execution manifest, a required tool whose status is unavailable/error, a
# required one-of group unsatisfied/unavailable, a required runner exit != 0, a report-
# writing runner that did NOT recreate its report, the gate result != pass, or gate exit
# != 0 — i.e. the gate can never PASS on stale reports while the live execution is broken.
#
# Each fixture prints a one-line evidence record:
#   {profile, stage, required_executed, unavailable, gate_result}
# The harness exits non-zero if ANY fixture's path is broken, so a regression in the
# policy->gate wiring (or in the tools/profiles the harness depends on) fails loudly.
#
# This is a LOCAL HARNESS (no live GitHub Actions runner this session). It exercises the
# SAME scripts CI runs; it does not exercise the GitHub workflow YAML itself.
#
# Usage: e2e-harness.sh [--keep]
#   --keep   Do not delete the per-fixture temp workdirs / fake-tool bin (for debugging).
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

# --- deterministic fake tools (B8) ------------------------------------------
# Build ONE temp bin of fake tools the report-WRITING runners (scripts/runners/*) invoke.
# Each fake emits a minimal VALID, clean report exactly where its runner expects it, so the
# runner produces a real report DURING run-tool-plan (no faked findings beyond "clean").
# Tools selected via command -v are shadowed by prepending the bin to PATH; tools selected
# via an env hook (phpstan/pint/php-cs-fixer/pest/phpunit) are pinned with SENTINEL_SHIELD_*_BIN
# so a stub binary committed under a fixture's vendor/bin cannot shadow them.
FAKEBIN=""
# eh_make_fakebin — e2e-harness helper: make fakebin.
eh_make_fakebin() {
	FAKEBIN=$(mktemp -d)
	# actionlint / zizmor: their runners redirect the tool's stdout into the report.
	printf '#!/bin/sh\nprintf "[]\\n"\n' > "$FAKEBIN/actionlint"
	printf '#!/bin/sh\nprintf "[]\\n"\n' > "$FAKEBIN/zizmor"
	# phpstan family: emit a clean PHPStan JSON object on stdout.
	printf '#!/bin/sh\nprintf "{\\"totals\\":{\\"file_errors\\":0,\\"errors\\":0},\\"files\\":{},\\"errors\\":[]}\\n"\n' > "$FAKEBIN/phpstan"
	# pint / php-cs-fixer: emit a clean (empty) JSON document on stdout.
	printf '#!/bin/sh\nprintf "{}\\n"\n' > "$FAKEBIN/pint"
	printf '#!/bin/sh\nprintf "{}\\n"\n' > "$FAKEBIN/php-cs-fixer"
	# pest / phpunit: write a minimal passing JUnit report at --log-junit <path>.
	cat > "$FAKEBIN/pest" <<'SH'
#!/bin/sh
_j=""
while [ $# -gt 0 ]; do case "$1" in --log-junit) _j="${2:-}"; shift 2 ;; *) shift ;; esac; done
[ -n "$_j" ] || exit 0
mkdir -p "$(dirname -- "$_j")"
printf '<?xml version="1.0" encoding="UTF-8"?><testsuites tests="1" failures="0" errors="0"><testsuite name="fake" tests="1" failures="0" errors="0"><testcase name="ok"/></testsuite></testsuites>\n' > "$_j"
exit 0
SH
	cp "$FAKEBIN/pest" "$FAKEBIN/phpunit"
	# php multiplexer: `php -l` (syntax ok), `php artisan ...` (no-op), and the JUnit ->
	# tests.json adapter call `php <adapter>.php <junit> <out>` (write a clean tests.json).
	cat > "$FAKEBIN/php" <<'SH'
#!/bin/sh
case "${1:-}" in
	-l) exit 0 ;;
	-v | --version) printf 'PHP 8.3.0 (sentinel-shield-fake)\n'; exit 0 ;;
	artisan) exit 0 ;;
	*to-tests-json.php)
		for _a in "$@"; do _out="$_a"; done
		[ -n "${_out:-}" ] && printf '{"failures":0,"errors":0}\n' > "$_out"
		exit 0 ;;
	*) exit 0 ;;
esac
SH
	# npx (eslint runner): honour `-o <path>` and write a clean ESLint JSON array there.
	cat > "$FAKEBIN/npx" <<'SH'
#!/bin/sh
_o=""
while [ $# -gt 0 ]; do case "$1" in -o | --output-file) _o="${2:-}"; shift 2 ;; *) shift ;; esac; done
[ -n "$_o" ] || exit 0
mkdir -p "$(dirname -- "$_o")"
printf '[]\n' > "$_o"
exit 0
SH
	# jest / vitest (JS one-of test runners): write a clean Jest/Vitest JSON report to
	# the runner's --outputFile=<path> so jest.sh/vitest.sh + their adapters produce a
	# clean reports/raw/tests.json during the real run.
	cat > "$FAKEBIN/jest" <<'SH'
#!/bin/sh
_o=""
for _a in "$@"; do case "$_a" in --outputFile=*) _o=${_a#--outputFile=} ;; esac; done
[ -n "$_o" ] || exit 0
mkdir -p "$(dirname -- "$_o")"
printf '{"numFailedTests":0,"numFailedTestSuites":0}\n' > "$_o"
exit 0
SH
	cp "$FAKEBIN/jest" "$FAKEBIN/vitest"
	# npm: satisfy deps-install (executable presence) and npm-audit's real runner
	# (`npm audit --json` -> clean audit JSON on stdout; npm-audit.sh captures it).
	cat > "$FAKEBIN/npm" <<'SH'
#!/bin/sh
case "${1:-}" in
	audit) printf '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"total":0}}}\n'; exit 0 ;;
	*) exit 0 ;;
esac
SH
	chmod +x "$FAKEBIN"/actionlint "$FAKEBIN"/zizmor "$FAKEBIN"/phpstan \
		"$FAKEBIN"/pint "$FAKEBIN"/php-cs-fixer "$FAKEBIN"/pest "$FAKEBIN"/phpunit \
		"$FAKEBIN"/php "$FAKEBIN"/npx "$FAKEBIN"/jest "$FAKEBIN"/vitest "$FAKEBIN"/npm
	export SENTINEL_SHIELD_PHPSTAN_BIN="$FAKEBIN/phpstan"
	export SENTINEL_SHIELD_PINT_BIN="$FAKEBIN/pint"
	export SENTINEL_SHIELD_PHP_CS_FIXER_BIN="$FAKEBIN/php-cs-fixer"
	export SENTINEL_SHIELD_PEST_BIN="$FAKEBIN/pest"
	export SENTINEL_SHIELD_PHPUNIT_BIN="$FAKEBIN/phpunit"
	export SENTINEL_SHIELD_JEST_BIN="$FAKEBIN/jest"
	export SENTINEL_SHIELD_VITEST_BIN="$FAKEBIN/vitest"
}

# shellcheck disable=SC2329  # invoked indirectly via trap below
eh_cleanup() { [ "$KEEP" -eq 1 ] || { [ -n "$FAKEBIN" ] && rm -rf "$FAKEBIN"; }; }
trap eh_cleanup EXIT INT TERM

# eh_resolve <profile> <target> — emit the canonical effective profile JSON, or fail.
eh_resolve() {
	sh "$SCRIPT_DIR/resolve-effective-profile.sh" --profile "$1" --target "$2" --format json 2>/dev/null
}

# eh_writer_reports <profile> <target> — report basenames for required+applicable tools
# (and the SELECTED one-of member) whose runner WRITES the report (scripts/runners/*) AND
# that actually EXECUTE at the pr stage (execution.pr). These are produced by the fake
# tools DURING run-tool-plan; the harness clears any seed first and asserts run-tool-plan
# recreated them. (A scripts/runners/* tool NOT scheduled at pr — e.g. codeql — is not run
# at this stage, so it is seeded like a verify-only report, not cleared.)
eh_writer_reports() {
	eh_resolve "$1" "$2" | jq -r '
		( [ .tools | to_entries[]
		    | select(.value.policy=="required" and (.value.applicability//"unknown")!="not-applicable")
		    | select(((.value.runner // "") | startswith("scripts/runners/")) and (.value.execution.pr == true))
		    | (.value.report // empty) ]
		+ [ (.one_of_groups | to_entries[]) as $g
		    | select($g.value.selected != null)
		    | ($g.value.selected) as $sel
		    | select(((.tools[$sel].runner // "") | startswith("scripts/runners/")) and ((.tools[$g.key].execution.pr // false) == true))
		    | (.tools[$g.key].report // .tools[$sel].report // "reports/raw/tests.json") ] )
		| unique[] | sub(".*/";"")'
}

# eh_seed_nonwriter <profile> <target> — seed a clean ('{}') raw report for every
# required+applicable tool / selected one-of member that is NOT produced at the pr stage by
# a report-writing runner — i.e. scripts/collectors/* readers, verify-only setup tools, and
# report-writing tools not scheduled at pr (e.g. codeql). These have no producing runner at
# this stage, so the seed legitimately stands in for the upstream tool's raw output. The
# complement (pr-stage report-writing tools, eh_writer_reports) is NOT seeded — run-tool-plan
# must produce those live.
eh_seed_nonwriter() {
	_eff=$(eh_resolve "$1" "$2") || { log_error "e2e-harness: could not resolve profile '$1'"; return 1; }
	ensure_dir "$2/reports/raw"
	for _rep in $(printf '%s' "$_eff" | jq -r '
		( [ .tools | to_entries[]
		    | select(.value.policy=="required" and (.value.applicability//"unknown")!="not-applicable")
		    | select( (((.value.runner // "") | startswith("scripts/runners/")) and (.value.execution.pr == true)) | not )
		    | (.value.report // empty) ]
		+ [ (.one_of_groups | to_entries[]) as $g
		    | select($g.value.selected != null)
		    | ($g.value.selected) as $sel
		    | select( (((.tools[$sel].runner // "") | startswith("scripts/runners/")) and ((.tools[$g.key].execution.pr // false) == true)) | not )
		    | (.tools[$g.key].report // .tools[$sel].report // "reports/raw/tests.json") ] )
		| unique[] | select(length>0) | sub(".*/";"")'); do
		[ -f "$2/reports/raw/$_rep" ] || printf '{}\n' > "$2/reports/raw/$_rep"
	done
}

# eh_oneof_report <profile> <target> — basename of the SELECTED one-of group's report
# (the FAIL variant removes it to force an unavailable required one-of GROUP). Empty when
# the profile has no satisfied one-of group.
eh_oneof_report() {
	eh_resolve "$1" "$2" | jq -r '
		[ (.one_of_groups | to_entries[]) as $g
		  | select($g.value.selected != null)
		  | ($g.value.selected) as $sel
		  | (.tools[$g.key].report // .tools[$sel].report // "reports/raw/tests.json") ]
		| sort | (.[0] // "") | sub(".*/";"")'
}

# eh_required_report <profile> <target> — one ORDINARY required+applicable tool report
# basename (NOT a one-of member); the FAIL variant removes it to force an unavailable
# required tool that the gate must reject.
eh_required_report() {
	eh_resolve "$1" "$2" | jq -r '
		# one-of group keys + their alternative members — explicitly excluded so the
		# FAIL(required) variant only ever picks an ORDINARY required tool report
		# (one-of coverage is exercised separately by eh_fail_oneof).
		( [ (.one_of_groups // {}) | to_entries[] | (.key, (.value.alternatives[]?)) ] ) as $oneof
		| ( [ .tools | to_entries[]
		    | select(.value.policy=="required" and (.value.applicability//"unknown")!="not-applicable")
		    | select(.key as $k | ($oneof | index($k)) | not)
		    | (.value.report // empty) ] )
		| sort | (.[0] // "") | sub(".*/";"")'
}

# eh_override_arg <workdir> — echo "--override <path>" when the fixture carries a committed
# project tool-policy override (.sentinel-shield/tool-policy.json), else "".
eh_override_arg() {
	if [ -f "$1/.sentinel-shield/tool-policy.json" ]; then
		printf -- '--override %s/.sentinel-shield/tool-policy.json' "$1"
	fi
}

# eh_run_tool_plan <profile> <workdir> — run the stage plan with the fake tools on PATH so
# report-writing runners produce real reports. Sets EH_TP_RC to run-tool-plan's exit code.
eh_run_tool_plan() {
	EH_TP_RC=0
	# shellcheck disable=SC2046
	PATH="$FAKEBIN:$PATH" sh "$SCRIPT_DIR/run-tool-plan.sh" \
		--profile "$1" --target "$2" --stage pr $(eh_override_arg "$2") >/dev/null 2>&1 || EH_TP_RC=$?
}

# eh_manifest_regressions <manifest> — print the required tools/groups that REGRESSED in
# the execution manifest (status unavailable/error/unsatisfied, or a non-zero runner exit).
# Empty output = clean execution. Used to fail the PASS variant on any execution regression.
eh_manifest_regressions() {
	jq -r '
		( [ (.tools // {}) | to_entries[]
		    | select(.value.policy=="required")
		    | select(.value.status=="unavailable" or .value.status=="error"
		             or ((.value.runner_exit != null) and (.value.runner_exit != 0)))
		    | "tool:\(.key)=\(.value.status)" ]
		+ [ (.one_of_groups // {}) | to_entries[]
		    | select(.value.policy=="required")
		    | select(.value.status=="unsatisfied" or .value.status=="unavailable" or .value.status=="error"
		             or ((.value.runner_exit != null) and (.value.runner_exit != 0)))
		    | "group:\(.key)=\(.value.status)" ] )
		| join(" ")' "$1" 2>/dev/null || true
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
	# This harness proves the REQUIRED-tool -> gate contract (tool availability/execution decides
	# pass/fail). The additive engineering-quality gates (v2.1) are orthogonal — driven by fixture
	# test-counts / debug / focused-test / diff-coverage content, not by required-tool availability —
	# and are exhaustively exercised by tests/prod/270-quality-gates.sh. Force them OFF here so
	# fixture source content cannot perturb the required-tool contract this harness verifies.
	_envf="$_w/reports/sentinel-shield-gates.env"
	awk '/^SENTINEL_SHIELD_FAIL_ON_(COVERAGE_THRESHOLD_VIOLATIONS|COVERAGE_REGRESSION|MUTATION_SCORE_VIOLATIONS|COMPLEXITY_VIOLATIONS|DUPLICATION_VIOLATIONS|DEAD_CODE_VIOLATIONS|MISSING_COVERAGE_EVIDENCE|CHANGED_LINES_COVERAGE_VIOLATIONS|MISSING_TEST_EVIDENCE|EMPTY_TEST_SUITE|SKIPPED_TESTS|FOCUSED_TEST_VIOLATIONS|SKIPPED_TEST_MARKER_VIOLATIONS|DEBUG_CODE_VIOLATIONS|LARGE_FILE_VIOLATIONS|LARGE_FUNCTION_VIOLATIONS)=/{sub(/=.*/,"=false")}{print}' "$_envf" > "$_envf.tmp" && mv "$_envf.tmp" "$_envf"
	_rc=0
	sh "$SCRIPT_DIR/enforce-gates.sh" \
		--gates-env "$_w/reports/sentinel-shield-gates.env" \
		--summary "$_w/reports/security-summary.json" \
		--output-dir "$_w/reports" --format json >/dev/null 2>&1 || _rc=$?
	_res=$(jq -r '.result // "error"' "$_w/reports/sentinel-shield-enforcement.json" 2>/dev/null || printf 'error')
	printf '%s' "$_res"
	return "$_rc"
}

# eh_pass_variant <name> <profile> <type> <workdir> — drive + assert the PASS variant.
eh_pass_variant() {
	_name="$1"; _profile="$2"; _type="$3"; _wp="$4"
	eh_seed_nonwriter "$_profile" "$_wp" || return 1
	# Clear report-writing-tool reports so run-tool-plan must RECREATE them via the fakes
	# (a stale seed must never stand in for a live execution — B8).
	_writers=$(eh_writer_reports "$_profile" "$_wp")
	for _r in $_writers; do rm -f "$_wp/reports/raw/$_r"; done

	eh_run_tool_plan "$_profile" "$_wp"
	_manifest="$_wp/reports/pr-execution.json"

	_req_exec=0; _unavail=0
	if [ -f "$_manifest" ]; then
		_req_exec=$(jq '[ (.tools // {})|to_entries[] | select(.value.policy=="required" and (.value.status=="ran" or .value.status=="findings")) ] | length' "$_manifest" 2>/dev/null || echo 0)
		_unavail=$(jq '[ (.tools // {})|to_entries[] | select(.value.status=="unavailable") ] | length' "$_manifest" 2>/dev/null || echo 0)
	fi

	_pass_rc=0
	_pass_res=$(eh_build_and_gate "$_profile" "$_type" "$_wp") || _pass_rc=$?

	printf '{"profile":"%s","stage":"pr","required_executed":%s,"unavailable":%s,"gate_result":"%s"}\n' \
		"$_profile" "$_req_exec" "$_unavail" "$_pass_res"

	# --- strict execution assertions (B8): the gate may NEVER pass while execution is broken.
	_why=""
	[ "$EH_TP_RC" -eq 0 ] || _why="run-tool-plan exit $EH_TP_RC"
	[ -n "$_why" ] || [ -f "$_manifest" ] || _why="missing execution manifest"
	if [ -z "$_why" ]; then
		_reg=$(eh_manifest_regressions "$_manifest")
		[ -z "$_reg" ] || _why="required execution regressions [$_reg]"
	fi
	if [ -z "$_why" ]; then
		for _r in $_writers; do
			jq -e . "$_wp/reports/raw/$_r" >/dev/null 2>&1 || { _why="report-writing runner did not recreate $_r"; break; }
		done
	fi
	[ -n "$_why" ] || { [ "$_pass_res" = "pass" ] && [ "$_pass_rc" -eq 0 ]; } || _why="${_why:-gate result=$_pass_res exit=$_pass_rc}"

	if [ -n "$_why" ]; then
		log_error "e2e-harness[$_name]: PASS variant did NOT pass ($_why; run-tool-plan exit=$EH_TP_RC, gate=$_pass_res/$_pass_rc)"
		return 1
	fi
	log_info "e2e-harness[$_name]: PASS variant OK (required_executed=$_req_exec, run-tool-plan=0, gate=pass)"
	return 0
}

# eh_fail_oneof <name> <profile> <type> <workdir> — B7: removing ONLY the selected one-of
# member's report (with no member able to reproduce it) MUST break the path — the one-of
# GROUP becomes unavailable and run-tool-plan exits non-zero. Returns 0 when proven.
eh_fail_oneof() {
	_name="$1"; _profile="$2"; _wf="$4"
	_omit=$(eh_oneof_report "$_profile" "$_wf")
	if [ -z "$_omit" ]; then
		log_info "e2e-harness[$_name]: no satisfied one-of group; skipping one-of FAIL check"
		return 0
	fi
	eh_seed_nonwriter "$_profile" "$_wf" || return 1
	# Produce every OTHER report-writing tool's report, but pin the test runners at a
	# nonexistent binary so the selected one-of member CANNOT reproduce its report — the
	# removal of the one-of report is then the SOLE trigger.
	_writers=$(eh_writer_reports "$_profile" "$_wf")
	for _r in $_writers; do rm -f "$_wf/reports/raw/$_r"; done
	rm -f "$_wf/reports/raw/$_omit"
	_rc=0
	# Pin EVERY one-of test runner (PHP + JS) at a nonexistent binary so NO member can
	# reproduce the removed report — the removal is then the SOLE trigger. Also drop any
	# committed node_modules/.bin test shims so the JS member cannot run from there.
	rm -f "$_wf/node_modules/.bin/jest" "$_wf/node_modules/.bin/vitest" 2>/dev/null || true
	# shellcheck disable=SC2046
	SENTINEL_SHIELD_PEST_BIN="$FAKEBIN/__absent__" SENTINEL_SHIELD_PHPUNIT_BIN="$FAKEBIN/__absent__" \
	SENTINEL_SHIELD_JEST_BIN="$FAKEBIN/__absent__" SENTINEL_SHIELD_VITEST_BIN="$FAKEBIN/__absent__" \
		PATH="$FAKEBIN:$PATH" sh "$SCRIPT_DIR/run-tool-plan.sh" \
		--profile "$_profile" --target "$_wf" --stage pr $(eh_override_arg "$_wf") >/dev/null 2>&1 || _rc=$?
	_manifest="$_wf/reports/pr-execution.json"
	_grp_bad=$(jq -r '[ (.one_of_groups // {})|to_entries[] | select(.value.policy=="required" and .value.selected!=null and (.value.status=="unavailable" or .value.status=="unsatisfied")) ] | length' "$_manifest" 2>/dev/null || echo 0)
	if [ "$_rc" -ne 0 ] && [ "${_grp_bad:-0}" -ge 1 ]; then
		log_info "e2e-harness[$_name]: FAIL(one-of) OK (removed=$_omit -> required one-of group unavailable, run-tool-plan exit=$_rc)"
		return 0
	fi
	log_error "e2e-harness[$_name]: FAIL(one-of) did NOT fail with '$_omit' removed (run-tool-plan exit=$_rc, bad-groups=${_grp_bad:-0}) — an unavailable required one-of group MUST break the path"
	return 1
}

# eh_fail_required <name> <profile> <type> <workdir> — removing an ordinary required tool's
# report MUST make the gate FAIL (an unavailable required tool is never rewritten clean).
eh_fail_required() {
	_name="$1"; _profile="$2"; _type="$3"; _wf="$4"
	eh_seed_nonwriter "$_profile" "$_wf" || return 1
	# Make the report-writing tools' reports present so the SOLE missing report is the one
	# we omit below.
	_pre_rc=0
	eh_run_tool_plan "$_profile" "$_wf" || _pre_rc=$?
	_omit=$(eh_required_report "$_profile" "$_wf")
	if [ -z "$_omit" ]; then
		log_error "e2e-harness[$_name]: could not determine a required report to omit"; return 1
	fi
	rm -f "$_wf/reports/raw/$_omit"
	_fail_rc=0
	_fail_res=$(eh_build_and_gate "$_profile" "$_type" "$_wf") || _fail_rc=$?
	if [ "$_fail_res" = "fail" ] && [ "$_fail_rc" -ne 0 ]; then
		log_info "e2e-harness[$_name]: FAIL(required) OK (omitted=$_omit -> gate=fail exit=$_fail_rc)"
		return 0
	fi
	log_error "e2e-harness[$_name]: FAIL(required) did NOT fail with '$_omit' removed (result=$_fail_res exit=$_fail_rc) — an unavailable required tool MUST fail the gate"
	return 1
}

# eh_run_fixture <name> <profile> <type>
eh_run_fixture() {
	_fname="$1"; _fprofile="$2"; _ftype="$3"
	_fx="$E2E_DIR/$_fname"
	if [ ! -d "$_fx" ]; then
		log_error "e2e-harness: fixture missing: $_fx"; FAILS=$((FAILS + 1)); return 0
	fi

	# --- PASS variant ---------------------------------------------------------
	_wp=$(mktemp -d); cp -R "$_fx/." "$_wp/"
	eh_pass_variant "$_fname" "$_fprofile" "$_ftype" "$_wp" || FAILS=$((FAILS + 1))
	[ "$KEEP" -eq 1 ] || rm -rf "$_wp"

	# --- FAIL variant: selected one-of report removed (B7) --------------------
	_wo=$(mktemp -d); cp -R "$_fx/." "$_wo/"
	eh_fail_oneof "$_fname" "$_fprofile" "$_ftype" "$_wo" || FAILS=$((FAILS + 1))
	[ "$KEEP" -eq 1 ] || rm -rf "$_wo"

	# --- FAIL variant: ordinary required report removed -> gate FAIL ----------
	_wf=$(mktemp -d); cp -R "$_fx/." "$_wf/"
	eh_fail_required "$_fname" "$_fprofile" "$_ftype" "$_wf" || FAILS=$((FAILS + 1))
	[ "$KEEP" -eq 1 ] || rm -rf "$_wf"
}

eh_make_fakebin
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
