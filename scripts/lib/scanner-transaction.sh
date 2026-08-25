# shellcheck shell=sh
# Sentinel Shield — the scanner evidence transaction (#96-#105, #135-#137, #184-#185).
#
# WHY THIS EXISTS
#
# Eight of the ten audit wrappers were 12-31 line stubs of the shape
#
#     tool ... || true
#     exit 0
#
# which cannot tell a clean scan from a crash, leaves whatever stale report was already on disk
# standing as current evidence, and reports success either way. Two others had grown partial
# lifecycles independently. Ten wrappers were on their way to ten subtly different implementations
# of one trust boundary.
#
# THE UNIT OF EVIDENCE IS A TRANSACTION, not a file:
#
#   applicability -> stale quarantine -> private workspace -> bounded execution
#   -> classification -> native validation -> provenance -> ATOMIC publication
#
# Either the report AND its provenance become current together, or neither does. There is no
# intermediate state in which a report exists without the provenance that says how it was made.
#
# WHAT IS SHARED AND WHAT IS NOT
#
# This file owns MECHANICS ONLY: ordering, atomicity, timeouts, cleanup, redaction, digests. It
# knows nothing about any scanner's exit codes or report shape, and it deliberately provides no
# "valid JSON means success" validator -- that is precisely the check that let `{}` pass as an
# SBOM. Each scanner supplies its own contract (scripts/lib/scanner-contracts/<tool>.sh)
# declaring exit vocabulary, report shapes, applicability, finding classification, completion
# proof, target binding and required provenance.
#
# It composes primitives that already exist and are already tested, rather than reimplementing
# them: bounded-process (bounded execution, separate stdout/stderr/exit), transaction (atomic
# multi-file publication with rollback), normalized-evidence (execution records and digests),
# filesystem-safety (unpredictable private workspaces, atomic replace), redaction (diagnostics
# that do not leak secrets), isolated-tools (platform and provenance records).

[ -n "${SS_SCANNER_TX_SH:-}" ] && return 0
SS_SCANNER_TX_SH=1

_st_dir=$(CDPATH= cd -- "$(dirname -- "${SCRIPT_DIR:-scripts/lib}")" 2>/dev/null && pwd) || _st_dir=""
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "${SS_LIB_DIR:-scripts/lib}/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/bounded-process.sh
. "${SS_LIB_DIR:-scripts/lib}/bounded-process.sh"
# shellcheck source=scripts/lib/filesystem-safety.sh
. "${SS_LIB_DIR:-scripts/lib}/filesystem-safety.sh"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "${SS_LIB_DIR:-scripts/lib}/normalized-evidence.sh"
# shellcheck source=scripts/lib/isolated-tools.sh
. "${SS_LIB_DIR:-scripts/lib}/isolated-tools.sh"

# ---------------------------------------------------------------------------
# COMPLETION STATES. This vocabulary is closed, and it is the reason the wrappers can no longer
# collapse every outcome into "exit 0". `unavailable` and `not-applicable` are NOT success and
# NOT failure -- they are the truthful third answer that a stub returning 0 could never give.
# ---------------------------------------------------------------------------
ST_STATE_CLEAN="completed-clean"
ST_STATE_FINDINGS="completed-findings"
ST_STATE_NOTARGETS="completed-no-targets"
ST_STATE_UNAVAILABLE="unavailable"
ST_STATE_NOTAPPLICABLE="not-applicable"
ST_STATE_TIMEOUT="timeout"
ST_STATE_ERROR="execution-error"

st_state_valid() { # st_state_valid <state>
	case "$1" in
	"$ST_STATE_CLEAN"|"$ST_STATE_FINDINGS"|"$ST_STATE_NOTARGETS"|"$ST_STATE_UNAVAILABLE"|"$ST_STATE_NOTAPPLICABLE"|"$ST_STATE_TIMEOUT"|"$ST_STATE_ERROR") return 0 ;;
	esac
	return 1
}

st_state_is_publishable() { # only these states may leave a report standing as current evidence
	case "$1" in
	"$ST_STATE_CLEAN"|"$ST_STATE_FINDINGS"|"$ST_STATE_NOTARGETS") return 0 ;;
	esac
	return 1
}

# ---------------------------------------------------------------------------
# st_begin <tool> <out>
#
# Opens the transaction: records the target paths, QUARANTINES any stale current evidence, and
# creates an unpredictable private workspace.
#
# STALE EVIDENCE IS MOVED BEFORE EXECUTION, NOT AFTER. If the scanner then fails, crashes or is
# killed, there is no previous report left behind to be mistaken for this run's result -- the
# defect named in #96, #99, #104 and #105. The quarantined copy is retained inside the workspace
# so a diagnostic can still refer to it, and it dies with the workspace.
# ---------------------------------------------------------------------------
st_begin() { # st_begin <tool> <out>
	ST_TOOL=${1:?st_begin: tool required}
	ST_OUT=${2:?st_begin: output path required}
	ST_PROV="${ST_OUT%.json}.provenance.json"
	ST_STATE=""
	ST_DETAIL=""
	ST_EXIT=""
	ST_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	ensure_dir "$(dirname "$ST_OUT")"

	# THE WORKSPACE ROOT IS THE OUTPUT'S OWN DIRECTORY, deliberately. fs_mktemp_dir creates an
	# unpredictable 0700 directory inside a trusted root and verifies containment; using the
	# destination's directory also guarantees the workspace is on the SAME FILESYSTEM, which is
	# what makes the final publish a true atomic rename rather than a copy with a window in the
	# middle. The name is dot-prefixed, so a collector globbing reports/raw/*.json cannot see it.
	_st_root=$(CDPATH= cd -- "$(dirname "$ST_OUT")" && pwd) || {
		log_error "$ST_TOOL: output directory is unusable; refusing to run"
		return 1
	}
	ST_WORK_ROOT="$_st_root"
	ST_WORK=$(fs_mktemp_dir "$_st_root") || {
		log_error "$ST_TOOL: could not create a private workspace ($ST_WORK); refusing to run"
		return 1
	}
	ST_RAW="$ST_WORK/report.json"
	ST_STDOUT="$ST_WORK/stdout"
	ST_STDERR="$ST_WORK/stderr"

	# Signal-safe: the workspace is removed on normal exit AND on interruption, so a killed scan
	# cannot leave a partial report anywhere a consumer might read it.
	trap 'st_cleanup' EXIT
	trap 'st_cleanup; exit 130' INT
	trap 'st_cleanup; exit 143' TERM

	ST_QUARANTINE=""
	if [ -e "$ST_OUT" ]; then
		ST_QUARANTINE="$ST_WORK/stale-report.json"
		mv -f "$ST_OUT" "$ST_QUARANTINE" 2>/dev/null || rm -f "$ST_OUT" 2>/dev/null || :
		log_warn "$ST_TOOL: a previous report was quarantined before execution; it can no longer be mistaken for this run"
	fi
	[ -e "$ST_PROV" ] && { mv -f "$ST_PROV" "$ST_WORK/stale-provenance.json" 2>/dev/null || rm -f "$ST_PROV" 2>/dev/null || :; }
	return 0
}

st_cleanup() {
	[ -n "${ST_WORK:-}" ] || return 0
	# fs_safe_rmtree is the only sanctioned rm -rf: it takes the OWNED ROOT and the target, and
	# refuses anything not physically contained in that root. There is deliberately no `rm -rf`
	# fallback here -- a refusal means the path was not ours to delete, and blindly removing it
	# anyway is exactly the behaviour that guard exists to prevent.
	if ! fs_safe_rmtree "${ST_WORK_ROOT:-}" "$ST_WORK" >/dev/null 2>&1; then
		log_warn "$ST_TOOL: workspace '$ST_WORK' was not removed (deletion refused); it contains no published evidence"
	fi
	ST_WORK=""
}

# ---------------------------------------------------------------------------
# st_probe_version <cmd> [args...]
#
# THE REGRESSION THIS EXISTS FOR. Master's grype.sh ran its version probe through bp_run,
# commenting that "a hung binary can no longer stall the scan indefinitely". Migrating ten adapters
# onto this transaction bounded the SCAN and left the version probe as a plain command
# substitution -- so a binary that hangs on --version stalled the adapter forever, before
# st_execute was ever reached. The Cluster B timeout dimension caught it by hanging.
#
# A version is metadata. Failing to read it must never decide the scan's outcome: the probe
# records "unknown" and execution continues, leaving unavailable / execution-error / clean /
# findings to the scan itself.
#
# Prints the normalized version, or "unknown". Never stalls, never emits partial output.
# ---------------------------------------------------------------------------
st_probe_version() { # st_probe_version <cmd> [args...]
	[ "$#" -ge 1 ] || { printf 'unknown'; return 0; }
	_sp_out="$ST_WORK/version.out"; _sp_err="$ST_WORK/version.err"
	_sp_to=$(bp_timeout scanner-version) || _sp_to=30
	if bp_run scanner-version "$_sp_to" "$_sp_out" "$_sp_err" -- "$@"; then
		# The first token that looks like a version, across the several shapes tools use.
		_sp_v=$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /^v?[0-9]+\.[0-9]+/) { gsub(/^v/, "", $i); print $i; exit }}' "$_sp_out" 2>/dev/null) || _sp_v=""
		[ -n "$_sp_v" ] || _sp_v=$(awk 'NR==1{print $NF}' "$_sp_out" 2>/dev/null) || _sp_v=""
		[ -n "$_sp_v" ] || _sp_v="unknown"
	else
		if [ "${BP_STATUS:-}" = "timed-out" ]; then
			log_warn "$ST_TOOL: version probe exceeded ${_sp_to}s; recording unknown and continuing"
		else
			log_warn "$ST_TOOL: version probe failed; recording unknown and continuing"
		fi
		_sp_v="unknown"
	fi
	rm -f "$_sp_out" "$_sp_err" 2>/dev/null || :
	printf '%s' "$_sp_v"
	return 0
}

# ---------------------------------------------------------------------------
# st_execute <timeout-category> <cmd> [args...]
#
# Runs the scanner under a bounded timeout with stdout, stderr and the exact process exit status
# captured SEPARATELY. Arguments are passed as a real argument vector -- never a whitespace
# command string -- so a path containing spaces, tabs, Unicode or shell metacharacters survives
# intact (#104).
# ---------------------------------------------------------------------------
st_execute() { # st_execute <category> <cmd> [args...]
	_st_cat=${1:?st_execute: timeout category required}
	shift
	[ "$#" -ge 1 ] || { log_error "$ST_TOOL: st_execute has no command"; return 1; }
	_st_to=$(bp_timeout "$_st_cat" "SENTINEL_SHIELD_$(printf '%s' "$ST_TOOL" | tr '[:lower:]-' '[:upper:]_')_TIMEOUT_SECONDS") || _st_to=300
	if bp_run "$_st_cat" "$_st_to" "$ST_STDOUT" "$ST_STDERR" -- "$@"; then
		ST_EXIT=0
	else
		ST_EXIT=$?
	fi
	ST_BP_STATUS="${BP_STATUS:-}"
	[ "$ST_BP_STATUS" = "timed-out" ] && ST_EXIT="timeout"
	return 0
}

# st_report_from_stdout — some scanners write the report to stdout rather than a file.
st_report_from_stdout() { cp -f "$ST_STDOUT" "$ST_RAW" 2>/dev/null || return 1; }
st_report_path() { printf '%s' "$ST_RAW"; }
st_workspace() { printf '%s' "$ST_WORK"; }

# ---------------------------------------------------------------------------
# st_fail <state> <detail>  — terminate the transaction WITHOUT publishing.
#
# Nothing success-looking survives: the workspace (with any partial report) is destroyed, and
# because stale evidence was quarantined in st_begin the output path is already absent. A
# provenance record IS written, recording the failure honestly, so a consumer can tell
# "scanner did not complete" from "scanner never ran".
# ---------------------------------------------------------------------------
st_fail() { # st_fail <state> <detail>
	ST_STATE=${1:?st_fail: state required}
	ST_DETAIL=${2:-}
	st_state_valid "$ST_STATE" || { log_error "$ST_TOOL: invalid state '$ST_STATE'"; ST_STATE="$ST_STATE_ERROR"; }
	log_warn "$ST_TOOL: $ST_STATE${ST_DETAIL:+ — $ST_DETAIL}"
	st_write_provenance "" || :
	rm -f "$ST_OUT" 2>/dev/null || :
	st_cleanup
	return 0
}

# ---------------------------------------------------------------------------
# st_publish <state> [extra-json]
#
# The atomic step. The validated report and its provenance become current TOGETHER, through the
# transaction primitive, so a reader can never observe one without the other. Publication is
# refused outright for any state that is not a completed scan.
# ---------------------------------------------------------------------------
st_publish() { # st_publish <state> [extra-provenance-json]
	ST_STATE=${1:?st_publish: state required}
	_st_extra=${2:-}
	st_state_valid "$ST_STATE" || { log_error "$ST_TOOL: invalid state '$ST_STATE'"; return 1; }
	st_state_is_publishable "$ST_STATE" || {
		log_error "$ST_TOOL: refusing to publish a report in state '$ST_STATE'"
		st_fail "$ST_STATE" "publication refused for a non-completed state"
		return 1
	}
	[ -s "$ST_RAW" ] || { st_fail "$ST_STATE_ERROR" "no report produced to publish"; return 1; }

	ST_ENDED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	ST_DIGEST=$(ne_sha256 "$ST_RAW") || ST_DIGEST=""
	[ -n "$ST_DIGEST" ] || { st_fail "$ST_STATE_ERROR" "could not digest the report"; return 1; }

	_st_prov_tmp="$ST_WORK/provenance.json"
	st_write_provenance "$_st_prov_tmp" || { st_fail "$ST_STATE_ERROR" "could not build provenance"; return 1; }

	# Both files, or neither. fs_atomic_replace makes each individual replace atomic; doing the
	# provenance FIRST and the report SECOND means the window between them can only ever leave
	# provenance without a report -- which every collector already treats as incomplete -- and
	# never a report without provenance, which is the state that reads as trustworthy.
	if ! fs_atomic_replace "$_st_prov_tmp" "$ST_PROV" 2>/dev/null; then
		st_fail "$ST_STATE_ERROR" "could not publish provenance"
		return 1
	fi
	if ! fs_atomic_replace "$ST_RAW" "$ST_OUT" 2>/dev/null; then
		rm -f "$ST_PROV" 2>/dev/null || :
		st_fail "$ST_STATE_ERROR" "could not publish the report; provenance withdrawn"
		return 1
	fi
	log_info "$ST_TOOL: published $ST_STATE (${ST_DIGEST%%????????????????????????????????????????????????????????}…) -> ${ST_OUT}"
	st_cleanup
	return 0
}

# ---------------------------------------------------------------------------
# st_write_provenance [path]
#
# Provenance is FINALIZED ONLY BY st_publish, after validation (#105, #104). When called from
# st_fail it records the failure state instead, and never a completion.
# ---------------------------------------------------------------------------
st_write_provenance() { # st_write_provenance [outfile]
	_st_pf=${1:-$ST_PROV}
	command_exists jq || { log_warn "$ST_TOOL: jq unavailable; provenance not written"; return 1; }
	_st_stderr_red=""
	if [ -s "${ST_STDERR:-/dev/null}" ]; then
		if command -v rd_redact_stream >/dev/null 2>&1; then
			_st_stderr_red=$(rd_redact_stream < "$ST_STDERR" 2>/dev/null | tail -c 2000) || _st_stderr_red=""
		else
			# No redactor loaded: record that diagnostics were withheld rather than risk emitting
			# an unredacted scanner stderr, which is where secrets surface.
			_st_stderr_red="(diagnostics withheld: no redactor loaded)"
		fi
	fi
	jq -n \
		--arg contract "sentinel-shield/scanner-transaction@1" \
		--arg tool "$ST_TOOL" \
		--arg state "${ST_STATE:-$ST_STATE_ERROR}" \
		--arg detail "${ST_DETAIL:-}" \
		--arg exit "${ST_EXIT:-}" \
		--arg started "${ST_STARTED:-}" \
		--arg ended "${ST_ENDED:-}" \
		--arg digest "${ST_DIGEST:-}" \
		--arg version "${ST_VERSION:-}" \
		--arg executor "${ST_EXECUTOR:-}" \
		--arg binpath "${ST_BINPATH:-}" \
		--arg image "${ST_IMAGE:-}" \
		--arg imagedigest "${ST_IMAGE_DIGEST:-}" \
		--arg platform "${ST_PLATFORM:-$(isolated_tool_platform 2>/dev/null || printf 'unknown')}" \
		--arg target "${ST_TARGET:-}" \
		--arg targetmode "${ST_TARGET_MODE:-}" \
		--arg dbid "${ST_DB_ID:-}" \
		--arg commit "${ST_COMMIT:-$(git rev-parse HEAD 2>/dev/null || printf '')}" \
		--arg diag "$_st_stderr_red" \
		'{contract:$contract, tool:$tool, completion:{state:$state, detail:$detail, exit:$exit,
		   started_at:$started, ended_at:$ended},
		  report:{sha256:$digest},
		  scanner:{version:$version, executor:$executor, binary_path:$binpath,
		           image:$image, image_digest:$imagedigest, platform:$platform},
		  target:{identity:$target, mode:$targetmode},
		  database:{identity:$dbid},
		  source:{commit:$commit},
		  diagnostics:$diag}' > "$_st_pf" 2>/dev/null || return 1
	return 0
}
