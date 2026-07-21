#!/bin/sh
# Sentinel Shield prod test — documentation accuracy (audit PR C).
#
# This product's central claim is HONESTY: it must never assert more validation than it
# performs. Several docs did exactly that, and nothing mechanically checked them. Each
# assertion here pins a claim that was FALSE and would silently rot again.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

# --- the LIVE consumer tier is not claimed unless it can actually run --------
# 201-node-consumers.sh gates its live tier on SS_CONSUMER_LIVE=1. If nothing sets that,
# no doc may describe those consumers as live-validated.
_livesets=$(grep -rl 'SS_CONSUMER_LIVE=1' .github/ scripts/ 2>/dev/null | grep -c . || true)
case "$_livesets" in '' | *[!0-9]*) _livesets=0 ;; esac
if [ "$_livesets" -eq 0 ]; then
	# Only TABLE ROWS make the claim. Prose that describes the former wording ("these rows
	# previously read yes (live)") is a correction, not an assertion.
	_claims=$(grep -E '^\|' docs/product-status.md 2>/dev/null | grep -c 'yes (live)' || true)
	case "$_claims" in '' | *[!0-9]*) _claims=0 ;; esac
	check "no doc claims 'yes (live)' while SS_CONSUMER_LIVE is never set" "$_claims" "0"
else
	pass "SS_CONSUMER_LIVE is wired somewhere ($_livesets file(s)); live claims are permissible"
fi

# --- a profile that resolves ZERO tools must be documented as non-operative --
for _p in docker laravel symfony node react php-library hardened-enterprise; do
	_n=$(sh scripts/resolve-effective-profile.sh --profile "$_p" --format json 2>/dev/null | jq '.tools|length' 2>/dev/null || echo 0)
	case "$_n" in '' | *[!0-9]*) _n=0 ;; esac
	if [ "$_n" -eq 0 ]; then
		_m="profiles/$_p/profile.manifest.json"
		# NOT `.operative // "unset"` — jq's `//` treats boolean FALSE as empty, so the
		# very value being asserted would read as "unset" (the same trap resolve-gates.sh
		# documents at its get_scalar helper).
		_op=$(jq -r 'if has("operative") then (.operative|tostring) else "unset" end' "$_m" 2>/dev/null || echo unset)
		check "profile '$_p' resolves 0 tools and is marked non-operative" "$_op" "false"
	else
		pass "profile '$_p' resolves $_n tool(s)"
	fi
done

# NEGATIVE CONTROL for the branch above. Every shipped profile now resolves tools, so the
# "zero tools must be marked non-operative" rule would sit unexercised and could rot into a
# no-op. Prove it still detects an empty profile.
_np=$(mktemp -d)
printf '{"profile":"ss-empty-probe","description":"probe","stacks":[]}\n' > "$_np/profile.manifest.json"
_probe=$(jq -r 'if has("operative") then (.operative|tostring) else "unset" end' "$_np/profile.manifest.json")
check "negative control: a manifest with no tools and no operative flag reads 'unset'" "$_probe" "unset"
rm -rf -- "$_np"

# --- SHA-pinning claims must match the workflows -----------------------------
_tot=$(grep -rhoE '^[[:space:]]*uses: [^[:space:]]+' .github/workflows/ templates/workflows/ 2>/dev/null | grep -c . || true)
_pin=$(grep -rhoE '^[[:space:]]*uses: [^@[:space:]]+@[0-9a-f]{40}' .github/workflows/ templates/workflows/ 2>/dev/null | grep -c . || true)
case "$_tot" in '' | *[!0-9]*) _tot=0 ;; esac
case "$_pin" in '' | *[!0-9]*) _pin=0 ;; esac
check "every 'uses:' is SHA-pinned ($_pin/$_tot)" "$_pin" "$_tot"

# Checking the PROPERTY is not enough: the inventory doc also cites a literal ("126 of
# 126"). A property check stays green while that literal silently goes stale — the very
# drift this file exists to catch. Pin the literal to the live count.
_docpins=$(grep -oE '\*\*[0-9]+ of [0-9]+\*\*' docs/workflow-template-inventory.md 2>/dev/null \
	| head -n1 | grep -oE '[0-9]+' | head -n1 || true)
case "$_docpins" in '' | *[!0-9]*) _docpins='' ;; esac
if [ -n "$_docpins" ]; then
	check "workflow-template-inventory.md's cited pin count matches the repo" "$_docpins" "$_pin"
else
	fail "workflow-template-inventory.md no longer states a '**N of M**' pin count to verify"
fi

# A doc must not say only ci-self-test is pinned while all of them are.
_understate=$(grep -rl "Only \`.github/workflows/ci-self-test.yml\`" docs/ 2>/dev/null | grep -c . || true)
case "$_understate" in '' | *[!0-9]*) _understate=0 ;; esac
check "no doc claims only ci-self-test is SHA-pinned" "$_understate" "0"

# --- dead references ---------------------------------------------------------
# ci-zap.yml was removed; no doc may pin actions for a workflow that no longer exists.
if [ ! -f .github/workflows/ci-zap.yml ]; then
	# Only COPYABLE pins matter: a row carrying a 40-hex SHA invites an adopter to use it.
	# Frozen historical snapshots (docs/*-v0NN.md) legitimately record what was true then.
	_zap=$(grep -rlE 'zaproxy/action[^|]*\|[^|]*[0-9a-f]{40}' docs/ 2>/dev/null \
		| grep -vE 'v0[0-9]+\.md$' | grep -c . || true)
	case "$_zap" in '' | *[!0-9]*) _zap=0 ;; esac
	check "no doc pins zaproxy actions after ci-zap removal" "$_zap" "0"
fi

# --- the support policy must not lag the published release -------------------
_latest=$(grep -oE 'v2\.[0-9]+\.[0-9]+' CHANGELOG.md 2>/dev/null | head -n1 || true)
if [ -n "$_latest" ]; then
	if grep -q "$_latest" docs/support-policy.md 2>/dev/null; then
		pass "support-policy.md cites the current release ($_latest)"
	else
		fail "support-policy.md does not mention $_latest — the entitlement doc lags the release"
	fi
fi

# --- the gate count must not be asserted as a stale literal ------------------
_w=$(mktemp -d); trap 'rm -rf -- "$_w"' EXIT INT TERM
sh scripts/resolve-gates.sh --mode strict --output-dir "$_w" --format env >/dev/null 2>&1
_gates=$(grep -c '^SENTINEL_SHIELD_FAIL_ON_' "$_w/sentinel-shield-gates.env" 2>/dev/null || true)
case "$_gates" in '' | *[!0-9]*) _gates=0 ;; esac
if [ "$_gates" -gt 0 ]; then
	_bad=$(grep -rl 'the twelve `fail_on` gates' docs/ RELEASE-GATES.md 2>/dev/null | grep -c . || true)
	case "$_bad" in '' | *[!0-9]*) _bad=0 ;; esac
	check "no doc asserts a stale literal gate count (resolver emits $_gates)" "$_bad" "0"

	# Same reasoning as the pin count: RELEASE-GATES.md cites a literal ("**41** on this
	# revision"). Absence of the OLD wrong number does not make the CURRENT number right.
	_docgates=$(grep -oE '\*\*[0-9]+\*\* on this revision' RELEASE-GATES.md 2>/dev/null \
		| head -n1 | grep -oE '[0-9]+' | head -n1 || true)
	case "$_docgates" in '' | *[!0-9]*) _docgates='' ;; esac
	if [ -n "$_docgates" ]; then
		check "RELEASE-GATES.md's cited gate count matches the resolver" "$_docgates" "$_gates"
	else
		fail "RELEASE-GATES.md no longer states a '**N** on this revision' gate count to verify"
	fi
fi

# --- the profile table's raw-report count must track the manifest ------------
# The docker row claimed 7 raw reports, `semgrep`/`trivy-image` in stages, and four
# scheduled tools, long after the manifest dropped all of them and grew to 13 reports.
# Nothing compared the two, so the table rotted silently — the exact drift this file
# exists to catch. Count is the cheapest invariant that moves whenever the manifest does.
_rowchecked=0
while IFS= read -r _row; do
	# Field 2 = profile name, last field = declared raw-report count.
	_prof=$(printf '%s' "$_row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
	_declared=$(printf '%s' "$_row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$(NF-1)); print $(NF-1)}')
	case "$_prof" in '' | Profile | ---*) continue ;; esac
	case "$_declared" in '' | *[!0-9]*) continue ;; esac
	_mf="profiles/$_prof/profile.manifest.json"
	[ -f "$_mf" ] || _mf="profiles/combinations/$_prof.manifest.json"
	[ -f "$_mf" ] || { fail "profile table row '$_prof' names a profile with no manifest"; continue; }
	_actual=$(jq -r '(.recommended_raw_reports // []) | length' "$_mf" 2>/dev/null || printf 'unreadable')
	check "profile table raw-report count for '$_prof' matches its manifest" "$_declared" "$_actual"
	_rowchecked=$((_rowchecked + 1))

	# Every tool NAMED in a stage column must appear in that stage's recommended_* list.
	# The docker row advertised `semgrep` and `trivy-image` that the manifest never
	# recommends — a reader would have wired scanners the profile does not run. Columns
	# 4/5/6 are PR-fast / main-gate / scheduled.
	_col=3
	for _key in recommended_pr_fast_tools recommended_main_gate_tools recommended_scheduled_tools; do
		_col=$((_col + 1))
		_listed=$(printf '%s' "$_row" | awk -F'|' -v c="$_col" '{gsub(/^[ \t]+|[ \t]+$/,"",$(c+1)); print $(c+1)}')
		case "$_listed" in '' | '_(none)_' | '(none)') continue ;; esac
		for _t in $(printf '%s' "$_listed" | tr ',' ' ' | tr -d '`'); do
			jq -e --arg k "$_key" --arg t "$_t" \
				'((.[$k] // []) | index($t)) != null' "$_mf" >/dev/null 2>&1 \
				|| fail "$_prof table lists '$_t' under $_key, but the manifest does not recommend it"
		done
	done
done <<EOF
$(grep -E '^\| [a-z0-9-]+ \| ' docs/profile-compatibility.md 2>/dev/null | grep -E '\| [0-9]+ \|[[:space:]]*$' || true)
EOF
# A parser that silently matches nothing would turn this whole section into a no-op.
if [ "$_rowchecked" -eq 0 ]; then
	fail "profile-compatibility table parsed 0 rows — the count check is not actually running"
fi

if [ "$FAILED" -eq 0 ]; then
	printf '\n268-documentation-accuracy: ALL CHECKS PASSED\n'
else
	printf '\n268-documentation-accuracy: FAILURES PRESENT\n'
fi
exit "$FAILED"
