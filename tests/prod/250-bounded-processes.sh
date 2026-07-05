#!/bin/sh
# Sentinel Shield production test — bounded external processes (NN=250).
#
# Verifies scripts/lib/bounded-process.sh bounds EVERY external process it wraps and
# never hangs indefinitely, and that the timeout state reaches the machine-readable
# output and the security audit report. All hang cases use a FAKE hanging executable
# fixture (a shell that sleeps) — nothing here depends on a real docker daemon, gh,
# or a real scanner. The portable watchdog path is FORCED so the TERM->KILL escalation
# and child-reaping are exercised deterministically on every platform.
#
# Covered (per the task's required list):
#   (1) completes before its timeout            (6) gh api hangs -> bounded
#   (2) exits non-zero (exit code preserved)    (7) scanner version probe hangs -> bounded
#   (3) ignores TERM, needs KILL                (8) zero/negative/nonnumeric/excessive rejected
#   (4) spawns a child (no orphan left)         (9) internal temp files removed
#   (5) docker probe to an unresponsive endpoint(10) timeout state reaches JSON + audit report
#
# A skip is not a pass: every assertion checks a specific value / exit code.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB_COMMON="$ROOT/scripts/lib/sentinel-shield-common.sh"
LIB_BP="$ROOT/scripts/lib/bounded-process.sh"
SCHEMA="$ROOT/schemas/bounded-command-result.schema.json"
AUDIT="$ROOT/scripts/audits/tool-provenance-audit.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required for this suite" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# Deterministic watchdog behaviour everywhere: force the portable path and use short,
# tight bounds so hang cases finish in ~2s.
export SENTINEL_SHIELD_BP_FORCE_PORTABLE=1
export SENTINEL_SHIELD_PROCESS_KILL_GRACE_SECONDS=1

# Load the library into THIS shell so we can call bp_run and read the BP_* globals.
# shellcheck source=/dev/null
. "$LIB_COMMON"
# shellcheck source=/dev/null
. "$LIB_BP"

OUTF="$WORK/out"; ERRF="$WORK/err"

# --- (0) schema is present and jq-valid --------------------------------------
if [ -f "$SCHEMA" ] && jq -e . "$SCHEMA" >/dev/null 2>&1; then
	pass "bounded-command-result schema present and jq-valid"
else
	fail "bounded-command-result schema missing or not jq-valid: $SCHEMA"
fi

# --- (1) completes before timeout --------------------------------------------
FAST="$WORK/fast.sh"
printf '#!/bin/sh\nprintf "done\\n"\nexit 0\n' > "$FAST"; chmod +x "$FAST"
rc=0; bp_run generic 5 "$OUTF" "$ERRF" -- "$FAST" || rc=$?
if [ "$rc" -eq 0 ] && [ "$BP_STATUS" = success ] && [ "$BP_EXIT_CODE" = 0 ]; then
	pass "fast command -> success, exit 0, returned 0"
else
	fail "fast command misclassified: rc=$rc status=$BP_STATUS exit=$BP_EXIT_CODE"
fi
if [ "$(cat "$OUTF")" = "done" ]; then pass "stdout captured for a completed command"; else fail "stdout not captured (got '$(cat "$OUTF")')"; fi

# --- (2) exits non-zero, exit code preserved ---------------------------------
FAILEXE="$WORK/fail.sh"
printf '#!/bin/sh\nprintf "boom\\n" >&2\nexit 7\n' > "$FAILEXE"; chmod +x "$FAILEXE"
rc=0; bp_run generic 5 "$OUTF" "$ERRF" -- "$FAILEXE" || rc=$?
if [ "$rc" -eq 7 ] && [ "$BP_STATUS" = failed ] && [ "$BP_EXIT_CODE" = 7 ]; then
	pass "non-zero command -> failed, exit code 7 preserved"
else
	fail "non-zero command misclassified: rc=$rc status=$BP_STATUS exit=$BP_EXIT_CODE"
fi
if [ "$(cat "$ERRF")" = "boom" ]; then pass "stderr captured for a failed command"; else fail "stderr not captured (got '$(cat "$ERRF")')"; fi

# --- (3) ignores TERM, needs KILL --------------------------------------------
MARKER="$WORK/term-seen"
IGNTERM="$WORK/ignterm.sh"
cat > "$IGNTERM" <<EOF
#!/bin/sh
trap 'printf trapped > "$MARKER"' TERM
i=0
while [ \$i -lt 60 ]; do sleep 1; i=\$((i + 1)); done
EOF
chmod +x "$IGNTERM"
rc=0; bp_run generic 1 "$OUTF" "$ERRF" -- "$IGNTERM" || rc=$?
if [ "$rc" -eq 124 ] && [ "$BP_STATUS" = timed-out ] && [ "$BP_TIMED_OUT" = 1 ] && [ -z "$BP_EXIT_CODE" ]; then
	pass "TERM-ignoring command -> timed-out (rc 124), exit_code null"
else
	fail "TERM-ignoring command misclassified: rc=$rc status=$BP_STATUS timed_out=$BP_TIMED_OUT exit=$BP_EXIT_CODE"
fi
if [ -f "$MARKER" ]; then pass "TERM was delivered before KILL (graceful-then-forced escalation)"; else fail "TERM never delivered (no marker) — escalation path not exercised"; fi

# --- (4) spawns a child; no orphan left --------------------------------------
CHILDPIDF="$WORK/childpid"
SPAWN="$WORK/spawn.sh"
cat > "$SPAWN" <<'EOF'
#!/bin/sh
sleep 300 &
echo $! > "$SS_CHILDPID"
while true; do sleep 1; done
EOF
chmod +x "$SPAWN"
rc=0; SS_CHILDPID="$CHILDPIDF" bp_run generic 1 "$OUTF" "$ERRF" -- "$SPAWN" || rc=$?
CHILD=$(cat "$CHILDPIDF" 2>/dev/null || echo "")
if [ "$BP_STATUS" = timed-out ]; then
	pass "child-spawning command -> timed-out"
else
	fail "child-spawning command not timed out: status=$BP_STATUS"
fi
if [ -n "$CHILD" ]; then
	# Give the KILL a beat to be reaped, then assert the child is gone (no orphan).
	sleep 1
	if kill -0 "$CHILD" 2>/dev/null; then
		kill -KILL "$CHILD" 2>/dev/null || true
		fail "orphaned child $CHILD survived the timeout (tree not reaped)"
	else
		pass "spawned child $CHILD was reaped (no orphan left behind)"
	fi
else
	fail "spawned child pid was not recorded by the fixture"
fi

# --- (5) docker socket / probe to an unresponsive endpoint -------------------
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/docker" <<'EOF'
#!/bin/sh
# Simulate a wedged Docker daemon: any invocation hangs.
while true; do sleep 1; done
EOF
chmod +x "$FAKEBIN/docker"
DTO=$(SENTINEL_SHIELD_DOCKER_PROBE_TIMEOUT_SECONDS=1 bp_timeout docker-probe)
if [ "$DTO" = 1 ]; then pass "docker-probe category honours SENTINEL_SHIELD_DOCKER_PROBE_TIMEOUT_SECONDS override"; else fail "docker-probe override not honoured (got '$DTO')"; fi
rc=0; PATH="$FAKEBIN:$PATH" bp_run docker-probe 1 "$OUTF" "$ERRF" -- docker info || rc=$?
if [ "$rc" -eq 124 ] && [ "$BP_STATUS" = timed-out ] && [ "$BP_COMMAND" = docker ]; then
	pass "unresponsive docker probe -> timed-out, command basename 'docker' (no args leaked)"
else
	fail "unresponsive docker probe misclassified: rc=$rc status=$BP_STATUS cmd=$BP_COMMAND"
fi

# --- (6) gh api hangs --------------------------------------------------------
cat > "$FAKEBIN/gh" <<'EOF'
#!/bin/sh
while true; do sleep 1; done
EOF
chmod +x "$FAKEBIN/gh"
rc=0; PATH="$FAKEBIN:$PATH" bp_run github-api 1 "$OUTF" "$ERRF" -- gh api /repos/x/y || rc=$?
if [ "$rc" -eq 124 ] && [ "$BP_STATUS" = timed-out ]; then
	pass "hanging gh api -> timed-out (bounded)"
else
	fail "hanging gh api not bounded: rc=$rc status=$BP_STATUS"
fi

# --- (7) scanner version probe hangs -----------------------------------------
cat > "$FAKEBIN/fakescanner" <<'EOF'
#!/bin/sh
# Hang specifically on the version probe.
case "$1" in
	version|--version) while true; do sleep 1; done ;;
	*) exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/fakescanner"
rc=0; PATH="$FAKEBIN:$PATH" bp_run scanner-version 1 "$OUTF" "$ERRF" -- fakescanner --version || rc=$?
if [ "$rc" -eq 124 ] && [ "$BP_STATUS" = timed-out ]; then
	pass "hanging scanner version probe -> timed-out (bounded)"
else
	fail "hanging scanner version probe not bounded: rc=$rc status=$BP_STATUS"
fi

# unavailable: an executable that is not on PATH is reported distinctly, never launched.
rc=0; bp_run generic 5 "$OUTF" "$ERRF" -- this-command-does-not-exist-xyz || rc=$?
if [ "$rc" -eq 127 ] && [ "$BP_STATUS" = unavailable ] && [ -z "$BP_EXIT_CODE" ]; then
	pass "missing executable -> unavailable (rc 127), never launched"
else
	fail "missing executable misclassified: rc=$rc status=$BP_STATUS exit=$BP_EXIT_CODE"
fi

# --- (8) invalid timeouts rejected -------------------------------------------
for bad in 0 -5 abc 1.5 "" 999999999; do
	rc=0; bp_run generic "$bad" "$OUTF" "$ERRF" -- "$FAST" || rc=$?
	if [ "$rc" -eq 2 ]; then
		pass "invalid timeout '$bad' rejected (rc 2, fail closed)"
	else
		fail "invalid timeout '$bad' NOT rejected: rc=$rc status=$BP_STATUS"
	fi
done
# A valid override still passes validation and resolves.
if bp_is_valid_timeout 30 && ! bp_is_valid_timeout 0 && ! bp_is_valid_timeout -1 && ! bp_is_valid_timeout x; then
	pass "bp_is_valid_timeout accepts positive integers and rejects zero/negative/nonnumeric"
else
	fail "bp_is_valid_timeout classification wrong"
fi

# --- (9) internal temp files removed -----------------------------------------
TMPHOME="$WORK/tmphome"; mkdir -p "$TMPHOME"
rc=0; TMPDIR="$TMPHOME" bp_run generic 1 "$OUTF" "$ERRF" -- "$IGNTERM" || rc=$?
LEFT=$(find "$TMPHOME" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$LEFT" = 0 ]; then
	pass "no internal temp/flag files left behind after a bounded run"
else
	fail "bounded run leaked $LEFT temp file(s) in TMPDIR"
fi

# --- (10a) timeout state reaches the machine-readable result -----------------
rc=0; bp_run docker-probe 1 "$WORK/j-out" "$WORK/j-err" -- "$IGNTERM" || rc=$?
RJSON="$WORK/result.json"
bp_result_json > "$RJSON"
if bp_validate_result "$RJSON" >/dev/null 2>&1; then
	pass "bp_result_json for a timeout validates against the schema (jq structural)"
else
	fail "bp_result_json timeout output failed structural validation"
fi
if [ "$(jq -r '.status' "$RJSON")" = "timed-out" ] \
	&& [ "$(jq -r '.exit_code' "$RJSON")" = "null" ] \
	&& [ "$(jq -r '.timed_out' "$RJSON")" = "true" ] \
	&& [ "$(jq -r '.command' "$RJSON")" = "ignterm.sh" ] \
	&& [ "$(jq -r '.command_category' "$RJSON")" = "docker-probe" ]; then
	pass "JSON result: status=timed-out, exit_code null, timed_out true, category preserved, no args"
else
	fail "JSON result malformed: $(jq -c . "$RJSON")"
fi
# A success result must validate too (exit_code 0 branch).
bp_run generic 5 "$WORK/j2-out" "$WORK/j2-err" -- "$FAST" || true
bp_result_json > "$WORK/result-ok.json"
if bp_validate_result "$WORK/result-ok.json" >/dev/null 2>&1 \
	&& [ "$(jq -r '.status' "$WORK/result-ok.json")" = success ] \
	&& [ "$(jq -r '.exit_code' "$WORK/result-ok.json")" = 0 ]; then
	pass "bp_result_json for a success validates (exit_code 0)"
else
	fail "bp_result_json success output failed validation"
fi

# --- (10b) timeout state reaches the tool-provenance-audit security report ----
# Fake, hanging docker on PATH + a repo:tag image (no @sha256) forces the audit down the
# BOUNDED docker-inspect digest path. It must NOT hang, and the timeout must surface in
# the report (docker_probe_timeouts >= 1, a docker_probes[] entry with status=timed-out),
# and under --require-image-digest it must FAIL CLOSED (unverified image).
[ -x "$AUDIT" ] || fail "provenance audit not executable: $AUDIT"
AOUT="$WORK/audit.json"
rc=0
PATH="$FAKEBIN:$PATH" \
	SENTINEL_SHIELD_DOCKER_PROBE_TIMEOUT_SECONDS=1 \
	SENTINEL_SHIELD_ZZZ_SCANNER_IMAGE="example.invalid/zzz-scanner:latest" \
	sh "$AUDIT" --require-image-digest --output "$AOUT" zzz-scanner >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && [ -f "$AOUT" ]; then
	pass "provenance audit completes (no hang) and fails closed on an unverifiable image via a bounded docker probe"
else
	fail "provenance audit did not fail-closed as expected: rc=$rc (file present=$( [ -f "$AOUT" ] && echo yes || echo no ))"
fi
if [ -f "$AOUT" ]; then
	DTOUT=$(jq -r '.docker_probe_timeouts' "$AOUT" 2>/dev/null || echo 0)
	HASTO=$(jq -r 'any(.docker_probes[]?; .status == "timed-out")' "$AOUT" 2>/dev/null || echo false)
	VSTATUS=$(jq -r '.records[0].image.verification_status' "$AOUT" 2>/dev/null || echo "?")
	if [ "$DTOUT" -ge 1 ] 2>/dev/null && [ "$HASTO" = true ] && [ "$VSTATUS" = unverified ]; then
		pass "audit report surfaces the docker-probe timeout (docker_probe_timeouts>=1, a timed-out probe, image unverified)"
	else
		fail "audit report did not surface the timeout: timeouts=$DTOUT hasTimedOut=$HASTO verify=$VSTATUS"
	fi
	# The audit JSON must still conform to its schema (structural jq check of the new fields).
	if jq -e '
		(.docker_probe_timeouts | type == "number") and
		(.docker_probes | type == "array") and
		(all(.docker_probes[]?; .schema == "bounded-command-result"))
	' "$AOUT" >/dev/null 2>&1; then
		pass "audit report new bounded-probe fields are well-formed"
	else
		fail "audit report bounded-probe fields malformed: $(jq -c '{docker_probe_timeouts,docker_probes}' "$AOUT" 2>/dev/null)"
	fi
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
exit 0
