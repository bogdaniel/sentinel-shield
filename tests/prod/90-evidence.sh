#!/bin/sh
# Sentinel Shield production test — release evidence registry + validator.
#
# Proves the evidence machinery is FAIL-CLOSED across release scopes:
#   * framework-validated (the default when release_scope is absent): a file with
#     no real consumer runs must NOT satisfy a stage gate; only a hand-built
#     fixture WITH real laravel+symfony runs passes --require-stage beta.
#   * engine-only: the release is backed by the engine's OWN CI (engine_ci[]).
#     An engine-only beta with a populated, self-consistent engine_ci passes; an
#     EMPTY engine_ci fails closed; the disclaimer banner is always printed.
# The shipped v2.0.0-beta.1.json is an engine-only beta backed by real engine_ci.
# Malformed input is rejected with exit 2.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

VALIDATOR="$ROOT/scripts/validate-release-evidence.sh"
SCHEMA="$ROOT/schemas/release-evidence.schema.json"
FAILS=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

# run_validator <expected-exit> <desc> -- args...
run_validator() {
	_exp="$1"; _desc="$2"; shift 2
	_rc=0
	sh "$VALIDATOR" "$@" >/dev/null 2>&1 || _rc=$?
	if [ "$_rc" = "$_exp" ]; then
		pass "$_desc (exit $_rc)"
	else
		fail "$_desc (expected exit $_exp, got $_rc)"
	fi
}

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssevidence)
trap 'rm -rf "$WORK"' EXIT INT TERM

# Preconditions: schema and shipped evidence files exist.
[ -f "$SCHEMA" ] && pass "schema present: schemas/release-evidence.schema.json" \
	|| fail "schema missing: schemas/release-evidence.schema.json"
if command -v jq >/dev/null 2>&1; then
	jq -e . "$SCHEMA" >/dev/null 2>&1 && pass "schema is valid JSON" || fail "schema is not valid JSON"
fi

GA="$ROOT/evidence/releases/v2.0.0.json"
BETA="$ROOT/evidence/releases/v2.0.0-beta.1.json"

# (a) shipped evidence files are schema-valid (exit 0, no --require-stage).
run_validator 0 "shipped v2.0.0.json is schema-valid" --file "$GA"
run_validator 0 "shipped v2.0.0-beta.1.json is schema-valid" --file "$BETA"

# Shipped files must honestly carry NO proof: empty consumer_runs, all flags false.
if command -v jq >/dev/null 2>&1; then
	for f in "$GA" "$BETA"; do
		_n=$(jq '.consumer_runs | length' "$f")
		_t=$(jq '[.required_evidence[] | select(. == true)] | length' "$f")
		if [ "$_n" = "0" ] && [ "$_t" = "0" ]; then
			pass "shipped $(basename "$f") has no fabricated evidence"
		else
			fail "shipped $(basename "$f") carries unproven evidence (runs=$_n true_flags=$_t)"
		fi
	done
fi

# (b) fail-closed for the framework/full-platform track: v2.0.0.json (full-platform,
# no consumer runs) must FAIL --require-stage beta.
run_validator 1 "fail-closed: shipped v2.0.0.json fails --require-stage beta" --file "$GA" --require-stage beta

# (b2) engine-only track: the shipped v2.0.0-beta.1.json is an engine-only beta
# backed by real engine_ci, so it PASSES its own beta gate...
run_validator 0 "engine-only: shipped v2.0.0-beta.1.json passes --require-stage beta" --file "$BETA" --require-stage beta
# ...but forcing the framework-validated matrix onto it FAILS (no laravel/symfony
# consumer runs). --scope must never be reinterpreted as "met".
run_validator 1 "engine-only file under --scope framework-validated fails beta" --file "$BETA" --require-stage beta --scope framework-validated
# The disclaimer must be printed, unmissably, for any engine-only evaluation.
if sh "$VALIDATOR" --file "$BETA" --require-stage beta 2>/dev/null | grep -qF 'FRAMEWORK LIVE-VALIDATION NOT INCLUDED'; then
	pass "engine-only prints 'FRAMEWORK LIVE-VALIDATION NOT INCLUDED'"
else
	fail "engine-only did NOT print the framework-live-validation disclaimer"
fi

# (b3) engine-only beta with an EMPTY engine_ci must FAIL CLOSED: an engine-only
# release is not "no gate" — it still requires the engine's own green CI.
EMPTY_ENGINE="$WORK/engine-only-empty.json"
cat > "$EMPTY_ENGINE" <<'EOF'
{
  "version": "2.0.0-beta.1",
  "stage": "beta",
  "release_scope": "engine-only",
  "engine_commit": "unknown",
  "consumer_runs": [],
  "required_evidence": {
    "laravel": false, "symfony": false, "php_library": false, "node_react": false,
    "combined_profile": false, "bootstrap_apply": false,
    "rollback_npm": false, "rollback_pnpm": false, "rollback_yarn": false
  }
}
EOF
run_validator 1 "fail-closed: engine-only beta with empty engine_ci fails" --file "$EMPTY_ENGINE" --require-stage beta

# (b4) an engine_ci run that did NOT succeed cannot back an engine-only beta.
FAILED_ENGINE="$WORK/engine-only-failed.json"
cat > "$FAILED_ENGINE" <<'EOF'
{
  "version": "2.0.0-beta.1",
  "stage": "beta",
  "release_scope": "engine-only",
  "engine_commit": "0123456789abcdef0123456789abcdef01234567",
  "engine_ci": [
    {"workflow_name":"ci-self-test","repository":"org/engine","commit":"0123456789abcdef0123456789abcdef01234567","event":"push","workflow_run_id":2001,"workflow_url":"https://github.com/org/engine/actions/runs/2001","result":"failure","artifacts":[],"artifacts_verified":false,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"},
    {"workflow_name":"ci-pipeline","repository":"org/engine","commit":"0123456789abcdef0123456789abcdef01234567","event":"push","workflow_run_id":2002,"workflow_url":"https://github.com/org/engine/actions/runs/2002","result":"success","artifacts":[],"artifacts_verified":false,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"}
  ],
  "consumer_runs": [],
  "required_evidence": {
    "laravel": false, "symfony": false, "php_library": false, "node_react": false,
    "combined_profile": false, "bootstrap_apply": false,
    "rollback_npm": false, "rollback_pnpm": false, "rollback_yarn": false
  }
}
EOF
run_validator 1 "fail-closed: engine-only beta with a failed engine_ci run fails" --file "$FAILED_ENGINE" --require-stage beta

# (b5) an invalid release_scope enum is a malformed record (non-overridable, exit 2).
BADSCOPE="$WORK/badscope.json"
cat > "$BADSCOPE" <<'EOF'
{
  "version": "2.0.0-beta.1",
  "stage": "beta",
  "release_scope": "engine-plus-vibes",
  "engine_commit": "unknown",
  "consumer_runs": [],
  "required_evidence": {
    "laravel": false, "symfony": false, "php_library": false, "node_react": false,
    "combined_profile": false, "bootstrap_apply": false,
    "rollback_npm": false, "rollback_pnpm": false, "rollback_yarn": false
  }
}
EOF
run_validator 2 "invalid release_scope enum rejected with exit 2" --file "$BADSCOPE"

# (b6) ABSENT release_scope must default to framework-validated (the stricter
# track), NOT engine-only. An engine-only-SHAPED file (engine_ci present, no
# consumer runs, all flags false) that forgets to declare release_scope must
# therefore FAIL --require-stage beta (needs laravel+symfony) — never be silently
# treated as an engine-only pass. Regression guard for Finding 4.
NOSCOPE="$WORK/no-scope-engine-shaped.json"
cat > "$NOSCOPE" <<'EOF'
{
  "version": "2.0.0-beta.1",
  "stage": "beta",
  "engine_commit": "8bd33a91343603434026408aded2de0142989159",
  "engine_ci": [
    {"workflow_name":"ci-self-test","repository":"org/engine","commit":"8bd33a91343603434026408aded2de0142989159","event":"push","workflow_run_id":9001,"workflow_url":"https://github.com/org/engine/actions/runs/9001","result":"success","artifacts":[],"artifacts_verified":false,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"},
    {"workflow_name":"ci-pipeline","repository":"org/engine","commit":"8bd33a91343603434026408aded2de0142989159","event":"push","workflow_run_id":9002,"workflow_url":"https://github.com/org/engine/actions/runs/9002","result":"success","artifacts":[],"artifacts_verified":false,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"}
  ],
  "consumer_runs": [],
  "required_evidence": {
    "laravel": false, "symfony": false, "php_library": false, "node_react": false,
    "combined_profile": false, "bootstrap_apply": false,
    "rollback_npm": false, "rollback_pnpm": false, "rollback_yarn": false
  }
}
EOF
run_validator 1 "absent release_scope defaults to framework-validated => beta fails (not engine-only)" --file "$NOSCOPE" --require-stage beta
# Explicitly forcing engine-only DOES pass the same file (proves the difference is the default, not the shape).
run_validator 0 "same file under --scope engine-only passes beta" --file "$NOSCOPE" --require-stage beta --scope engine-only

# (c) hand-built fixture WITH real-looking laravel+symfony runs passes beta.
# Each run carries the FULL hardened proof shape: 40-hex commits, a 40-hex
# sentinel_shield_commit equal to engine_commit, a positive-integer run id,
# a canonical run URL whose owner/repo+run-id match, verified artifacts, an
# ISO-8601 UTC timestamp, and a verification_method.
GOOD="$WORK/good-beta.json"
cat > "$GOOD" <<'EOF'
{
  "version": "2.0.0-beta.1",
  "stage": "beta",
  "engine_commit": "0123456789abcdef0123456789abcdef01234567",
  "consumer_runs": [
    {"stack":"laravel","repository":"org/laravel-demo","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sentinel_shield_commit":"0123456789abcdef0123456789abcdef01234567","profile":"laravel","tool_mode":"bootstrap-tools","workflow_run_id":1001,"workflow_url":"https://github.com/org/laravel-demo/actions/runs/1001","result":"success","artifacts":[{"id":11,"name":"sbom","verified":true}],"artifacts_verified":true,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"},
    {"stack":"symfony","repository":"org/symfony-demo","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sentinel_shield_commit":"0123456789abcdef0123456789abcdef01234567","profile":"symfony","tool_mode":"require-existing","workflow_run_id":1002,"workflow_url":"https://github.com/org/symfony-demo/actions/runs/1002","result":"success","artifacts":[{"id":12,"name":"sbom","verified":true}],"artifacts_verified":true,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"}
  ],
  "required_evidence": {
    "laravel": true, "symfony": true, "php_library": false, "node_react": false,
    "combined_profile": false, "bootstrap_apply": false,
    "rollback_npm": false, "rollback_pnpm": false, "rollback_yarn": false
  }
}
EOF
run_validator 0 "real laravel+symfony runs pass --require-stage beta" --file "$GOOD" --require-stage beta
# The same fixture must still FALL SHORT of a higher stage (rc needs more proof).
run_validator 1 "beta-only fixture does not satisfy --require-stage rc" --file "$GOOD" --require-stage rc

# A flag set true but with NO backing successful run must NOT pass beta.
# The run is well-formed (passes schema + semantics) but FAILED, so it cannot
# back any flag: artifacts_verified=false with an empty artifacts[] is honest.
UNBACKED="$WORK/unbacked.json"
cat > "$UNBACKED" <<'EOF'
{
  "version": "2.0.0-beta.1",
  "stage": "beta",
  "engine_commit": "0123456789abcdef0123456789abcdef01234567",
  "consumer_runs": [
    {"stack":"laravel","repository":"org/laravel-demo","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sentinel_shield_commit":"0123456789abcdef0123456789abcdef01234567","profile":"laravel","tool_mode":"bootstrap-tools","workflow_run_id":1001,"workflow_url":"https://github.com/org/laravel-demo/actions/runs/1001","result":"failure","artifacts":[],"artifacts_verified":false,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"}
  ],
  "required_evidence": {
    "laravel": true, "symfony": true, "php_library": false, "node_react": false,
    "combined_profile": false, "bootstrap_apply": false,
    "rollback_npm": false, "rollback_pnpm": false, "rollback_yarn": false
  }
}
EOF
run_validator 1 "fail-closed: true flags without successful runs fail beta" --file "$UNBACKED" --require-stage beta

# (d) malformed file -> exit 2.
BAD="$WORK/malformed.json"
printf '{ this is not json ' > "$BAD"
run_validator 2 "malformed JSON is rejected with exit 2" --file "$BAD"

# Structurally-broken-but-parseable JSON (missing required_evidence) -> exit 2.
BROKEN="$WORK/broken.json"
printf '{"version":"x","stage":"beta","engine_commit":"x","consumer_runs":[]}\n' > "$BROKEN"
run_validator 2 "schema-invalid (missing required_evidence) rejected with exit 2" --file "$BROKEN"

# Bad enum value -> exit 2.
BADENUM="$WORK/badenum.json"
cat > "$BADENUM" <<'EOF'
{
  "version": "x", "stage": "platinum", "engine_commit": "x", "consumer_runs": [],
  "required_evidence": {
    "laravel": false, "symfony": false, "php_library": false, "node_react": false,
    "combined_profile": false, "bootstrap_apply": false,
    "rollback_npm": false, "rollback_pnpm": false, "rollback_yarn": false
  }
}
EOF
run_validator 2 "invalid stage enum rejected with exit 2" --file "$BADENUM"

# Invalid invocation (bad --require-stage value) -> exit 2.
run_validator 2 "invalid --require-stage value rejected with exit 2" --file "$GA" --require-stage bogus

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
exit 0
