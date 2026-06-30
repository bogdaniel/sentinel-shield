#!/bin/sh
# Sentinel Shield prod test — local scanner sweep is a NON-authoritative convenience.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

SWEEP="$ROOT/scripts/run-local-scanner-sweep.sh"
DEPRECATED="$ROOT/scripts/run-local-security.sh"

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t sssweep)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

mkdir -p "$tmp/proj"

# link_base <dir> — populate <dir> with the base utilities the scripts need (sh +
# dirname for the wrapper's SCRIPT_DIR), but deliberately NO security scanners.
link_base() {
	mkdir -p "$1"
	for u in sh dirname; do
		_p=$(command -v "$u")
		ln -s "$_p" "$1/$u" 2>/dev/null || cp "$_p" "$1/$u"
	done
}

# A PATH with NO scanners installed (base utils only, so sweep + wrapper can run).
clean="$tmp/clean"
link_base "$clean"

# A PATH where one scanner (gitleaks) exists and reports findings (exit 1).
findbin="$tmp/findbin"
link_base "$findbin"
printf '#!/bin/sh\nexit 1\n' > "$findbin/gitleaks"
chmod +x "$findbin/gitleaks"

# (a) Header AND runtime banner declare NON-authoritative / not gate evidence.
if grep -iq 'non-authoritative' "$SWEEP" && grep -iq 'gate evidence' "$SWEEP"; then
	pass "sweep header declares NON-authoritative / not gate evidence"
else
	fail "sweep header missing NON-authoritative / gate-evidence disclaimer"
fi
out=$(PATH="$clean" sh "$SWEEP" --target "$tmp/proj" 2>/dev/null) || true
if printf '%s' "$out" | grep -iq 'non-authoritative'; then
	pass "sweep stdout banner states NON-authoritative"
else
	fail "sweep stdout banner missing NON-authoritative"
fi

# (b) Default invocation exits 0 with no scanners installed (skips gracefully).
if PATH="$clean" sh "$SWEEP" --target "$tmp/proj" >/dev/null 2>&1; then
	pass "default sweep exits 0 with no scanners installed"
else
	fail "default sweep did not exit 0 with no scanners installed"
fi

# (b2) Default mode stays 0 even when an installed scanner reports findings.
if PATH="$findbin" sh "$SWEEP" --target "$tmp/proj" >/dev/null 2>&1; then
	pass "default sweep exits 0 even when a scanner reports findings"
else
	fail "default sweep should exit 0 despite findings"
fi

# (c) --strict-exit path exists: documented, and exits nonzero on findings.
if grep -q -- '--strict-exit' "$SWEEP"; then
	pass "sweep documents/accepts --strict-exit"
else
	fail "sweep missing --strict-exit"
fi
if PATH="$clean" sh "$SWEEP" --strict-exit --target "$tmp/proj" >/dev/null 2>&1; then
	pass "--strict-exit with no findings exits 0"
else
	fail "--strict-exit with no findings should exit 0"
fi
if PATH="$findbin" sh "$SWEEP" --strict-exit --target "$tmp/proj" >/dev/null 2>&1; then
	fail "--strict-exit should exit nonzero when a scanner reports findings"
else
	pass "--strict-exit exits nonzero when a scanner reports findings"
fi

# (d) Deprecated wrapper emits a notice to stderr and still works (passes args through).
err=$(PATH="$clean" sh "$DEPRECATED" --target "$tmp/proj" 2>&1 >/dev/null) || true
if printf '%s' "$err" | grep -iq 'deprecat'; then
	pass "run-local-security.sh emits a deprecation notice to stderr"
else
	fail "run-local-security.sh missing deprecation notice"
fi
if PATH="$clean" sh "$DEPRECATED" --target "$tmp/proj" >/dev/null 2>&1; then
	pass "deprecated wrapper still works (exit 0, args passed through)"
else
	fail "deprecated wrapper did not exit 0"
fi

if [ "$fails" -eq 0 ]; then
	echo "50-sweep: all assertions passed"
	exit 0
else
	echo "50-sweep: $fails assertion(s) failed"
	exit 1
fi
