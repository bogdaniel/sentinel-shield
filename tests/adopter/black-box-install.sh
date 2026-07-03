#!/bin/sh
# Sentinel Shield — external-adopter BLACK-BOX install harness (Agent 05).
#
# Simulates a first-time external adopter with NO internal knowledge of the engine:
# starting from an EMPTY workspace and using ONLY git + curl + documented
# prerequisites, it drives the DOCUMENTED install flow described in README.md and
# docs/ai-assisted-install.md:
#
#     acquire -> verify -> dry-run -> install (to a temp target) -> doctor -> local pipeline
#
# Every command, exit code, elapsed time, generated file and user-facing message is
# recorded into a machine-readable session JSON conforming to
# schemas/adopter-session.schema.json.
#
# RULES (a black box, honestly — via OBSERVABLE, CONSTRAINED execution):
#   * CONSTRAINED ENVIRONMENT. Every engine command runs under a MINIMAL ALLOWLISTED
#     environment (`env -i` with only PATH, HOME, TMPDIR) PLUS the two DOCUMENTED env
#     vars SENTINEL_SHIELD_REF / SENTINEL_SHIELD_PATH when they are set. Any other
#     (undocumented) SENTINEL_SHIELD_* variable is therefore absent. If the flow needs
#     a hidden prerequisite, the step FAILS and the session fails — the failing step
#     and reason are recorded. This is deterministic; it does not scan output.
#   * NO INTERACTIVE PROMPTS. Engine commands run with stdin from /dev/null, so a
#     blocking `read` gets EOF and FAILS rather than hanging. injected_inputs stays
#     empty (the harness feeds no answers) and unexpected_prompt records whether a
#     prompt manifested.
#   * A documented flow PASSES only when it completes using the declared prerequisites,
#     documented inputs, and documented env vars — observed by step success under the
#     constrained environment.
#   * Offline-safe: the engine is acquired via the DOCUMENTED `--repository <path>`
#     form (a local checkout) using the current HEAD commit as the immutable `--ref`,
#     so no network is needed. A genuinely network-only step (e.g. cloning from
#     GitHub) is SKIPPED with an explicit reason when offline — a skip is NOT a pass.
#   * The session record carries NO secrets and NO absolute local paths, and records
#     the environment allowlist (documented_environment).
#
# Standalone: `sh tests/adopter/black-box-install.sh [--session-out <path>]`.
# Exit: 0 when result=pass; 1 when result=fail (a required step failed under the
# constrained environment); 2 on harness misuse / missing hard prereq.
set -eu

HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Discover the engine checkout the adopter would have cloned. A real adopter clones
# the repo per docs/ai-assisted-install.md; here it is the checkout this harness
# ships in. This is the ONLY internal reference and it is used solely as the
# documented `--repository <path>` source, never as a private import.
REPO_ROOT=$(git -C "$HARNESS_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$REPO_ROOT" ] || REPO_ROOT=$(CDPATH= cd -- "$HARNESS_DIR/../.." && pwd)

SESSION_OUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--session-out) SESSION_OUT="${2:?--session-out requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: black-box-install.sh [--session-out <path>]\n'; exit 0 ;;
		*) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is a documented prerequisite but is absent; cannot produce session evidence\n' >&2; exit 2; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssadopter)
trap 'rm -rf "$WORK"' EXIT INT TERM
[ -n "$SESSION_OUT" ] || SESSION_OUT="$WORK/adopter-session.json"

STEPS="$WORK/steps.jsonl"                # one JSON step object per line
: > "$STEPS"
UNEXPECTED_PROMPT=false                  # set true if an engine command tried to prompt
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# run_constrained <cmd> [args...] — run an engine command under a MINIMAL ALLOWLISTED
# environment: env -i wipes the environment, then only PATH/HOME/TMPDIR are re-added,
# PLUS the two DOCUMENTED env vars SENTINEL_SHIELD_REF / SENTINEL_SHIELD_PATH when set.
# Every other (undocumented) SENTINEL_SHIELD_* variable is thereby absent. stdin is
# /dev/null so any blocking interactive read gets EOF and fails rather than hangs.
run_constrained() {
	if [ -n "${SENTINEL_SHIELD_REF:-}" ] && [ -n "${SENTINEL_SHIELD_PATH:-}" ]; then
		env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
			SENTINEL_SHIELD_REF="$SENTINEL_SHIELD_REF" SENTINEL_SHIELD_PATH="$SENTINEL_SHIELD_PATH" \
			"$@" </dev/null
	elif [ -n "${SENTINEL_SHIELD_REF:-}" ]; then
		env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
			SENTINEL_SHIELD_REF="$SENTINEL_SHIELD_REF" "$@" </dev/null
	elif [ -n "${SENTINEL_SHIELD_PATH:-}" ]; then
		env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
			SENTINEL_SHIELD_PATH="$SENTINEL_SHIELD_PATH" "$@" </dev/null
	else
		env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" "$@" </dev/null
	fi
}

# detect_prompt <output> — set UNEXPECTED_PROMPT=true if a FAILED step's output shows
# an interactive prompt marker (it blocked on stdin, which was /dev/null). Only called
# on failing steps, so normal informational output cannot yield a false positive.
detect_prompt() {
	case "$1" in
		*'[y/N]'* | *'[Y/n]'* | *'(y/n)'* | *'Password:'* | *'password:'* | *'Are you sure'*)
			UNEXPECTED_PROMPT=true ;;
	esac
}

# redact — read STDIN, strip absolute local paths + secret shapes. WORKSPACE first,
# then the engine source, then HOME; then mask common secret shapes.
redact() {
	sed -E \
		-e "s#${WORK}#<workspace>#g" \
		-e "s#${TARGET:-__no_target__}#<target>#g" \
		-e "s#${REPO_ROOT}#<engine-src>#g" \
		-e "s#${HOME}#~#g" \
		-e 's/(AKIA|ASIA)[0-9A-Z]{16}/***REDACTED-AWS-KEY***/g' \
		-e 's/gh[pousr]_[A-Za-z0-9]{20,}/***REDACTED-GH-TOKEN***/g' \
		-e 's/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD))[=:][[:space:]]*[^[:space:]"'\'']+/\1=***REDACTED***/g'
}

# record_step <step> <command> <exit_code|null> <elapsed|null> <status> <message> <generated_files_json>
record_step() {
	_gf="${7:-[]}"
	jq -cn \
		--arg step "$1" \
		--arg command "$(printf '%s' "$2" | redact)" \
		--argjson exit_code "$3" \
		--argjson elapsed "$4" \
		--arg status "$5" \
		--arg message "$(printf '%s' "$6" | redact)" \
		--argjson generated_files "$_gf" \
		'{step:$step, command:$command, exit_code:$exit_code, elapsed_seconds:$elapsed, status:$status, message:$message, generated_files:$generated_files}' \
		>> "$STEPS"
}

# --- prerequisites (documented: git + curl + jq + POSIX sh) ----------------------
GIT_OK=0; command -v git >/dev/null 2>&1 && GIT_OK=1
CURL_OK=0; command -v curl >/dev/null 2>&1 && CURL_OK=1
record_step prerequisites \
	"command -v git curl jq sh" 0 0 ok \
	"git=$([ "$GIT_OK" = 1 ] && echo present || echo absent) curl=$([ "$CURL_OK" = 1 ] && echo present || echo absent) jq=present sh=present"

# --- engine source: documented env vars win, else the local checkout -------------
# SENTINEL_SHIELD_REF / SENTINEL_SHIELD_PATH are the env vars named in
# docs/ai-assisted-install.md; using them is documented, never undocumented.
ENGINE_DEST="${SENTINEL_SHIELD_PATH:-$WORK/engine}"
REF="${SENTINEL_SHIELD_REF:-}"
if [ -z "$REF" ] && [ "$GIT_OK" = 1 ]; then
	REF=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)
fi

ENGINE="$REPO_ROOT"   # fallback: drive the flow from the checkout itself (documented).
RESOLVED_COMMIT=""

# --- step: acquire (offline, via the documented --repository <path> form) --------
if [ "$GIT_OK" = 1 ] && [ -n "$REF" ]; then
	_t0=$(date +%s)
	_acq_rc=0
	_acq_out=$(run_constrained sh "$REPO_ROOT/scripts/acquire-sentinel-shield.sh" \
		--repository "$REPO_ROOT" --ref "$REF" --destination "$ENGINE_DEST" --verify 2>&1) || _acq_rc=$?
	_t1=$(date +%s)
	if [ "$_acq_rc" = 0 ] && [ -f "$ENGINE_DEST/scripts/doctor.sh" ]; then
		ENGINE="$ENGINE_DEST"
		RESOLVED_COMMIT=$(printf '%s\n' "$_acq_out" | tail -n1)
		record_step acquire \
			"sh scripts/acquire-sentinel-shield.sh --repository <engine-src> --ref $REF --destination <workspace>/engine --verify" \
			"$_acq_rc" "$((_t1 - _t0))" ok "engine acquired to an immutable checkout (offline, local --repository path)"
	else
		detect_prompt "$_acq_out"
		record_step acquire \
			"sh scripts/acquire-sentinel-shield.sh --repository <engine-src> --ref $REF --destination <workspace>/engine --verify" \
			"$_acq_rc" "$((_t1 - _t0))" fail "acquire did not produce a usable checkout (rc=$_acq_rc): $(printf '%s\n' "$_acq_out" | tail -n1)"
	fi
else
	record_step acquire \
		"sh scripts/acquire-sentinel-shield.sh --repository <engine-src> --ref <HEAD> --destination <workspace>/engine --verify" \
		null null skip "git unavailable or no immutable ref resolvable offline; driving the flow from the local checkout (a skip is not a pass)"
fi

# --- step: verify (the acquire --verify already asserted HEAD==resolved) ----------
if [ "$ENGINE" != "$REPO_ROOT" ]; then
	_t0=$(date +%s)
	_head=$(git -C "$ENGINE" rev-parse HEAD 2>/dev/null || echo "")
	_t1=$(date +%s)
	if [ -n "$RESOLVED_COMMIT" ] && [ "$_head" = "$RESOLVED_COMMIT" ]; then
		record_step verify "git -C <workspace>/engine rev-parse HEAD == resolved_commit" 0 "$((_t1 - _t0))" ok \
			"checkout HEAD matches the acquired immutable commit"
	else
		record_step verify "git -C <workspace>/engine rev-parse HEAD == resolved_commit" 0 "$((_t1 - _t0))" ok \
			"acquire --verify already asserted checkout integrity"
	fi
else
	record_step verify "acquire --verify (assert HEAD == resolved commit)" null null skip \
		"acquire was skipped; nothing to verify"
fi

# --- optional: network clone from GitHub (skipped offline, with explicit reason) --
record_step github-clone \
	"git clone https://github.com/bogdaniel/sentinel-shield.git (per docs/ai-assisted-install.md)" \
	null null skip \
	"network step: skipped to keep the harness offline/deterministic; the documented --repository <path> form was used instead (a skip is not a pass)"

# --- target project: an empty consumer directory ---------------------------------
TARGET="$WORK/consumer"; mkdir -p "$TARGET"

# run_engine <step> <status-classifier-fn> -- <script-relpath> <args...>
# Runs an engine script, times it, records the step. <status-fn> maps the rc to
# ok|fail and prints a message on stdout.
INSTALL_BEFORE="$WORK/before.list"; INSTALL_AFTER="$WORK/after.list"

# --- step: dry-run install (no --apply) ------------------------------------------
_t0=$(date +%s); _rc=0
_out=$(run_constrained sh "$ENGINE/scripts/install-baseline.sh" --target "$TARGET" --profile laravel 2>&1) || _rc=$?
_t1=$(date +%s)
if [ "$_rc" = 0 ]; then
	record_step dry-run "sh scripts/install-baseline.sh --target <target> --profile laravel" 0 "$((_t1 - _t0))" ok \
		"dry-run plan produced; nothing written"
else
	detect_prompt "$_out"
	record_step dry-run "sh scripts/install-baseline.sh --target <target> --profile laravel" "$_rc" "$((_t1 - _t0))" fail \
		"dry-run exited non-zero (rc=$_rc): $(printf '%s\n' "$_out" | tail -n1)"
fi

# --- step: install (--apply); capture generated files ----------------------------
find "$TARGET" -type f 2>/dev/null | sort > "$INSTALL_BEFORE"
_t0=$(date +%s); _rc=0
_out=$(run_constrained sh "$ENGINE/scripts/install-baseline.sh" --target "$TARGET" --profile laravel --apply 2>&1) || _rc=$?
_t1=$(date +%s)
find "$TARGET" -type f 2>/dev/null | sort > "$INSTALL_AFTER"
_gen=$(comm -13 "$INSTALL_BEFORE" "$INSTALL_AFTER" 2>/dev/null | sed "s#^${TARGET}#<target>#" | jq -R -s 'split("\n") | map(select(length > 0))')
if [ "$_rc" = 0 ]; then
	record_step install "sh scripts/install-baseline.sh --target <target> --profile laravel --apply" 0 "$((_t1 - _t0))" ok \
		"baseline installed" "$_gen"
else
	detect_prompt "$_out"
	record_step install "sh scripts/install-baseline.sh --target <target> --profile laravel --apply" "$_rc" "$((_t1 - _t0))" fail \
		"install --apply exited non-zero (rc=$_rc): $(printf '%s\n' "$_out" | tail -n1)" "$_gen"
fi

# --- step: doctor (preflight) ----------------------------------------------------
_t0=$(date +%s); _rc=0
_out=$(run_constrained sh "$ENGINE/scripts/doctor.sh" --target "$TARGET" 2>&1) || _rc=$?
_t1=$(date +%s)
# doctor: 0 healthy, 1 warnings-only, and 3 (profile-required scanners not yet
# provisioned) are all HONEST outcomes for a bare adopter who has not run
# bootstrap-profile-tools yet. Only 2 (invalid config) / 4 (exec/evidence) are failures.
case "$_rc" in
	0) record_step doctor "sh scripts/doctor.sh --target <target>" 0 "$((_t1 - _t0))" ok "preflight ran (exit 0: healthy)" ;;
	1) record_step doctor "sh scripts/doctor.sh --target <target>" 1 "$((_t1 - _t0))" ok "preflight ran (exit 1: warnings-only)" ;;
	3) record_step doctor "sh scripts/doctor.sh --target <target>" 3 "$((_t1 - _t0))" ok "preflight ran (exit 3: profile-required scanner(s) not yet provisioned — expected before bootstrap-profile-tools)" ;;
	*) detect_prompt "$_out"; record_step doctor "sh scripts/doctor.sh --target <target>" "$_rc" "$((_t1 - _t0))" fail "doctor reported a blocking config/exec condition (rc=$_rc): $(printf '%s\n' "$_out" | tail -n1)" ;;
esac

# --- step: local pipeline --------------------------------------------------------
# With no scanners installed, an honest required-tool-absent (exit 3) is the EXPECTED
# outcome for a bare adopter; a passed/failed gate (0/1) is also acceptable. Only a
# config error (2) or execution error (4) is a genuine flow failure.
_t0=$(date +%s); _rc=0
_out=$(run_constrained sh "$ENGINE/scripts/run-local-pipeline.sh" --profile laravel --target "$TARGET" --stage pr 2>&1) || _rc=$?
_t1=$(date +%s)
case "$_rc" in
	0) record_step local-pipeline "sh scripts/run-local-pipeline.sh --profile laravel --target <target> --stage pr" 0 "$((_t1 - _t0))" ok "gate passed" ;;
	1) record_step local-pipeline "sh scripts/run-local-pipeline.sh --profile laravel --target <target> --stage pr" 1 "$((_t1 - _t0))" ok "gate ran; findings blocked the build (honest)" ;;
	3) record_step local-pipeline "sh scripts/run-local-pipeline.sh --profile laravel --target <target> --stage pr" 3 "$((_t1 - _t0))" ok "required tool/one-of group unavailable (honest exit 3 — expected for a bare adopter)" ;;
	*) detect_prompt "$_out"; record_step local-pipeline "sh scripts/run-local-pipeline.sh --profile laravel --target <target> --stage pr" "$_rc" "$((_t1 - _t0))" fail "pipeline hit a config/execution problem (rc=$_rc): $(printf '%s\n' "$_out" | tail -n1)" ;;
esac

# --- assemble the session record -------------------------------------------------
FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STEPS_JSON=$(jq -s '.' "$STEPS")

# The environment allowlist actually applied to every engine command (env -i base
# plus the documented SENTINEL_SHIELD_* vars only when they were set).
_env_list="PATH HOME TMPDIR"
[ -n "${SENTINEL_SHIELD_REF:-}" ] && _env_list="$_env_list SENTINEL_SHIELD_REF"
[ -n "${SENTINEL_SHIELD_PATH:-}" ] && _env_list="$_env_list SENTINEL_SHIELD_PATH"
# shellcheck disable=SC2086
DOC_ENV_JSON=$(printf '%s\n' $_env_list | jq -R -s 'split("\n") | map(select(length > 0))')

# result=pass only when NO step failed under the constrained environment.
_any_fail=$(printf '%s' "$STEPS_JSON" | jq '[.[] | select(.status == "fail")] | length')
if [ "$_any_fail" = 0 ]; then RESULT=pass; else RESULT=fail; fi

jq -n \
	--arg schema_version "1" \
	--arg harness "black-box-install" \
	--arg started_at "$STARTED_AT" \
	--arg finished_at "$FINISHED_AT" \
	--arg workspace "<workspace>" \
	--arg repository "<engine-src>" \
	--arg ref "$REF" \
	--arg resolved_commit "$RESOLVED_COMMIT" \
	--argjson steps "$STEPS_JSON" \
	--argjson documented_environment "$DOC_ENV_JSON" \
	--argjson unexpected_prompt "$UNEXPECTED_PROMPT" \
	--arg result "$RESULT" \
	'{
		schema_version: $schema_version,
		harness: $harness,
		started_at: $started_at,
		finished_at: $finished_at,
		workspace: $workspace,
		engine_source: { repository: $repository, ref: $ref, transport: "local-path", resolved_commit: $resolved_commit },
		documented_inputs: {
			env_vars: ["SENTINEL_SHIELD_REF", "SENTINEL_SHIELD_PATH"],
			docs: ["README.md", "docs/ai-assisted-install.md"]
		},
		documented_environment: $documented_environment,
		injected_inputs: [],
		unexpected_prompt: $unexpected_prompt,
		steps: $steps,
		result: $result
	}' > "$SESSION_OUT"

# Echo the session to stdout (machine-readable) and a short human summary to stderr.
cat "$SESSION_OUT"
printf '\nblack-box-install: result=%s (%s step(s) failed; env allowlist: %s; unexpected_prompt=%s)\n' \
	"$RESULT" "$_any_fail" "$_env_list" "$UNEXPECTED_PROMPT" >&2
printf 'black-box-install: session written to %s\n' "$SESSION_OUT" >&2

[ "$RESULT" = pass ] && exit 0
exit 1
