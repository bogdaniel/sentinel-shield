#!/bin/sh
# Sentinel Shield prod test — approved scanner-image contract (issue #86).
#
# The defect: `owasp/dependency-check:latest` shipped as the DEFAULT in the scheduled and
# dedicated Dependency-Check templates. The scanner implementation could therefore change
# with no repository change and no review, and no evidence run was reproducible from the
# workflow source alone.
#
# This suite proves (a) no shipped template executes a moving tag or an unapproved image,
# (b) the validator actually detects each of those defects (isolated fixtures, never the
# real tree), and (c) the runtime provenance audit rejects digest drift.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
VALIDATOR="$ROOT/scripts/validate-scanner-images.sh"
CONTRACT="$ROOT/config/scanner-images.json"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$VALIDATOR" ] || { fail "missing scripts/validate-scanner-images.sh"; exit 1; }
[ -f "$CONTRACT" ] || { fail "missing config/scanner-images.json"; exit 1; }

TMPROOT=$(mktemp -d)
trap 'rm -rf -- "$TMPROOT"' EXIT INT TERM HUP

rc() { _c=0; sh "$VALIDATOR" "$@" >/dev/null 2>&1 || _c=$?; printf '%s' "$_c"; }

# ---------------------------------------------------------------------------
# 1. The real repository satisfies the contract.
# ---------------------------------------------------------------------------
check "real repo: contract mode passes"  "$(rc contract)"  0
check "real repo: templates mode passes" "$(rc templates)" 0
check "real repo: all passes"            "$(rc all)"       0
check "malformed contract is exit 2"     "$(printf 'nope' > "$TMPROOT/bad.json"; rc all --contract "$TMPROOT/bad.json")" 2
check "missing contract is exit 2"       "$(rc all --contract "$TMPROOT/absent.json")" 2
check "unknown mode is exit 2"           "$(rc frobnicate)" 2

# ---------------------------------------------------------------------------
# 2. The specific #86 regression: NO active template may execute a moving tag.
#    Asserted directly against the shipped files, independently of the validator.
# ---------------------------------------------------------------------------
_mutable=$(jq -r '.mutable_tags[]' "$CONTRACT")
_hits=0
for _t in $(jq -r '.templates[]' "$CONTRACT"); do
	[ -f "$_t" ] || { fail "declared template missing: $_t"; continue; }
	while IFS= read -r _line; do
		[ -n "$_line" ] || continue
		_val=$(printf '%s' "$_line" | sed -E 's/^[[:space:]]*[A-Z0-9_]+:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//')
		case "$_val" in '${{'*) continue ;; esac
		case "$_val" in *@sha256:*) continue ;; esac
		_tag="${_val##*:}"
		for _m in $_mutable; do
			[ "$_tag" = "$_m" ] && { fail "$_t executes the moving tag '$_val'"; _hits=$((_hits + 1)); }
		done
	done <<EOF
$(grep -E '^[[:space:]]*SENTINEL_SHIELD_[A-Z0-9_]*_IMAGE:' "$_t" 2>/dev/null || true)
EOF
done
check "no shipped template executes a moving image tag" "$_hits" 0

# Dependency-Check specifically must ship as a full digest, in BOTH templates that run it.
_dcref=$(jq -r '.images.SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE.default_reference' "$CONTRACT")
case "$_dcref" in
	*@sha256:*) pass "the approved Dependency-Check reference is a full digest" ;;
	*) fail "the approved Dependency-Check reference is not digest-pinned: $_dcref" ;;
esac
_dccount=0
for _t in templates/workflows/sentinel-shield-scheduled.yml templates/workflows/sentinel-shield-dependency-check.yml; do
	grep -Eq "^[[:space:]]*SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE:[[:space:]]*${_dcref}([[:space:]]|\$)" "$_t" && _dccount=$((_dccount + 1))
done
check "both Dependency-Check templates pin the same approved digest" "$_dccount" 2

# ---------------------------------------------------------------------------
# 3. Negative controls — isolated fixtures, so a detection claim is proven.
# ---------------------------------------------------------------------------
mkfix() { # mkfix <name> — a clean fixture that PASSES, ready to be mutated
	_d="$TMPROOT/$1"
	mkdir -p "$_d/templates/workflows"
	cat > "$_d/contract.json" <<'JSON'
{
  "contract": "sentinel-shield/scanner-images@1",
  "resolved_at": "2026-07-26",
  "mutable_tags": ["latest", "main"],
  "images": {
    "SENTINEL_SHIELD_FAKE_IMAGE": {
      "repository": "acme/fake",
      "resolved_from": "v1.2.3",
      "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "default_pin": "tag",
      "default_reference": "acme/fake:v1.2.3"
    },
    "SENTINEL_SHIELD_PINNED_IMAGE": {
      "repository": "acme/pinned",
      "resolved_from": "latest",
      "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
      "default_pin": "digest",
      "default_reference": "acme/pinned@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
  },
  "templates": ["templates/workflows/wf.yml"]
}
JSON
	cat > "$_d/templates/workflows/wf.yml" <<'YML'
env:
  SENTINEL_SHIELD_FAKE_IMAGE: acme/fake:v1.2.3
  SENTINEL_SHIELD_PINNED_IMAGE: acme/pinned@sha256:2222222222222222222222222222222222222222222222222222222222222222
YML
	printf '%s' "$_d"
}
frc() { _fd="$1"; shift; _c=0; sh "$VALIDATOR" "$@" --repo-root "$_fd" --contract "$_fd/contract.json" >/dev/null 2>&1 || _c=$?; printf '%s' "$_c"; }
mut() { jq "$2" "$1/contract.json" > "$1/c.tmp" && mv -- "$1/c.tmp" "$1/contract.json"; }

B=$(mkfix base)
check "fixture baseline passes" "$(frc "$B" all)" 0

D=$(mkfix m1)
printf 'env:\n  SENTINEL_SHIELD_FAKE_IMAGE: acme/fake:latest\n  SENTINEL_SHIELD_PINNED_IMAGE: acme/pinned@sha256:2222222222222222222222222222222222222222222222222222222222222222\n' > "$D/templates/workflows/wf.yml"
check "detects a template executing a moving tag" "$(frc "$D" templates)" 1

D=$(mkfix m2)
printf 'env:\n  SENTINEL_SHIELD_FAKE_IMAGE: acme/fake:v9.9.9\n  SENTINEL_SHIELD_PINNED_IMAGE: acme/pinned@sha256:2222222222222222222222222222222222222222222222222222222222222222\n' > "$D/templates/workflows/wf.yml"
check "detects a template drifting from the approved reference" "$(frc "$D" templates)" 1

D=$(mkfix m3)
printf 'env:\n  SENTINEL_SHIELD_FAKE_IMAGE: acme/fake:v1.2.3\n  SENTINEL_SHIELD_PINNED_IMAGE: acme/pinned:latest\n' > "$D/templates/workflows/wf.yml"
check "detects a digest-pinned image downgraded to a tag" "$(frc "$D" templates)" 1

D=$(mkfix m4)
printf 'env:\n  SENTINEL_SHIELD_FAKE_IMAGE: acme/fake:v1.2.3\n  SENTINEL_SHIELD_PINNED_IMAGE: acme/pinned@sha256:2222222222222222222222222222222222222222222222222222222222222222\n  SENTINEL_SHIELD_ROGUE_IMAGE: evil/rogue:v1\n' > "$D/templates/workflows/wf.yml"
check "detects an image that is not in the approved contract at all" "$(frc "$D" templates)" 1

D=$(mkfix m5)
printf 'env:\n  SOMETHING: else\n' > "$D/templates/workflows/wf.yml"
check "detects a template sweep that inspected nothing" "$(frc "$D" templates)" 1

D=$(mkfix c1); mut "$D" '.images.SENTINEL_SHIELD_PINNED_IMAGE.default_reference = "acme/pinned:latest"'
check "detects a digest-pin image approved as a mutable tag" "$(frc "$D" contract)" 1

D=$(mkfix c2); mut "$D" '.images.SENTINEL_SHIELD_FAKE_IMAGE.digest = "sha256:1111"'
check "detects an abbreviated digest (not a pin)" "$(frc "$D" contract)" 1

D=$(mkfix c3); mut "$D" '.images.SENTINEL_SHIELD_FAKE_IMAGE.resolved_from = "v9.9.9"'
check "detects a tag whose digest was resolved from a different tag" "$(frc "$D" contract)" 1

D=$(mkfix c4); mut "$D" '.images.SENTINEL_SHIELD_FAKE_IMAGE.default_reference = "someone-else/fake:v1.2.3"'
check "detects a reference pointing at another repository" "$(frc "$D" contract)" 1

D=$(mkfix c5); mut "$D" '.templates += ["templates/workflows/absent.yml"]'
check "detects a declared template that does not exist" "$(frc "$D" contract)" 1

# `show` is the accessor other tooling uses; it must never invent a reference.
check "show returns the approved reference" \
	"$(sh "$VALIDATOR" show --var SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE)" "$_dcref"
check "show fails for an unapproved variable" "$(rc show --var SENTINEL_SHIELD_NOPE_IMAGE)" 1

# ---------------------------------------------------------------------------
# 4. Documentation must not still present :latest as the shipped default.
# ---------------------------------------------------------------------------
# Only the ASSIGNMENT form is a claim about the shipped default. Prose that describes the
# former default ("used to ship as …") is a correction, and `-vNNN.md` files are frozen
# evidence records of runs that really did execute that image.
_pattern='SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE[:=][[:space:]]*owasp/dependency-check:latest'
_stale=$(grep -rlE "$_pattern" docs/*.md 2>/dev/null | grep -vE '\-v[0-9]+\.md$' | grep -c . || true)
case "$_stale" in '' | *[!0-9]*) _stale=0 ;; esac
if [ "$_stale" -eq 0 ]; then
	pass "no active doc presents owasp/dependency-check:latest as the shipped default"
else
	fail "$_stale active doc(s) still present owasp/dependency-check:latest as the shipped default"
	grep -rlE "$_pattern" docs/*.md 2>/dev/null | grep -vE '\-v[0-9]+\.md$' | sed 's/^/       /'
fi
# The same claim must not survive in the templates themselves.
_tmpl=$(grep -rlE "$_pattern" templates/ examples/ 2>/dev/null | grep -c . || true)
case "$_tmpl" in '' | *[!0-9]*) _tmpl=0 ;; esac
check "no template or example assigns the moving Dependency-Check tag" "$_tmpl" 0

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '282-scanner-image-pinning: ALL CHECKS PASSED\n'
	exit 0
fi
printf '282-scanner-image-pinning: FAILURES PRESENT\n'
exit 1
