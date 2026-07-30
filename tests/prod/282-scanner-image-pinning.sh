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

# --- CodeRabbit round 2: the contract cannot be disabled by breaking it ------
# A malformed contract used to be collapsed into "no contract", which silently switched OFF
# mutable-tag and digest-drift enforcement in the provenance audit — corrupting the file was
# a way to disable the check the file exists to perform.
BAD="$TMPROOT/bad-contract"; mkdir -p "$BAD"
printf 'not json at all\n' > "$BAD/scanner-images.json"
_c=0; sh "$VALIDATOR" contract --contract "$BAD/scanner-images.json" >/dev/null 2>&1 || _c=$?
check "a non-JSON contract is refused as invalid input" "$_c" 2
printf '{"contract":"sentinel-shield/scanner-images@1","resolved_at":"2026-01-01","mutable_tags":["latest"],"images":{},"templates":["x"]}\n' > "$BAD/scanner-images.json"
_c=0; sh "$VALIDATOR" contract --contract "$BAD/scanner-images.json" >/dev/null 2>&1 || _c=$?
check "an EMPTY images object is refused (a contract that checks nothing)" "$_c" 2
printf '{"contract":"sentinel-shield/scanner-images@1","resolved_at":"2026-01-01","mutable_tags":["latest"],"images":{"SENTINEL_SHIELD_X_IMAGE":{"repository":"a/b"}},"templates":["x"]}\n' > "$BAD/scanner-images.json"
_c=0; sh "$VALIDATOR" contract --contract "$BAD/scanner-images.json" >/dev/null 2>&1 || _c=$?
check "an image record missing its digest/pin fields is refused" "$_c" 2
_c=0; sh "$VALIDATOR" templates --contract "$BAD/scanner-images.json" >/dev/null 2>&1 || _c=$?
check "  and no mode can run against it" "$_c" 2

# The schema enforces the per-image shape inline (this repo's jq-based validation does not
# resolve $ref, so a $ref'd definition is not enforced at all).
check "the scanner-image schema inlines the per-image constraints" \
	"$(jq -r '(.properties.images.additionalProperties.required // []) | length > 0' "$ROOT/schemas/scanner-images.schema.json")" "true"
check "  and no \$ref remains in it" \
	"$(grep -c '"\$ref"' "$ROOT/schemas/scanner-images.schema.json" || true)" "0"

# Shipped defaults are digest pins, not version tags.
check "every shipped image default is digest-pinned" \
	"$(jq -r '[.images[] | select(.default_pin != "digest")] | length' "$ROOT/config/scanner-images.json")" "0"
check "  and every default_reference is a digest reference" \
	"$(jq -r '[.images[] | select((.default_reference | test("@sha256:[0-9a-f]{64}$")) | not)] | length' "$ROOT/config/scanner-images.json")" "0"

# --- the EXECUTION sweep: a declaration is not what runs ---------------------
# Everything above inspects `VAR: value` declarations. A template executes a COMMAND, and an
# image named inline — as a literal or as a `${VAR:-default}` fallback — was invisible to the
# declaration sweep. The validator's header has always promised "no template executes a
# mutable tag"; that promise had nothing enforcing it, and a moving tag shipped in exactly
# that position. These fixtures prove the validator now sees the executed reference.
EX="$TMPROOT/exec"
# Seed the fixture FROM the contract, never from a hardcoded directory list: the contract
# also covers the engine's own .github/workflows, and a fixture that silently omits a
# declared template turns every check below into TEMPLATE_MISSING noise.
seed_ex() {
	rm -rf "$EX"; mkdir -p "$EX/config"
	cp "$CONTRACT" "$EX/config/scanner-images.json"
	for _p in $(jq -r '.templates[]' "$CONTRACT"); do
		mkdir -p "$EX/$(dirname "$_p")"
		cp "$ROOT/$_p" "$EX/$_p"
	done
}
seed_ex
_victim="$EX/templates/workflows/sentinel-shield.yml"

check "the real tree executes no unapproved image reference" "$(rc templates --repo-root "$EX")" "0"

# (a) a moving tag reached inline through a fallback default
sed 's|"${SENTINEL_SHIELD_GITLEAKS_IMAGE}"|"${SENTINEL_SHIELD_GITLEAKS_IMAGE:-zricethezav/gitleaks:latest}"|' \
	"$_victim" > "$_victim.new" && mv "$_victim.new" "$_victim"
_out=$(sh "$VALIDATOR" templates --repo-root "$EX" 2>&1 || true)
check "an inline \${VAR:-<moving tag>} fallback is detected as EXECUTED" \
	"$(printf '%s' "$_out" | grep -c 'MUTABLE_TAG_EXECUTED' || true)" "1"
check "  and the run fails closed" "$(rc templates --repo-root "$EX")" "1"

# (b) a pinned-but-unapproved reference executed inline
sed 's|zricethezav/gitleaks:latest|zricethezav/gitleaks:v8.18.4|' "$_victim" > "$_victim.new" && mv "$_victim.new" "$_victim"
_out=$(sh "$VALIDATOR" templates --repo-root "$EX" 2>&1 || true)
# Both sweeps legitimately report this one: the reference sweep sees the occurrence of an
# approved repository at the wrong version, and the operand sweep sees the executed operand.
# Two reports of one defect is noise, not a wrong answer — assert detection, not a count.
_ndrift=$(printf '%s' "$_out" | grep -c 'IMAGE_DRIFT_EXECUTED' || true)
if [ "${_ndrift:-0}" -ge 1 ]; then
	pass "an inline reference that is not the approved digest is detected"
else
	fail "an inline reference that is not the approved digest was NOT detected"
fi

# (c) reading a contract variable the template never declares: the fallback is what runs
seed_ex
grep -v '^  SENTINEL_SHIELD_GITLEAKS_IMAGE:' "$_victim" > "$_victim.new" && mv "$_victim.new" "$_victim"
_out=$(sh "$VALIDATOR" templates --repo-root "$EX" 2>&1 || true)
check "reading an undeclared image variable is refused" \
	"$(printf '%s' "$_out" | grep -c 'IMAGE_VAR_UNDECLARED' || true)" "1"

# --- a missing declared template must not abort the run before it reports ----
# `[ … ] && pass` as a function's last command makes its exit status the test's, so under
# `set -eu` a missing template killed the script mid-run: the summary never printed and, in
# `all` mode, the template sweep never ran at all. The run reported less than it had found.
seed_ex
rm -f "$EX/templates/workflows/sentinel-shield-main.yml"
_out=$(sh "$VALIDATOR" all --repo-root "$EX" 2>&1 || true)
check "a missing declared template still reaches the template sweep" \
	"$(printf '%s' "$_out" | grep -c 'scanner-images: templates' || true)" "1"
check "  and still prints the closing summary" \
	"$(printf '%s' "$_out" | grep -c 'validate-scanner-images: all FAILED' || true)" "1"

# --- ref_tag: the tag separator is the ':' after the last '/', not the last ':' ----
# A registry host may carry a port. Matching the last ':' in the whole reference read
# 'registry.example.com:5000/team/img' as carrying the tag '5000/team/img'.
# --- ref_canonical: normalise the tag away, never anything else --------------
# One parser is safer than three interpretations, but only if it preserves every supported
# form. `${ref%%:*}` cut at the FIRST colon, which on a ported registry is the PORT: it turned
# registry.example.com:5000/team/img:v1@sha256:… into registry.example.com@sha256:…, discarding
# the repository path and making two different images on that host indistinguishable.
_rcfn=$(sed -n '/^ref_canonical()/,/^}/p' "$VALIDATOR")
_rc() { printf '%s\nref_canonical "%s"\n' "$_rcfn" "$1" | sh; }
check "ref_canonical: a tag-only reference is unchanged" \
	"$(_rc 'repo/img:v1.2.3')" "repo/img:v1.2.3"
check "ref_canonical: a digest-only reference is unchanged" \
	"$(_rc 'repo/img@sha256:aaaa')" "repo/img@sha256:aaaa"
check "ref_canonical: tag+digest reduces to the digest form" \
	"$(_rc 'repo/img:v1.2.3@sha256:aaaa')" "repo/img@sha256:aaaa"
check "ref_canonical: a ported registry keeps its port and path (tag+digest)" \
	"$(_rc 'registry.example.com:5000/team/img:v1@sha256:bbbb')" "registry.example.com:5000/team/img@sha256:bbbb"
check "ref_canonical: a ported registry keeps its port and path (digest only)" \
	"$(_rc 'registry.example.com:5000/team/img@sha256:cccc')" "registry.example.com:5000/team/img@sha256:cccc"
check "ref_canonical: a ported registry with no tag or digest is unchanged" \
	"$(_rc 'registry.example.com:5000/team/img')" "registry.example.com:5000/team/img"
check "ref_canonical: a bare repository is unchanged" \
	"$(_rc 'repo/img')" "repo/img"
# Two DIFFERENT images on the same ported host must not canonicalise to the same string.
check "ref_canonical: two images on one ported host stay distinct" \
	"$([ "$(_rc 'registry.example.com:5000/a/img@sha256:1')" = "$(_rc 'registry.example.com:5000/b/img@sha256:1')" ] && echo same || echo distinct)" "distinct"

_rt=$(sed -n '/^ref_tag()/,/^}/p' "$VALIDATOR")
check "ref_tag treats a ported registry with no tag as untagged" \
	"$(printf '%s\nref_tag "registry.example.com:5000/team/img"\n' "$_rt" | sh)" ""
check "ref_tag still reads the tag on a ported registry" \
	"$(printf '%s\nref_tag "registry.example.com:5000/team/img:v1.2.3"\n' "$_rt" | sh)" "v1.2.3"
check "ref_tag reports no tag for a digest reference" \
	"$(printf '%s\nref_tag "repo/img@sha256:abc"\n' "$_rt" | sh)" ""

# --- the OPERAND sweep: an allowlist has to reject the unknown ---------------
# Both sweeps above start FROM the approved contract and look for those repositories in the
# file. That can only find drift in an image already approved — an entirely unknown image has
# no repository pattern to search for, so `docker run … evilcorp/backdoor:latest` in a shipped
# template passed cleanly. The operand sweep runs the other way: every image the template
# executes must BE an approved reference, so unknown is a violation.
seed_ex
_victim="$EX/templates/workflows/sentinel-shield.yml"

sed 's|docker run --rm -v "$PWD:/repo" "${SENTINEL_SHIELD_GITLEAKS_IMAGE}"|docker run --rm -v "$PWD:/repo" evilcorp/backdoor:latest|' \
	"$_victim" > "$_victim.new" && mv "$_victim.new" "$_victim"
_out=$(sh "$VALIDATOR" templates --repo-root "$EX" 2>&1 || true)
check "an image that is in no contract entry at all is refused" \
	"$(printf '%s' "$_out" | grep -c 'IMAGE_NOT_APPROVED' || true)" "1"
check "  and the run fails closed" "$(rc templates --repo-root "$EX")" "1"

seed_ex
sed 's|"${SENTINEL_SHIELD_GITLEAKS_IMAGE}"|"${MY_OWN_IMAGE}"|' "$_victim" > "$_victim.new" && mv "$_victim.new" "$_victim"
_out=$(sh "$VALIDATOR" templates --repo-root "$EX" 2>&1 || true)
check "an image chosen by a variable outside the contract is refused" \
	"$(printf '%s' "$_out" | grep -c 'IMAGE_VAR_UNKNOWN' || true)" "1"

# A job/service `container: image:` executes just as surely as `docker run`.
seed_ex
awk '/^jobs:/ { print; print "  rogue:"; print "    container:"; print "      image: evilcorp/rogue:latest"; next } { print }' \
	"$_victim" > "$_victim.new" && mv "$_victim.new" "$_victim"
_out=$(sh "$VALIDATOR" templates --repo-root "$EX" 2>&1 || true)
check "an unapproved job container image is refused" \
	"$(printf '%s' "$_out" | grep -c 'IMAGE_NOT_APPROVED' || true)" "1"

# `repo:tag@sha256:X` is exactly as immutable as `repo@sha256:X` — the digest is what the
# daemon resolves — so it must be ACCEPTED, not reported as an unapproved spelling.
# `repo:tag@sha256:X` must be ACCEPTED: the digest is what the daemon resolves, so the
# reference is immutable and the tag is a readability annotation. Both sweeps have to
# understand it — the reference sweep's alternation used to stop at the tag and never consume
# the digest, reporting a correctly pinned combined reference as drift. Asserted by rewriting
# a shipped digest pin into the combined form, not just by the real tree happening to pass.
seed_ex
check "the real tree still passes" "$(rc templates --repo-root "$EX")" "0"
_gl=$(jq -r '.images.SENTINEL_SHIELD_GITLEAKS_IMAGE.default_reference' "$CONTRACT")
_glrepo=${_gl%%@*}; _gldig=${_gl#*@}
sed "s|${_gl}|${_glrepo}:v8.18.4@${_gldig}|g" "$_victim" > "$_victim.new" && mv "$_victim.new" "$_victim"
check "  and repo:tag@digest is accepted as the same immutable reference" \
	"$(rc templates --repo-root "$EX")" "0"
# …while tag-only, with the digest removed, is still refused.
seed_ex
sed "s|${_gl}|${_glrepo}:v8.18.4|g" "$_victim" > "$_victim.new" && mv "$_victim.new" "$_victim"
check "  but the same reference WITHOUT the digest is refused" \
	"$(rc templates --repo-root "$EX")" "1"

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '282-scanner-image-pinning: ALL CHECKS PASSED\n'
	exit 0
fi
printf '282-scanner-image-pinning: FAILURES PRESENT\n'
exit 1
