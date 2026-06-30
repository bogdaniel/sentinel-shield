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

for f in "$WF_DIR"/*.yml; do
	[ -f "$f" ] || continue
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

	# (d) every actions/checkout step sets persist-credentials: false.
	co=$(printf '%s\n' "$CODE" | grep -cE 'uses:[[:space:]]*actions/checkout@' || true)
	pc=$(printf '%s\n' "$CODE" | grep -cE 'persist-credentials:[[:space:]]*false' || true)
	if [ "$co" -eq 0 ]; then
		pass "$b: no checkout steps (persist-credentials n/a)"
	elif [ "$pc" -ge "$co" ]; then
		pass "$b: persist-credentials:false on all $co checkout step(s)"
	else
		fail "$b: $co checkout step(s) but only $pc persist-credentials:false"
	fi

	# (e) no `curl ... | sh` pipe-to-shell install.
	if printf '%s\n' "$CODE" | grep -qE 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash)'; then
		fail "$b: contains curl | sh pipe-to-shell"
	else
		pass "$b: no curl | sh"
	fi
done

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
exit 0
