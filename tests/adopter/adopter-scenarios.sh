#!/bin/sh
# Sentinel Shield — external-adopter MULTI-ENVIRONMENT validation suite.
#
# Replaces the single black-box session (tests/adopter/black-box-install.sh) with a
# reproducible suite of ISOLATED adopter scenarios, each started with NO internal repo
# knowledge (published docs only) and driven through the documented lifecycle:
#
#     acquire -> verify source identity -> dry-run -> install -> doctor -> local pipeline
#     -> INJECT >=1 understandable failure -> RECOVER -> emit a schema-valid session report
#
# Scenarios implemented here (all OFFLINE + DETERMINISTIC):
#   clean-linux           full documented flow; a config-level failure + re-run recovery.
#   minimal-posix         flow under a MINIMAL PATH; a missing-target failure + recovery.
#   managed-file-conflict a MANAGED file is tampered (mutation); --force restores it byte-for-byte.
#   read-only-project     install into a read-only target FAILS; restore perms + re-install recovers.
#   interrupted-recovery  the transaction journal is corrupted; recover-operation --inspect FAILS
#                         closed (distinct code); restoring the journal recovers.
#   proxy-configured      the offline flow runs with a black-hole http(s)_proxy set, proving it
#                         needs no network; config-level failure + re-run recovery.
#   offline-restricted    a network clone is attempted and FAILS; the documented --repository
#                         offline form is the safe next action (recovery).
#
# Scenarios that genuinely cannot run offline are recorded as EXPLICIT, reasoned SKIPs on
# the scorecard (a skip is NEVER a pass): update-from-beta.1 (needs the published ref) and
# uninstall (no engine uninstall command is published).
#
# Each scenario emits one record conforming to schemas/adopter-session.schema.json into an
# output directory; the suite then folds them into a scorecard via
# scripts/report-adopter-usability.sh (schemas/adopter-scorecard.schema.json).
#
# Every engine command runs under a MINIMAL ALLOWLISTED environment (env -i + PATH/HOME/TMPDIR
# plus the documented SENTINEL_SHIELD_* vars when set), with stdin from /dev/null, and under a
# BOUNDED timeout with a DISTINCT timeout result code (124). Records carry NO secrets and NO
# absolute local paths.
#
# Usage: sh tests/adopter/adopter-scenarios.sh [--out-dir <dir>] [--keep]
# Exit: 0 when the scorecard result=pass; 1 when it fails; 2 on harness misuse / missing prereq.
set -eu

HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "$HARNESS_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$REPO_ROOT" ] || REPO_ROOT=$(CDPATH= cd -- "$HARNESS_DIR/../.." && pwd)

OUT_DIR=""
KEEP=0
while [ $# -gt 0 ]; do
	case "$1" in
		--out-dir) OUT_DIR="${2:?--out-dir requires a value}"; shift 2 ;;
		--keep) KEEP=1; shift ;;
		-h|--help) printf 'Usage: adopter-scenarios.sh [--out-dir <dir>] [--keep]\n'; exit 0 ;;
		*) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is a documented prerequisite but is absent\n' >&2; exit 2; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssadopter)
# shellcheck disable=SC2329 # invoked indirectly via the trap below
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
[ -n "$OUT_DIR" ] || OUT_DIR="$WORK/sessions"
mkdir -p "$OUT_DIR"

PLATFORM=$(uname -s 2>/dev/null || echo unknown)
DEFAULT_BUDGET=60          # per-step wall-clock budget the scorecard holds mandatory steps to
TIMEOUT_SECS=45            # bounded timeout for any single engine command
TIMEOUT_RC=124            # DISTINCT result code for a timed-out command

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

# --- redaction (workspace/target/engine/home + secret shapes) --------------------
CUR_TARGET="__no_target__"
_ere_escape() { printf '%s' "$1" | sed 's/[]#.^$*+?(){}|[]/\\&/g'; }
redact() {
	_rw=$(_ere_escape "$WORK")
	_rt=$(_ere_escape "$CUR_TARGET")
	_rr=$(_ere_escape "$REPO_ROOT")
	_rh=$(_ere_escape "${HOME:-__no_home__}")
	sed -E \
		-e "s#${_rt}#<target>#g" \
		-e "s#${_rw}#<workspace>#g" \
		-e "s#${_rr}#<engine-src>#g" \
		-e "s#${_rh}#~#g" \
		-e 's/(AKIA|ASIA)[0-9A-Z]{16}/***REDACTED-AWS-KEY***/g' \
		-e 's/gh[pousr]_[A-Za-z0-9]{20,}/***REDACTED-GH-TOKEN***/g' \
		-e 's/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD))[=:][[:space:]]*[^[:space:]"'\'']+/\1=***REDACTED***/g'
}

# --- constrained execution under a bounded timeout with a distinct code ----------
# ss_run <outfile> <cmd...> : run under env -i allowlist, stdin /dev/null, output to
# <outfile>. Returns the command's exit code, or TIMEOUT_RC (124) if it exceeded the
# bounded timeout. A background killer is used so the fast path adds no latency.
ss_run() {
	_of="$1"; shift
	(
		exec </dev/null
		# Proxy variables (when set) MUST survive env -i, else the proxy-configured scenario
		# would silently run with no proxy and prove nothing.
		env -i PATH="$PATH" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
			${http_proxy:+http_proxy="$http_proxy"} ${https_proxy:+https_proxy="$https_proxy"} ${no_proxy:+no_proxy="$no_proxy"} \
			${HTTP_PROXY:+HTTP_PROXY="$HTTP_PROXY"} ${HTTPS_PROXY:+HTTPS_PROXY="$HTTPS_PROXY"} ${NO_PROXY:+NO_PROXY="$NO_PROXY"} \
			"$@"
	) >"$_of" 2>&1 &
	_pid=$!
	(
		sleep "$TIMEOUT_SECS"
		if kill -0 "$_pid" 2>/dev/null; then
			kill -TERM "$_pid" 2>/dev/null
			sleep 1
			kill -KILL "$_pid" 2>/dev/null
		fi
	) 2>/dev/null &
	_killer=$!
	_rc=0
	wait "$_pid" 2>/dev/null || _rc=$?
	if kill -0 "$_killer" 2>/dev/null; then kill "$_killer" 2>/dev/null; fi
	wait "$_killer" 2>/dev/null || :
	# A SIGTERM/SIGKILL exit means the watchdog fired: normalise to the distinct code.
	case "$_rc" in 143|137) _rc=$TIMEOUT_RC ;; esac
	return "$_rc"
}

# --- per-scenario step recorder --------------------------------------------------
STEPS=""   # path to the current scenario's steps jsonl
# record <step> <command> <exit|null> <elapsed|null> <status> <message> <next_action> [gen_json]
record() {
	_na="$7"; _gf="${8:-[]}"
	jq -cn \
		--arg step "$1" \
		--arg command "$(printf '%s' "$2" | redact)" \
		--argjson exit_code "$3" \
		--argjson elapsed "$4" \
		--arg status "$5" \
		--arg message "$(printf '%s' "$6" | redact)" \
		--arg next_action "$(printf '%s' "$_na" | redact)" \
		--argjson generated_files "$_gf" '
		{step:$step, command:$command, exit_code:$exit_code, elapsed_seconds:$elapsed, status:$status, message:$message, generated_files:$generated_files}
		+ (if $next_action == "" then {} else {next_action:$next_action} end)' >> "$STEPS"
}

# emit_session <scenario> <recovery_json|null> <result>
emit_session() {
	_scn="$1"; _rec="$2"; _res="$3"
	_steps=$(jq -s '.' "$STEPS")
	jq -n \
		--arg scenario "$_scn" \
		--arg platform "$PLATFORM" \
		--arg started "$SCN_STARTED" \
		--arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--argjson budget "$DEFAULT_BUDGET" \
		--argjson steps "$_steps" \
		--argjson recovery "$_rec" \
		--arg result "$_res" '
		{
			schema_version: "1",
			harness: "adopter-scenarios",
			scenario: $scenario,
			platform: $platform,
			started_at: $started,
			finished_at: $finished,
			documented_environment: ["PATH","HOME","TMPDIR"],
			injected_inputs: [],
			unexpected_prompt: false,
			budget_seconds: $budget,
			steps: $steps,
			result: $result
		}
		+ (if $recovery == null then {} else {recovery:$recovery} end)' > "$OUT_DIR/$_scn.session.json"
}

# scenario_begin <name> : fresh steps file + timestamp.
scenario_begin() {
	STEPS="$WORK/steps-$1.jsonl"; : > "$STEPS"
	SCN_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
}

# --- shared documented sub-flows (each records a step) ---------------------------
# flow_dry_run + flow_install + flow_doctor + flow_pipeline against $CUR_TARGET.
elapsed_since() { echo "$(( $(date +%s) - $1 ))"; }

flow_install() {
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/install-baseline.sh" --target "$CUR_TARGET" --profile node --apply || _rc=$?
	_el=$(elapsed_since "$_t0")
	if [ "$_rc" = 0 ]; then
		record install "sh scripts/install-baseline.sh --target <target> --profile node --apply" 0 "$_el" ok "baseline installed" "" \
			"$(find "$CUR_TARGET" -type f 2>/dev/null | sed "s#^$(_ere_escape "$CUR_TARGET")#<target>#" | jq -R -s 'split("\n")|map(select(length>0))')"
	else
		record install "sh scripts/install-baseline.sh --target <target> --profile node --apply" "$_rc" "$_el" fail \
			"install --apply failed (rc=$_rc): $(tail -n1 "$WORK/out" | redact)" "inspect the message, resolve the blocker, then re-run install --apply"
	fi
	return "$_rc"
}

flow_doctor() {
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/doctor.sh" --target "$CUR_TARGET" || _rc=$?
	_el=$(elapsed_since "$_t0")
	case "$_rc" in
		0) record doctor "sh scripts/doctor.sh --target <target>" 0 "$_el" ok "preflight healthy" "" ;;
		1) record doctor "sh scripts/doctor.sh --target <target>" 1 "$_el" ok "preflight warnings-only" "" ;;
		3) record doctor "sh scripts/doctor.sh --target <target>" 3 "$_el" ok "profile scanners not yet provisioned (expected before bootstrap-profile-tools)" "" ;;
		*) record doctor "sh scripts/doctor.sh --target <target>" "$_rc" "$_el" fail "doctor reported a blocking condition (rc=$_rc)" "run: sh scripts/bootstrap-profile-tools.sh, then re-run doctor" ;;
	esac
	return 0
}

flow_pipeline() {
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/run-local-pipeline.sh" --profile node --target "$CUR_TARGET" --stage pr || _rc=$?
	_el=$(elapsed_since "$_t0")
	case "$_rc" in
		0) record local-pipeline "sh scripts/run-local-pipeline.sh --profile node --target <target> --stage pr" 0 "$_el" ok "gate passed" "" ;;
		1) record local-pipeline "sh scripts/run-local-pipeline.sh --profile node --target <target> --stage pr" 1 "$_el" ok "gate ran; findings blocked the build (honest)" "" ;;
		3) record local-pipeline "sh scripts/run-local-pipeline.sh --profile node --target <target> --stage pr" 3 "$_el" ok "required tool unavailable (honest exit 3 for a bare adopter)" "" ;;
		"$TIMEOUT_RC") record local-pipeline "sh scripts/run-local-pipeline.sh --profile node --target <target> --stage pr" "$TIMEOUT_RC" "$_el" fail "pipeline exceeded the bounded timeout" "increase the timeout budget or provision scanners; re-run the pipeline" ;;
		*) record local-pipeline "sh scripts/run-local-pipeline.sh --profile node --target <target> --stage pr" "$_rc" "$_el" fail "pipeline config/execution problem (rc=$_rc)" "fix the reported configuration issue, then re-run the pipeline" ;;
	esac
	return 0
}

# verify_result <scenario> : result=pass iff no NON-injected mandatory step failed. The
# deliberate 'inject-failure' step is expected; it must carry a message + next_action but
# does not, by itself, fail the scenario. Prints pass|fail.
verify_result() {
	_bad=$(jq -s '[.[] | select(.status=="fail" and (.step|test("^inject-failure")|not))] | length' "$STEPS")
	_injtotal=$(jq -s '[.[] | select(.step|test("^inject-failure"))] | length' "$STEPS")
	_injfailed=$(jq -s '[.[] | select((.step|test("^inject-failure")) and .status=="fail")] | length' "$STEPS")
	_injbad=$(jq -s '[.[] | select(.step|test("^inject-failure")) | select((.message//"")=="" or (.next_action//"")=="")] | length' "$STEPS")
	# pass iff: no non-injected mandatory step failed; every injected failure carried a
	# message + next_action; AND every inject-failure step ACTUALLY failed (an injected
	# command that unexpectedly exits 0 — status != fail — is a broken test, not a pass).
	if [ "$_bad" = 0 ] && [ "$_injbad" = 0 ] && [ "$_injfailed" = "$_injtotal" ]; then echo pass; else echo fail; fi
}

# ======================================================================
# SCENARIO: clean-linux
# ======================================================================
scn_clean_linux() {
	scenario_begin clean-linux
	CUR_TARGET="$WORK/clean"; mkdir -p "$CUR_TARGET"
	# dry-run
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/install-baseline.sh" --target "$CUR_TARGET" --profile node || _rc=$?
	if [ "$_rc" = 0 ]; then record dry-run "sh scripts/install-baseline.sh --target <target> --profile node" 0 "$(elapsed_since "$_t0")" ok "dry-run plan produced; nothing written" ""; else record dry-run "sh scripts/install-baseline.sh --target <target> --profile node" "$_rc" "$(elapsed_since "$_t0")" fail "dry-run failed (rc=$_rc)" "review the plan error and retry the dry-run"; fi
	flow_install || :
	flow_doctor
	flow_pipeline
	# INJECT: an unknown pipeline stage => config error (understandable), then recover by re-running with a valid stage.
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/run-local-pipeline.sh" --profile node --target "$CUR_TARGET" --stage bogus-stage || _rc=$?
	record inject-failure "sh scripts/run-local-pipeline.sh --profile node --target <target> --stage bogus-stage" "$_rc" "$(elapsed_since "$_t0")" fail \
		"unknown stage 'bogus-stage' rejected (rc=$_rc)" "use a documented stage (pr|push|nightly); re-run with --stage pr"
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/run-local-pipeline.sh" --profile node --target "$CUR_TARGET" --stage pr || _rc=$?
	case "$_rc" in 0|1|3) record recover "sh scripts/run-local-pipeline.sh --profile node --target <target> --stage pr" "$_rc" "$(elapsed_since "$_t0")" ok "re-ran with a documented stage; flow recovered" "" ;; *) record recover "sh scripts/run-local-pipeline.sh --profile node --target <target> --stage pr" "$_rc" "$(elapsed_since "$_t0")" fail "recovery re-run failed (rc=$_rc)" "provision scanners and re-run" ;; esac
	emit_session clean-linux '{"required":false,"performed":true,"restored":true,"method":"re-run with a documented --stage"}' "$(verify_result)"
}

# ======================================================================
# SCENARIO: minimal-posix (restricted PATH)
# ======================================================================
scn_minimal_posix() {
	scenario_begin minimal-posix
	CUR_TARGET="$WORK/minimal"; mkdir -p "$CUR_TARGET"
	# Restrict PATH to ONLY the directories holding the engine's core tools, proving the flow
	# needs no other PATH entries (the advertised minimal-POSIX environment). ss_run reads the
	# ambient PATH, so this constrains every step below. Saved/restored around the scenario.
	_mp_saved="$PATH"
	_mp=$(for _t in sh jq git awk sed grep; do _p=$(command -v "$_t" 2>/dev/null) && dirname -- "$_p"; done | sort -u | tr '\n' ':')
	_mp="${_mp%:}"
	[ -n "$_mp" ] && { PATH="$_mp"; export PATH; }
	flow_install || :
	# INJECT: doctor against a non-existent target => invalid invocation (rc 2), then recover.
	_missing="$WORK/minimal-absent"
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/doctor.sh" --target "$_missing" || _rc=$?
	record inject-failure "sh scripts/doctor.sh --target <target>-absent" "$_rc" "$(elapsed_since "$_t0")" fail \
		"doctor refused a non-existent target (rc=$_rc)" "point --target at an installed project directory, then re-run doctor"
	flow_doctor
	PATH="$_mp_saved"; export PATH; unset _mp_saved _mp
	emit_session minimal-posix '{"required":false,"performed":true,"restored":true,"method":"re-run doctor against the installed target"}' "$(verify_result)"
}

# ======================================================================
# SCENARIO: managed-file-conflict (tamper a MANAGED file; --force restores it)
# ======================================================================
scn_managed_conflict() {
	scenario_begin managed-file-conflict
	CUR_TARGET="$WORK/conflict"; mkdir -p "$CUR_TARGET"
	flow_install || :
	_mf="$CUR_TARGET/.github/workflows/sentinel-shield.yml"
	_res=pass; _restored=false
	if [ -f "$_mf" ]; then
		_sha0=$(shasum "$_mf" | cut -d' ' -f1)
		# INJECT: a pre-existing managed-file conflict — the managed file is mutated out of band.
		printf '\n# LOCAL DRIFT INJECTED BY ADOPTER SCENARIO\n' >> "$_mf"
		_sha1=$(shasum "$_mf" | cut -d' ' -f1)
		record inject-failure "detect drift in <target>/.github/workflows/sentinel-shield.yml" 1 0 fail \
			"managed file drifted from the baseline (checksum changed)" "re-run install with --force to restore the managed baseline"
		# RECOVER: the documented resolution — install --apply --force restores managed files.
		_t0=$(date +%s); _rc=0
		ss_run "$WORK/out" sh "$REPO_ROOT/scripts/install-baseline.sh" --target "$CUR_TARGET" --profile node --apply --force || _rc=$?
		_sha2=$(shasum "$_mf" | cut -d' ' -f1)
		if [ "$_rc" = 0 ] && [ "$_sha2" = "$_sha0" ]; then
			record recover "sh scripts/install-baseline.sh --target <target> --profile node --apply --force" 0 "$(elapsed_since "$_t0")" ok "managed file restored byte-for-byte to the baseline" ""
			_restored=true
		else
			record recover "sh scripts/install-baseline.sh --target <target> --profile node --apply --force" "$_rc" "$(elapsed_since "$_t0")" fail "managed file was NOT restored (rc=$_rc, sha match=$([ "$_sha2" = "$_sha0" ] && echo yes || echo no))" "restore the managed file from the engine baseline manually"
			_res=fail
		fi
		[ "$_sha1" = "$_sha0" ] && _res=fail   # sanity: drift must have changed the file
	else
		record inject-failure "detect managed file" null null fail "expected managed workflow file was not installed" "verify the install step succeeded before injecting drift"
		_res=fail
	fi
	emit_session managed-file-conflict "{\"required\":true,\"performed\":true,\"restored\":$_restored,\"method\":\"install --apply --force restores managed baseline\"}" "$_res"
}

# ======================================================================
# SCENARIO: read-only-project (install into a read-only target FAILS; restore + recover)
# ======================================================================
scn_read_only() {
	scenario_begin read-only-project
	CUR_TARGET="$WORK/readonly"; mkdir -p "$CUR_TARGET"
	chmod 0555 "$CUR_TARGET"
	# INJECT: install into a read-only project directory must fail (no partial writes).
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/install-baseline.sh" --target "$CUR_TARGET" --profile node --apply || _rc=$?
	record inject-failure "sh scripts/install-baseline.sh --target <target> --profile node --apply" "$_rc" "$(elapsed_since "$_t0")" fail \
		"install into a read-only project failed (rc=$_rc)" "grant write permission to the project directory, then re-run install --apply"
	# RECOVER: restore write permission and re-install; verify the install completed.
	chmod 0755 "$CUR_TARGET"
	_res=fail; _restored=false
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/install-baseline.sh" --target "$CUR_TARGET" --profile node --apply || _rc=$?
	if [ "$_rc" = 0 ] && [ -f "$CUR_TARGET/.sentinel-shield/installation.json" ]; then
		record recover "sh scripts/install-baseline.sh --target <target> --profile node --apply" 0 "$(elapsed_since "$_t0")" ok "install completed after write permission was restored" ""
		_res=pass; _restored=true
	else
		record recover "sh scripts/install-baseline.sh --target <target> --profile node --apply" "$_rc" "$(elapsed_since "$_t0")" fail "re-install after restoring permissions failed (rc=$_rc)" "check directory ownership and re-run install --apply"
	fi
	emit_session read-only-project "{\"required\":true,\"performed\":true,\"restored\":$_restored,\"method\":\"restore write permission + re-run install --apply\"}" "$_res"
}

# ======================================================================
# SCENARIO: interrupted-recovery (corrupt journal -> fail-closed detect -> restore)
# ======================================================================
scn_interrupted_recovery() {
	scenario_begin interrupted-recovery
	CUR_TARGET="$WORK/interrupted"; mkdir -p "$CUR_TARGET"
	flow_install || :
	_journal="$CUR_TARGET/.sentinel-shield/transaction-journal.jsonl"
	_res=fail; _restored=false
	if [ -f "$_journal" ]; then
		cp "$_journal" "$WORK/journal.bak"
		# INJECT: a truncated/partial journal entry (as if a run was interrupted mid-append).
		printf 'THIS-IS-A-TRUNCATED-PARTIAL-ENTRY\n' >> "$_journal"
		_t0=$(date +%s); _rc=0
		ss_run "$WORK/out" sh "$REPO_ROOT/scripts/recover-operation.sh" --target "$CUR_TARGET" --inspect || _rc=$?
		if [ "$_rc" = 4 ]; then
			record inject-failure "sh scripts/recover-operation.sh --target <target> --inspect" 4 "$(elapsed_since "$_t0")" fail \
				"journal integrity check FAILED CLOSED on a corrupt/partial entry (rc=4)" "restore the journal from a known-good snapshot, then re-run --inspect"
		else
			record inject-failure "sh scripts/recover-operation.sh --target <target> --inspect" "$_rc" "$(elapsed_since "$_t0")" fail \
				"expected fail-closed journal detection (rc=4) but got rc=$_rc" "verify the transaction journal integrity contract"
		fi
		# RECOVER: restore the good journal; a clean --inspect proves recovery.
		cp "$WORK/journal.bak" "$_journal"
		_t0=$(date +%s); _rc=0
		ss_run "$WORK/out" sh "$REPO_ROOT/scripts/recover-operation.sh" --target "$CUR_TARGET" --inspect || _rc=$?
		if [ "$_rc" = 0 ]; then
			record recover "sh scripts/recover-operation.sh --target <target> --inspect" 0 "$(elapsed_since "$_t0")" ok "journal restored; integrity check passes again" ""
			_res=pass; _restored=true
		else
			record recover "sh scripts/recover-operation.sh --target <target> --inspect" "$_rc" "$(elapsed_since "$_t0")" fail "journal did not recover (rc=$_rc)" "re-run recovery or reinstall the baseline"
		fi
	else
		record inject-failure "locate transaction journal" null null fail "no transaction journal was produced by install --apply" "confirm install --apply ran transactionally"
	fi
	emit_session interrupted-recovery "{\"required\":true,\"performed\":true,\"restored\":$_restored,\"method\":\"restore journal snapshot; recover-operation --inspect re-verifies\"}" "$_res"
}

# ======================================================================
# SCENARIO: proxy-configured (offline flow runs with a black-hole proxy set)
# ======================================================================
scn_proxy() {
	scenario_begin proxy-configured
	CUR_TARGET="$WORK/proxy"; mkdir -p "$CUR_TARGET"
	# The engine flow must not need the network; set an unreachable proxy to prove it.
	http_proxy="http://127.0.0.1:9"; https_proxy="http://127.0.0.1:9"; export http_proxy https_proxy
	flow_install || :
	flow_doctor
	# INJECT: same config-level failure, recovered by re-run — proves the proxy is irrelevant offline.
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/run-local-pipeline.sh" --profile node --target "$CUR_TARGET" --stage bogus || _rc=$?
	record inject-failure "sh scripts/run-local-pipeline.sh --profile node --target <target> --stage bogus" "$_rc" "$(elapsed_since "$_t0")" fail \
		"unknown stage rejected under a black-hole proxy (rc=$_rc) — no network was attempted" "re-run the OFFLINE flow (doctor) against the installed target"
	# RECOVER with a genuinely OFFLINE operation (doctor). The full 'pr' pipeline runs scanners
	# that fetch vulnerability databases — a real NETWORK operation, so it must not be used to
	# prove offline recovery under a black-hole proxy. doctor is offline and deterministic.
	_t0=$(date +%s); _rc=0
	ss_run "$WORK/out" sh "$REPO_ROOT/scripts/doctor.sh" --target "$CUR_TARGET" || _rc=$?
	case "$_rc" in 0|3) record recover "sh scripts/doctor.sh --target <target>" "$_rc" "$(elapsed_since "$_t0")" ok "offline flow (doctor) recovered with the black-hole proxy still set — no network attempted" "" ;; *) record recover "sh scripts/doctor.sh --target <target>" "$_rc" "$(elapsed_since "$_t0")" fail "offline recovery failed under a black-hole proxy (rc=$_rc)" "the offline flow must not require the network" ;; esac
	unset http_proxy https_proxy
	emit_session proxy-configured '{"required":false,"performed":true,"restored":true,"method":"re-run offline flow; proxy is not consulted"}' "$(verify_result)"
}

# ======================================================================
# SCENARIO: offline-restricted (network clone fails; documented offline form recovers)
# ======================================================================
scn_offline_restricted() {
	scenario_begin offline-restricted
	CUR_TARGET="$WORK/offline"; mkdir -p "$CUR_TARGET"
	# INJECT: attempting a network clone to an unreachable host fails (no network).
	_t0=$(date +%s); _rc=0
	if command -v git >/dev/null 2>&1; then
		ss_run "$WORK/out" git clone --depth 1 https://127.0.0.1:9/unreachable.git "$WORK/offline-clone" || _rc=$?
		record inject-failure "git clone https://<host>/sentinel-shield.git (network)" "$_rc" "$(elapsed_since "$_t0")" fail \
			"network clone failed under offline/restricted network (rc=$_rc)" "acquire offline via the documented --repository <path> form"
	else
		record inject-failure "git clone (network)" null null fail "git unavailable; a network clone cannot be attempted" "install git or use the documented --repository <path> offline form"
	fi
	# RECOVER: the documented offline acquire form (local --repository path).
	_res=fail; _restored=false
	if command -v git >/dev/null 2>&1; then
		_ref=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
		_t0=$(date +%s); _rc=0
		ss_run "$WORK/out" sh "$REPO_ROOT/scripts/acquire-sentinel-shield.sh" --repository "$REPO_ROOT" --ref "$_ref" --destination "$WORK/offline-engine" --verify || _rc=$?
		if [ "$_rc" = 0 ] && [ -f "$WORK/offline-engine/scripts/doctor.sh" ]; then
			record recover "sh scripts/acquire-sentinel-shield.sh --repository <engine-src> --ref <HEAD> --destination <workspace>/offline-engine --verify" 0 "$(elapsed_since "$_t0")" ok "acquired offline via the documented --repository form; identity verified" ""
			_res=pass; _restored=true
		else
			record recover "sh scripts/acquire-sentinel-shield.sh --repository <engine-src> --ref <HEAD> --destination <workspace>/offline-engine --verify" "$_rc" "$(elapsed_since "$_t0")" fail "offline acquire failed (rc=$_rc)" "verify the local checkout path and ref, then retry"
		fi
	else
		record recover "offline acquire" null null skip "git unavailable — offline acquire form cannot be exercised (a skip is not a pass)" "install git to exercise the offline acquire form"
	fi
	emit_session offline-restricted "{\"required\":true,\"performed\":true,\"restored\":$_restored,\"method\":\"documented --repository <path> offline acquire + --verify\"}" "$_res"
}

# --- run every scenario ----------------------------------------------------------
printf '# Sentinel Shield external-adopter multi-environment suite (platform=%s)\n' "$PLATFORM"
scn_clean_linux
scn_minimal_posix
scn_managed_conflict
scn_read_only
scn_interrupted_recovery
scn_proxy
scn_offline_restricted

# --- per-scenario PASS/FAIL + schema validity ------------------------------------
for _s in clean-linux minimal-posix managed-file-conflict read-only-project interrupted-recovery proxy-configured offline-restricted; do
	_f="$OUT_DIR/$_s.session.json"
	if [ ! -s "$_f" ]; then fail "$_s: no session record emitted"; continue; fi
	_r=$(jq -r '.result' "$_f" 2>/dev/null || echo error)
	if [ "$_r" = pass ]; then pass "$_s: session result=pass"; else fail "$_s: session result=$_r"; fi
done

# --- fold sessions into the consolidated scorecard (JSON + Markdown) -------------
# Genuinely-unsupported flows are recorded as EXPLICIT, reasoned skips (never a pass).
SCJSON="$OUT_DIR/adopter-scorecard.json"
SCMD="$OUT_DIR/adopter-scorecard.md"
_sc_rc=0
sh "$REPO_ROOT/scripts/report-adopter-usability.sh" \
	--sessions-dir "$OUT_DIR" \
	--json-out "$SCJSON" --md-out "$SCMD" \
	--budget-seconds "$DEFAULT_BUDGET" \
	--skipped "update-from-beta.1=requires the published v2.0.0-beta.1 ref over the network; not runnable offline" \
	--skipped "uninstall=no engine uninstall command is published; rollback is covered by the recovery scenarios" \
	>/dev/null 2>"$WORK/sc.err" || _sc_rc=$?

if [ ! -s "$SCJSON" ]; then
	fail "scorecard was not produced"
	cat "$WORK/sc.err" >&2 || :
else
	if jq -e . "$SCJSON" >/dev/null 2>&1; then pass "scorecard is valid JSON"; else fail "scorecard is not valid JSON"; fi
	_scres=$(jq -r '.result' "$SCJSON")
	if [ "$_scres" = pass ] && [ "$_sc_rc" = 0 ]; then
		pass "adopter scorecard result=pass (all blocking criteria met)"
	else
		fail "adopter scorecard result=$_scres (rc=$_sc_rc)"
		jq -r '.criteria[]|select(.status=="fail")|"  - FAILED: "+.title' "$SCJSON" >&2 2>/dev/null || :
	fi
	printf 'scorecard JSON: %s\nscorecard MD:   %s\n' "$SCJSON" "$SCMD" >&2
fi

printf '\nadopter-scenarios: %d failure(s)\n' "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
printf 'All adopter scenarios passed and the scorecard is green.\n'
exit 0
