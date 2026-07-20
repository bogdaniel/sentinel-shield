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

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf 'checked %d workflow template(s)\n' "$_seen"
exit 0
