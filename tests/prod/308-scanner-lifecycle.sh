#!/bin/sh
# Sentinel Shield production test — the shared scanner evidence transaction (#96-#105).
#
# LAYER 1 OF THREE, WRITTEN ONCE.
#
# Ten adapters share one lifecycle. Proving its mechanics per adapter would multiply the same
# assertions ten times and let them drift; proving them here once means an adapter only has to
# demonstrate its own tool semantics (Layer 3) and its conformance row (Layer 2, tests/prod/309).
#
# Everything below drives a MINIMAL probe adapter whose validator is one field, so a rejection is
# always a lifecycle rejection and never a disagreement about a report shape.
#
# THE PROPERTY THAT MATTERS: after any failure, no report may remain that a consumer would read
# as this run's successful result. Stale evidence is therefore quarantined BEFORE execution, not
# cleaned up afterwards -- a killed process never reaches its own cleanup.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/scanner-fake.sh"
# The digest helper the lifecycle itself uses, so the test compares like with like rather than
# reimplementing sha256 and proving only that two implementations agree.
SS_LIB_DIR="$ROOT/scripts/lib"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$ROOT/scripts/lib/normalized-evidence.sh"

assert_precondition "jq is available" command -v jq
assert_precondition "the shared lifecycle exists" test -f "$ROOT/scripts/lib/scanner-transaction.sh"
assert_precondition "the probe adapter exists" test -f "$ROOT/tests/fixtures/scanner-lifecycle/probe-adapter.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT
PROBE="$ROOT/tests/fixtures/scanner-lifecycle/probe-adapter.sh"
OUTREL="reports/raw/probe.json"

# probe_tool <mode> — an executable fake standing in for the scanned tool.
probe_tool() { # <workdir> <mode>
	mkdir -p "$1/bin"
	case "$2" in
	fail)      printf '#!/bin/sh\nprintf "probe: operational failure\\n" >&2\nexit 3\n' > "$1/bin/ss-probe-tool" ;;
	malformed) printf '#!/bin/sh\nprintf "{\\"probe_ok\\":tr"\n' > "$1/bin/ss-probe-tool" ;;
	invalid)   printf '#!/bin/sh\nprintf "{\\"unrelated\\":1}"\n' > "$1/bin/ss-probe-tool" ;;
	empty)     printf '#!/bin/sh\nprintf ""\n' > "$1/bin/ss-probe-tool" ;;
	*)         printf '#!/bin/sh\nprintf "{\\"probe_ok\\":true}"\n' > "$1/bin/ss-probe-tool" ;;
	esac
	chmod +x "$1/bin/ss-probe-tool"
}

# run_probe <case-dir> <tool-mode> [env...] -> populates $CASE for assertions
run_probe() {
	_rp_d="$TMP/$1"; shift
	_rp_tool="$1"; shift
	rm -rf "$_rp_d"; mkdir -p "$_rp_d/proj/reports/raw"
	probe_tool "$_rp_d" "$_rp_tool"
	sf_plant_stale "$_rp_d/proj" "$OUTREL"
	# The adapter's own exit status is CAPTURED, never propagated. Some cases legitimately end
	# non-zero, and letting that escape would kill this suite under `set -e` — silently, after a
	# PASS line, which is precisely the shape #345 exists to prevent.
	RUN_RC=0
	( cd "$_rp_d/proj" || exit 1
	  PATH="$_rp_d/bin:/usr/bin:/bin:/usr/sbin:/sbin"; export PATH
	  for _e in "$@"; do export "${_e?}"; done
	  sh "$PROBE" "$OUTREL" >/dev/null 2>&1 ) || RUN_RC=$?
	CASE="$_rp_d/proj"
	return 0
}
c_report()  { [ -f "$CASE/$OUTREL" ] && printf 'present' || printf 'absent'; }
c_stale()   { sf_stale_survived "$CASE" "$OUTREL" && printf 'SURVIVED' || printf 'gone'; }
c_state()   { sf_state "$CASE" "$OUTREL"; }
c_temp()    { sf_temp_left "$CASE"; }

# ===========================================================================
# 1. STALE EVIDENCE IS REMOVED BEFORE EXECUTION
#
# Every failing path is checked, because the whole point is that the guarantee does not depend on
# reaching a cleanup step: a crash, a rejection and a missing binary must all leave the same
# absence behind.
# ===========================================================================
for _m in fail malformed invalid empty; do
	run_probe "stale-$_m" "$_m"
	assert_equal "stale report does not survive a '$_m' run" "gone" "$(c_stale)"
	assert_equal "no report is left standing after a '$_m' run" "absent" "$(c_report)"
done
run_probe "stale-missing" missing SS_PROBE_MODE=missing-binary
assert_equal "stale report does not survive a missing executor" "gone" "$(c_stale)"
assert_equal "no report is left standing when the executor is missing" "absent" "$(c_report)"

# Stale PROVENANCE is removed too. A surviving sidecar would let a consumer pair last run's
# provenance with this run's absence and call it complete.
assert_false "stale provenance does not survive either" \
	grep -q 'PREVIOUS-PROVENANCE' "$CASE/reports/raw/probe.provenance.json"

# ===========================================================================
# 2. SUCCESS PUBLISHES ONLY AFTER VALIDATION, AND PUBLISHES BOTH FILES
# ===========================================================================
run_probe ok clean
assert_equal "a validated run publishes its report" "present" "$(c_report)"
assert_equal "and records completed-clean" "completed-clean" "$(c_state)"
assert_true "the published report is the tool's output, not the stale one" \
	grep -q 'probe_ok' "$CASE/$OUTREL"
assert_true "provenance is published alongside it" test -f "$CASE/reports/raw/probe.provenance.json"
assert_true "provenance binds the report digest" \
	jq -e '(.report.sha256 | type == "string") and (.report.sha256 | length == 64)' "$CASE/reports/raw/probe.provenance.json"
_d_actual=$(ne_sha256 "$CASE/$OUTREL" 2>/dev/null || printf 'x')
_d_recorded=$(jq -r '.report.sha256' "$CASE/reports/raw/probe.provenance.json" 2>/dev/null || printf 'y')
assert_equal "the recorded digest is the digest of the published report" "$_d_actual" "$_d_recorded"

# ===========================================================================
# 3. NO FAILURE PATH EXPOSES A REPORT AS SUCCESSFUL
#
# The validator rejection case is the important one: the tool exited 0 and produced well-formed
# JSON. Only the tool-specific contract can tell that it is not a report, which is why the
# lifecycle refuses to publish on a validator verdict rather than on an exit status.
# ===========================================================================
run_probe reject invalid
assert_equal "a validator rejection publishes nothing" "absent" "$(c_report)"
assert_equal "and is recorded as an execution error, not a clean scan" "execution-error" "$(c_state)"
run_probe nonzero fail
assert_equal "a non-zero exit publishes nothing" "absent" "$(c_report)"
assert_equal "and is recorded as an execution error" "execution-error" "$(c_state)"
run_probe truncated malformed
assert_equal "truncated output publishes nothing" "absent" "$(c_report)"
run_probe emptyout empty
assert_equal "empty output publishes nothing" "absent" "$(c_report)"
# Publication refused for a non-completed state: even a VALID report is not published when the
# adapter declares a state that is not a completed scan.
run_probe refuse clean SS_PROBE_PUBLISH_AS=refuse
assert_equal "a valid report is NOT published under a non-completed state" "absent" "$(c_report)"

# ===========================================================================
# 4. COMPLETION STATES REMAIN DISTINGUISHABLE
#
# `unavailable` is neither success nor failure. A consumer that cannot tell it from a clean scan
# is the defect this whole batch exists to remove.
# ===========================================================================
run_probe s_clean clean
assert_equal "completed-clean is recorded distinctly" "completed-clean" "$(c_state)"
run_probe s_find clean SS_PROBE_PUBLISH_AS=findings
assert_equal "completed-findings is recorded distinctly" "completed-findings" "$(c_state)"
run_probe s_nt clean SS_PROBE_PUBLISH_AS=no-targets
assert_equal "completed-no-targets is recorded distinctly" "completed-no-targets" "$(c_state)"
run_probe s_un missing SS_PROBE_MODE=missing-binary
assert_equal "unavailable is recorded distinctly, and is not clean" "unavailable" "$(c_state)"
run_probe s_err fail
assert_equal "execution-error is recorded distinctly" "execution-error" "$(c_state)"

# ===========================================================================
# 5. PRIVATE WORKSPACE AND OWNED CLEANUP
# ===========================================================================
for _c in ok reject nonzero truncated s_un; do
	CASE="$TMP/$_c/proj"
	assert_equal "$_c: no workspace is left behind" "0" "$(c_temp)"
done

# The workspace is unpredictable and private. Two runs must not reuse one name, and the directory
# must be 0700 while it exists -- a scanner's partial output is not world-readable.
_w1=$(sh -c '. '"$ROOT"'/scripts/lib/filesystem-safety.sh; fs_mktemp_dir "'"$TMP"'"' 2>/dev/null || printf '')
_w2=$(sh -c '. '"$ROOT"'/scripts/lib/filesystem-safety.sh; fs_mktemp_dir "'"$TMP"'"' 2>/dev/null || printf '')
assert_true "two workspaces are distinct — the name is unpredictable" test "$_w1" != "$_w2"
_mode=$(ls -ld "$_w1" 2>/dev/null | cut -c1-10)
assert_equal "the workspace is private (0700)" "drwx------" "$_mode"
rm -rf "$_w1" "$_w2" 2>/dev/null || :

# ===========================================================================
# 6. CLEANUP NEVER FALLS BACK TO UNSAFE DELETION
#
# fs_safe_rmtree is the only sanctioned rm -rf: it refuses a target not contained in the owned
# root. The lifecycle must honour that refusal and warn, NOT delete anyway -- a fallback would
# turn a containment guard into a suggestion.
# ===========================================================================
mkdir -p "$TMP/unowned/keepme"; printf 'DO-NOT-DELETE' > "$TMP/unowned/keepme/file"
_rc=0
sh -c '. '"$ROOT"'/scripts/lib/sentinel-shield-common.sh
. '"$ROOT"'/scripts/lib/filesystem-safety.sh
fs_safe_rmtree "'"$TMP"'/owned" "'"$TMP"'/unowned/keepme"' >/dev/null 2>&1 || _rc=$?
assert_true "fs_safe_rmtree refuses a path outside its owned root" test "$_rc" -ne 0
assert_true "and the unowned path is untouched" test -f "$TMP/unowned/keepme/file"
assert_false "the lifecycle contains no unguarded rm -rf fallback" \
	grep -qE 'rm -rf .*ST_WORK' "$ROOT/scripts/lib/scanner-transaction.sh"

# ===========================================================================
# 7. EXECUTOR SELECTION CANNOT ESCAPE TO A HOST-INSTALLED SCANNER
#
# Found the hard way: an early probe measured the real `syft` installed on this machine instead
# of the fixture, and reported a pass that proved nothing about the adapter.
# ===========================================================================
run_probe escape missing SS_PROBE_MODE=missing-binary
assert_equal "with no fake on PATH the adapter reports unavailable, never a host binary result" \
	"unavailable" "$(c_state)"
_hostcount=$(command -v ss-probe-tool >/dev/null 2>&1 && printf '1' || printf '0')
assert_equal "the probe tool name is not a real host binary — the isolation is meaningful" "0" "$_hostcount"

assert_summary "scanner-lifecycle (shared transaction mechanics, proven once for ten adapters)"
