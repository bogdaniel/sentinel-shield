#!/bin/sh
# Sentinel Shield production test — release evidence registry + validator.
#
# Proves the evidence machinery is FAIL-CLOSED: the shipped evidence files are
# schema-valid but, because they carry no real consumer runs, they must NOT
# satisfy a stage gate. A hand-built fixture WITH real-looking laravel+symfony
# runs is the only thing that passes --require-stage beta. Malformed input is
# rejected with exit 2.
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

# (b) --require-stage beta FAILS on the shipped files (fail-closed => exit 1).
run_validator 1 "fail-closed: shipped v2.0.0.json fails --require-stage beta" --file "$GA" --require-stage beta
run_validator 1 "fail-closed: shipped v2.0.0-beta.1.json fails --require-stage beta" --file "$BETA" --require-stage beta

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
