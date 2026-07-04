#!/bin/sh
# Sentinel Shield production test — process-TREE termination via process-group isolation
# (NN=255). Complements 250 (which asserts bounding/JSON/audit) by proving the PRIMARY
# containment is PROCESS-GROUP isolation, NOT descendant enumeration (pgrep). Every hang
# fixture is a plain shell that sleeps — no real daemons. Absent tools (GNU timeout,
# gtimeout, pgrep) are simulated by shadowing them out of PATH via a sandbox bin dir.
#
# Required coverage (task list):
#   (1) GNU timeout absent           (6) double-fork / reparent fixture
#   (2) gtimeout absent              (7) several nested descendants
#   (3) pgrep absent                 (8) forced KILL (TERM ignored -> KILL)
#   (4) child ignores TERM           (9) ordinary successful command
#   (5) parent exits, child continues(10) ordinary nonzero command
# Plus: isolation/descendant_cleanup/timeout_status/no_orphans reach the JSON and are
# honest (no_orphans NEVER claimed without isolation); REQUIRE_ISOLATION fails closed.
#
# A skip is not a pass: every assertion checks a specific value / exit code.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB_COMMON="$ROOT/scripts/lib/sentinel-shield-common.sh"
LIB_BP="$ROOT/scripts/lib/bounded-process.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required for this suite" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

export SENTINEL_SHIELD_PROCESS_KILL_GRACE_SECONDS=1

# shellcheck source=/dev/null
. "$LIB_COMMON"
# shellcheck source=/dev/null
. "$LIB_BP"

OUTF="$WORK/out"; ERRF="$WORK/err"

# --- sandbox PATH builder ----------------------------------------------------
# make_sandbox <dir> <space-separated exclusions> — populate <dir> with symlinks to the
# real tools the library + fixtures need, OMITTING any excluded name (to simulate its
# absence). Only tools that actually resolve on the current PATH are linked.
BASE_TOOLS="sh dash bash sleep cat printf date basename dirname mktemp rm find wc tr mkdir chmod ps pgrep pkill kill env sed grep head tail sort ln touch jq expr id uname"
make_sandbox() {
	_sb="$1"; _excl=" $2 "
	mkdir -p "$_sb"
	for _t in $BASE_TOOLS; do
		case "$_excl" in *" $_t "*) continue ;; esac
		_p=$(command -v "$_t" 2>/dev/null || true)
		[ -n "$_p" ] && ln -sf "$_p" "$_sb/$_t" 2>/dev/null || true
	done
	unset _sb _excl _t _p
}

alive() { kill -0 "$1" 2>/dev/null; }
reap_if_alive() { alive "$1" && kill -KILL "$1" 2>/dev/null || true; }

# run_with_path <sandbox_path> <bp_run args...> — invoke bp_run with PATH set to the
# sandbox, then RESTORE PATH. (A variable assignment prefixed on a FUNCTION call may
# persist after the function returns — POSIX leaves it unspecified — so we save/restore
# explicitly to keep later assertions on the real PATH.) BP_* globals are set in this
# same shell, so no subshell is used.
run_with_path() {
	_rwp_old="$PATH"; _rwp_sb="$1"; shift
	PATH="$_rwp_sb"; export PATH
	_rwp_rc=0
	bp_run "$@" || _rwp_rc=$?
	PATH="$_rwp_old"; export PATH
	unset _rwp_old _rwp_sb
	return "$_rwp_rc"
}

# --- fixtures ----------------------------------------------------------------
FAST="$WORK/fast.sh";  printf '#!/bin/sh\nprintf "ok\\n"\nexit 0\n' > "$FAST"; chmod +x "$FAST"
NZ="$WORK/nz.sh";      printf '#!/bin/sh\nprintf "boom\\n" >&2\nexit 7\n' > "$NZ"; chmod +x "$NZ"

# single spawned child (records its pid in $SS_CHILDPID)
SPAWN="$WORK/spawn.sh"
cat > "$SPAWN" <<'EOF'
#!/bin/sh
sleep 300 &
echo $! > "$SS_CHILDPID"
while true; do sleep 1; done
EOF
chmod +x "$SPAWN"

# parent exits 0 immediately, leaving a running child behind (final-sweep guarantee)
ORPHANER="$WORK/orphaner.sh"
cat > "$ORPHANER" <<'EOF'
#!/bin/sh
sleep 300 &
echo $! > "$SS_CHILDPID"
exit 0
EOF
chmod +x "$ORPHANER"

# double-fork / reparent: an intermediate child spawns a grandchild then exits, so the
# grandchild reparents to init but REMAINS in the process group (no setsid).
DFORK="$WORK/dfork.sh"
cat > "$DFORK" <<'EOF'
#!/bin/sh
sh -c 'sleep 300 & echo $! > "$SS_CHILDPID"; exit 0' &
while true; do sleep 1; done
EOF
chmod +x "$DFORK"

# several nested descendants: l1 -> l2 -> l3, each records its deepest sleeper pid.
NESTED="$WORK/nested.sh"
cat > "$NESTED" <<'EOF'
#!/bin/sh
l3() { sleep 300 & echo "$!" >> "$SS_CHILDPID"; while true; do sleep 1; done; }
l2() { l3 & echo "$!" >> "$SS_CHILDPID"; while true; do sleep 1; done; }
l2 & echo "$!" >> "$SS_CHILDPID"
while true; do sleep 1; done
EOF
chmod +x "$NESTED"

# ignores TERM (records that TERM was delivered), forcing escalation to KILL.
IGNTERM="$WORK/ignterm.sh"
cat > "$IGNTERM" <<'EOF'
#!/bin/sh
trap 'echo trapped >> "$SS_MARK"' TERM
i=0
while [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
EOF
chmod +x "$IGNTERM"

# ============================================================================
# (1)+(2) GNU timeout AND gtimeout absent -> portable watchdog engages & bounds
# ============================================================================
SB="$WORK/sb-notimeout"
make_sandbox "$SB" "timeout gtimeout"
if PATH="$SB" command -v timeout >/dev/null 2>&1; then
	fail "(1) sandbox still exposes 'timeout' (cannot simulate absence)"
else
	pass "(1) GNU timeout absent in sandbox PATH"
fi
if PATH="$SB" command -v gtimeout >/dev/null 2>&1; then
	fail "(2) sandbox still exposes 'gtimeout' (cannot simulate absence)"
else
	pass "(2) gtimeout absent in sandbox PATH"
fi
# With neither present, bp_uses_portable must select the portable path (save/restore
# PATH — bp_uses_portable is a function, so a prefix assignment could persist).
_savedpath="$PATH"; PATH="$SB"; export PATH
if bp_uses_portable; then _upsel=1; else _upsel=0; fi
PATH="$_savedpath"; export PATH; unset _savedpath
if [ "$_upsel" = 1 ]; then
	pass "(1/2) with timeout+gtimeout absent, portable watchdog is selected"
else
	fail "(1/2) portable path NOT selected despite timeout+gtimeout absent"
fi
# ...and a hanging child is still bounded and reaped via process-group isolation.
CPF="$WORK/c1"; export SS_CHILDPID="$CPF"
rc=0
run_with_path "$SB" generic 1 "$OUTF" "$ERRF" -- "$SPAWN" || rc=$?
CH=$(cat "$CPF" 2>/dev/null || echo "")
sleep 1
if [ "$rc" -eq 124 ] && [ "$BP_STATUS" = timed-out ] && [ "$BP_ISOLATION" = process-group ]; then
	pass "(1/2) portable path bounds a hanging child (timed-out, isolation=process-group)"
else
	fail "(1/2) portable path did not bound as expected: rc=$rc status=$BP_STATUS iso=$BP_ISOLATION"
fi
if [ -n "$CH" ] && ! alive "$CH"; then
	pass "(1/2) spawned child reaped with no GNU timeout available"
else
	reap_if_alive "$CH"
	fail "(1/2) spawned child $CH survived without GNU timeout"
fi

# ============================================================================
# (3) pgrep absent -> process-group isolation STILL reaps the whole tree
#     (proves descendant enumeration is only SECONDARY, not the primary guarantee)
# ============================================================================
SBNP="$WORK/sb-nopgrep"
make_sandbox "$SBNP" "timeout gtimeout pgrep pkill"
if PATH="$SBNP" command -v pgrep >/dev/null 2>&1; then
	fail "(3) sandbox still exposes 'pgrep' (cannot simulate absence)"
else
	pass "(3) pgrep absent in sandbox PATH"
fi
CPF="$WORK/c3"; export SS_CHILDPID="$CPF"
rc=0
run_with_path "$SBNP" generic 1 "$OUTF" "$ERRF" -- "$SPAWN" || rc=$?
CH=$(cat "$CPF" 2>/dev/null || echo "")
sleep 1
if [ "$rc" -eq 124 ] && [ "$BP_STATUS" = timed-out ] && [ "$BP_ISOLATION" = process-group ] \
	&& [ "$BP_NO_ORPHANS" = 1 ] && [ "$BP_DESCENDANT_CLEANUP" = process-group-only ]; then
	pass "(3) pgrep absent: isolation=process-group, no_orphans=1, cleanup=process-group-only"
else
	fail "(3) pgrep-absent classification wrong: rc=$rc status=$BP_STATUS iso=$BP_ISOLATION noorph=$BP_NO_ORPHANS cleanup=$BP_DESCENDANT_CLEANUP"
fi
if [ -n "$CH" ] && ! alive "$CH"; then
	pass "(3) child reaped by GROUP kill with pgrep absent (primary containment, not enumeration)"
else
	reap_if_alive "$CH"
	fail "(3) child $CH survived when pgrep was absent — containment wrongly depends on enumeration"
fi

# ============================================================================
# (4) child ignores TERM   +   (8) forced KILL
# ============================================================================
MK="$WORK/mark4"
rc=0
SS_MARK="$MK" bp_run generic 1 "$OUTF" "$ERRF" -- "$IGNTERM" || rc=$?
if [ "$rc" -eq 124 ] && [ "$BP_STATUS" = timed-out ] && [ -z "$BP_EXIT_CODE" ]; then
	pass "(4) TERM-ignoring command -> timed-out (rc 124, exit_code null)"
else
	fail "(4) TERM-ignoring command misclassified: rc=$rc status=$BP_STATUS exit=$BP_EXIT_CODE"
fi
if [ -s "$MK" ]; then
	pass "(8) TERM was delivered first, then KILL forced the exit (escalation exercised)"
else
	fail "(8) TERM never delivered — forced-KILL escalation path not exercised"
fi

# ============================================================================
# (5) parent exits 0 while a child keeps running -> FINAL SWEEP reaps it,
#     and the run is still classified SUCCESS (exit preserved), no orphan left.
# ============================================================================
CPF="$WORK/c5"
rc=0
SS_CHILDPID="$CPF" bp_run generic 5 "$OUTF" "$ERRF" -- "$ORPHANER" || rc=$?
CH=$(cat "$CPF" 2>/dev/null || echo "")
sleep 1
if [ "$rc" -eq 0 ] && [ "$BP_STATUS" = success ] && [ "$BP_EXIT_CODE" = 0 ]; then
	pass "(5) fast-exiting parent -> success, exit 0 preserved"
else
	fail "(5) parent-exit classification wrong: rc=$rc status=$BP_STATUS exit=$BP_EXIT_CODE"
fi
if [ -n "$CH" ] && ! alive "$CH"; then
	pass "(5) child that outlived its parent was reaped by the final group sweep (no orphan)"
else
	reap_if_alive "$CH"
	fail "(5) orphan $CH survived after the parent exited — final containment sweep failed"
fi

# ============================================================================
# (6) double-fork / reparent -> reparented grandchild still reaped via the group
# ============================================================================
CPF="$WORK/c6"
rc=0
SS_CHILDPID="$CPF" bp_run generic 1 "$OUTF" "$ERRF" -- "$DFORK" || rc=$?
CH=$(cat "$CPF" 2>/dev/null || echo "")
sleep 1
if [ "$BP_STATUS" = timed-out ] && [ -n "$CH" ] && ! alive "$CH"; then
	pass "(6) double-forked / reparented grandchild $CH reaped via process group"
else
	reap_if_alive "$CH"
	fail "(6) double-fork grandchild survived or misclassified: status=$BP_STATUS child=$CH alive=$(alive "$CH" && echo yes || echo no)"
fi

# ============================================================================
# (7) several nested descendants -> ALL reaped
# ============================================================================
CPF="$WORK/c7"
rc=0
SS_CHILDPID="$CPF" bp_run generic 1 "$OUTF" "$ERRF" -- "$NESTED" || rc=$?
sleep 1
NLEFT=0; NTOTAL=0
if [ -f "$CPF" ]; then
	while IFS= read -r pid; do
		[ -n "$pid" ] || continue
		NTOTAL=$((NTOTAL + 1))
		if alive "$pid"; then NLEFT=$((NLEFT + 1)); reap_if_alive "$pid"; fi
	done < "$CPF"
fi
if [ "$BP_STATUS" = timed-out ] && [ "$NTOTAL" -ge 2 ] && [ "$NLEFT" -eq 0 ]; then
	pass "(7) all $NTOTAL nested descendants reaped (none survived)"
else
	fail "(7) nested descendants not fully reaped: status=$BP_STATUS total=$NTOTAL survived=$NLEFT"
fi

# ============================================================================
# (9) ordinary successful command   +   (10) ordinary nonzero command
# ============================================================================
rc=0; bp_run generic 5 "$OUTF" "$ERRF" -- "$FAST" || rc=$?
if [ "$rc" -eq 0 ] && [ "$BP_STATUS" = success ] && [ "$BP_EXIT_CODE" = 0 ] \
	&& [ "$(cat "$OUTF")" = ok ] && [ "$BP_TIMEOUT_STATUS" = within-timeout ]; then
	pass "(9) ordinary success -> success, exit 0, stdout captured, timeout_status within-timeout"
else
	fail "(9) ordinary success misclassified: rc=$rc status=$BP_STATUS exit=$BP_EXIT_CODE out='$(cat "$OUTF")' tstat=$BP_TIMEOUT_STATUS"
fi
rc=0; bp_run generic 5 "$OUTF" "$ERRF" -- "$NZ" || rc=$?
if [ "$rc" -eq 7 ] && [ "$BP_STATUS" = failed ] && [ "$BP_EXIT_CODE" = 7 ] && [ "$(cat "$ERRF")" = boom ]; then
	pass "(10) ordinary nonzero -> failed, exit 7 preserved, stderr captured"
else
	fail "(10) ordinary nonzero misclassified: rc=$rc status=$BP_STATUS exit=$BP_EXIT_CODE err='$(cat "$ERRF")'"
fi

# ============================================================================
# JSON contract: new fields present, honest, and schema-valid
# ============================================================================
# success run -> isolation present, no_orphans true, timeout_status within-timeout
bp_run generic 5 "$WORK/jo" "$WORK/je" -- "$FAST" || true
J="$WORK/ok.json"; bp_result_json > "$J"
if bp_validate_result "$J" >/dev/null 2>&1 \
	&& [ "$(jq -r '.isolation' "$J")" = process-group ] \
	&& [ "$(jq -r '.no_orphans' "$J")" = true ] \
	&& [ "$(jq -r '.descendant_cleanup' "$J")" = complete ] \
	&& [ "$(jq -r '.timeout_status' "$J")" = within-timeout ]; then
	pass "JSON success: isolation/no_orphans/descendant_cleanup/timeout_status present, honest, schema-valid"
else
	fail "JSON success fields wrong: $(jq -c '{isolation,no_orphans,descendant_cleanup,timeout_status}' "$J" 2>/dev/null)"
fi
# timeout run -> timeout_status timed-out, still isolation=process-group + no_orphans
rc=0; bp_run generic 1 "$WORK/jo2" "$WORK/je2" -- "$IGNTERM" || rc=$?
J2="$WORK/to.json"; bp_result_json > "$J2"
if bp_validate_result "$J2" >/dev/null 2>&1 \
	&& [ "$(jq -r '.timeout_status' "$J2")" = timed-out ] \
	&& [ "$(jq -r '.timed_out' "$J2")" = true ] \
	&& [ "$(jq -r '.isolation' "$J2")" = process-group ]; then
	pass "JSON timeout: timeout_status=timed-out, timed_out=true, isolation=process-group, schema-valid"
else
	fail "JSON timeout fields wrong: $(jq -c '{timeout_status,timed_out,isolation,no_orphans}' "$J2" 2>/dev/null)"
fi

# --- honesty guards: validator must REJECT over-claims (fail closed) ----------
BAD1="$WORK/bad1.json"
jq '.no_orphans = true | .isolation = "none"' "$J" > "$BAD1"
if bp_validate_result "$BAD1" >/dev/null 2>&1; then
	fail "validator ACCEPTED no_orphans=true with isolation=none (over-claim not caught)"
else
	pass "validator rejects no_orphans=true without process-group isolation (never over-claims)"
fi
BAD2="$WORK/bad2.json"
jq '.timeout_status = "timed-out" | .timed_out = false' "$J" > "$BAD2"
if bp_validate_result "$BAD2" >/dev/null 2>&1; then
	fail "validator ACCEPTED timeout_status/timed_out mismatch"
else
	pass "validator rejects timeout_status/timed_out inconsistency"
fi

# ============================================================================
# FAILURE INJECTION: process-group isolation UNAVAILABLE (shadow job-control probe)
#   - default: run proceeds but reports isolation=none, no_orphans=0 (never over-claim),
#     and a hang is still bounded via secondary descendant enumeration.
#   - REQUIRE_ISOLATION=1: FAIL CLOSED — command is NOT launched.
# ============================================================================
# Override the job-control probe to force the "no job control" branch deterministically
# (the real one is restored at the end of this block). Invoked indirectly by bp_run.
# shellcheck disable=SC2329
bp_job_control_supported() { return 1; }
export SENTINEL_SHIELD_BP_FORCE_PORTABLE=1

# On Linux, setsid(1) would ESTABLISH isolation even without job control, so run these
# unavailability cases under a sandbox PATH that ALSO excludes setsid (BASE_TOOLS carries
# no setsid). Combined with the bp_job_control_supported override above, isolation is
# deterministically unavailable on every platform. pgrep IS present, so the default case
# still bounds the hang via secondary descendant enumeration.
SBI="$WORK/sb-noiso"
make_sandbox "$SBI" ""

# default (no strict flag): honest degradation, still bounded (pgrep present here).
CPF="$WORK/c_noiso"
rc=0
SS_CHILDPID="$CPF" run_with_path "$SBI" generic 1 "$OUTF" "$ERRF" -- "$SPAWN" || rc=$?
CH=$(cat "$CPF" 2>/dev/null || echo "")
sleep 1
if [ "$rc" -eq 124 ] && [ "$BP_ISOLATION" = none ] && [ "$BP_NO_ORPHANS" = 0 ] \
	&& [ "$BP_DESCENDANT_CLEANUP" = descendant-enumeration ]; then
	pass "iso-unavailable (default): reports isolation=none, no_orphans=0, cleanup=descendant-enumeration (honest, still bounded)"
else
	fail "iso-unavailable default classification wrong: rc=$rc iso=$BP_ISOLATION noorph=$BP_NO_ORPHANS cleanup=$BP_DESCENDANT_CLEANUP"
fi
reap_if_alive "$CH"

# strict: REQUIRE_ISOLATION=1 must fail closed and NOT launch the command.
LAUNCHMARK="$WORK/launched"
rm -f "$LAUNCHMARK"
MARKER_CMD="$WORK/marker.sh"
printf '#!/bin/sh\ntouch "%s"\nsleep 300\n' "$LAUNCHMARK" > "$MARKER_CMD"; chmod +x "$MARKER_CMD"
rc=0
SENTINEL_SHIELD_BP_REQUIRE_ISOLATION=1 run_with_path "$SBI" generic 5 "$OUTF" "$ERRF" -- "$MARKER_CMD" || rc=$?
if [ "$rc" -eq 2 ] && [ "$BP_STATUS" = isolation-unavailable ] && [ ! -f "$LAUNCHMARK" ]; then
	pass "REQUIRE_ISOLATION=1 with no job control: FAIL CLOSED (rc 2, status isolation-unavailable, command NOT launched)"
else
	fail "REQUIRE_ISOLATION strict path wrong: rc=$rc status=$BP_STATUS launched=$( [ -f "$LAUNCHMARK" ] && echo yes || echo no )"
fi

# restore the real probe (this process exits next, but keep state honest).
# shellcheck disable=SC2329
bp_job_control_supported() { ( set -m 2>/dev/null; case $- in *m*) exit 0 ;; *) exit 1 ;; esac ); }
unset SENTINEL_SHIELD_BP_FORCE_PORTABLE

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
exit 0
