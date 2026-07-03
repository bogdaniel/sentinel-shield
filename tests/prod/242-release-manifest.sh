#!/bin/sh
# Sentinel Shield production test — release MANIFEST reproducibility (NN=242).
#
# Exercises scripts/generate-release-manifest.sh + scripts/verify-release-manifest.sh
# + schemas/release-manifest.schema.json. Proves:
#   * the manifest schema is jq-valid;
#   * the same inputs produce an IDENTICAL reproducibility hash across two runs;
#   * generated_at (a timestamp) does NOT enter the hash (it lives in non-hashed
#     metadata) — two runs differ in metadata.generated_at yet share one hash;
#   * verify passes self-consistency and reconstruction on an untampered manifest;
#   * a tamper to body is DETECTED (self-consistency fails);
#   * an input change (different tag target) is DETECTED as reconstruction drift;
#   * the generated manifest conforms to the schema's required shape.
# Hermetic: explicit --source-commit/--tree-hash/--tag-target avoid any git lookup;
# --repo-root points at the real tree so action-pin/profile/schema digests are real.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
GEN="$ROOT/scripts/generate-release-manifest.sh"
VER="$ROOT/scripts/verify-release-manifest.sh"
SCHEMA="$ROOT/schemas/release-manifest.schema.json"
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssmanifest)
trap 'rm -rf "$WORK"' EXIT INT TERM

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # source commit
T=1111111111111111111111111111111111111111   # tree hash
G=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # tag target (metadata commit)

# Synthetic engine-only evidence with two engine_ci runs.
EV="$WORK/ev.json"
cat > "$EV" <<EOF
{ "version":"2.0.0-beta.2","stage":"beta","release_scope":"engine-only",
  "engine_commit":"$A","release_commit":"$G",
  "engine_ci":[
    {"workflow_name":"ci-self-test","repository":"org/engine","commit":"$A","event":"push","workflow_run_id":5002,"workflow_url":"https://github.com/org/engine/actions/runs/5002","result":"success","artifacts":[],"artifacts_verified":false,"verified_at":"2026-07-01T00:00:00Z","verification_method":"github-api"},
    {"workflow_name":"ci-pipeline","repository":"org/engine","commit":"$A","event":"push","workflow_run_id":5001,"workflow_url":"https://github.com/org/engine/actions/runs/5001","result":"success","artifacts":[],"artifacts_verified":false,"verified_at":"2026-07-01T00:00:00Z","verification_method":"github-api"}
  ],
  "consumer_runs":[],
  "required_evidence":{"laravel":false,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false} }
EOF

gen() { sh "$GEN" --evidence "$EV" --repo-root "$ROOT" --source-commit "$A" --tree-hash "$T" --tag-target "$1" --output "$2"; }

# --- schema is jq-valid ------------------------------------------------------
if [ -f "$SCHEMA" ] && jq -e . "$SCHEMA" >/dev/null 2>&1; then
	pass "release-manifest schema present and jq-valid"
else
	fail "release-manifest schema missing or not jq-valid"
fi

# --- reproducibility: same inputs => identical hash --------------------------
gen "$G" "$WORK/m1.json" 2>/dev/null
sleep 1   # force a different generated_at so we prove it does not enter the hash
gen "$G" "$WORK/m2.json" 2>/dev/null
H1=$(jq -r '.reproducibility.hash' "$WORK/m1.json")
H2=$(jq -r '.reproducibility.hash' "$WORK/m2.json")
if [ -n "$H1" ] && [ "$H1" = "$H2" ]; then
	pass "reproducibility: identical inputs yield identical hash ($H1)"
else
	fail "reproducibility: hashes differ ($H1 vs $H2)"
fi
TS1=$(jq -r '.metadata.generated_at' "$WORK/m1.json")
TS2=$(jq -r '.metadata.generated_at' "$WORK/m2.json")
if [ "$TS1" != "$TS2" ]; then
	pass "timestamp isolation: generated_at differs between runs yet the hash is stable"
else
	fail "timestamp isolation: generated_at did not change (test could not prove isolation)"
fi

# --- ordering determinism: workflow_runs sorted by run_id --------------------
if [ "$(jq -r '.body.workflow_runs[0].run_id' "$WORK/m1.json")" = 5001 ]; then
	pass "determinism: workflow_runs are sorted deterministically (run_id ascending)"
else
	fail "determinism: workflow_runs not sorted -> $(jq -c '[.body.workflow_runs[].run_id]' "$WORK/m1.json")"
fi

# --- schema conformance (required shape) -------------------------------------
if jq -e '
	.schema_version == "1"
	and (.metadata | has("generated_at") and has("generator"))
	and (.reproducibility.hash_algorithm == "sha256")
	and (.reproducibility.hash | test("^[0-9a-f]{64}$"))
	and (.body as $b | ["version","stage","release_scope","source_commit","tree_hash","tag_target","workflow_runs","artifact_digests","action_pins","tool_versions","profile_policy_digests","schema_digests"] | all(. as $k | ($b|has($k))))
' "$WORK/m1.json" >/dev/null 2>&1; then
	pass "manifest conforms to the schema's required shape"
else
	fail "manifest does not conform to required shape"
fi

# --- verify: untampered manifest passes self-consistency + reconstruction ----
if sh "$VER" --manifest "$WORK/m1.json" >/dev/null 2>&1; then
	pass "verify: untampered manifest passes self-consistency"
else
	fail "verify: untampered manifest failed self-consistency"
fi
if sh "$VER" --manifest "$WORK/m1.json" --evidence "$EV" --repo-root "$ROOT" \
	--source-commit "$A" --tree-hash "$T" --tag-target "$G" >/dev/null 2>&1; then
	pass "verify: manifest reconstructs from the same inputs"
else
	fail "verify: reconstruction from identical inputs failed"
fi

# --- tamper: edit a body digest without fixing the hash => detected ----------
jq '.body.schema_digests[0].sha256="0000000000000000000000000000000000000000000000000000000000000000"' \
	"$WORK/m1.json" > "$WORK/tampered.json"
_rc=0; sh "$VER" --manifest "$WORK/tampered.json" >/dev/null 2>&1 || _rc=$?
if [ "$_rc" = 1 ]; then
	pass "tamper: a modified body is detected (self-consistency fails, exit 1)"
else
	fail "tamper: modified body NOT detected (exit $_rc)"
fi

# --- tamper: swap tag_target inside the body => hash mismatch detected --------
jq '.body.tag_target="cccccccccccccccccccccccccccccccccccccccc"' \
	"$WORK/m1.json" > "$WORK/tampered2.json"
_rc=0; sh "$VER" --manifest "$WORK/tampered2.json" >/dev/null 2>&1 || _rc=$?
if [ "$_rc" = 1 ]; then
	pass "tamper: a swapped tag_target in body is detected"
else
	fail "tamper: swapped tag_target NOT detected (exit $_rc)"
fi

# --- input drift: a different tag target reconstructs to a different hash -----
_rc=0
sh "$VER" --manifest "$WORK/m1.json" --evidence "$EV" --repo-root "$ROOT" \
	--source-commit "$A" --tree-hash "$T" --tag-target "cccccccccccccccccccccccccccccccccccccccc" >/dev/null 2>&1 || _rc=$?
if [ "$_rc" = 1 ]; then
	pass "drift: a changed input (tag target) is detected as reconstruction mismatch"
else
	fail "drift: changed input NOT detected (exit $_rc)"
fi

# --- a genuinely different input => different hash (positive control) ---------
gen "cccccccccccccccccccccccccccccccccccccccc" "$WORK/m3.json" 2>/dev/null
H3=$(jq -r '.reproducibility.hash' "$WORK/m3.json")
if [ "$H3" != "$H1" ]; then
	pass "sensitivity: a different tag target produces a different hash"
else
	fail "sensitivity: different input produced the SAME hash (hash is not input-sensitive)"
fi

if [ "$FAILS" -gt 0 ]; then printf '\n%d assertion(s) failed\n' "$FAILS" >&2; exit 1; fi
exit 0
