#!/bin/sh
# Sentinel Shield production test — release-evidence FORMAT + SEMANTIC + stage
# hardening, plus MOCKED --verify-github (Blocker 4).
#
# Blocker 4 is: "release evidence must not accept arbitrary strings as proof".
# This test proves the validator rejects every shape of fake/inconsistent proof
# with the NON-overridable exit 2 (malformed/format/semantic), enforces stage
# ordering with exit 1, accepts a fully well-formed offline record (and labels
# it as STRUCTURAL, not proof the run exists), and — through a STUBBED GH_BIN —
# accepts a matching GitHub-verified record while rejecting nonexistent runs and
# missing artifacts. NETWORK-FREE: every gh call is routed through a fake bin.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

VALIDATOR="$ROOT/scripts/validate-release-evidence.sh"
FAILS=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssevsem)
trap 'rm -rf "$WORK"' EXIT INT TERM

if ! command -v jq >/dev/null 2>&1; then
	# jq is a documented hard prerequisite (the validator exits 3 without it). Exit with the
	# distinct prereq code (2) — matching scripts/self-test.sh and the adopter suite — so a
	# jq-less environment is NOT indistinguishable from a full pass to the runner.
	printf 'FAIL: jq is a documented prerequisite but is absent (validator needs jq)\n' >&2
	exit 2
fi

ENG="0123456789abcdef0123456789abcdef01234567"
CM="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

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

# run_validator_env <expected-exit> <desc> <env-assignment> -- args...
# Like run_validator but with a single VAR=value prefix (used for GH_BIN).
run_validator_env() {
	_exp="$1"; _desc="$2"; _env="$3"; shift 3
	_rc=0
	env "$_env" sh "$VALIDATOR" "$@" >/dev/null 2>&1 || _rc=$?
	if [ "$_rc" = "$_exp" ]; then
		pass "$_desc (exit $_rc)"
	else
		fail "$_desc (expected exit $_exp, got $_rc)"
	fi
}

# write_doc <file> <engine_commit> <run-json> <re-json>
write_doc() {
	cat > "$1" <<EOF
{"version":"2.0.0-beta.1","stage":"beta","engine_commit":"$2",
 "consumer_runs":[$3],
 "required_evidence":$4}
EOF
}

# A single fully-valid laravel run (the baseline we mutate to create bad cases).
GOODRUN='{"stack":"laravel","repository":"org/laravel-demo","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sentinel_shield_commit":"0123456789abcdef0123456789abcdef01234567","profile":"laravel","tool_mode":"bootstrap-tools","workflow_run_id":1001,"workflow_url":"https://github.com/org/laravel-demo/actions/runs/1001","result":"success","artifacts":[{"id":11,"name":"sbom","verified":true}],"artifacts_verified":true,"verified_at":"2026-06-01T00:00:00Z","verification_method":"github-api"}'
RE_LAR='{"laravel":true,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false}'
RE_NONE='{"laravel":false,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false}'

# mutate <jq-filter> -> echoes a mutated single-run array element to stdout
mutate() { printf '%s' "$GOODRUN" | jq -c "$1"; }

# --- valid baseline accepted structurally (and LABELED structural) ----------
F="$WORK/valid.json"
write_doc "$F" "$ENG" "$GOODRUN" "$RE_LAR"
run_validator 0 "valid offline evidence accepted structurally" --file "$F"
if sh "$VALIDATOR" --file "$F" 2>&1 | grep -qi 'structural'; then
	pass "offline output is labeled structural (not proof of run existence)"
else
	fail "offline output is NOT labeled structural"
fi
# The doc declares stage beta (>= alpha) and has no unmet alpha needs, so an
# alpha gate is satisfied. (A full beta pass needs laravel+symfony; covered in 90.)
run_validator 0 "valid evidence meets --require-stage alpha" --file "$F" --require-stage alpha

# --- FORMAT rejections (exit 2) ---------------------------------------------
# non-numeric run_id
write_doc "$F" "$ENG" "$(mutate '.workflow_run_id="gh-actions-run-1001"')" "$RE_LAR"
run_validator 2 "non-numeric run_id rejected" --file "$F"
# short commit (not 40 hex)
write_doc "$F" "$ENG" "$(mutate '.commit="abc123"')" "$RE_LAR"
run_validator 2 "short commit rejected" --file "$F"
# non-hex commit (uppercase / out-of-range chars)
write_doc "$F" "$ENG" "$(mutate '.commit="zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"')" "$RE_LAR"
run_validator 2 "non-hex commit rejected" --file "$F"
# bad repo shape (no slash)
write_doc "$F" "$ENG" "$(mutate '.repository="orglaraveldemo"')" "$RE_LAR"
run_validator 2 "bad repo shape rejected" --file "$F"
# unknown top-level key
cat > "$F" <<EOF
{"version":"v","stage":"beta","engine_commit":"$ENG","consumer_runs":[],"required_evidence":$RE_LAR,"surprise":1}
EOF
run_validator 2 "unknown top-level key rejected" --file "$F"

# --- SEMANTIC rejections (exit 2) -------------------------------------------
# workflow_url repo mismatch
write_doc "$F" "$ENG" "$(mutate '.workflow_url="https://github.com/org/OTHER/actions/runs/1001"')" "$RE_LAR"
run_validator 2 "workflow_url repo mismatch rejected" --file "$F"
# workflow_url run-id mismatch
write_doc "$F" "$ENG" "$(mutate '.workflow_url="https://github.com/org/laravel-demo/actions/runs/2002"')" "$RE_LAR"
run_validator 2 "workflow_url run-id mismatch rejected" --file "$F"
# engine-commit mismatch (sentinel_shield_commit != engine_commit)
write_doc "$F" "$ENG" "$(mutate '.sentinel_shield_commit="2222222222222222222222222222222222222222"')" "$RE_LAR"
run_validator 2 "engine-commit mismatch rejected" --file "$F"
# empty artifacts with artifacts_verified true
write_doc "$F" "$ENG" "$(mutate '.artifacts=[]')" "$RE_LAR"
run_validator 2 "empty artifact list with artifacts_verified true rejected" --file "$F"
# an artifact with verified=false
write_doc "$F" "$ENG" "$(mutate '.artifacts[0].verified=false')" "$RE_LAR"
run_validator 2 "artifact verified=false rejected" --file "$F"
# success contradiction: artifacts_verified true but result cancelled
write_doc "$F" "$ENG" "$(mutate '.result="cancelled"')" "$RE_LAR"
run_validator 2 "artifacts_verified+cancelled contradiction rejected" --file "$F"
# stack/profile mismatch: laravel stack carrying a node profile
write_doc "$F" "$ENG" "$(mutate '.profile="node-react"')" "$RE_LAR"
run_validator 2 "stack/profile mismatch rejected" --file "$F"
# bootstrap_apply with wrong tool_mode
write_doc "$F" "$ENG" \
	"$(mutate '.stack="bootstrap_apply" | .tool_mode="config-only"')" \
	'{"laravel":false,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":true,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false}'
run_validator 2 "bootstrap_apply wrong tool_mode rejected" --file "$F"
# rollback stack not documenting an actual rollback test
write_doc "$F" "$ENG" \
	"$(mutate '.stack="rollback_npm" | .profile="node-react" | .verification_method="github-api"')" \
	'{"laravel":false,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":true,"rollback_pnpm":false,"rollback_yarn":false}'
run_validator 2 "rollback evidence without rollback test rejected" --file "$F"
# duplicate run_id reused across two distinct stacks
RUN_LAR=$(mutate '.')
RUN_SYM=$(printf '%s' "$GOODRUN" | jq -c '.stack="symfony" | .repository="org/laravel-demo" | .profile="symfony" | .tool_mode="require-existing"')
write_doc "$F" "$ENG" "$RUN_LAR,$RUN_SYM" \
	'{"laravel":true,"symfony":true,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false}'
run_validator 2 "duplicate run_id across distinct stacks rejected" --file "$F"

# --- STAGE consistency (exit 1) ---------------------------------------------
# An alpha document must NOT satisfy a ga request.
ALPHA="$WORK/alpha.json"
cat > "$ALPHA" <<EOF
{"version":"2.0.0-alpha.1","stage":"alpha","engine_commit":"unknown","consumer_runs":[],"required_evidence":$RE_NONE}
EOF
run_validator 1 "alpha doc does not satisfy --require-stage ga" --file "$ALPHA" --require-stage ga

# --- MOCKED --verify-github (network-free via GH_BIN stub) -------------------
BIN="$WORK/bin"
mkdir -p "$BIN"

# Stub that returns matching run + artifact metadata for run 1001.
cat > "$BIN/gh-ok" <<EOF
#!/bin/sh
# args: api repos/<owner>/<repo>/actions/runs/<rid>[/artifacts]
case "\$2" in
	*/artifacts) printf '{"artifacts":[{"id":11,"name":"sbom"}]}\n' ;;
	*runs/1001) printf '{"id":1001,"head_sha":"$CM","conclusion":"success","html_url":"https://github.com/org/laravel-demo/actions/runs/1001"}\n' ;;
	*) printf '{}\n' ;;
esac
EOF
chmod +x "$BIN/gh-ok"

# Stub that reports the run as nonexistent (gh api fails).
cat > "$BIN/gh-missing" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$BIN/gh-missing"

# Stub where the run exists but publishes NO artifacts (declared one is missing).
cat > "$BIN/gh-noart" <<EOF
#!/bin/sh
case "\$2" in
	*/artifacts) printf '{"artifacts":[]}\n' ;;
	*runs/1001) printf '{"id":1001,"head_sha":"$CM","conclusion":"success","html_url":"https://github.com/org/laravel-demo/actions/runs/1001"}\n' ;;
	*) printf '{}\n' ;;
esac
EOF
chmod +x "$BIN/gh-noart"

write_doc "$F" "$ENG" "$GOODRUN" "$RE_LAR"
run_validator_env 0 "valid MOCKED --verify-github accepted (stub GH_BIN)" "GH_BIN=$BIN/gh-ok" --file "$F" --verify-github
run_validator_env 1 "mocked nonexistent run rejected" "GH_BIN=$BIN/gh-missing" --file "$F" --verify-github
run_validator_env 1 "mocked missing artifact rejected" "GH_BIN=$BIN/gh-noart" --file "$F" --verify-github

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
exit 0
