#!/bin/sh
# Sentinel Shield production test — machine-readable command-result envelope
# (Agent 05: external-adopter usability + machine-readable output).
#
# Proves the OPT-IN `--output json` contract across the CLI:
#   (1) each patched command, invoked with `--output json`, emits ONE envelope
#       object on STDOUT that conforms to schemas/command-result.schema.json
#       (jq required-keys + status/exit_category enums), and nothing else on stdout;
#   (2) `--output json` does NOT change the command's human output or exit code
#       (the underlying run is byte-for-byte identical; the human text is merely
#       forwarded to STDERR and the exit code is preserved);
#   (3) the envelope redacts secrets and absolute local paths (HOME -> ~, the
#       run's --target root -> <target>, secret shapes masked).
#
# Hermetic + offline: uses mktemp fixtures and only FAST command paths (dry-runs
# and invalid-input exits), never the network and never the slow release gates.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCHEMA="$ROOT/schemas/command-result.schema.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for the output-contract test but is absent\n'; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssoc)
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- (0) the schema itself is present and jq-valid --------------------------------
if [ -f "$SCHEMA" ] && jq -e . "$SCHEMA" >/dev/null 2>&1; then
	pass "(0) command-result.schema.json present and valid JSON"
else
	fail "(0) command-result.schema.json missing or not valid JSON"
fi

# assert_envelope <label> <file> — structural validation of one envelope object
# against schemas/command-result.schema.json (required keys + enum constraints).
assert_envelope() {
	_lbl="$1"; _f="$2"
	if ! jq -e . "$_f" >/dev/null 2>&1; then
		fail "$_lbl: stdout is not a single valid JSON object"
		return
	fi
	if jq -e '
		. as $r
		| (($r.command | type) == "string") and (($r.command | length) > 0)
		and (($r.version | type) == "string") and (($r.version | length) > 0)
		and ((["ok","warn","error"] | index($r.status)) != null)
		and ((["success","warnings","invalid_input","requirements_unmet","execution_error","not_ready","findings"] | index($r.exit_category)) != null)
		and (($r.reason_codes | type) == "array") and (($r.reason_codes | length) > 0)
		and (($r.warnings | type) == "array")
		and (($r.artifacts | type) == "array")
		and (($r.next_actions | type) == "array")
	' "$_f" >/dev/null 2>&1; then
		pass "$_lbl: envelope conforms (required keys + status/exit_category enums)"
	else
		fail "$_lbl: envelope does NOT conform to command-result.schema.json"
		jq -c . "$_f" 2>/dev/null | sed 's/^/       got: /' || true
	fi
}

# run_case <label> <cmd-path> -- <args...> :
#   Runs the command WITHOUT the flag (plain) and WITH `--output json` (envelope),
#   then asserts: envelope conforms; the plain exit code equals the envelope exit
#   code; and the plain human output (stdout THEN stderr) equals the human text the
#   envelope run forwards to STDERR (proving the human output is unchanged).
run_case() {
	_lbl="$1"; shift
	_cmd="$1"; shift
	[ "$1" = "--" ] && shift
	_pout="$WORK/${_lbl}.p.out"; _perr="$WORK/${_lbl}.p.err"
	_eout="$WORK/${_lbl}.e.out"; _eerr="$WORK/${_lbl}.e.err"

	_prc=0; sh "$_cmd" "$@" >"$_pout" 2>"$_perr" || _prc=$?
	_erc=0; sh "$_cmd" "$@" --output json >"$_eout" 2>"$_eerr" || _erc=$?

	assert_envelope "$_lbl" "$_eout"

	if [ "$_prc" = "$_erc" ]; then
		pass "$_lbl: exit code unchanged by --output json (exit $_prc)"
	else
		fail "$_lbl: exit code changed (plain=$_prc envelope=$_erc)"
	fi

	# Human output must be unchanged: the wrapper forwards the child's stdout then
	# its stderr to the real STDERR, so (plain stdout + plain stderr) == envelope stderr.
	cat "$_pout" "$_perr" > "$WORK/${_lbl}.human"
	if diff -q "$WORK/${_lbl}.human" "$_eerr" >/dev/null 2>&1; then
		pass "$_lbl: human output unchanged (forwarded verbatim to STDERR)"
	else
		fail "$_lbl: human output changed under --output json"
		diff "$WORK/${_lbl}.human" "$_eerr" 2>/dev/null | head -6 | sed 's/^/       /' || true
	fi

	# STDOUT under --output json must be ONLY the envelope (exactly one JSON value).
	if [ "$(jq -s 'length' "$_eout" 2>/dev/null)" = "1" ]; then
		pass "$_lbl: stdout carries exactly one JSON object (machine-readable)"
	else
		fail "$_lbl: stdout is not exactly one JSON object"
	fi
}

# --- fixtures -----------------------------------------------------------------
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
PROJ="$WORK/proj"; mkdir -p "$PROJ"

# --- (1..7) each patched command, FAST deterministic path ------------------------
# doctor: healthy-ish empty target -> exits 0/1 quickly.
run_case doctor "$ROOT/scripts/doctor.sh" -- --target "$EMPTY" --quiet

# install-baseline: dry-run (no --apply) -> exit 0.
run_case install-baseline "$ROOT/scripts/install-baseline.sh" -- --target "$PROJ" --profile laravel

# sync-baseline: no .sentinel-shield present -> fast invalid-input exit 2.
run_case sync-baseline "$ROOT/scripts/sync-baseline.sh" -- --target "$EMPTY"

# plan-upgrade: read-only plan -> exit 0.
run_case plan-upgrade "$ROOT/scripts/plan-upgrade.sh" -- --from 1.8.0 --to 2.0.0 --profile laravel

# bootstrap-profile-tools: dry-run plan (default) -> exit 0.
run_case bootstrap-profile-tools "$ROOT/scripts/bootstrap-profile-tools.sh" -- --profile laravel --target "$PROJ"

# run-local-pipeline: missing --profile -> fast invalid-input exit 2.
run_case run-local-pipeline "$ROOT/scripts/run-local-pipeline.sh" -- --target "$PROJ" --stage pr

# check-release-readiness: missing --version -> fast invalid-input exit 2
# (never runs the slow self-test / evidence gates).
run_case check-release-readiness "$ROOT/scripts/check-release-readiness.sh" -- --stage alpha

# --- (8) reconciliation: plan-upgrade's legacy `--format json` is unchanged ------
if sh "$ROOT/scripts/plan-upgrade.sh" --from 1.8.0 --to 2.0.0 --profile laravel --format json 2>/dev/null \
	| jq -e '.sentinel_shield.from == "1.8.0" and (.command? == null)' >/dev/null 2>&1; then
	pass "(8) plan-upgrade --format json still emits the RAW plan (backward-compatible)"
else
	fail "(8) plan-upgrade --format json no longer emits the raw plan"
fi
# And plan-upgrade's legacy `--output <path>` file write still works.
if sh "$ROOT/scripts/plan-upgrade.sh" --from 1.8.0 --to 2.0.0 --profile laravel --format json --output "$WORK/legacy-report.json" >/dev/null 2>&1 \
	&& [ -f "$WORK/legacy-report.json" ] && jq -e '.profile == "laravel"' "$WORK/legacy-report.json" >/dev/null 2>&1; then
	pass "(8) plan-upgrade --output <path> still writes the report file (backward-compatible)"
else
	fail "(8) plan-upgrade --output <path> no longer writes the report file"
fi

# --- (9) redaction: absolute --target root never leaks into the envelope ----------
# doctor prints the absolute target; the envelope must relativize it to <target>.
sh "$ROOT/scripts/doctor.sh" --target "$PROJ" --output json >"$WORK/redact.json" 2>/dev/null || true
if jq -e . "$WORK/redact.json" >/dev/null 2>&1; then
	if grep -Fq "$PROJ" "$WORK/redact.json"; then
		fail "(9) envelope leaked the absolute --target path"
	else
		pass "(9) envelope does not leak the absolute --target path (relativized)"
	fi
else
	fail "(9) redaction case: envelope was not valid JSON"
fi

# --- (10) redaction unit test: HOME, target root, and secret shapes are masked ----
# shellcheck source=scripts/lib/output-contract.sh
. "$ROOT/scripts/lib/output-contract.sh"
OC_HOME="/home/adopter"; OC_TARGET_ROOT="/var/tmp/consumer/proj"; export OC_HOME OC_TARGET_ROOT
_red=$(printf 'home=/home/adopter/.ssh target=/var/tmp/consumer/proj/reports key AKIAIOSFODNN7EXAMPLE tok NVD_API_TOKEN=deadbeef1234567890 end\n' | oc_redact)
_ok=1
case "$_red" in *"/home/adopter"*) _ok=0 ;; esac
case "$_red" in *"/var/tmp/consumer/proj"*) _ok=0 ;; esac
case "$_red" in *"AKIAIOSFODNN7EXAMPLE"*) _ok=0 ;; esac
case "$_red" in *"deadbeef1234567890"*) _ok=0 ;; esac
case "$_red" in *"~"*) : ;; *) _ok=0 ;; esac
case "$_red" in *"<target>"*) : ;; *) _ok=0 ;; esac
if [ "$_ok" = 1 ]; then
	pass "(10) oc_redact masks HOME, --target root, and secret shapes"
else
	fail "(10) oc_redact did NOT fully redact: $_red"
fi

# --- verdict ---------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
	printf '\n230-output-contract: all checks passed\n'
	exit 0
fi
printf '\n230-output-contract: %d check(s) failed\n' "$FAILS"
exit 1
