#!/bin/sh
# Sentinel Shield prod test — summary build integrity (#235, #236, #238).
#
# #235  `.tools` was built with `reduce .[] as $c ({}; .[$c.tool] = $c.tool_report)`, so two
#       producers emitting one channel name silently overwrote each other's evidence while
#       both remained in the aggregate counts — a clean report could replace a failing one
#       and the counts would no longer be explainable by the details.
#
# #236  A profile-declared report was reduced to `$RAW_DIR/$(basename …)`, discarding every
#       directory: same-basename reports in different contexts collided, a missing report
#       could be satisfied by an unrelated artifact, and an absolute or traversing declared
#       path was never checked because only its last component survived.
#
# #238  The summary was written by redirecting jq at its final path: the previous summary
#       was truncated before generation began, the self-check ran on a file that had already
#       replaced it, a symlinked destination redirected the write, and concurrent builders
#       raced with no interlock.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
BUILD="$ROOT/scripts/build-security-summary.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

# build <raw-dir> <output> [extra args...] — run the builder, echoing its exit code.
build() {
	_r="$1"; _o="$2"; shift 2
	_c=0
	sh "$BUILD" --raw-dir "$_r" --output "$_o" "$@" >"$WORK/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}

# ---------------------------------------------------------------------------
# 1. #235 — every contributing producer survives.
# ---------------------------------------------------------------------------
D="$WORK/dup"; mkdir -p "$D/raw"
printf '{"status":"pass","violations":0}\n' > "$D/raw/php-style.json"
printf '{"status":"findings","violations":7}\n' > "$D/raw/php-cs-fixer.json"
check "two producers on one registered channel build" "$(build "$D/raw" "$D/s.json")" 0
check "  both producers are preserved under the channel" \
	"$(jq -r '[.tools.php_style.producers[].producer] | sort | join(",")' "$D/s.json")" "php-cs-fixer,php-style"
check "  the channel takes the WORST producer status, not the last one" \
	"$(jq -r '.tools.php_style.status' "$D/s.json")" "fail"
check "  the aggregate count still reflects both" "$(jq -r '.summary.style_violations' "$D/s.json")" 7
check "  each producer carries the checksum of the bytes it was read from" \
	"$(jq -r '[.tools.php_style.producers[] | select(.sha256 != null)] | length' "$D/s.json")" 2
_sha=$(jq -r '.tools.php_style.producers[] | select(.producer == "php-cs-fixer") | .sha256' "$D/s.json")
_real=$( (sha256sum "$D/raw/php-cs-fixer.json" 2>/dev/null || shasum -a 256 "$D/raw/php-cs-fixer.json") | cut -d' ' -f1)
check "  and that checksum is the real one" "$_sha" "$_real"

# The result must not depend on which report happened to be written first.
D2="$WORK/dup-rev"; mkdir -p "$D2/raw"
printf '{"status":"findings","violations":7}\n' > "$D2/raw/php-cs-fixer.json"
printf '{"status":"pass","violations":0}\n' > "$D2/raw/php-style.json"
check "the reversed write order builds" "$(build "$D2/raw" "$D2/s.json")" 0
check "  and produces an identical channel view (order-independent)" \
	"$(jq -S -c '.tools.php_style | .producers |= map(.report = "-")' "$D2/s.json")" \
	"$(jq -S -c '.tools.php_style | .producers |= map(.report = "-")' "$D/s.json")"

# Failure-injection copies live in a temp COPY of scripts/ (the builder resolves its shared
# library relative to $0) — the real repo scripts are NEVER edited.
SBIN="$WORK/scripts"
cp -R "$ROOT/scripts" "$SBIN"
# inject <name> <sed-expression> — a patched builder inside the copied scripts/ tree.
inject() {
	sed "$2" "$ROOT/scripts/build-security-summary.sh" > "$SBIN/$1"
	cmp -s "$ROOT/scripts/build-security-summary.sh" "$SBIN/$1" && return 1
	return 0
}

# An UNREGISTERED duplicate emit name is a configuration failure.
D3="$WORK/collide"; mkdir -p "$D3/raw"
if inject build-collide.sh 's#^semgrep|semgrep.json|semgrep.sh|semgrep$#semgrep-two|semgrep.json|semgrep.sh|semgrep\
&#'; then
	pass "the temp copy declares a colliding row"
else
	fail "the collision injection did not apply"
fi
printf '{"results":[]}\n' > "$D3/raw/semgrep.json"
_c=0
sh "$SBIN/build-collide.sh" --raw-dir "$D3/raw" --output "$D3/s.json" >"$D3/log" 2>&1 || _c=$?
check "an unregistered duplicate emit name fails the build" "$_c" 2
contains "  the failure names the channel and both producers" "$(cat "$D3/log")" "semgrep <- semgrep, semgrep-two"
check "  and nothing was published" "$([ -e "$D3/s.json" ] && echo written || echo clean)" "clean"

# ---------------------------------------------------------------------------
# 2. #236 — the declared report path is consumed exactly.
# ---------------------------------------------------------------------------
mkprofile() { # mkprofile <root> <name> <report-path>
	mkdir -p "$1/profiles/$2"
	jq -n --arg n "$2" --arg r "$3" '{profile:$n, description:"prod-test fixture",
		tool_policy_version:2,
		tools:{gitleaks:{policy:"required", category:"secrets", report:$r,
			execution:{pr:true, main:true, scheduled:true}}}}' > "$1/profiles/$2/profile.manifest.json"
}
P="$WORK/profiles"; mkdir -p "$WORK/praw"
for _bad in '/etc/passwd|absolute' 'reports/raw/../../etc/passwd|traversal' 'raw/gitleaks.json|outside the raw root' 'reports/raw/gitleaks*.json|glob metacharacter'; do
	_path=${_bad%%|*}; _why=${_bad#*|}
	mkprofile "$P" bad "$_path"
	_c=0
	EP_REPO_ROOT="$P" sh "$BUILD" --raw-dir "$WORK/praw" --output "$WORK/praw-out.json" \
		--profile bad >"$WORK/plog" 2>&1 || _c=$?
	check "a declared report path with $_why is refused" "$_c" 2
	check "  and no summary was published" "$([ -e "$WORK/praw-out.json" ] && echo written || echo clean)" "clean"
done

# Directories are PRESERVED, so a MISSING nested report is not satisfied by a
# same-basename artifact sitting at the raw root: the declared evidence is absent, and the
# required tool reports it honestly instead of inheriting an unrelated file's verdict.
mkprofile "$P" nested "reports/raw/api/gitleaks.json"
N="$WORK/nested"; mkdir -p "$N/raw/api"
printf '{"status":"pass","findings":0}\n' > "$N/raw/gitleaks.json"
_c=0
EP_REPO_ROOT="$P" sh "$BUILD" --raw-dir "$N/raw" --output "$N/s.json" --profile nested >"$N/log" 2>&1 || _c=$?
check "a build with the nested report ABSENT still completes" "$_c" 0
check "  the same-basename artifact at the raw root does NOT satisfy it" \
	"$(jq -r '.tools.gitleaks.status' "$N/s.json")" "unavailable"
check "  and it counts as a required-tool failure" \
	"$(jq -r '.summary.required_tool_failures' "$N/s.json")" 1
# With the declared path present, the same profile resolves cleanly.
printf '{"status":"pass","findings":0}\n' > "$N/raw/api/gitleaks.json"
_c=0
EP_REPO_ROOT="$P" sh "$BUILD" --raw-dir "$N/raw" --output "$N/s2.json" --profile nested >"$N/log2" 2>&1 || _c=$?
check "the nested declared report is consumed once present" "$_c" 0
check "  the required tool is no longer unavailable" \
	"$(jq -r '.tools.gitleaks.status != "unavailable"' "$N/s2.json")" "true"

# A symlinked artifact is refused rather than followed out of the raw root.
S="$WORK/symrep"; mkdir -p "$S/raw/api"
printf '{"status":"pass","findings":0}\n' > "$S/outside.json"
ln -s "$S/outside.json" "$S/raw/api/gitleaks.json"
_c=0
EP_REPO_ROOT="$P" sh "$BUILD" --raw-dir "$S/raw" --output "$S/s.json" --profile nested >"$S/log" 2>&1 || _c=$?
check "a symlinked declared report is refused" "$_c" 2
contains "  the refusal names the symlink" "$(cat "$S/log")" "resolves to a symlink"

# ---------------------------------------------------------------------------
# 3. #238 — publication is staged, validated and atomic.
# ---------------------------------------------------------------------------
D="$WORK/pub"; mkdir -p "$D/raw"
check "a clean build publishes" "$(build "$D/raw" "$D/s.json")" 0
check "  the published summary states the operation that produced it" \
	"$(jq -r '(.build.operation_id | length) > 0' "$D/s.json")" "true"
check "  no staging directory is left behind" \
	"$(find "$D" -maxdepth 1 -name '.security-summary.stage.*' | wc -l | tr -d ' ')" 0
check "  no lock is left behind" \
	"$([ -e "$D/.security-summary.lock" ] && echo held || echo released)" "released"

printf '{"status":"pass","findings":0}\n' > "$D/raw/gitleaks.json"
check "a rebuild records the consumed report and its checksum" "$(build "$D/raw" "$D/s.json")" 0
check "  the input manifest names the producer" \
	"$(jq -r '[.build.inputs[] | select(.producer == "gitleaks")] | length' "$D/s.json")" 1
_real=$( (sha256sum "$D/raw/gitleaks.json" 2>/dev/null || shasum -a 256 "$D/raw/gitleaks.json") | cut -d' ' -f1)
check "  with the checksum of the bytes consumed" \
	"$(jq -r '.build.inputs[] | select(.producer == "gitleaks") | .sha256' "$D/s.json")" "$_real"

# Destination safety.
SY="$WORK/sym"; mkdir -p "$SY/raw"
ln -s "$SY/outside.json" "$SY/s.json"
check "a symlinked destination is refused" "$(build "$SY/raw" "$SY/s.json")" 2
check "  and nothing was written through it" \
	"$([ -e "$SY/outside.json" ] && echo written || echo clean)" "clean"

DD="$WORK/dir"; mkdir -p "$DD/raw" "$DD/s.json"
check "a directory destination is refused" "$(build "$DD/raw" "$DD/s.json")" 2

# A concurrent builder is refused rather than racing.
LK="$WORK/lock"; mkdir -p "$LK/raw" "$LK/.security-summary.lock"
check "a held lock refuses a second writer" "$(build "$LK/raw" "$LK/s.json")" 2
contains "  and says why" "$(cat "$WORK/log")" "refusing to race a second writer"
check "  the foreign lock is NOT removed by the refused build" \
	"$([ -d "$LK/.security-summary.lock" ] && echo held || echo removed)" "held"
rmdir "$LK/.security-summary.lock"

# Failure injection: a build whose assembly is corrupted must not replace a good summary.
FI="$WORK/inject"; mkdir -p "$FI/raw"
check "a good summary exists first" "$(build "$FI/raw" "$FI/s.json")" 0
_before=$(jq -S -c 'del(.generated_at, .build)' "$FI/s.json")
# (a) a summary counter that is not a number.
if inject build-badtype.sh 's|summary: (\$counts|summary: (($counts + {secrets: "many"})|'; then
	pass "  the type injection applied"
else
	fail "  the type injection did not apply"
fi
_c=0; sh "$SBIN/build-badtype.sh" --raw-dir "$FI/raw" --output "$FI/s.json" >"$FI/log2" 2>&1 || _c=$?
check "  a non-numeric summary value fails the build" "$_c" 2
contains "    naming the offending key" "$(cat "$FI/log2")" "summary.secrets must be a number or a boolean"
check "  the previous summary is untouched" "$(jq -S -c 'del(.generated_at, .build)' "$FI/s.json")" "$_before"
check "  and no staging directory survives the failure" \
	"$(find "$FI" -maxdepth 1 -name '.security-summary.stage.*' | wc -l | tr -d ' ')" 0
check "  and the lock is released" \
	"$([ -e "$FI/.security-summary.lock" ] && echo held || echo released)" "released"

# (b) evidence booleans that contradict the evidence block.
if inject build-badevidence.sh 's|missing_sbom: \$ms|missing_sbom: (if $ms then false else true end)|'; then
	pass "  the evidence injection applied"
else
	fail "  the evidence injection did not apply"
fi
_c=0; sh "$SBIN/build-badevidence.sh" --raw-dir "$FI/raw" --output "$FI/s.json" >"$FI/log3" 2>&1 || _c=$?
check "an inconsistent evidence boolean fails the build" "$_c" 2
contains "  naming the disagreement" "$(cat "$FI/log3")" "disagrees with evidence.sbom.present"
check "  the previous summary is still untouched" "$(jq -S -c 'del(.generated_at, .build)' "$FI/s.json")" "$_before"

# The published summary is still consumable by the enforcer (no contract regression).
E="$WORK/enf"; mkdir -p "$E"
sh "$ROOT/scripts/resolve-gates.sh" --mode baseline --output-dir "$E" --format all >/dev/null 2>&1
jq '.tools = {"tests":{"status":"pass"}}' "$D/s.json" > "$E/s.json"
_c=0
sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$E/sentinel-shield-gates.env" --summary "$E/s.json" \
	--output-dir "$E" --format json >"$E/log" 2>&1 || _c=$?
check "a freshly built summary still enforces cleanly" "$_c" 0

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '294-summary-build-integrity: ALL CHECKS PASSED\n'
	exit 0
fi
printf '294-summary-build-integrity: FAILURES PRESENT\n'
exit 1
