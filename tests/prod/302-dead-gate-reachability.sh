#!/bin/sh
# Sentinel Shield production test — reachability of three gates that could not fire (#326).
#
# THE INVARIANT THIS SUITE ENCODES: a fail-closed branch that exists in the source is not
# evidence that the branch is reachable. All three defects below shipped with the rejection
# logic plainly visible in the file, reviewed, and permanently unreachable:
#
#   A  enforce-gates.sh — `(.evidence.execution.observed // true) == false`. jq's `//`
#      substitutes for `false` as well as for `null`, so `false // true` is `true` and the
#      comparison was unsatisfiable. SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION=1 had never
#      rejected anything (#310's withdrawn criterion).
#   B  release-authz.sh — `(.complete // true) == true`, the same inversion, on the line
#      ADJACENT to a correctly written one. `{"result":"pass","complete":false}` — documented
#      four lines above the code as a fail — passed ra_gate_ok.
#   C  health.sh / compatibility-policy.sh — the documented gate exit 4 (probe timeout,
#      UNVERIFIABLE) had never been producible. `set -e`-unsafe status captures let `timeout`'s
#      raw 124 out of the gate, and the CP_PROBE_TIMEOUT flag was raised inside a command
#      substitution, so even a corrected capture produced exit 3, not 4 (#306).
#
# Every assertion here therefore RUNS the gate. Each rejection is paired with a CONTROL that
# must pass, because a gate that refuses everything satisfies a rejection test without being
# correct, and a rejection produced by an unrelated missing precondition looks identical to a
# rejection produced by the gate under test.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss302)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf -- "$WORK" 2>/dev/null || :' EXIT INT TERM HUP

sha() { { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" || shasum -a 256 "$1"; } 2>/dev/null | awk '{print $1}'; }

# =============================================================================================
# A — enforce-gates.sh: SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION must actually reject
# =============================================================================================
# The two summaries differ by EXACTLY one field: evidence.execution.observed. Everything else —
# tool set, statuses, source trust, attestation — is identical, so a rejection cannot be
# attributed to a missing precondition, and the observed:true control proves the pair is
# otherwise acceptable to the enforcer in the same mode.
ENFORCE="$ROOT/scripts/enforce-gates.sh"
RESOLVE="$ROOT/scripts/resolve-gates.sh"
EXAMPLE="$ROOT/templates/security-summary.example.json"

# a_case <dir> <mode> <observed-json> — a complete enforcement input pair, echo the directory.
a_case() {
	_d="$WORK/a-$1"; mkdir -p "$_d"
	sh "$RESOLVE" --mode "$2" --output-dir "$_d" --format all >/dev/null 2>&1
	# strict/regulated legitimately refuse an evidence-free summary, and regulated requires a
	# verified platform attestation (#278) — so the fixture carries what a real attested run
	# would produce. Copied from tests/prod/288, which pins that input contract.
	jq --argjson obs "$3" '.tools = {
			"gitleaks": {"status":"pass","evidence":{"execution":{"observed":$obs}}},
			"tests":    {"status":"pass"}
		}
		| .source.trust = "github-actions-attested"
		| .attestation = {verified:true, issuer:"https://token.actions.githubusercontent.com",
			repository:(.source.repository // "example-org/example-repo"),
			commit:(.source.commit // "0123456789abcdef0123456789abcdef01234567"),
			workflow:"sentinel-shield", workflow_sha:"1111111111111111111111111111111111111111",
			run_id:"1", run_attempt:"1",
			artifact_digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000"}' \
		"$EXAMPLE" > "$_d/s.json"
	printf '%s' "$_d"
}

# a_enf <dir> — run the enforcer over the pair, echo its exit code.
a_enf() {
	_d="$1"; _c=0
	# regulated needs an INDEPENDENT attestation record bound to the summary digest: a summary
	# cannot attest to itself. Bound here, after the summary is final.
	jq -n --arg dg "sha256:$(sha "$_d/s.json")" \
		--arg r "$(jq -r '.source.repository // ""' "$_d/s.json")" \
		--arg c "$(jq -r '.source.commit // ""' "$_d/s.json")" \
		'{attestation:"sentinel-shield/source-attestation@1", verified:true, verifier:"tests/prod/302",
		  artifact:"s.json", artifact_digest:$dg, repository:$r, commit:$c,
		  workflow:"sentinel-shield", run_id:"1"}' > "$_d/att.json"
	sh "$ENFORCE" --gates-env "$_d/sentinel-shield-gates.env" --summary "$_d/s.json" \
		--attestation "$_d/att.json" --output-dir "$_d" --format json >"$_d/out.log" 2>&1 || _c=$?
	printf '%s' "$_c"
}

if [ ! -f "$ENFORCE" ] || [ ! -f "$EXAMPLE" ]; then
	fail "A: enforce-gates.sh or the example summary is missing; the dynamic regression cannot run"
else
	for _m in strict regulated; do
		# CONTROL 1 — observed:true is accepted with the requirement ON. Without this, the
		# rejection below could be an enforcer that refuses this fixture for any reason at all.
		_rc=$(SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION=1 a_enf "$(a_case "obs-$_m" "$_m" true)")
		check "A CONTROL: $_m + REQUIRE_OBSERVED_EXECUTION=1 ACCEPTS observed:true" "$_rc" 0

		# CONTROL 2 — the same observed:false summary is accepted while the requirement is OFF.
		# This is what makes the rejection attributable to the flag and not to the field.
		_rc=$(a_enf "$(a_case "unobs-off-$_m" "$_m" false)")
		check "A CONTROL: $_m WITHOUT the requirement accepts observed:false (opt-in preserved)" "$_rc" 0

		# THE REGRESSION — the gate that had never rejected anything.
		_d=$(a_case "unobs-on-$_m" "$_m" false)
		_rc=$(SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION=1 a_enf "$_d")
		if [ "$_rc" = 0 ]; then
			fail "A: $_m + REQUIRE_OBSERVED_EXECUTION=1 ACCEPTED evidence with execution.observed:false (the gate is a no-op)"
		else
			pass "A: $_m + REQUIRE_OBSERVED_EXECUTION=1 REJECTS execution.observed:false (exit $_rc)"
		fi
		if grep -q 'UNOBSERVED execution' "$_d/out.log" 2>/dev/null; then
			pass "A: the refusal names UNOBSERVED execution (rejected by THIS gate, not another)"
		else
			fail "A: $_m rejected observed:false but not via the observed-execution gate — see $_d/out.log"
		fi
	done

	# An ABSENT execution record must stay outside the gate: the documented behaviour keys on an
	# explicitly recorded `observed: false`, never on a missing one. `null == false` is false in
	# jq, so this holds without a `//` default — and asserting it here is what stops a future
	# "fix" from re-introducing one.
	_d="$WORK/a-absent"; mkdir -p "$_d"
	sh "$RESOLVE" --mode strict --output-dir "$_d" --format all >/dev/null 2>&1
	jq '.tools = {"gitleaks":{"status":"pass"},"tests":{"status":"pass"}}
		| .source.trust = "github-actions-attested"' "$EXAMPLE" > "$_d/s.json"
	_rc=$(SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION=1 a_enf "$_d")
	check "A: an ABSENT execution record is not treated as observed:false (still opt-in)" "$_rc" 0

	# Malformed evidence must FAIL CLOSED, not be skipped. `.evidence?.execution?.observed?`
	# would make jq yield EMPTY for a non-object `.evidence` and silently drop the tool.
	_d="$WORK/a-malformed"; mkdir -p "$_d"
	sh "$RESOLVE" --mode strict --output-dir "$_d" --format all >/dev/null 2>&1
	jq '.tools = {"gitleaks":{"status":"pass","evidence":"not-an-object"},"tests":{"status":"pass"}}
		| .source.trust = "github-actions-attested"' "$EXAMPLE" > "$_d/s.json"
	_rc=$(SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION=1 a_enf "$_d")
	if [ "$_rc" = 0 ]; then
		fail "A: a tool whose .evidence is not an object was silently SKIPPED by the observed-execution check"
	else
		pass "A: malformed .evidence fails closed under the observed-execution check (exit $_rc)"
	fi
fi

# =============================================================================================
# B — release-authz.sh: ra_gate_ok must refuse an explicit complete:false
# =============================================================================================
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$ROOT/scripts/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/release-authz.sh
. "$ROOT/scripts/lib/release-authz.sh"

# b <label> <json> <expected: PASS|REJECT>
b() {
	printf '%s' "$2" > "$WORK/b.json"
	if ra_gate_ok "$WORK/b.json" 2>/dev/null; then _r=PASS; else _r=REJECT; fi
	check "B: $1" "$_r" "$3"
}

# CONTROLS — a genuinely green report is still accepted, in both of its documented shapes.
b "CONTROL a green report with no 'complete' key is accepted (the key is OPTIONAL)" \
	'{"result":"pass"}' PASS
b "CONTROL a green report with complete:true is accepted" \
	'{"result":"pass","complete":true}' PASS
b "CONTROL 'decision' and 'verdict' verdict keys are still recognised" \
	'{"decision":"accepted","complete":true}' PASS

# THE REGRESSION — line 112 of release-authz.sh has always documented complete!=false.
b "an explicit complete:false is REJECTED on an otherwise green report" \
	'{"result":"pass","complete":false}' REJECT
b "complete:false is rejected even alongside every other clean signal" \
	'{"result":"pass","complete":false,"incomplete":false,"missing":[],"failure_count":0}' REJECT

# The neighbouring clauses must be unchanged — a "fix" that broke them would otherwise hide here.
b "incomplete:true remains rejected" '{"result":"pass","incomplete":true}' REJECT
b "a non-empty missing[] remains rejected" '{"result":"pass","missing":["compat/linux"]}' REJECT
b "failure_count>0 remains rejected" '{"result":"pass","failure_count":1}' REJECT
b "an unrecognised verdict still FAILS CLOSED" '{"result":"maybe"}' REJECT
b "an absent verdict still FAILS CLOSED" '{"complete":true}' REJECT

# =============================================================================================
# C — health.sh --policy: exit 4 must be producible, and 0/1/2/3 must be untouched
# =============================================================================================
HEALTH="$ROOT/scripts/health.sh"
POLICY="$ROOT/config/compatibility-policy.json"

# A `timeout` shim that reports the GNU-coreutils timeout status. This is the ONLY way to reach
# the path on a developer host: macOS ships no `timeout`, so cp_bounded runs probes directly and
# 124 can never occur locally — which is exactly why the defect survived (#306).
SHIM="$WORK/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\nexit 124\n' > "$SHIM/timeout"
chmod +x "$SHIM/timeout"

# c_gate <expect-shim: 0|1> <env assignments...> — echo the gate's exit code.
c_gate() {
	_shim=$1; shift
	if [ "$_shim" = 1 ]; then _p="$SHIM:$PATH"; else _p="$PATH"; fi
	_c=0
	env PATH="$_p" SENTINEL_SHIELD_COMPAT_FS_CASE=sensitive "$@" \
		sh "$HEALTH" --policy "$POLICY" >"$WORK/c.log" 2>&1 || _c=$?
	printf '%s' "$_c"
}

# THE REGRESSION — the documented exit that had never been produced. Before the fix this is
# 124 (the raw timeout status escaping under set -e); with only the capture form corrected it
# is 3 (every version reads empty), because the flag was raised inside a command substitution.
_rc=$(c_gate 1 SENTINEL_SHIELD_COMPAT_OS=linux SENTINEL_SHIELD_COMPAT_ARCH=x86_64 \
	SENTINEL_SHIELD_COMPAT_SHELL=sh SENTINEL_SHIELD_COMPAT_NODE_VERSION=20.11 \
	SENTINEL_SHIELD_COMPAT_NPM_VERSION=10.9 SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.2)
check "C: a bounded probe timeout exits 4 — not 124 (unmapped), not 3 (misclassified)" "$_rc" 4
if grep -q 'UNVERIFIABLE (exit 4)' "$WORK/c.log" 2>/dev/null; then
	pass "C: the exit-4 path prints the documented UNVERIFIABLE diagnostic"
else
	fail "C: exit 4 was reached without the UNVERIFIABLE diagnostic — see $WORK/c.log"
fi

# The flag has to cross the command substitution in cp_detect_into_env. Asserted directly at the
# library level, because this is the step that a capture-form-only fix leaves broken.
(
	# shellcheck source=scripts/lib/compatibility-policy.sh
	. "$ROOT/scripts/lib/compatibility-policy.sh"
	cp_probe_timeout_reset
	cp_probe_timed_out && exit 1        # armed: not yet raised
	PATH="$SHIM:$PATH" cp_detect_into_env
	cp_probe_timed_out || exit 1
	exit 0
) >/dev/null 2>&1 && pass "C: the probe-timeout flag survives cp_detect_into_env's command substitution" \
	|| fail "C: cp_detect_into_env swallowed the probe-timeout flag (set in a subshell, lost to the reader)"

# CONTROLS — every existing matrix verdict is unchanged. These are the six cases pinned by
# compat-representative plus the invalid-invocation and degraded paths. Without them, "exit 4"
# could have been bought by breaking classification everywhere else.
check "C CONTROL: linux-min is supported (0)" \
	"$(c_gate 0 SENTINEL_SHIELD_COMPAT_OS=linux SENTINEL_SHIELD_COMPAT_ARCH=x86_64 SENTINEL_SHIELD_COMPAT_SHELL=sh \
		SENTINEL_SHIELD_COMPAT_NODE_VERSION=18.0 SENTINEL_SHIELD_COMPAT_NPM_VERSION=8.0 SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.1)" 0
check "C CONTROL: macos-high is supported (0)" \
	"$(c_gate 0 SENTINEL_SHIELD_COMPAT_OS=macos SENTINEL_SHIELD_COMPAT_ARCH=arm64 SENTINEL_SHIELD_COMPAT_SHELL=zsh \
		SENTINEL_SHIELD_COMPAT_NODE_VERSION=22.11 SENTINEL_SHIELD_COMPAT_NPM_VERSION=11.0 SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.4)" 0
check "C CONTROL: unsupported-shell fails closed (3)" \
	"$(c_gate 0 SENTINEL_SHIELD_COMPAT_OS=linux SENTINEL_SHIELD_COMPAT_ARCH=x86_64 SENTINEL_SHIELD_COMPAT_SHELL=fish \
		SENTINEL_SHIELD_COMPAT_NODE_VERSION=20.11 SENTINEL_SHIELD_COMPAT_NPM_VERSION=10.9 SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.2)" 3
check "C CONTROL: unsupported-arch fails closed (3)" \
	"$(c_gate 0 SENTINEL_SHIELD_COMPAT_OS=linux SENTINEL_SHIELD_COMPAT_ARCH=s390x SENTINEL_SHIELD_COMPAT_SHELL=bash \
		SENTINEL_SHIELD_COMPAT_NODE_VERSION=20.11 SENTINEL_SHIELD_COMPAT_NPM_VERSION=10.9 SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.2)" 3
check "C CONTROL: unsupported-node fails closed (3)" \
	"$(c_gate 0 SENTINEL_SHIELD_COMPAT_OS=linux SENTINEL_SHIELD_COMPAT_ARCH=x86_64 SENTINEL_SHIELD_COMPAT_SHELL=bash \
		SENTINEL_SHIELD_COMPAT_NODE_VERSION=16.20 SENTINEL_SHIELD_COMPAT_NPM_VERSION=10.9 SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.2)" 3
check "C CONTROL: unsupported-npm-major fails closed (3)" \
	"$(c_gate 0 SENTINEL_SHIELD_COMPAT_OS=linux SENTINEL_SHIELD_COMPAT_ARCH=x86_64 SENTINEL_SHIELD_COMPAT_SHELL=bash \
		SENTINEL_SHIELD_COMPAT_NODE_VERSION=20.11 SENTINEL_SHIELD_COMPAT_NPM_VERSION=7.9 SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.2)" 3
_c=0; env SENTINEL_SHIELD_COMPAT_OS=linux SENTINEL_SHIELD_COMPAT_ARCH=x86_64 SENTINEL_SHIELD_COMPAT_SHELL=sh \
	SENTINEL_SHIELD_COMPAT_NODE_VERSION=18.0 SENTINEL_SHIELD_COMPAT_NPM_VERSION=8.0 SENTINEL_SHIELD_COMPAT_PHP_VERSION=8.1 \
	SENTINEL_SHIELD_COMPAT_FS_CASE=insensitive sh "$HEALTH" --policy "$POLICY" >/dev/null 2>&1 || _c=$?
check "C CONTROL: a case-insensitive filesystem is degraded, not unsupported (1)" "$_c" 1
_c=0; sh "$HEALTH" --policy "$WORK/does-not-exist.json" >/dev/null 2>&1 || _c=$?
check "C CONTROL: a missing policy is an invalid invocation (2)" "$_c" 2
_c=0; sh "$HEALTH" --policy "$POLICY" --docker bogus >/dev/null 2>&1 || _c=$?
check "C CONTROL: an invalid --docker value is an invalid invocation (2)" "$_c" 2

# ---------------------------------------------------------------------------------------------
# C2 — the matrix's contract for exit 4 (#306 acceptance criterion 4)
# ---------------------------------------------------------------------------------------------
# A probe timeout is an ENVIRONMENTAL NON-VERDICT: the gate classified nothing, so reporting it
# as "expected 3 but got 4" describes a compatibility judgement that was never made. It is also
# not a pass. This runs the SHIPPED assertion block out of ci-compatibility.yml against a stub
# gate, so the workflow's behaviour is proven rather than asserted by inspection.
WF="$ROOT/.github/workflows/ci-compatibility.yml"
STEP="$WORK/step.sh"
# The block is a YAML literal scalar: everything indented at least as far as the first body
# line belongs to it, and the first non-blank line indented less ends it.
awk '
	/^      - name: Assert gate exit code/ { instep = 1; next }
	instep && /^        run: \|$/          { inrun = 1; next }
	inrun && $0 !~ /^          / && $0 ~ /[^[:space:]]/ { exit }
	inrun                                   { sub(/^          /, ""); print }
' "$WF" > "$STEP"

if [ ! -s "$STEP" ]; then
	fail "C2: could not extract the compat-representative assertion block from ci-compatibility.yml"
else
	# c2 <label> <expect-exit> <expect-substring> <not-substring> <stub codes...>
	# The stub emits one code per attempt, so a transient non-verdict can be distinguished
	# from a persistent one.
	c2() {
		_lbl=$1; _xrc=$2; _want=$3; _not=$4; shift 4
		_s="$WORK/c2-$(printf '%s' "$_lbl" | tr -cd 'a-z0-9')"
		rm -rf "$_s"; mkdir -p "$_s/scripts" "$_s/config"
		printf '%s\n' "$@" > "$_s/codes"
		: > "$_s/config/compatibility-policy.json"
		cat > "$_s/scripts/health.sh" <<-'STUB'
			#!/bin/sh
			# stub gate: emit the Nth line of ./codes on the Nth invocation.
			n=$(cat ./attempts 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > ./attempts
			c=$(sed -n "${n}p" ./codes); [ -n "$c" ] || c=$(tail -n 1 ./codes)
			exit "$c"
		STUB
		chmod +x "$_s/scripts/health.sh"
		_rc=0
		( cd "$_s" && env EXPECT_RC=3 CASE_NAME=stub-case sh "$STEP" ) >"$_s/log" 2>&1 || _rc=$?
		check "C2: $_lbl (exit)" "$_rc" "$_xrc"
		if [ -n "$_want" ]; then
			if grep -q "$_want" "$_s/log"; then pass "C2: $_lbl says '$_want'"
			else fail "C2: $_lbl did not say '$_want' — see $_s/log"; fi
		fi
		if [ -n "$_not" ]; then
			if grep -q "$_not" "$_s/log"; then fail "C2: $_lbl wrongly reported '$_not' — see $_s/log"
			else pass "C2: $_lbl does not report '$_not'"; fi
		fi
	}

	# CONTROL — the matrix still asserts the classification it always did.
	c2 "a matching verdict passes" 0 "" "COMPAT" 3
	# THE NON-WEAKENING PROOF — a WRONG verdict is still a hard mismatch failure.
	c2 "a wrong verdict is still a MISMATCH failure" 1 "COMPAT MISMATCH" "" 0
	# THE #306 AC4 REGRESSION — a persistent non-verdict fails as UNVERIFIABLE, never as a
	# mismatch against a classification the gate never reached.
	c2 "a persistent non-verdict fails as UNVERIFIABLE, not as a mismatch" 1 "COMPAT UNVERIFIABLE" "COMPAT MISMATCH" 4 4
	# A transient non-verdict is re-probed and the resulting verdict is asserted normally.
	c2 "a transient non-verdict is re-probed to a verdict" 0 "" "COMPAT" 4 3
	# And a re-probe that lands on the WRONG verdict is still a mismatch — the retry must not
	# become a way to launder a bad classification.
	c2 "a re-probe onto a wrong verdict is still a MISMATCH" 1 "COMPAT MISMATCH" "COMPAT UNVERIFIABLE" 4 0
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n302-dead-gate-reachability: %d check(s) FAILED\n' "$FAILS" >&2
	exit 1
fi
printf '\n302-dead-gate-reachability: OK (all three gates proven reachable, each against a passing control)\n'
exit 0
