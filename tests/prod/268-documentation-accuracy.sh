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
# `- uses:` (list form) counts too. The previous pattern matched only `uses:` at the start of
# a line, so 14 of the shipped references were never checked for pinning and never included in
# the count the inventory is validated against — an unpinned action in list form would have
# passed both.
_tot=$(grep -rhoE '^[[:space:]]*(- )?uses: [^[:space:]]+' .github/workflows/ templates/workflows/ 2>/dev/null | grep -c . || true)
# The SHA must END after 40 hex characters. `@[0-9a-f]{40}` alone matches a PREFIX, so a
# 41-character hex ref — or a branch/tag whose name begins with 40 hex — counted as pinned and
# was dropped from the unpinned list. Neither is immutable. Anchored to end-of-token, allowing
# only trailing whitespace or a YAML comment after it.
_pin=$(grep -rhE '^[[:space:]]*(- )?uses: [^@[:space:]]+@[0-9a-f]{40}([[:space:]]|#|$)' .github/workflows/ templates/workflows/ 2>/dev/null | grep -c . || true)
case "$_tot" in '' | *[!0-9]*) _tot=0 ;; esac
case "$_pin" in '' | *[!0-9]*) _pin=0 ;; esac
check "every 'uses:' is SHA-pinned ($_pin/$_tot)" "$_pin" "$_tot"
# Enumerate the two step forms SEPARATELY, so neither can be silently absent. The original
# pattern matched only mapping-form `uses:` at line start; the 14 list-form `- uses:` steps
# were never counted and never pin-checked, so an unpinned action written in list form passed
# both this assertion and the inventory's cited count.
_map_tot=$(grep -rhoE '^[[:space:]]*uses: [^[:space:]]+' .github/workflows/ templates/workflows/ 2>/dev/null | grep -c . || true)
_lst_tot=$(grep -rhoE '^[[:space:]]*- uses: [^[:space:]]+' .github/workflows/ templates/workflows/ 2>/dev/null | grep -c . || true)
case "$_map_tot" in '' | *[!0-9]*) _map_tot=0 ;; esac
case "$_lst_tot" in '' | *[!0-9]*) _lst_tot=0 ;; esac
[ "$_map_tot" -gt 0 ] && pass "mapping-form 'uses:' steps are enumerated ($_map_tot)" \
	|| fail "no mapping-form 'uses:' steps were found — that form would go unchecked"
[ "$_lst_tot" -gt 0 ] && pass "list-form '- uses:' steps are enumerated ($_lst_tot)" \
	|| fail "no list-form '- uses:' steps were found — that form would go unchecked, which is exactly how 14 references escaped this suite"
[ $((_map_tot + _lst_tot)) -eq "$_tot" ] && pass "  and the two forms account for every counted reference" \
	|| fail "  the two forms sum to $((_map_tot + _lst_tot)) but $_tot were counted — a third step form is unaccounted for"

# REGRESSION CONTROL: an unpinned LIST-FORM step must fail this suite for the pinning reason,
# not merely because a total moved. Run the pin check against a fixture tree, so the assertion
# is about detection rather than about the repository happening to be clean.
_pf=$(mktemp -d)
mkdir -p "$_pf/.github/workflows"
cp .github/workflows/*.yml "$_pf/.github/workflows/" 2>/dev/null || true
printf 'name: probe
on: push
jobs:
  p:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: evilcorp/rogue-action@v1
' 	> "$_pf/.github/workflows/zz-probe.yml"
# A 41-character hex ref is NOT a SHA pin: `@[0-9a-f]{40}` matches only its PREFIX, so it was
# counted as pinned and dropped from the unpinned list. A branch whose name merely begins with
# 40 hex characters behaves the same way. Neither is immutable.
_long_hex=$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1)
printf 'name: probe2\non: push\njobs:\n  q:\n    runs-on: ubuntu-latest\n    timeout-minutes: 5\n    steps:\n      - uses: evilcorp/long-hex@%s\n' \
	"$_long_hex" > "$_pf/.github/workflows/zz-probe2.yml"
_p_tot=$(grep -rhoE '^[[:space:]]*(- )?uses: [^[:space:]]+' "$_pf/.github/workflows/" 2>/dev/null | grep -c . || true)
_p_pin=$(grep -rhE '^[[:space:]]*(- )?uses: [^@[:space:]]+@[0-9a-f]{40}([[:space:]]|#|$)' "$_pf/.github/workflows/" 2>/dev/null | grep -c . || true)
case "$_p_tot" in '' | *[!0-9]*) _p_tot=0 ;; esac
case "$_p_pin" in '' | *[!0-9]*) _p_pin=0 ;; esac
_unpinned=$(grep -rhoE '^[[:space:]]*(- )?uses: [^[:space:]]+' "$_pf/.github/workflows/" 2>/dev/null \
	| grep -vE '@[0-9a-f]{40}$' | sed 's/^[[:space:]]*//')
if [ "$_p_pin" -eq "$_p_tot" ]; then
	fail "regression control: an unpinned LIST-FORM '- uses:' was NOT detected — the pin check cannot see that step form"
elif printf '%s' "$_unpinned" | grep -q 'evilcorp/rogue-action@v1'; then
	pass "regression control: an unpinned list-form '- uses:' is detected, and named"
	if printf '%s' "$_unpinned" | grep -q 'evilcorp/long-hex@'; then
		pass "regression control: a 41-character hex ref is classified unpinned, not pinned"
	else
		fail "regression control: a 41-character hex ref was treated as a SHA pin — that is a prefix match, not an immutable reference"
	fi
else
	fail "regression control: the count changed but the unpinned step was not identified — the failure would not say why"
fi
rm -rf "$_pf"

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

# --- a cited tag target must be the commit that tag actually points at -------
# support-policy.md described v2.0.1 as "tag target 13be630" — that is v2.0.0's commit.
# A wrong tag target sends someone auditing the wrong release; prose citing an immutable
# identifier must be checked against the identifier, not merely against other prose.
# Read the candidate lines from a here-doc, NOT a pipe: `cmd | while read` runs the loop in
# a subshell, so `fail`'s FAILED=1 would be discarded and a mismatch would print but not fail.
if git rev-parse --git-dir >/dev/null 2>&1; then
	# grep is line-based, so a claim wrapped across two lines matches nothing and the check
	# silently covers less than it appears to. That already happened once here: the v2.0.1
	# claim wrapped, only v2.0.0 was verified, and swapping v2.0.1's tag still "passed".
	# Assert the claim count so under-coverage fails loudly instead of reading as clean.
	_tagclaims=$(grep -ohE '`v[0-9]+\.[0-9]+\.[0-9]+`[^`]{0,120}tag target `[0-9a-f]{7,40}`' docs/support-policy.md 2>/dev/null | grep -c . || true)
	case "$_tagclaims" in '' | *[!0-9]*) _tagclaims=0 ;; esac
	# Three claims since v2.2.0 became current: v2.2.0 (latest) plus the intact v2.0.1/v2.0.0.
	# The literal is the COUNT, not the versions — the loop below checks each cited target
	# against the real tag, and config/release-status.json is the canonical version source.
	check "support-policy.md states all three tag-target claims on single lines (grep-visible)" "$_tagclaims" "3"

	while IFS= read -r _line; do
		[ -n "$_line" ] || continue
		_ver=$(printf '%s' "$_line" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
		_cited=$(printf '%s' "$_line" | grep -oE 'tag target `[0-9a-f]{7,40}`' | grep -oE '[0-9a-f]{7,40}' | head -n1)
		[ -n "$_ver" ] && [ -n "$_cited" ] || continue
		_real=$(git rev-list -n1 "$_ver" 2>/dev/null || true)
		if [ -z "$_real" ]; then
			pass "support-policy.md cites $_ver (tag not present locally; not checkable)"
		else
			_short=$(printf '%s' "$_real" | cut -c1-"${#_cited}")
			check "support-policy.md's tag target for $_ver matches the real tag" "$_cited" "$_short"
		fi
	done <<EOF
$(grep -ohE '`v[0-9]+\.[0-9]+\.[0-9]+`[^\`]{0,120}tag target `[0-9a-f]{7,40}`' docs/support-policy.md 2>/dev/null)
EOF
fi
_latest=$(grep -oE 'v2\.[0-9]+\.[0-9]+' CHANGELOG.md 2>/dev/null | head -n1 || true)
if [ -n "$_latest" ]; then
	if grep -q "$_latest" docs/support-policy.md 2>/dev/null; then
		pass "support-policy.md cites the current release ($_latest)"
	else
		fail "support-policy.md does not mention $_latest — the entitlement doc lags the release"
	fi
fi

# --- the gate count must not be asserted as a stale literal ------------------
# A test harness must not be able to exit 0 without finishing.
#
# `trap 'rm -rf …' EXIT` ends with a successful `rm`, and that success became the script's
# status: an abort part-way through exited 0 and this suite printed ALL CHECKS PASSED while
# every check after the abort never ran. Capturing `$?` in the trap does not fix it either —
# under bash-as-/bin/sh the EXIT trap observes `$? = 0` for a `set -u` abort (verified: bash
# reports 0, dash reports 2), so the status is not available to preserve at all.
#
# Both dimensions are therefore tracked EXPLICITLY and neither is inferred from `$?`:
#   COMPLETED  did the script reach its end at all
#   FINAL_RC   what the run actually decided, set only on a normal outcome
# `trap - EXIT` inside the handler prevents re-entry, and the deliberate final status can never
# be replaced by the cleanup's own.
COMPLETED=0
FINAL_RC=1
_w=$(mktemp -d)
cleanup() {
	rm -rf -- "$_w"

	trap - EXIT

	if [ "$COMPLETED" -ne 1 ]; then
		printf '%s\n' "268-documentation-accuracy: ABORTED before completion — the checks after the abort never ran, so this run proves nothing" >&2
		exit 1
	fi

	exit "$FINAL_RC"
}
trap cleanup EXIT INT TERM HUP
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

# --- every profile manifest appears in the managed-file inventory ------------
# The inventory is hand-written prose describing an executable contract (what install
# writes into a consumer). `hardened-enterprise` shipped without an entry, so a reader
# could not learn that it installs a `.semgrepignore`. Assert the set of documented
# profiles equals the set of manifests, and that each documented row names a target the
# manifest actually declares.
_invmiss=""; _invmode=""
for _pm in "$ROOT"/profiles/*/profile.manifest.json "$ROOT"/profiles/combinations/*.manifest.json; do
	[ -f "$_pm" ] || continue
	case "$_pm" in
		*/combinations/*) _pname=$(basename "$_pm" .manifest.json) ;;
		*) _pname=$(basename "$(dirname "$_pm")") ;;
	esac
	grep -q "Profile: \`$_pname\`" "$ROOT/docs/managed-file-inventory.md" || _invmiss="$_invmiss $_pname"
	# Every managed target must be listed IN THIS PROFILE'S OWN SECTION. Searching the whole
	# document let a missing row pass because the same target name (`.semgrepignore`) appears
	# under other profiles — the check would have reported success with the row absent.
	_sec=$(awk -v p="Profile: \`$_pname\`" '
		index($0, p) > 0 { inb = 1; next }
		inb && /^### / { inb = 0 }
		inb { print }' "$ROOT/docs/managed-file-inventory.md")
	for _tgt in $(jq -r '(.files // [])[].target' "$_pm" 2>/dev/null); do
		printf '%s\n' "$_sec" | grep -q -- "\`$_tgt\`" \
			|| { _invmiss="$_invmiss ${_pname}:${_tgt}"; continue; }
		# Listing the row is not enough: the row states a MODE, and a mode that disagrees with
		# the manifest is worse than an absent row because it reads as authoritative. Five
		# profiles moved .semgrepignore to `merge-required-lines` while every documented row
		# still said `create-if-missing`, and the presence check above was satisfied by both.
		_mmode=$(jq -r --arg t "$_tgt" '(.files // [])[] | select(.target==$t) | .mode' "$_pm" 2>/dev/null | head -n1)
		[ -n "$_mmode" ] || continue
		_dmode=$(printf '%s\n' "$_sec" | awk -F'|' -v t="\`$_tgt\`" '
			{ c2=$2; gsub(/^[ \t]+|[ \t]+$/, "", c2) }
			c2 == t { c4=$4; gsub(/^[ \t]+|[ \t]+$/, "", c4); print c4; exit }')
		[ "$_dmode" = "$_mmode" ] \
			|| _invmode="$_invmode ${_pname}:${_tgt}(doc='${_dmode:-none}',manifest='$_mmode')"
	done
done
if [ -n "$_invmiss" ]; then
	fail "managed-file inventory is missing:$_invmiss"
else
	pass "every profile manifest and managed target is documented in the managed-file inventory"
fi
if [ -n "$_invmode" ]; then
	fail "managed-file inventory states a mode the manifest contradicts:$_invmode"
else
	pass "every documented managed-file mode matches its profile manifest"
fi

# --- "off by default" must not be claimed for the v2.2 gate families ---------
# The families are ADDITIVE, not uniformly disabled: resolve-gates.sh enables
# architecture_violations, changed_lines_coverage_violations, acceptance_test_failures,
# missing_test_evidence, empty_test_suite and debug_code_violations from `baseline`, and
# focused_test_violations in EVERY mode. Prose saying "off by default in existing modes"
# tells an adopter upgrading changes no gate outcome, which is false. Published release
# notes are excluded: they are immutable historical records of what was said at the time.
# `grep -r "$ROOT"/docs/*.md` is a shell glob over TOP-LEVEL files only — `-r` never sees a
# nested directory. Walk the whole docs tree so a stale claim under docs/<subdir>/ cannot hide.
# Every phrasing of the claim, not just one: the first sweep matched only the exact string
# "off by default in existing modes", so `(engine-only; off by default in existing modes)` and
# "additive, off by default in existing modes" shipped straight past it.
_offclaim=$(find "$ROOT/docs" -type f -name '*.md' -print 2>/dev/null | LC_ALL=C sort |
	{ xargs grep -lE 'off by default[^.]{0,40}existing modes' 2>/dev/null || true; } |
	grep -v -- '-release-notes\.md$' || true)
if grep -q 'off by default in existing modes' "$ROOT/README.md" 2>/dev/null; then
	_offclaim="$_offclaim
$ROOT/README.md"
fi
if [ -n "$_offclaim" ]; then
	fail "these docs still claim the v2.2 gate families are off by default in existing modes: $(printf '%s' "$_offclaim" | tr '\n' ' ')"
else
	pass "no active doc claims the v2.2 gate families are off by default in existing modes"
fi
# The claim is false BECAUSE the resolver enables these in baseline — assert that, so the
# check above cannot be satisfied by weakening the engine instead of the prose.
# The resolver's own result is checked BEFORE anything is asserted about its output. It used
# to be `>/dev/null 2>&1` with the status discarded: a resolver that failed, or wrote no env
# file, made every gate below report "baseline no longer enforces <gate>" — pointing the
# operator at gate defaults when the actual fault was the run that never produced them.
#
# The temp dir is removed by a trap rather than a trailing `rm`, so an assertion that aborts
# the script does not leak it. `trap` is additive here: the existing EXIT handler is preserved.
# `trap -p EXIT` is a bashism — dash, which is /bin/sh on the CI runner, does not support it,
# so the "preserve the caller's handler" logic silently produced an empty string there. The
# only EXIT handler this suite has is the WORK cleanup installed at the top, so the temp dir is
# simply created INSIDE it and removed with the rest. No handler to preserve, nothing to lose.
_benv="$_w/baseline-env"
mkdir -p "$_benv"
if ! sh "$ROOT/scripts/resolve-gates.sh" --mode baseline --output-dir "$_benv" --format env >"$_benv/out" 2>&1; then
	fail "resolve-gates.sh --mode baseline FAILED; the gate assertions below would blame the gate defaults for a resolver fault"
	sed 's/^/       /' "$_benv/out" 2>/dev/null | head -5
elif [ ! -s "$_benv/sentinel-shield-gates.env" ]; then
	fail "resolve-gates.sh --mode baseline wrote no gate env; the gate assertions below cannot mean anything"
else
	pass "the baseline resolution used by the assertions below actually succeeded"
	for _g in architecture_violations changed_lines_coverage_violations focused_test_violations; do
		if grep -q "^SENTINEL_SHIELD_FAIL_ON_$(printf '%s' "$_g" | tr 'a-z' 'A-Z')=true" "$_benv/sentinel-shield-gates.env" 2>/dev/null; then
			pass "baseline really does enforce $_g (so the prose above must not say otherwise)"
		else
			fail "baseline no longer enforces $_g — the doc claim and the engine have swapped places"
		fi
	done
fi

# --- the documented mode enum must cover the modes actually shipped -----------
# profile-compatibility.md states the manifest `mode` enum twice: in prose, and in an embedded
# Python reproduction a reader is invited to run. `merge-required-lines` shipped in five
# manifests while both copies still listed four modes, so that reproduction would have
# assert-failed for anyone who ran it — on manifests that are perfectly valid.
_modes_used=$(for _m in "$ROOT"/profiles/*/profile.manifest.json "$ROOT"/profiles/combinations/*.manifest.json; do
	[ -f "$_m" ] || continue
	jq -r '((.files // []) + (.workflows // []) + (.docs // []))[].mode' "$_m" 2>/dev/null
done | sort -u)
[ -n "$_modes_used" ] || fail "no manifest modes were read — this check would pass vacuously"
_undocumented=""
for _mode in $_modes_used; do
	grep -q -- "$_mode" "$ROOT/docs/profile-compatibility.md" 2>/dev/null || _undocumented="$_undocumented $_mode"
done
if [ -z "$_undocumented" ]; then
	pass "every manifest mode in use appears in profile-compatibility.md"
else
	fail "manifests use mode(s)$_undocumented that profile-compatibility.md does not document — its embedded reproduction would assert-fail on a valid manifest"
fi

if [ "$FAILED" -eq 0 ]; then
	printf '\n268-documentation-accuracy: ALL CHECKS PASSED\n'
	FINAL_RC=0
else
	printf '\n268-documentation-accuracy: FAILURES PRESENT\n'
	FINAL_RC=1
fi
COMPLETED=1
exit "$FINAL_RC"
