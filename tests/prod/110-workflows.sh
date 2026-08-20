#!/bin/sh
# Sentinel Shield production test — workflow template hardening (WS11).
#
# NOTE: actionlint and zizmor are NOT installed in this environment, so this test
# enforces grep/yq STRUCTURAL invariants only. It does NOT replace those linters —
# actionlint + zizmor MUST still be run in CI against templates/workflows/*.yml.
#
# Per templates/workflows/*.yml this asserts:
#   (a) every third-party `uses:` is pinned to a full 40-hex commit SHA
#       (local './' refs are allowed; SHA-pinned 'actions/*' counts as pinned);
#   (b) no `pull_request_target` trigger;
#   (c) a `permissions:` block is present;
#   (d) every actions/checkout step sets persist-credentials: false;
#   (e) no `curl ... | sh` (pipe-to-shell) install.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

WF_DIR="$ROOT/templates/workflows"
FAILS=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

printf '# NOTE: actionlint/zizmor were NOT run (not installed); run them in CI too.\n'

if [ ! -d "$WF_DIR" ]; then
	fail "workflow dir missing: templates/workflows"
	printf '\n1 assertion(s) failed\n' >&2
	exit 1
fi
pass "workflow dir present: templates/workflows"

# Effective lines only: drop lines whose first non-space char is '#' so commented
# mentions (e.g. "no pull_request_target") never trip the invariants below.
code_lines() { grep -vE '^[[:space:]]*#' "$1"; }

# Guard against an EMPTY glob. If templates/workflows/ is renamed or converted to .yaml,
# the loop body never runs, FAILS stays 0, and all five hardening invariants (SHA pinning,
# no pull_request_target, permissions:, persist-credentials:false, no curl|sh) silently
# stop being enforced while the log still looks healthy. 111-workflow-timeouts.sh already
# guards this way; this suite did not.
_seen=0
for f in "$WF_DIR"/*.yml; do
	[ -f "$f" ] || continue
	_seen=$((_seen + 1))
	b=$(basename "$f")
	CODE=$(code_lines "$f")

	# (a) every third-party `uses:` pinned to a 40-hex SHA (local './' allowed).
	unpinned=$(printf '%s\n' "$CODE" \
		| grep -E '^[[:space:]]*-?[[:space:]]*uses:' \
		| sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//; s/[[:space:]]*#.*$//' \
		| grep -vE '^\./' \
		| grep -vE '@[0-9a-f]{40}$' || true)
	if [ -z "$unpinned" ]; then
		pass "$b: all third-party uses pinned to a 40-hex SHA"
	else
		fail "$b: tag/unpinned uses -> $(printf '%s' "$unpinned" | tr '\n' ' ')"
	fi

	# (b) no pull_request_target. Strip inline comments first so a benign mention
	# (e.g. "# no pull_request_target") is not mistaken for an actual trigger.
	if printf '%s\n' "$CODE" | sed -E 's/[[:space:]]#.*$//' | grep -qE '\bpull_request_target\b'; then
		fail "$b: uses pull_request_target"
	else
		pass "$b: no pull_request_target"
	fi

	# (c) a permissions: block is present.
	if printf '%s\n' "$CODE" | grep -qE '^[[:space:]]*permissions:'; then
		pass "$b: has a permissions: block"
	else
		fail "$b: missing permissions: block"
	fi

	# (d) every actions/checkout step sets persist-credentials: false — checked
	# PER STEP. A global count would let one hardened checkout mask an unhardened
	# one; instead split CODE into list-item ('- ') step blocks and require each
	# block that checks out the repo to carry persist-credentials: false itself.
	counts=$(printf '%s\n' "$CODE" | awk '
		function flush() {
			if (have && block ~ /uses:[[:space:]]*actions\/checkout@/) {
				total++
				if (block ~ /persist-credentials:[[:space:]]*false/) ok++
			}
		}
		/^[[:space:]]*-[[:space:]]/ { flush(); block=""; have=1 }
		{ block = block "\n" $0 }
		END { flush(); printf "%d %d", total+0, ok+0 }
	')
	co=${counts% *}
	pc=${counts#* }
	if [ "$co" -eq 0 ]; then
		pass "$b: no checkout steps (persist-credentials n/a)"
	elif [ "$pc" -eq "$co" ]; then
		pass "$b: persist-credentials:false on all $co checkout step(s)"
	else
		fail "$b: $co checkout step(s) but only $pc with persist-credentials:false"
	fi

	# (e) no `curl ... | sh` pipe-to-shell install.
	if printf '%s\n' "$CODE" | grep -qE 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash)'; then
		fail "$b: contains curl | sh pipe-to-shell"
	else
		pass "$b: no curl | sh"
	fi
done

# Zero workflow files means zero assertions ran — an empty glob must be a FAILURE, not a
# silent green. Without this the suite exits 0 having verified nothing. (#53)
if [ "$_seen" -eq 0 ]; then
	fail "no workflow files found under $WF_DIR — the hardening invariants were not checked"
fi

# No scanner container image may use a MUTABLE `:latest` tag. A floating tag in the job that
# produces release evidence means the scanner set can change silently between two runs of the
# SAME commit — the acceptance artifact stops being reproducible — and a republished upstream
# tag is code execution with the repository bind-mounted. The repo already enforces 40-hex SHA
# pins on `uses:`; that discipline stopped at container images. (#55)
_latest=0
for _wf in "$WF_DIR"/*.yml "$ROOT"/.github/workflows/*.yml; do
	[ -f "$_wf" ] || continue
	# Executable positions only (`docker run …`, `image:`) — never prose in a comment.
	_hits=$(grep -nE '^[^#]*(docker[[:space:]]+run|image:)[^#]*:latest' "$_wf" 2>/dev/null || true)
	if [ -n "$_hits" ]; then
		fail "$(basename "$_wf"): uses a mutable :latest scanner image"
		printf '%s\n' "$_hits" | sed 's/^/    /'
		_latest=$((_latest + 1))
	fi
done
[ "$_latest" -eq 0 ] && pass "no workflow uses a mutable :latest scanner image"

# --- the backlog-reconciliation governance check ---------------------------
#
# tests/prod/112's live half is the only thing that detects plan drift, and it reports SKIP
# without an authenticated `gh`. Drift reached master green twice that way. The fix is a
# dedicated workflow that supplies the credential and refuses to proceed without it — so the
# properties that make it worth having are asserted here rather than assumed.
_BR="$ROOT/.github/workflows/ci-backlog-reconciliation.yml"
if [ ! -f "$_BR" ]; then
	fail "ci-backlog-reconciliation.yml is missing — nothing in CI runs 112's live half"
else
	pass "ci-backlog-reconciliation workflow exists"

	grep -qE '^[[:space:]]+issues:[[:space:]]*read' "$_BR" \
		&& pass "backlog-reconciliation declares issues: read" \
		|| fail "backlog-reconciliation does not declare issues: read — 112's live half cannot run"

	# The flag is the whole point: without it 112 SKIPs and the job passes over an unexecuted
	# half, which is the state this workflow exists to end.
	# Anchored on the exact YAML key. A substring match passes for a RENAMED variable —
	# `SENTINEL_SHIELD_REQUIRE_LIVE_BACKLOG_TYPO` contains the name — and a mutation proved
	# this assertion green against exactly that, which is the defect class it is meant to stop.
	grep -qE '^[[:space:]]+SENTINEL_SHIELD_REQUIRE_LIVE_BACKLOG:[[:space:]]*.?1' "$_BR" \
		&& pass "backlog-reconciliation sets SENTINEL_SHIELD_REQUIRE_LIVE_BACKLOG=1" \
		|| fail "backlog-reconciliation does not set the flag to 1 — 112 would SKIP and the job would pass"

	# Authentication must be PROVEN by a real query. `gh auth status` succeeds for a token with
	# no `issues` scope, which would fail 112 for the wrong reason.
	grep -q 'gh issue list' "$_BR" \
		&& pass "backlog-reconciliation proves issue-read access with a real query" \
		|| fail "backlog-reconciliation does not prove issue-read access before reconciling"

	# The credential must NOT have been added to the general production sweep instead.
	if grep -qE '^[[:space:]]+issues:[[:space:]]*read' "$ROOT/.github/workflows/ci-production-readiness.yml" 2>/dev/null; then
		fail "ci-production-readiness now declares issues: read — the token surface of a 94-suite sweep was widened to serve one check"
	else
		pass "ci-production-readiness still carries no issues: read scope"
	fi

	# 112 must actually honour the flag. A workflow that sets a variable no test reads is
	# theatre, so the contract is asserted from the consuming side too.
	# Anchored on the parameter expansion 112 actually reads, for the same reason.
	grep -qE '\$\{SENTINEL_SHIELD_REQUIRE_LIVE_BACKLOG:-' "$ROOT/tests/prod/112-remediation-plan.sh" \
		&& pass "112 reads SENTINEL_SHIELD_REQUIRE_LIVE_BACKLOG" \
		|| fail "112 does not read the flag — the workflow sets a variable nothing consumes"

	# The probe must judge the API call on SUCCESS AND SHAPE, not on the answer being
	# non-empty. Its first version required `n > 0`, which would fail a repository whose
	# backlog is legitimately empty — the state this whole programme is working toward.
	if grep -qE '\[ "\$n" -gt 0 \]' "$_BR"; then
		fail "backlog-reconciliation still requires a NON-EMPTY backlog — an empty backlog is a valid state, not a failed query"
	else
		pass "backlog-reconciliation does not require a non-empty backlog"
	fi
	grep -q 'type == "array"' "$_BR" \
		&& pass "backlog-reconciliation judges the query on JSON-array shape" \
		|| fail "backlog-reconciliation does not assert the response shape — a failed query could read as an empty backlog"

	# Drift is introduced by ISSUE events, not only by commits. The schedule stays as a
	# backstop and is asserted separately: if the events were removed, a 24h-latency check
	# must not silently become the only one.
	grep -qE '^[[:space:]]+issues:' "$_BR" \
		&& pass "backlog-reconciliation is triggered by issue events" \
		|| fail "backlog-reconciliation has no issues: trigger — a GitHub-UI closure would wait for the daily run"
	grep -qE '^[[:space:]]+schedule:' "$_BR" \
		&& pass "backlog-reconciliation keeps the daily schedule as a backstop" \
		|| fail "backlog-reconciliation lost its schedule — nothing then covers a missed webhook"
	for _ev in closed deleted transferred; do
		grep -qE "types:.*$_ev" "$_BR" \
			&& pass "backlog-reconciliation reconciles on issue '$_ev'" \
			|| fail "backlog-reconciliation ignores issue '$_ev' — that transition removes an issue from the open set"
	done

	# DYNAMIC: the finished state must actually pass, and corruption must still fail. A static
	# grep proves a guard was reworded; only running it proves the state is reachable.
	_bt=$(mktemp -d)
	printf '#!/bin/sh\ncase "$1 $2" in\n"auth status") exit 0 ;;\n"issue list") printf "[]\\n"; exit 0 ;;\nesac\nexit 0\n' > "$_bt/gh"
	chmod +x "$_bt/gh"
	jq '.issues = [] | .milestones = []' "$ROOT/config/remediation-plan.json" > "$_bt/empty-plan.json"
	# A FINISHED PROGRAMME IS FINISHED ON BOTH DOCUMENTS. Emptying the plan alone left the
	# semantic reconciliation debt list populated, and every entry then named an issue the plan no
	# longer contains — which is stale debt, and correctly fatal. That state is not "finished", it
	# is inconsistent. The simulation supplies an empty debt list for the same reason it supplies
	# an empty plan: the end state has no outstanding exceptions, and no exemption CATEGORIES either
	# — a class with no members is a slot for the next thing that wants excusing.
	jq '.reconciliation_debt.entries = [] | .reconciliation_debt.classes = {}' \
		"$ROOT/config/backlog-semantics.json" > "$_bt/empty-semantics.json"
	if PATH="$_bt:$PATH" SENTINEL_PLAN_FILE="$_bt/empty-plan.json" \
		SENTINEL_SEMANTICS_FILE="$_bt/empty-semantics.json" \
		sh "$ROOT/tests/prod/112-remediation-plan.sh" >/dev/null 2>&1; then
		pass "DYNAMIC: an empty live backlog with an empty plan PASSES — the finished state is reachable"
	else
		fail "DYNAMIC: a finished programme (no open issues, empty plan) fails its own governance check"
	fi
	# CONTROL: without this, the assertion above is satisfied by a check that passes anything.
	jq '.issues = "not-an-array"' "$ROOT/config/remediation-plan.json" > "$_bt/broken-plan.json"
	if PATH="$_bt:$PATH" SENTINEL_PLAN_FILE="$_bt/broken-plan.json" \
		sh "$ROOT/tests/prod/112-remediation-plan.sh" >/dev/null 2>&1; then
		fail "DYNAMIC CONTROL: a malformed .issues was accepted — 'empty is valid' was widened into 'anything is valid'"
	else
		pass "DYNAMIC CONTROL: a malformed .issues is still fatal"
	fi
	rm -rf "$_bt"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf 'checked %d workflow template(s)\n' "$_seen"
exit 0
