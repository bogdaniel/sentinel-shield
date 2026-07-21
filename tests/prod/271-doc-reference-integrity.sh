#!/bin/sh
# Sentinel Shield prod test — documentation reference integrity (audit PR H).
#
# Docs drift silently because nothing executes them. These assertions pin the classes that
# actually bit: a documented COMMAND whose file does not exist, a COUNT stated as a literal,
# and a gate table contradicting the resolver. Each failed before this PR.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss271)
trap 'rm -rf -- "$WORK"' EXIT INT TERM

# --- every evidence path a doc tells you to RUN must exist -------------------
# generate-release-manifest.sh exits 2 on a missing --evidence file, so a wrong path is not
# a typo — the documented command fails outright.
# Only paths in COMMAND POSITION — i.e. immediately preceded by a flag that CONSUMES a
# file (--evidence / --candidate / --file / --summary). Three narrower rules learned the
# hard way while writing this suite:
#   * a path after `--output` is PRODUCED by the command; its absence is correct;
#   * PROSE that quotes a wrong path while CORRECTING it is not an instruction — this
#     assertion tripped on its own CHANGELOG entry, the third time in this series that
#     corrective text was mistaken for a live claim;
#   * CHANGELOG.md is a historical record, like the frozen docs/*-v0NN.md evidence files.
# A guard that flags the description of a fix as the bug is not measuring anything.
_missing=""
for _p in $(grep -rhoE -- '--(evidence|candidate|file|summary)[= ]evidence/releases/[A-Za-z0-9._-]+\.json' \
		docs/ *.md 2>/dev/null \
		| grep -oE 'evidence/releases/[A-Za-z0-9._-]+\.json' | sort -u); do
	[ -f "$_p" ] || _missing="$_missing$_p "
done
check "every documented evidence/releases path exists" "${_missing:-none}" "none"

# --- documented profile-manifest counts must match what ships ---------------
_ships=$(( $(ls "$ROOT"/profiles/*/profile.manifest.json 2>/dev/null | grep -c .) \
         + $(ls "$ROOT"/profiles/combinations/*.json 2>/dev/null | grep -c .) ))
_wrong=""
for _d in docs/multi-project-rollout.md docs/profile-compatibility.md docs/profile-adoption-guide.md; do
	[ -f "$_d" ] || continue
	# A doc may not state a manifest count that disagrees with the filesystem.
	if grep -qiE '(eight|nine|ten) manifests' "$_d" 2>/dev/null; then
		_word=$(grep -ioE '(eight|nine|ten) manifests' "$_d" | head -n1 | cut -d' ' -f1 | tr 'A-Z' 'a-z')
		case "$_word" in
			eight) _n=8 ;; nine) _n=9 ;; ten) _n=10 ;; *) _n=0 ;;
		esac
		[ "$_n" = "$_ships" ] || _wrong="$_wrong$(basename "$_d")($_word vs $_ships) "
	fi
done
check "documented manifest counts match the filesystem ($_ships ship)" "${_wrong:-none}" "none"

# --- a gate table must not contradict the resolver --------------------------
sh "$ROOT/scripts/resolve-gates.sh" --mode strict --output-dir "$WORK" --format env >/dev/null 2>&1
_sbom=$(awk -F= '/^SENTINEL_SHIELD_FAIL_ON_MISSING_SBOM=/{print $2}' "$WORK/sentinel-shield-gates.env")
if [ "$_sbom" = "true" ]; then
	# RELEASE-GATES.md marks blocking with ✅ and report-only with ⚠️; its second table said
	# ⚠️ for Missing SBOM in strict while the first said blocking, under a line asserting the
	# two are kept consistent.
	_row=$(grep -E '^\| Missing SBOM \|' RELEASE-GATES.md 2>/dev/null | head -n1)
	case "$_row" in
		*"⚠️ | ✅ |") fail "RELEASE-GATES.md marks Missing SBOM report-only in strict, but the resolver blocks on it" ;;
		*) pass "RELEASE-GATES.md agrees with the resolver on Missing SBOM in strict" ;;
	esac
fi

# --- a doc may not describe parsing the code does not do --------------------
# dependency-check matches the severity STRING; it parses no CVSS score.
if ! grep -q 'tonumber' "$ROOT/scripts/collectors/dependency-check.sh" 2>/dev/null; then
	_cvss=$(grep -c 'CVSS bucket → `critical/high/medium`' docs/severity-normalization.md 2>/dev/null || true)
	case "$_cvss" in '' | *[!0-9]*) _cvss=0 ;; esac
	check "no doc claims dependency-check parses a CVSS score" "$_cvss" "0"
fi
# ZAP/Nuclei counts are FILTERED, so dast_findings:0 does not mean "no findings".
if grep -q 'riskcode' "$ROOT/scripts/collectors/zap.sh" 2>/dev/null; then
	if grep -q 'filtered' docs/severity-normalization.md 2>/dev/null; then
		pass "severity-normalization records that dast_findings is a FILTERED count"
	else
		fail "severity-normalization describes dast_findings as a raw finding count, but zap.sh filters riskcode >= 2"
	fi
fi

# --- php-library docs must not contradict its own manifest ------------------
_pl="$ROOT/profiles/php-library/profile.manifest.json"
if [ -f "$_pl" ] && jq -e '.tools.deptrac' "$_pl" >/dev/null 2>&1; then
	_claim=$(grep -c 'No deptrac/psalm' docs/profile-compatibility.md 2>/dev/null || true)
	case "$_claim" in '' | *[!0-9]*) _claim=0 ;; esac
	check "no doc claims php-library has no deptrac while the manifest declares it" "$_claim" "0"
fi

if [ "$FAILED" -eq 0 ]; then
	printf '\n271-doc-reference-integrity: ALL CHECKS PASSED\n'
else
	printf '\n271-doc-reference-integrity: FAILURES PRESENT\n'
fi
exit "$FAILED"
