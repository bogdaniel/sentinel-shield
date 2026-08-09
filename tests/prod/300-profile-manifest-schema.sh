#!/bin/sh
# Sentinel Shield production test — profile manifests are schema-validated BEFORE
# inheritance and composition (#248).
#
# WHY THIS EXISTS
#
# The effective-profile resolver used to admit a manifest on two facts: `jq -e .`
# said it was JSON, and every `tools[*].policy` string was in the enum. Everything
# else — extends identifiers, tool field types, execution booleans, report/runner/
# config/executable paths, packages, alternatives, fallback order, the tool-policy
# version, unknown fields — went straight into shell `for` loops, jq merge logic,
# path probes and the installer plan without ever being checked.
#
# `profiles/profile.manifest.schema.json` existed but ran only inside an
# `if command_exists check-jsonschema` branch of self-test.sh. That tool is not a
# dependency of this engine and is not installed in CI, so the branch logged
# "SKIPPING" and the schema validated nothing, anywhere, ever.
#
# This suite proves five things, in this order, because each is worthless without
# the one before it:
#
#   1. POSITIVE CONTROL — the validator ACCEPTS the whole live tree and a
#      full-featured control manifest. A validator that rejects everything is
#      indistinguishable from one that works, and the rejections below would mean
#      nothing.
#   2. PARITY — the shell validator and the published JSON Schema agree on every
#      enum, allowlist, pattern and supported version, so "the schema" is one
#      contract and not two that drift.
#   3. NEGATIVE CORPUS — every registered fixture is rejected, with the recorded
#      code; and the registry records, per fixture, whether the PRE-#248 gate
#      (reconstructed here verbatim) accepted it. That verdict is recomputed live,
#      so the claim "this was a real hole" cannot rot into an assertion.
#   4. MUTATION OF THE LIVE TREE — a real shipped manifest is mutated in a
#      synthetic root and the REAL entry points (resolver, installer, sync,
#      upgrade planner, bootstrapper, release packaging) are re-run against it.
#      Static grep proves wiring; this proves behaviour.
#   5. NO UNVALIDATED READER — no consumer still admits a manifest on `jq -e .`.
#
# Fixtures: tests/fixtures/profile-schema/ (registry.json is the contract).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/lib/profile-schema.sh"
CLI="$ROOT/scripts/validate-profile-manifest.sh"
MSCHEMA="$ROOT/profiles/profile.manifest.schema.json"
TSCHEMA="$ROOT/schemas/tool-policy.schema.json"
REG="$ROOT/tests/fixtures/profile-schema/registry.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
for _f in "$LIB" "$CLI" "$MSCHEMA" "$TSCHEMA" "$REG"; do
	[ -f "$_f" ] || { fail "missing required file: $_f"; exit 1; }
done

TMP=$(mktemp -d)
# No `exit` inside the trap: an aborted run must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# `sorted_words <space-separated>` — canonical comparable form for a set.
sorted_words() { printf '%s\n' "$1" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
# `shell_const <NAME>` — the value of a constant as the library itself defines it.
shell_const() {
	# shellcheck disable=SC1090
	( . "$ROOT/scripts/lib/sentinel-shield-common.sh"; . "$LIB"; eval "printf '%s' \"\${$1}\"" )
}

# The PRE-#248 gate, reconstructed verbatim from ep__collect as it stood before
# this change: `jq -e .` plus a tools[*].policy enum check, and nothing else.
# Exit 0 = the old engine would have ACCEPTED this manifest and composed it.
prefix_gate() {
	jq -e . "$1" >/dev/null 2>&1 || return 1
	_bp=$(jq -r '
		(.tools // {}) | to_entries[]
		| select((.value.policy // "") | IN("required","recommended","optional","one-of","disabled","external") | not)
		| .key' "$1" 2>/dev/null || true)
	[ -z "$_bp" ] || return 1
	return 0
}

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROLS — non-vacuity
# ---------------------------------------------------------------------------
if sh "$CLI" --all --quiet >"$TMP/all.out" 2>&1; then
	pass "positive control: every shipped profile manifest passes at role=install"
else
	fail "the live tree does not satisfy its own validator — every rejection below would be meaningless"
	cat "$TMP/all.out"
	exit 1
fi

_shipped=$(find "$ROOT/profiles" -name 'profile.manifest.json' -o -name '*.manifest.json' | grep -vc 'schema.json' || printf '0')
if [ "$_shipped" -ge 7 ]; then
	pass "positive control: $_shipped shipped manifests were actually inspected"
else
	fail "only $_shipped manifests found under profiles/ — the --all sweep is near-vacuous"
fi

_ctl_ok=1
for _a in "$ROOT"/tests/fixtures/profile-schema/accepted/*.json; do
	[ -f "$_a" ] || continue
	sh "$CLI" --role install --quiet "$_a" >/dev/null 2>&1 || { fail "control manifest rejected: $_a"; _ctl_ok=0; }
done
[ "$_ctl_ok" = 1 ] && pass "positive control: the accepted-fixture corpus validates at role=install"

if sh "$ROOT/scripts/resolve-effective-profile.sh" --manifest "$ROOT/tests/fixtures/profile-schema/accepted/02-full-featured.json" >"$TMP/full.json" 2>/dev/null \
	&& [ "$(jq -r '.one_of_groups | keys | join(",")' "$TMP/full.json")" = "php-tests" ]; then
	pass "positive control: the full-featured control manifest RESOLVES and derives its one-of group"
else
	fail "the full-featured control manifest does not resolve — the composed checks below would be meaningless"
fi

_resolved=0
for _p in laravel node react symfony php-library docker hardened-enterprise laravel-react-docker node-react; do
	if sh "$ROOT/scripts/resolve-effective-profile.sh" --profile "$_p" >/dev/null 2>&1; then
		_resolved=$((_resolved + 1))
	else
		fail "shipped profile no longer resolves with validation enabled: $_p"
	fi
done
[ "$_resolved" -ge 9 ] && pass "positive control: all $_resolved shipped profiles still resolve end to end"

# ---------------------------------------------------------------------------
# 2. PARITY — one contract, two faces
# ---------------------------------------------------------------------------
# A shell constant and a JSON Schema keyword that disagree are two contracts. The
# published schema is what an adopter reads; the shell validator is what runs.
parity() {
	_name=$1; _shell=$2; _schema=$3
	if [ "$(sorted_words "$_shell")" = "$(sorted_words "$_schema")" ]; then
		pass "parity: $_name"
	else
		fail "parity: $_name — validator=[$(sorted_words "$_shell")] schema=[$(sorted_words "$_schema")]"
	fi
}

parity "top-level field allowlist" \
	"$(shell_const PS_TOP_KEYS)" \
	"$(jq -r '.properties | keys | join(" ")' "$MSCHEMA")"
parity "tool-policy field allowlist" \
	"$(shell_const PS_TOOL_KEYS)" \
	"$(jq -r '.["$defs"].toolPolicy.properties | keys | join(" ")' "$TSCHEMA")"
parity "package field allowlist" \
	"$(shell_const PS_PACKAGE_KEYS)" \
	"$(jq -r '.["$defs"].package.properties | keys | join(" ")' "$TSCHEMA")"
parity "execution stage allowlist" \
	"$(shell_const PS_EXECUTION_KEYS)" \
	"$(jq -r '.["$defs"].execution.properties | keys | join(" ")' "$TSCHEMA")"
parity "config field allowlist" \
	"$(shell_const PS_CONFIG_KEYS)" \
	"$(jq -r '.["$defs"].config.properties | keys | join(" ")' "$TSCHEMA")"
parity "entry-list field allowlist" \
	"$(shell_const PS_ENTRY_KEYS)" \
	"$(jq -r '.["$defs"].entryList.items.properties | keys | join(" ")' "$MSCHEMA")"
parity "policy enum" \
	"$(shell_const PS_POLICIES)" \
	"$(jq -r '.["$defs"].policy.enum | join(" ")' "$TSCHEMA")"
parity "missing_behavior enum" \
	"$(shell_const PS_MISSING_BEHAVIORS)" \
	"$(jq -r '.["$defs"].missingBehavior.enum | join(" ")' "$TSCHEMA")"
parity "config.classification enum" \
	"$(shell_const PS_CONFIG_CLASSIFICATIONS)" \
	"$(jq -r '.["$defs"].config.properties.classification.enum | join(" ")' "$TSCHEMA")"
parity "package.scope enum" \
	"$(shell_const PS_PACKAGE_SCOPES)" \
	"$(jq -r '.["$defs"].package.properties.scope.enum | join(" ")' "$TSCHEMA")"
parity "one-of selection enum" \
	"$(shell_const PS_SELECTIONS)" \
	"$(jq -r '.["$defs"].toolPolicy.properties.selection.enum | join(" ")' "$TSCHEMA")"
parity "entry mode enum" \
	"$(shell_const PS_ENTRY_MODES)" \
	"$(jq -r '.["$defs"].entryList.items.properties.mode.enum | join(" ")' "$MSCHEMA")"
parity "supported tool-policy version" \
	"$(shell_const PS_TOOL_POLICY_VERSION)" \
	"$(jq -r '.properties.tool_policy_version.const' "$MSCHEMA")"
parity "identifier grammar (manifest)" \
	"$(shell_const PS_ID_PATTERN)" \
	"$(jq -r '.["$defs"].identifier.pattern' "$MSCHEMA")"
parity "identifier grammar (tool key)" \
	"$(shell_const PS_ID_PATTERN)" \
	"$(jq -r '.["$defs"].toolKey.pattern' "$TSCHEMA")"
parity "normalized-report path grammar" \
	"$(shell_const PS_REPORT_PATTERN)" \
	"$(jq -r '.["$defs"].toolPolicy.properties.report.pattern' "$TSCHEMA")"

# The published schema must be CLOSED at the top level, or "unknown field" is not
# a rule the schema states at all.
if [ "$(jq -r '.additionalProperties' "$MSCHEMA")" = "false" ]; then
	pass "parity: the manifest schema rejects additional top-level properties"
else
	fail "the manifest schema still allows unknown top-level properties"
fi
if [ "$(jq -r '.["$defs"].toolPolicy.additionalProperties' "$TSCHEMA")" = "false" ]; then
	pass "parity: the tool-policy schema rejects additional tool fields"
else
	fail "the tool-policy schema still allows unknown tool fields"
fi

# ---------------------------------------------------------------------------
# 3. NEGATIVE CORPUS
# ---------------------------------------------------------------------------
REJ_N=$(jq -r '.rejected | length' "$REG")
CMP_N=$(jq -r '.composed | length' "$REG")
if [ "$REJ_N" -ge 30 ] && [ "$CMP_N" -ge 5 ]; then
	pass "registry lists $REJ_N per-manifest and $CMP_N composed negative fixtures"
else
	fail "negative corpus is too small to be meaningful (rejected=$REJ_N composed=$CMP_N)"
	exit 1
fi

# Every declared category must actually be exercised, or the corpus can claim
# coverage it does not have.
_uncovered=""
for _c in $(jq -r '.categories[]' "$REG"); do
	_n=$(jq -r --arg c "$_c" '[(.rejected + .composed)[] | select(.category == $c)] | length' "$REG")
	[ "$_n" -gt 0 ] || _uncovered="$_uncovered $_c"
done
if [ -z "$_uncovered" ]; then
	pass "every declared fixture category is exercised by at least one fixture"
else
	fail "declared but unexercised fixture categories:$_uncovered"
fi

# The acceptance criteria of #248 name seven classes explicitly. Assert each has
# a fixture, by name, so a future edit cannot quietly drop one.
for _c in malformed-types missing-required unknown-fields unsafe-paths invalid-identifiers one-of-errors version-drift execution-semantics composed-semantics; do
	_n=$(jq -r --arg c "$_c" '[(.rejected + .composed)[] | select(.category == $c)] | length' "$REG")
	if [ "$_n" -gt 0 ]; then
		pass "acceptance class '$_c' has $_n negative fixture(s)"
	else
		fail "acceptance class '$_c' has NO negative fixture"
	fi
done

# Per-manifest corpus.
_bad_reject=0; _bad_code=0; _bad_prefix=0; _bad_missing=0; _prefix_accepted=0
jq -r '.rejected[] | "\(.path)\t\(.code)\t\(.pre_fix)"' "$REG" > "$TMP/rejected.tsv"
while IFS="$(printf '\t')" read -r _path _code _prefix; do
	[ -n "$_path" ] || continue
	_abs="$ROOT/$_path"
	if [ ! -f "$_abs" ]; then
		fail "registered fixture does not exist: $_path"; _bad_missing=1; continue
	fi
	if sh "$CLI" --quiet "$_abs" >"$TMP/out" 2>&1; then
		fail "negative fixture ACCEPTED by the validator: $_path"; _bad_reject=1; continue
	fi
	grep -q "$_code" "$TMP/out" || { fail "fixture $_path did not report $_code"; _bad_code=1; }
	# The resolver's arbitrary-manifest entry point must reject it too, and emit
	# NO effective profile: composition must not begin on an invalid manifest.
	if sh "$ROOT/scripts/resolve-effective-profile.sh" --manifest "$_abs" >"$TMP/eff" 2>/dev/null; then
		fail "resolver COMPOSED an invalid manifest: $_path"; _bad_reject=1
	elif [ -s "$TMP/eff" ]; then
		fail "resolver emitted a partial effective profile for an invalid manifest: $_path"; _bad_reject=1
	fi
	# Recompute the pre-#248 verdict live.
	if prefix_gate "$_abs"; then _live="accepted"; _prefix_accepted=$((_prefix_accepted + 1)); else _live="rejected"; fi
	[ "$_live" = "$_prefix" ] || { fail "registry says the pre-#248 gate '$_prefix' $_path, live recomputation says '$_live'"; _bad_prefix=1; }
done < "$TMP/rejected.tsv"

[ "$_bad_missing" = 0 ] && pass "every registered per-manifest fixture exists"
[ "$_bad_reject" = 0 ] && pass "every per-manifest fixture is rejected by BOTH the validator and the resolver, with no partial output"
[ "$_bad_code" = 0 ] && pass "every per-manifest fixture reports its registered diagnostic code"
[ "$_bad_prefix" = 0 ] && pass "the recorded pre-#248 verdicts match a live recomputation of the old gate"

# The load-bearing number: how many of these defects the old gate waved through.
if [ "$_prefix_accepted" -ge 30 ]; then
	pass "regression proof: the pre-#248 gate ACCEPTED $_prefix_accepted of $REJ_N manifests this validator rejects"
else
	fail "only $_prefix_accepted fixtures reproduce a pre-#248 hole — this corpus is not mainly a regression for #248"
fi

# Composed corpus: individually valid, invalid once merged.
_bad_cmp=0
jq -r '.composed[] | "\(.path)\t\(.code)"' "$REG" > "$TMP/composed.tsv"
while IFS="$(printf '\t')" read -r _path _code; do
	[ -n "$_path" ] || continue
	_abs="$ROOT/$_path"
	[ -f "$_abs" ] || { fail "registered composed fixture does not exist: $_path"; _bad_cmp=1; continue; }
	# It must PASS per-manifest validation — otherwise it is not a composed-only defect.
	if ! sh "$CLI" --quiet "$_abs" >/dev/null 2>&1; then
		fail "composed fixture is rejected per-manifest, so it does not exercise composition: $_path"; _bad_cmp=1; continue
	fi
	if sh "$ROOT/scripts/resolve-effective-profile.sh" --manifest "$_abs" >"$TMP/eff" 2>"$TMP/err"; then
		fail "resolver accepted a composed-invalid manifest: $_path"; _bad_cmp=1; continue
	fi
	grep -q "$_code" "$TMP/err" || { fail "composed fixture $_path did not report $_code"; _bad_cmp=1; }
	[ -s "$TMP/eff" ] && { fail "resolver emitted a partial effective profile for $_path"; _bad_cmp=1; }
done < "$TMP/composed.tsv"
[ "$_bad_cmp" = 0 ] && pass "every composed fixture passes per-manifest validation and fails cross-manifest validation"

# The corpus directories must not accumulate unregistered files: an unregistered
# fixture is one nothing asserts anything about.
_unreg=0
for _f in "$ROOT"/tests/fixtures/profile-schema/rejected/*.json "$ROOT"/tests/fixtures/profile-schema/composed/*.json; do
	[ -f "$_f" ] || continue
	_rel=${_f#"$ROOT"/}
	jq -e --arg p "$_rel" '[(.rejected + .composed)[] | select(.path == $p)] | length > 0' "$REG" >/dev/null \
		|| { fail "fixture present but not registered: $_rel"; _unreg=1; }
done
[ "$_unreg" = 0 ] && pass "no unregistered fixture in the negative corpus"

# ---------------------------------------------------------------------------
# 4. MUTATION OF THE LIVE TREE — real entry points, real shipped manifest
# ---------------------------------------------------------------------------
# A synthetic root: a real COPY of profiles/ (the thing under mutation) with the
# engine's own directories linked in, so the production entry points run against
# a tree that differs from the repository in exactly one manifest.
SYNTH="$TMP/synth"
mkdir -p "$SYNTH" "$TMP/proj"
cp -R "$ROOT/profiles" "$SYNTH/profiles"
for _d in scripts templates schemas docs config; do
	[ -e "$ROOT/$_d" ] && ln -s "$ROOT/$_d" "$SYNTH/$_d"
done
LARAVEL="$SYNTH/profiles/laravel/profile.manifest.json"
cp "$LARAVEL" "$TMP/laravel.orig"

# Control: the UNMUTATED synthetic root behaves exactly like the repository.
if sh "$SYNTH/scripts/resolve-effective-profile.sh" --profile laravel >/dev/null 2>&1 \
	&& sh "$SYNTH/scripts/install-baseline.sh" --target "$TMP/proj" --profile laravel --apply >/dev/null 2>&1; then
	pass "mutation control: the unmutated synthetic root resolves AND installs"
else
	fail "the synthetic root does not work unmutated — every mutation result below is uninterpretable"
	exit 1
fi

# mutate <jq-filter> — rewrite the shipped laravel manifest in the synthetic root.
mutate() { jq "$1" "$TMP/laravel.orig" > "$LARAVEL"; }
unmutate() { cp "$TMP/laravel.orig" "$LARAVEL"; }

# Each mutation: (a) the pre-#248 gate accepts it, so it is a genuine hole;
# (b) every real entry point now refuses it.
mutation_case() {
	_label=$1; _filter=$2; _code=$3
	mutate "$_filter"
	if prefix_gate "$LARAVEL"; then
		pass "mutation '$_label': the pre-#248 gate ACCEPTS the mutated shipped manifest (the hole is real)"
	else
		fail "mutation '$_label': the pre-#248 gate already rejected it — not a regression for #248"
	fi
	_all_reject=1
	for _entry in \
		"resolve-effective-profile.sh --profile laravel" \
		"validate-profile-manifest.sh --all" \
		"bootstrap-profile-tools.sh --target $TMP/proj --profile laravel" \
		"install-baseline.sh --target $TMP/proj --profile laravel" \
		"sync-baseline.sh --target $TMP/proj --profile laravel"; do
		# shellcheck disable=SC2086
		set -- $_entry
		_s=$1; shift
		if sh "$SYNTH/scripts/$_s" "$@" >"$TMP/m.out" 2>"$TMP/m.err"; then
			fail "mutation '$_label': $_s ACCEPTED the mutated manifest"
			_all_reject=0
		elif ! grep -q "$_code" "$TMP/m.err" "$TMP/m.out"; then
			fail "mutation '$_label': $_s failed without reporting $_code"
			_all_reject=0
		fi
	done
	[ "$_all_reject" = 1 ] && pass "mutation '$_label': every entry point refuses it with $_code"
	unmutate
}

mutation_case "report path escapes reports/raw" \
	'.tools.phpstan.report = "reports/raw/../../etc/passwd.json"' INVALID_REPORT_PATH
mutation_case "executable becomes a glob" \
	'.tools.phpstan.executable = ["vendor/bin/*"]' UNSAFE_PATH
mutation_case "execution.pr becomes the string \"false\"" \
	'.tools.phpstan.execution.pr = "false"' FIELD_TYPE
mutation_case "tool-policy version drifts to 3" \
	'.tool_policy_version = 3' UNSUPPORTED_TOOL_POLICY_VERSION
mutation_case "a tool field is misspelt" \
	'.tools.phpstan.missing_behaviour = "warn"' UNKNOWN_FIELD
mutation_case "a parent name gains a traversal" \
	'.extends = ["../../etc"]' INVALID_IDENTIFIER
mutation_case "the one-of group loses its alternatives" \
	'.tools["php-tests"] |= del(.alternatives)' MISSING_REQUIRED_FIELD

# Release packaging refuses to digest a tree it has not validated.
printf '{}' > "$TMP/ev.json"
if sh "$ROOT/scripts/generate-release-manifest.sh" --evidence "$TMP/ev.json" --repo-root "$SYNTH" --body-only >/dev/null 2>&1; then
	pass "release packaging control: a clean tree packages"
else
	fail "release packaging rejects a clean tree — the mutation result below is uninterpretable"
fi
mutate '.tools.phpstan.report = "reports/raw/../../etc/passwd.json"'
if sh "$ROOT/scripts/generate-release-manifest.sh" --evidence "$TMP/ev.json" --repo-root "$SYNTH" --body-only >/dev/null 2>"$TMP/rel.err"; then
	fail "release packaging digested a tree carrying an invalid profile manifest"
else
	grep -q "refusing to package" "$TMP/rel.err" \
		&& pass "release packaging refuses to digest a tree carrying an invalid profile manifest" \
		|| fail "release packaging failed for an unrelated reason: $(head -1 "$TMP/rel.err")"
fi
unmutate

# The repository audit runs the same validator over every shipped manifest.
if sh "$ROOT/scripts/audits/profile-tool-integrity.sh" 2>&1 | grep -q 'satisfies profile.manifest.schema.json'; then
	pass "the profile-tool-integrity audit validates every shipped manifest at role=install"
else
	fail "the profile-tool-integrity audit no longer validates manifests"
fi

# ---------------------------------------------------------------------------
# 5. NO UNVALIDATED READER
# ---------------------------------------------------------------------------
# The defect this issue names is a manifest reaching composition on `jq -e .`
# alone. The consumer set is DISCOVERED, not listed: any script that turns a
# profile name into a manifest path must call the canonical validator. A new
# consumer added later is caught by this without editing the test.
#
# (#251) The discovery predicate follows the code. A consumer resolves a profile
# name to a manifest path either by calling the shared, identifier-validating
# lookup `ps_require_profile_manifest`, or by open-coding
# `profiles/$PROFILE/profile.manifest.json` — the pre-#251 form, which is a
# finding in its own right (asserted separately in tests/prod/301) but must
# still be DISCOVERED here so it cannot escape the validator requirement.
_consumers=$(grep -rl -e 'profiles/\$PROFILE/profile.manifest.json' -e 'ps_require_profile_manifest' "$ROOT/scripts" 2>/dev/null | grep -v '/lib/profile-schema\.sh$' || true)
_n_consumers=$(printf '%s\n' "$_consumers" | grep -c . || printf '0')
if [ "$_n_consumers" -ge 5 ]; then
	pass "discovered $_n_consumers script(s) that resolve a profile name to a manifest path"
else
	fail "only $_n_consumers manifest-resolving consumer(s) discovered — this check would be near-vacuous"
fi
_unvalidated=""
_stale=""
for _f in $_consumers; do
	[ -n "$_f" ] || continue
	grep -q 'ps_validate_manifest' "$_f" || _unvalidated="$_unvalidated ${_f#"$ROOT"/}"
	grep -q 'jq -e \. "\$MANIFEST"' "$_f" && _stale="$_stale ${_f#"$ROOT"/}"
done
[ -z "$_unvalidated" ] && pass "every discovered consumer calls the canonical validator" \
	|| fail "consumers that resolve a manifest without validating it:$_unvalidated"
[ -z "$_stale" ] && pass "no consumer still admits a profile manifest on 'jq -e .' alone" \
	|| fail "consumers still admitting a manifest on 'jq -e .' alone:$_stale"

for _c in install-baseline.sh sync-baseline.sh plan-upgrade.sh migrate-v1.sh bootstrap-profile-tools.sh; do
	if grep -q 'ps_validate_manifest' "$ROOT/scripts/$_c"; then
		pass "$_c calls the canonical validator"
	else
		fail "$_c does not call the canonical validator"
	fi
done
if grep -q 'ps_validate_manifest' "$ROOT/scripts/lib/effective-profile.sh" \
	&& grep -q 'ps_validate_composed' "$ROOT/scripts/lib/effective-profile.sh"; then
	pass "the resolver validates every manifest in the DAG and the composed result"
else
	fail "the resolver no longer calls the canonical validator"
fi
# The resolver must fail closed if the validator library is missing, rather than
# silently reverting to the old behaviour.
if grep -q 'refusing to resolve an unvalidated manifest' "$ROOT/scripts/lib/effective-profile.sh"; then
	pass "the resolver fails closed when the validator library is absent"
else
	fail "the resolver does not fail closed when the validator library is absent"
fi

printf '\n'
if [ "$FAILS" -eq 0 ]; then
	printf 'profile-manifest-schema: ALL CHECKS PASSED\n'
	exit 0
fi
printf 'profile-manifest-schema: %s CHECK(S) FAILED\n' "$FAILS"
exit 1
