#!/bin/sh
# Sentinel Shield production test — production-grade doctor (workstream 15).
#
# Proves the v2 doctor integrity checks and the canonical exit-code contract
# (0 healthy / 1 warnings-only / 2 invalid-config / 3 required-tool-missing /
# 4 execution-evidence-problem) without network access, using mktemp fixtures:
#   (a) a healthy adoption fixture exits 0 or 1 (no FAIL/invalid lines),
#   (b) a STALE .sentinel-shield/operation-lock.json is flagged (exit 4),
#   (c) a pinned-ref / resolved-commit MISMATCH is detected (exit 2),
#   (d) an unsatisfied profile-REQUIRED tool still yields exit 3 (no regression).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

DOCTOR="$ROOT/scripts/doctor.sh"
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

# run_doctor <out-var-file> -- args...  : runs doctor, captures exit code in RC and
# output in the named file. Never aborts the test (set -e safe).
RC=0
run_doctor() {
	_of="$1"; shift
	RC=0
	sh "$DOCTOR" "$@" >"$_of" 2>&1 || RC=$?
}

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for the doctor engine but is absent\n'; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssdoctor)
trap 'rm -rf "$WORK"' EXIT INT TERM

# Precondition: doctor exists and documents the new exit codes in its header.
[ -f "$DOCTOR" ] && pass "doctor.sh present" || fail "doctor.sh missing"
grep -q 'STALE operation-lock' "$DOCTOR" && pass "doctor documents/handles stale operation-lock" \
	|| fail "doctor does not mention a stale operation-lock"

# --- (a) healthy adoption fixture -> exit 0 or 1 ----------------------------------
HA="$WORK/healthy"; mkdir -p "$HA/.sentinel-shield"
cat > "$HA/.sentinel-shield/installation.json" <<'JSON'
{ "schema_version":"2","version":"2.0.0","profile":"laravel","profile_schema":2,
  "tool_mode":"config-only","repository":"o/r",
  "resolved_commit":"3333333333333333333333333333333333333333",
  "installed_at":"2026-06-27T12:00:00Z","updated_at":"2026-06-27T12:00:00Z",
  "managed_files":[],"project_owned_files":[],
  "enabled_tools":["phpstan"],"disabled_tools":[] }
JSON
# An immutable TAG ref proven by acquisition metadata (ref_kind=tag) with a
# well-formed resolved commit is internally consistent.
printf '{"repository":"o/r","ref":"v2.0.0","ref_kind":"tag","resolved_commit":"%s"}\n' \
	"3333333333333333333333333333333333333333" > "$HA/.sentinel-shield/.sentinel-shield-ref"
# No --quiet here: doctor suppresses ok-lines under --quiet, and we assert one below.
run_doctor "$WORK/a.out" --target "$HA"
if [ "$RC" = 0 ]; then
	pass "(a) healthy fixture exits exactly 0 (got $RC)"
else
	fail "(a) healthy fixture expected exit 0, got $RC"
fi
if grep -q 'FAIL' "$WORK/a.out"; then
	fail "(a) healthy fixture printed a FAIL line (should be clean)"
else
	pass "(a) healthy fixture prints no FAIL line"
fi
grep -q 'installation.json valid' "$WORK/a.out" \
	&& pass "(a) healthy fixture validates installation.json" \
	|| fail "(a) healthy fixture did not validate installation.json"

# --- (b) STALE operation-lock -> flagged, exit 4 --------------------------------
SL="$WORK/stale-lock"; mkdir -p "$SL/.sentinel-shield"
printf '{"operation":"sync","pid":4242}\n' > "$SL/.sentinel-shield/operation-lock.json"
# Backdate the lock far past the staleness threshold (mtime-based detection).
touch -t 200001010000 "$SL/.sentinel-shield/operation-lock.json"
run_doctor "$WORK/b.out" --target "$SL" --quiet
[ "$RC" = 4 ] && pass "(b) stale operation-lock -> exit 4 (got $RC)" \
	|| fail "(b) stale operation-lock expected exit 4, got $RC"
grep -q 'STALE operation-lock' "$WORK/b.out" \
	&& pass "(b) stale operation-lock is flagged in output" \
	|| fail "(b) stale operation-lock not flagged in output"

# A FRESH lock is degraded (warnings-only), not an execution problem.
FL="$WORK/fresh-lock"; mkdir -p "$FL/.sentinel-shield"
printf '{"operation":"sync","pid":4242}\n' > "$FL/.sentinel-shield/operation-lock.json"
run_doctor "$WORK/b2.out" --target "$FL" --quiet
[ "$RC" = 1 ] && pass "(b) fresh operation-lock -> exit 1 (degraded, got $RC)" \
	|| fail "(b) fresh operation-lock expected exit 1, got $RC"

# --- (c) pinned-ref / resolved-commit MISMATCH -> exit 2 ------------------------
MM="$WORK/mismatch"; mkdir -p "$MM/.sentinel-shield"
printf '{"repository":"o/r","ref":"%s","resolved_commit":"%s"}\n' \
	"1111111111111111111111111111111111111111" \
	"2222222222222222222222222222222222222222" > "$MM/.sentinel-shield/.sentinel-shield-ref"
run_doctor "$WORK/c.out" --target "$MM" --quiet
[ "$RC" = 2 ] && pass "(c) ref/commit mismatch -> exit 2 (got $RC)" \
	|| fail "(c) ref/commit mismatch expected exit 2, got $RC"
grep -q 'MISMATCH' "$WORK/c.out" \
	&& pass "(c) mismatch is detected and reported" \
	|| fail "(c) mismatch not reported in output"

# A moving-branch ref is also invalid configuration (exit 2).
MB="$WORK/movingbranch"; mkdir -p "$MB/.sentinel-shield"
printf '{"repository":"o/r","ref":"main","resolved_commit":"%s"}\n' \
	"4444444444444444444444444444444444444444" > "$MB/.sentinel-shield/.sentinel-shield-ref"
run_doctor "$WORK/c2.out" --target "$MB" --quiet
[ "$RC" = 2 ] && pass "(c) moving-branch ref -> exit 2 (got $RC)" \
	|| fail "(c) moving-branch ref expected exit 2, got $RC"

# --- (d) profile-REQUIRED tool missing -> exit 3 (no regression) ----------------
# Self-contained engine fixture: a profile with one REQUIRED tool whose only declared
# executable cannot resolve, so it is classified not-installed.
ENG="$WORK/engine"; mkdir -p "$ENG/profiles/needtool"
cat > "$ENG/profiles/needtool/profile.manifest.json" <<'JSON'
{ "profile": "needtool",
  "description": "Production-test fixture: a single REQUIRED tool with an absent executable.",
  "tool_policy_version": 2,
  "tools": {
    "ghosttool": {
      "policy": "required",
      "category": "test-fixture",
      "executable": ["vendor/bin/ghosttool-absent-xyzzy"],
      "execution": { "pr": true, "main": true, "scheduled": true }
    }
  } }
JSON
DT="$WORK/reqtarget"; mkdir -p "$DT"
RC=0
EP_REPO_ROOT="$ENG" sh "$DOCTOR" --target "$DT" --profile needtool --tool-mode require-existing --quiet \
	>"$WORK/d.out" 2>&1 || RC=$?
[ "$RC" = 3 ] && pass "(d) required-tool-missing -> exit 3 (got $RC)" \
	|| fail "(d) required-tool-missing expected exit 3, got $RC"
grep -q 'profile-required tool(s) absent' "$WORK/d.out" \
	&& pass "(d) required-tool failure is reported" \
	|| fail "(d) required-tool failure not reported in output"

if [ "$FAILS" -eq 0 ]; then
	printf 'ALL PASS (150-doctor)\n'
	exit 0
fi
printf '%s FAIL(s) (150-doctor)\n' "$FAILS"
exit 1
