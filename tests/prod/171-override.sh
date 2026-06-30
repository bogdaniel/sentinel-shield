#!/bin/sh
# tests/prod/171-override.sh — FINDING 5: release-readiness override GOVERNANCE.
#
# A free-text --override-reason is NOT a blanket bypass. Asserts
# scripts/check-release-readiness.sh enforces the staged override policy:
#   * beta  : an override REQUIRES a version-controlled governance RECORD
#             (CONTRACT 3 / schemas/release-override.schema.json):
#               valid (matching --version AND --stage, unexpired, requester !=
#               approver) is ACCEPTED (exit 0, loud banner); self-approved,
#               expired, wrong-version, and wrong-stage records are REJECTED
#               (exit 1, fail closed); a malformed record is NON-overridable
#               (exit 2). A bare free-text --override-reason is refused at beta.
#   * rc/ga : override is PROHIBITED by default — a free-text reason is refused
#             (exit 1) — and permitted ONLY via the same strict record, which is
#             reported as an EXCEPTIONAL override (exit 0).
#   * An override can NEVER waive a NON-WAIVABLE failure: malformed evidence
#             (validator exit 2 — also the channel for rollback-integrity /
#             path-safety violations) fails closed at exit 2 even WITH a valid
#             record; a tracked secret (hygiene) is refused even WITH an override.
#
# Hermetic: $SELF_TEST is stubbed and the static validators are shadowed by
# passing fakes on PATH. The honest empty-evidence fixture is schema-VALID but
# satisfies no stage, so a real WAIVABLE gate is unmet for the governance path
# to act upon. The tracked-secret case runs against a throwaway git repo so the
# real repository is never mutated. NETWORK-FREE.
# Run via: sh tests/prod/171-override.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/check-release-readiness.sh"

FAILED=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

[ -f "$SCRIPT" ] || { bad "check-release-readiness.sh exists"; exit 1; }

TMPDIR_T=$(mktemp -d "${TMPDIR:-/tmp}/171-override.XXXXXX")
trap 'rm -rf "$TMPDIR_T"' EXIT INT TERM

# Fake-bin: passing self-test + passing static validators (so actionlint/zizmor,
# which are MANDATORY at beta+, do not independently fail the run). Real jq/yq/git.
BIN="$TMPDIR_T/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "$BIN/selftest-ok"
for v in shellcheck actionlint zizmor; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$v"; done
chmod +x "$BIN"/*

# Honest no-evidence fixture: schema-VALID but satisfies no stage gate (validator
# exit 1, a WAIVABLE failure) — so the override-governance path is exercised.
EMPTY_EVIDENCE="$TMPDIR_T/empty-evidence.json"
cat >"$EMPTY_EVIDENCE" <<'JSON'
{
  "version": "0.0.0-test",
  "stage": "beta",
  "engine_commit": "unknown",
  "consumer_runs": [],
  "required_evidence": {
    "laravel": false, "symfony": false, "php_library": false,
    "node_react": false, "combined_profile": false, "bootstrap_apply": false,
    "rollback_npm": false, "rollback_pnpm": false, "rollback_yarn": false
  }
}
JSON

# Malformed evidence: not parseable -> validator exit 2 (non-overridable). This is
# the same exit-2 channel used for rollback-integrity / path-safety violations.
MALFORMED_EVIDENCE="$TMPDIR_T/malformed-evidence.json"
printf 'this is { not json' > "$MALFORMED_EVIDENCE"

# mk_override <path> <version> <stage> <requested_by> <approved_by> <expires_at>
mk_override() {
	cat >"$1" <<EOF
{
  "schema_version": "1",
  "version": "$2",
  "stage": "$3",
  "controls": ["evidence:consumer-runs"],
  "reason": "documented justification for governed override (test)",
  "requested_by": "$4",
  "approved_by": "$5",
  "created_at": "2024-01-01T00:00:00Z",
  "expires_at": "$6"
}
EOF
}

FUTURE="2099-01-01T00:00:00Z"
PAST="2000-01-01T00:00:00Z"

run() { # run <args...> — execute the readiness check with stubs/fakes.
	SELF_TEST="$BIN/selftest-ok" PATH="$BIN:$PATH" sh "$SCRIPT" "$@" 2>&1
}

# --- beta: a valid governance record is ACCEPTED (loud banner) ----------------
VALID="$TMPDIR_T/ovr-valid.json"
mk_override "$VALID" v2.0.0 beta alice bob "$FUTURE"
rc=0; out=$(run --version v2.0.0 --stage beta --evidence "$EMPTY_EVIDENCE" --override-file "$VALID") || rc=$?
if [ "$rc" -eq 0 ]; then ok "beta accepts a valid governance record (exit 0)"
else bad "beta valid record expected exit 0, got $rc; out: $out"; fi
if printf '%s' "$out" | grep -q 'OVERRIDE IN EFFECT'; then ok "beta valid record prints the loud OVERRIDE banner"
else bad "beta valid record missing loud banner"; fi

# --- beta: a bare free-text --override-reason is REFUSED ----------------------
rc=0; out=$(run --version v2.0.0 --stage beta --evidence "$EMPTY_EVIDENCE" --override-reason "just trust me") || rc=$?
if [ "$rc" -eq 1 ]; then ok "beta refuses a bare free-text override-reason (exit 1)"
else bad "beta free-text reason expected exit 1, got $rc"; fi
if printf '%s' "$out" | grep -q 'does NOT accept a free-text'; then ok "beta free-text refusal is explained"
else bad "beta free-text refusal message missing"; fi

# --- beta: self-approved record is REJECTED (governance) ----------------------
SELFAPP="$TMPDIR_T/ovr-self.json"
mk_override "$SELFAPP" v2.0.0 beta alice alice "$FUTURE"
rc=0; out=$(run --version v2.0.0 --stage beta --evidence "$EMPTY_EVIDENCE" --override-file "$SELFAPP") || rc=$?
if [ "$rc" -eq 1 ]; then ok "beta rejects a self-approved record (exit 1, fail closed)"
else bad "beta self-approved expected exit 1, got $rc"; fi
if printf '%s' "$out" | grep -q 'self-approval FORBIDDEN'; then ok "beta self-approval rejection is explained"
else bad "beta self-approval rejection message missing"; fi

# --- beta: expired record is REJECTED -----------------------------------------
EXPIRED="$TMPDIR_T/ovr-expired.json"
mk_override "$EXPIRED" v2.0.0 beta alice bob "$PAST"
rc=0; out=$(run --version v2.0.0 --stage beta --evidence "$EMPTY_EVIDENCE" --override-file "$EXPIRED") || rc=$?
if [ "$rc" -eq 1 ]; then ok "beta rejects an expired record (exit 1, fail closed)"
else bad "beta expired expected exit 1, got $rc"; fi
if printf '%s' "$out" | grep -q 'EXPIRED'; then ok "beta expiry rejection is explained"
else bad "beta expiry rejection message missing"; fi

# --- beta: wrong-version record is REJECTED -----------------------------------
WRONGVER="$TMPDIR_T/ovr-wrongver.json"
mk_override "$WRONGVER" v9.9.9 beta alice bob "$FUTURE"
rc=0; out=$(run --version v2.0.0 --stage beta --evidence "$EMPTY_EVIDENCE" --override-file "$WRONGVER") || rc=$?
if [ "$rc" -eq 1 ]; then ok "beta rejects a version-mismatched record (exit 1)"
else bad "beta wrong-version expected exit 1, got $rc"; fi
if printf '%s' "$out" | grep -q 'version mismatch'; then ok "beta version-mismatch rejection is explained"
else bad "beta version-mismatch message missing"; fi

# --- beta: wrong-stage record is REJECTED -------------------------------------
WRONGSTAGE="$TMPDIR_T/ovr-wrongstage.json"
mk_override "$WRONGSTAGE" v2.0.0 alpha alice bob "$FUTURE"
rc=0; out=$(run --version v2.0.0 --stage beta --evidence "$EMPTY_EVIDENCE" --override-file "$WRONGSTAGE") || rc=$?
if [ "$rc" -eq 1 ]; then ok "beta rejects a stage-mismatched record (exit 1)"
else bad "beta wrong-stage expected exit 1, got $rc"; fi
if printf '%s' "$out" | grep -q 'stage mismatch'; then ok "beta stage-mismatch rejection is explained"
else bad "beta stage-mismatch message missing"; fi

# --- beta: malformed (schema-invalid) record is NON-overridable (exit 2) ------
BADREC="$TMPDIR_T/ovr-malformed.json"
# Missing the required "approved_by" field -> schema-invalid -> exit 2.
cat >"$BADREC" <<EOF
{
  "schema_version": "1",
  "version": "v2.0.0",
  "stage": "beta",
  "controls": ["evidence:consumer-runs"],
  "reason": "missing approver",
  "requested_by": "alice",
  "created_at": "2024-01-01T00:00:00Z",
  "expires_at": "$FUTURE"
}
EOF
rc=0; run --version v2.0.0 --stage beta --evidence "$EMPTY_EVIDENCE" --override-file "$BADREC" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "beta treats a malformed record as NON-overridable (exit 2)"
else bad "beta malformed record expected exit 2, got $rc"; fi

# --- override can NEVER waive MALFORMED EVIDENCE (validator exit 2) ------------
# Even with a perfectly valid governance record, malformed evidence (the same
# exit-2 channel as rollback-integrity / path-safety) fails closed at exit 2.
rc=0; run --version v2.0.0 --stage beta --evidence "$MALFORMED_EVIDENCE" --override-file "$VALID" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "a valid override cannot waive malformed evidence (exit 2, non-overridable)"
else bad "malformed-evidence + valid override expected exit 2, got $rc"; fi

# --- rc: free-text override PROHIBITED ----------------------------------------
rc=0; out=$(run --version v2.0.0 --stage rc --evidence "$EMPTY_EVIDENCE" --override-reason "ship it") || rc=$?
if [ "$rc" -eq 1 ]; then ok "rc prohibits a free-text override (exit 1)"
else bad "rc free-text override expected exit 1, got $rc"; fi

# --- rc: a valid record is permitted but reported EXCEPTIONAL ------------------
RCREC="$TMPDIR_T/ovr-rc.json"
mk_override "$RCREC" v2.0.0 rc alice bob "$FUTURE"
rc=0; out=$(run --version v2.0.0 --stage rc --evidence "$EMPTY_EVIDENCE" --override-file "$RCREC") || rc=$?
if [ "$rc" -eq 0 ]; then ok "rc accepts a strict valid record (exit 0)"
else bad "rc valid record expected exit 0, got $rc; out: $out"; fi
if printf '%s' "$out" | grep -q 'EXCEPTIONAL'; then ok "rc override is reported as EXCEPTIONAL"
else bad "rc override missing the EXCEPTIONAL marker"; fi

# --- rc: self-approved record is still REJECTED -------------------------------
RCSELF="$TMPDIR_T/ovr-rc-self.json"
mk_override "$RCSELF" v2.0.0 rc alice alice "$FUTURE"
rc=0; run --version v2.0.0 --stage rc --evidence "$EMPTY_EVIDENCE" --override-file "$RCSELF" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then ok "rc rejects a self-approved record (exit 1)"
else bad "rc self-approved expected exit 1, got $rc"; fi

# --- override can NEVER waive a TRACKED SECRET (hygiene, NON-WAIVABLE) ---------
# Build a throwaway git repo carrying the readiness check + a tracked .env secret
# so the real repository is never touched. Even WITH an override the run is
# refused. The sentinel secret must still EXIST afterwards (read-only auditor).
FAKE="$TMPDIR_T/fakerepo"
mkdir -p "$FAKE/scripts/lib" "$FAKE/templates/workflows" "$FAKE/schemas" "$FAKE/tests/fixtures/wf-good"
cp "$ROOT/scripts/check-release-readiness.sh" "$FAKE/scripts/check-release-readiness.sh"
cp "$ROOT/scripts/lib/sentinel-shield-common.sh" "$FAKE/scripts/lib/sentinel-shield-common.sh"
cat >"$FAKE/templates/workflows/ci.yml" <<'YML'
name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./local-action
YML
cat >"$FAKE/schemas/x.schema.json" <<'JSON'
{ "type": "object" }
JSON
cat >"$FAKE/.env" <<'ENVF'
API_TOKEN=super-secret-should-never-ship
ENVF
(
	cd "$FAKE" \
		&& git init -q \
		&& git config user.email t@t.t \
		&& git config user.name t \
		&& git add -A
) >/dev/null 2>&1

rc=0; out=$(SELF_TEST="$BIN/selftest-ok" PATH="$BIN:$PATH" \
	sh "$FAKE/scripts/check-release-readiness.sh" \
	--version v2.0.0 --stage alpha --override-reason "force it past the secret" 2>&1) || rc=$?
if [ "$rc" -eq 1 ]; then ok "a tracked secret cannot be overridden (exit 1, fail closed)"
else bad "tracked-secret override expected exit 1, got $rc; out: $out"; fi
if printf '%s' "$out" | grep -qi 'non-waivable'; then ok "tracked-secret failure is marked NON-WAIVABLE"
else bad "tracked-secret NON-WAIVABLE marker missing"; fi
if printf '%s' "$out" | grep -q 'REFUSED'; then ok "the supplied override is explicitly REFUSED"
else bad "override-refused message missing for tracked secret"; fi
if [ -f "$FAKE/.env" ]; then ok "the read-only auditor left the sentinel secret intact"
else bad "sentinel secret .env was unexpectedly removed"; fi

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
