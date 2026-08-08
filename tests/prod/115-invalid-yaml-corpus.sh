#!/bin/sh
# Sentinel Shield production test — the intentionally-invalid YAML registry is a CONTRACT.
#
# WHY THIS EXISTS
#
# Proving the canonical policy parser rejects malformed input requires shipping malformed YAML,
# which collides with the repository-wide "every *.yml/*.yaml must parse" check. The cheap fix
# is to skip tests/fixtures/ — and that is a blind spot, not a fix: a genuinely broken workflow
# or profile fixture would then never be noticed.
#
# So the exemption is a registry, and this suite asserts that the registry is honest:
#
#   1. every registered path exists
#   2. every registered file really is unparseable by the reference YAML parser
#   3. every registered file is ALSO rejected by the Sentinel parser (it is a negative fixture
#      for the product, not merely broken text)
#   4. every rejected-corpus file that is NOT registered is VALID YAML — i.e. the Sentinel
#      contract is stricter than YAML syntax rather than a garbage detector
#   5. an unregistered malformed file anywhere still fails the audit (the original guarantee)
#   6. a registered file that starts parsing cleanly also fails the audit (the registry cannot
#      rot into a dumping ground)
#
# 5 and 6 are the load-bearing ones: they are the two directions of the exemption, and each is
# proven by running the real audit against a synthetic tree, not by reading the source.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
AUDIT="$ROOT/scripts/audits/yaml-corpus-audit.sh"
MANIFEST="$ROOT/config/intentionally-invalid-yaml.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$AUDIT" ] || { fail "scripts/audits/yaml-corpus-audit.sh is missing"; exit 1; }
[ -f "$MANIFEST" ] || { fail "config/intentionally-invalid-yaml.json is missing"; exit 1; }

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# A reference YAML parser is required for the corpus assertions. Without one this suite cannot
# distinguish "valid" from "invalid" at all, and reporting PASS would be reporting nothing.
if command -v ruby >/dev/null 2>&1; then
	yaml_parses() { ruby -ryaml -e 'begin; YAML.load_stream(File.read(ARGV[0])); rescue Exception; exit 1; end' "$1" 2>/dev/null; }
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
	yaml_parses() { python3 -c 'import sys,yaml
try: list(yaml.safe_load_all(open(sys.argv[1],"rb").read()))
except Exception: sys.exit(1)' "$1" 2>/dev/null; }
else
	fail "neither ruby nor python3+PyYAML is available — this suite cannot verify YAML validity and will not report success without checking"
	exit 1
fi

# --- 1. the live repository satisfies the audit ---------------------------
if sh "$AUDIT" --quiet; then
	pass "the repository satisfies the YAML corpus audit"
else
	fail "the repository does not satisfy the YAML corpus audit"
fi

REG_N=$(jq -r '.intentionally_invalid_yaml | length' "$MANIFEST")
[ "$REG_N" -gt 0 ] && pass "registry lists $REG_N intentionally-invalid file(s)" \
	|| fail "registry is empty — every assertion below would be vacuous"

# --- 2 & 3. registered files exist, are unparseable, and are product-rejected
_missing=0
_parseable=0
for _p in $(jq -r '.intentionally_invalid_yaml[]' "$MANIFEST"); do
	if [ ! -e "$ROOT/$_p" ]; then
		fail "registered path does not exist: $_p"
		_missing=1
		continue
	fi
	if yaml_parses "$ROOT/$_p"; then
		fail "registered as intentionally-invalid but parses cleanly: $_p"
		_parseable=1
	fi
done
[ "$_missing" = 0 ] && pass "every registered path exists"
[ "$_parseable" = 0 ] && pass "every registered file is genuinely unparseable"

# The Sentinel parser must reject them too. A file that is merely broken text, and that the
# product would never be asked to read, does not belong in the registry.
if [ -f "$ROOT/scripts/lib/yaml-policy.sh" ]; then
	# POSITIVE CONTROL FIRST. "rejects every registered file" is satisfied by a parser that
	# rejects everything — including one that is simply broken, or a CLI whose subcommand was
	# renamed. Prove it accepts known-good input before trusting any rejection it reports.
	_ctrl="$ROOT/tests/fixtures/yaml-policy/accepted/01-simple-block-map.yaml"
	if [ -e "$_ctrl" ] && sh "$ROOT/scripts/lib/yaml-policy.sh" normalize "$_ctrl" >/dev/null 2>&1; then
		pass "control: the Sentinel parser ACCEPTS a known-good fixture"

		_not_rejected=0
		for _p in $(jq -r '.intentionally_invalid_yaml[]' "$MANIFEST"); do
			[ -e "$ROOT/$_p" ] || continue
			if sh "$ROOT/scripts/lib/yaml-policy.sh" normalize "$ROOT/$_p" >/dev/null 2>&1; then
				fail "the Sentinel parser ACCEPTS a file registered as intentionally-invalid: $_p"
				_not_rejected=1
			fi
		done
		[ "$_not_rejected" = 0 ] && pass "the Sentinel parser rejects every registered file"
	else
		fail "the Sentinel parser does not accept a known-good fixture — every rejection it reports below would be meaningless, so they are not counted"
	fi
else
	fail "scripts/lib/yaml-policy.sh is missing — cannot prove the registry describes product-rejected input"
fi

# --- 4. the unregistered rejected corpus is VALID YAML --------------------
# This is the assertion that keeps the exemption narrow. Duplicate keys, anchors, block
# scalars and multi-document files are all valid YAML; the Sentinel contract rejects them for
# its own reasons. If one of those ever needed registering, it would mean the fixture had
# become malformed text rather than a contract case.
_corpus="$ROOT/tests/fixtures/yaml-policy/rejected"
if [ -d "$_corpus" ]; then
	jq -r '.intentionally_invalid_yaml[]' "$MANIFEST" | sed 's|.*/||' | sort > "$TMP/reg_names"
	_bad=0
	_checked=0
	for _f in "$_corpus"/*.yaml "$_corpus"/*.yml; do
		[ -e "$_f" ] || continue
		grep -qx "${_f##*/}" "$TMP/reg_names" && continue
		_checked=$((_checked + 1))
		if ! yaml_parses "$_f"; then
			fail "unregistered rejected-corpus file is not valid YAML: ${_f##*/} (register it, or fix it)"
			_bad=1
		fi
	done
	[ "$_bad" = 0 ] && pass "all $_checked unregistered rejected-corpus file(s) are valid YAML the Sentinel contract rejects"
else
	fail "tests/fixtures/yaml-policy/rejected/ is missing"
fi

# --- 5 & 6. the audit fails in BOTH directions ----------------------------
# Proven against the real audit in a synthetic tree. A guard that has never rejected anything
# is indistinguishable from one that always passes.
mk_tree() { # mk_tree <dir> — a minimal repo-shaped tree with one valid YAML file
	mkdir -p "$1/config" "$1/fixtures"
	printf 'name: ok\non:\n  push:\n' > "$1/fixtures/good.yaml"
	printf '{"intentionally_invalid_yaml":[]}\n' > "$1/config/intentionally-invalid-yaml.json"
}

mk_tree "$TMP/t1"
if sh "$AUDIT" --root "$TMP/t1" --manifest "$TMP/t1/config/intentionally-invalid-yaml.json" --quiet; then
	pass "control: a clean tree with an empty registry passes"
else
	fail "control: a clean tree with an empty registry should pass"
fi

# Direction 1 — unregistered malformed file must FAIL.
mk_tree "$TMP/t2"
printf 'a: [unterminated\n  b: : :\n' > "$TMP/t2/fixtures/broken.yaml"
if sh "$AUDIT" --root "$TMP/t2" --manifest "$TMP/t2/config/intentionally-invalid-yaml.json" --quiet 2>/dev/null; then
	fail "direction 1: an unregistered malformed YAML file was ACCEPTED — the repository-wide guarantee is gone"
else
	pass "direction 1: an unregistered malformed YAML file is rejected"
fi

# ...and registering it makes the same tree pass, so the exemption actually works.
printf '{"intentionally_invalid_yaml":["fixtures/broken.yaml"]}\n' > "$TMP/t2/config/intentionally-invalid-yaml.json"
if sh "$AUDIT" --root "$TMP/t2" --manifest "$TMP/t2/config/intentionally-invalid-yaml.json" --quiet; then
	pass "direction 1: registering that file makes the tree pass"
else
	fail "direction 1: a registered malformed file should be exempt"
fi

# Direction 2 — a registered file that parses cleanly must FAIL.
mk_tree "$TMP/t3"
printf '{"intentionally_invalid_yaml":["fixtures/good.yaml"]}\n' > "$TMP/t3/config/intentionally-invalid-yaml.json"
if sh "$AUDIT" --root "$TMP/t3" --manifest "$TMP/t3/config/intentionally-invalid-yaml.json" --quiet 2>/dev/null; then
	fail "direction 2: a registered file that parses cleanly was ACCEPTED — the registry can rot into a dumping ground"
else
	pass "direction 2: a registered file that parses cleanly is rejected"
fi

# A registered path that does not exist must FAIL — a registry pointing at a deleted file
# exempts nothing and hides that the corpus lost a case.
mk_tree "$TMP/t4"
printf '{"intentionally_invalid_yaml":["fixtures/gone.yaml"]}\n' > "$TMP/t4/config/intentionally-invalid-yaml.json"
if sh "$AUDIT" --root "$TMP/t4" --manifest "$TMP/t4/config/intentionally-invalid-yaml.json" --quiet 2>/dev/null; then
	fail "a registered path that does not exist was ACCEPTED"
else
	pass "a registered path that does not exist is rejected"
fi

# --- 7. the workflow consumes the audit, not its own inline glob ----------
_wf="$ROOT/.github/workflows/ci-self-test.yml"
if grep -vE '^[[:space:]]*#' "$_wf" 2>/dev/null | grep -q 'yaml-corpus-audit.sh'; then
	pass "ci-self-test invokes the shared audit"
else
	fail "ci-self-test does not invoke scripts/audits/yaml-corpus-audit.sh — a second inline YAML check would drift from this contract"
fi
if grep -vE '^[[:space:]]*#' "$_wf" 2>/dev/null | grep -qE 'YAML\.load_stream'; then
	fail "ci-self-test still carries an inline YAML parse loop — two implementations of one contract"
else
	pass "ci-self-test carries no inline YAML parse loop"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d invalid-YAML-corpus check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\ninvalid-yaml-corpus: OK (%s registered, exemption enforced in both directions)\n' "$REG_N"
exit 0
