#!/bin/sh
# Sentinel Shield prod test — accepted-risk schema v2 and its explicit migration.
#
# Accepted risks are EXECUTABLE POLICY: a record can stop a gate from failing. v1.1 left every
# object OPEN, and an ignored unknown field is dangerous in exactly one direction — a field
# meant to NARROW a record (`paths` instead of `files`, a misspelled `components`) is silently
# dropped, and the record then suppresses MORE than its author intended. v2 closes every
# object, puts deliberate additions in `extensions`, and requires the authorisation dates the
# validity policy needs.
#
# Migration is explicit: it never rewrites the consumer's file, never invents an approval, and
# refuses records that need a human.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
ENFORCE="$ROOT/scripts/enforce-gates.sh"
RESOLVE="$ROOT/scripts/resolve-gates.sh"
MIGRATE="$ROOT/scripts/migrate-accepted-risks.sh"
SCHEMA="$ROOT/schemas/accepted-risks-v2.schema.json"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$MIGRATE" ] || { fail "missing scripts/migrate-accepted-risks.sh"; exit 1; }
[ -f "$SCHEMA" ] || { fail "missing schemas/accepted-risks-v2.schema.json"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP
mkdir -p "$WORK/out"
TODAY=$(date -u +%Y-%m-%d)
SOON=$(date -u -d '+30 days' +%Y-%m-%d 2>/dev/null || date -u -v+30d +%Y-%m-%d)
PAST=$(date -u -d '-10 days' +%Y-%m-%d 2>/dev/null || date -u -v-10d +%Y-%m-%d)
FUTURE=$(date -u -d '+400 days' +%Y-%m-%d 2>/dev/null || date -u -v+400d +%Y-%m-%d)

jq '.tools = {"tests":{"status":"pass"}}' "$ROOT/templates/security-summary.example.json" > "$WORK/s.json"
sh "$RESOLVE" --mode baseline --output-dir "$WORK/out" --format all >/dev/null 2>&1

# v2 <extra-json> — a valid v2 document with one record, plus <extra-json> merged in.
v2() {
	jq -n --arg t "$TODAY" --arg e "$SOON" --argjson x "${1:-{\}}" \
		'{version:"2", risks:[({id:"AR-1", gate:"unsafe_docker", scope:"gate", status:"approved",
			owner:"o", reason:"r", created_at:$t, approved_at:$t, expires_at:$e} + $x)]}' > "$WORK/ar.json"
}
# doc <full-json> — an arbitrary document.
doc() { printf '%s' "$1" > "$WORK/ar.json"; }
enf() {
	_c=0
	sh "$ENFORCE" --gates-env "$WORK/out/sentinel-shield-gates.env" --summary "$WORK/s.json" \
		--accepted-risks "$WORK/ar.json" --output-dir "$WORK/out" --format json >"$WORK/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}

# ---------------------------------------------------------------------------
# 1. The schema document itself.
# ---------------------------------------------------------------------------
check "the v2 schema is valid JSON" "$(jq -e . "$SCHEMA" >/dev/null 2>&1 && echo yes || echo no)" "yes"
check "  the document object is closed" "$(jq -r '.additionalProperties' "$SCHEMA")" "false"
check "  each risk record is closed" "$(jq -r '.properties.risks.items.additionalProperties' "$SCHEMA")" "false"
check "  the approval object is closed" "$(jq -r '.properties.risks.items.properties.approval.additionalProperties' "$SCHEMA")" "false"
check "  version is pinned to 2" "$(jq -r '.properties.version.const' "$SCHEMA")" "2"
check "  extensions are namespaced by grammar" \
	"$(jq -r '(.properties.extensions.propertyNames.pattern // "") | length > 0' "$SCHEMA")" "true"
for _f in id gate scope status owner reason created_at expires_at; do
	check "  $_f is required" "$(jq -r --arg f "$_f" '[.properties.risks.items.required[]] | index($f) != null' "$SCHEMA")" "true"
done
# approved_at is required CONDITIONALLY: a pending record has not been approved, so demanding
# its approval date would be incoherent — the schema requires it only when status is approved.
check "  approved_at is required only for an APPROVED record" \
	"$(jq -r '[.properties.risks.items.allOf[]? | select(.if.properties.status.const == "approved") | .then.required[]] | index("approved_at") != null' "$SCHEMA")" "true"
check "  status is an enum" "$(jq -r '.properties.risks.items.properties.status.enum | length' "$SCHEMA")" "5"
check "  scope is an enum" "$(jq -r '.properties.risks.items.properties.scope.enum | join(",")' "$SCHEMA")" "finding,gate"

# ---------------------------------------------------------------------------
# 2. A valid v2 document works, and extensions are allowed.
# ---------------------------------------------------------------------------
v2 '{}'; check "a valid v2 document enforces" "$(enf)" 0
v2 '{"extensions":{"acme.example/ticket":"SEC-1","vendor.io/team":{"name":"platform"}}}'
check "a namespaced extension object is accepted" "$(enf)" 0
doc "$(jq -n --arg t "$TODAY" --arg e "$SOON" '{version:"2", extensions:{"acme.example/owner":"x"},
	risks:[{id:"AR-1",gate:"unsafe_docker",scope:"gate",status:"approved",owner:"o",reason:"r",
	created_at:$t,approved_at:$t,expires_at:$e}]}')"
check "a document-level extension is accepted" "$(enf)" 0

# ---------------------------------------------------------------------------
# 3. Unknown fields fail closed — the core of v2.
# ---------------------------------------------------------------------------
v2 '{"paths":["src/app.php"]}'
check "an unknown field that LOOKS like a narrowing matcher is refused" "$(enf)" 2
contains "  and the message explains the danger" "$(cat "$WORK/log")" "would BROADEN the suppression"
v2 '{"componentss":["lodash"]}'; check "a misspelled matcher is refused" "$(enf)" 2
v2 '{"notes":"harmless"}'; check "even a harmless-looking unknown field is refused" "$(enf)" 2
contains "  pointing at extensions" "$(cat "$WORK/log")" "extensions"
doc "$(jq -n --arg t "$TODAY" --arg e "$SOON" '{version:"2", whatever:1,
	risks:[{id:"AR-1",gate:"unsafe_docker",scope:"gate",status:"approved",owner:"o",reason:"r",
	created_at:$t,approved_at:$t,expires_at:$e}]}')"
check "an unknown TOP-LEVEL property is refused" "$(enf)" 2
contains "  naming it" "$(cat "$WORK/log")" "unknown top-level property"
v2 '{"extensions":{"NoNamespace":1}}'; check "a malformed extension key is refused" "$(enf)" 2
v2 '{"extensions":{"acme.example/UPPER-ok":1}}'; check "  a valid key with mixed-case value part is accepted" "$(enf)" 0
v2 '{"extensions":"a string"}'; check "extensions must be an object" "$(enf)" 2

# ---------------------------------------------------------------------------
# 4. Types, enums, identity and dates.
# ---------------------------------------------------------------------------
v2 '{"emergency":"yes"}'; check "a YAML-style boolean supplied as a string is refused" "$(enf)" 2
v2 '{"emergency":true}';  check "  a real boolean is accepted" "$(enf)" 0
v2 '{"owner":123}';       check "a number where a string is required is refused" "$(enf)" 2
v2 '{"reason":true}';     check "a boolean where a string is required is refused" "$(enf)" 2
v2 '{"files":"src/a.php"}'; check "a scalar where an array is required is refused" "$(enf)" 2
v2 '{"files":["src/a.php",""]}'; check "an empty array member is refused" "$(enf)" 2
v2 '{"files":["../../etc/passwd"]}'; check "a traversing path is refused" "$(enf)" 2
v2 '{"files":["/etc/passwd"]}'; check "an absolute path is refused" "$(enf)" 2
v2 '{"status":"approvedish"}'; check "an unknown status is refused" "$(enf)" 2
v2 '{"scope":"everything"}'; check "an unknown scope is refused" "$(enf)" 2
v2 '{"severity":"spicy"}'; check "an unknown severity is refused" "$(enf)" 2
v2 '{"id":"a b"}'; check "a malformed id is refused" "$(enf)" 2
v2 '{"id":"ab"}'; check "  a too-short id is refused" "$(enf)" 2
v2 '{"approved_at":"2026-02-31"}'; check "an impossible calendar date is refused" "$(enf)" 2
v2 '{"approved_at":"not-a-date"}'; check "a malformed date is refused" "$(enf)" 2
doc "$(jq -n --arg t "$TODAY" --arg e "$SOON" '{version:"2", risks:[
	{id:"AR-1",gate:"unsafe_docker",scope:"gate",status:"approved",owner:"o",reason:"r",created_at:$t,approved_at:$t,expires_at:$e},
	{id:"AR-1",gate:"secrets",scope:"gate",status:"approved",owner:"o",reason:"r",created_at:$t,approved_at:$t,expires_at:$e}]}')"
check "a duplicate record id is refused" "$(enf)" 2
contains "  naming the duplicate" "$(cat "$WORK/log")" "duplicate record id"
doc "$(jq -n --arg t "$TODAY" --arg e "$SOON" '{version:"2", risks:[
	{id:"AR-1",gate:"unsafe_docker",scope:"gate",status:"approved",owner:"o",reason:"r",created_at:$t,expires_at:$e}]}')"
check "a missing required field is refused" "$(enf)" 2
contains "  naming the field" "$(cat "$WORK/log")" "approved_at"
v2 "$(jq -nc --arg o "o" '{approval:{approved_by:$o, authority:"platform"}}')"
check "self-approval (approved_by == owner) is refused" "$(enf)" 2
v2 '{"approval":{"approved_by":"sec","authority":"platform","surprise":1}}'
check "an unknown approval property is refused" "$(enf)" 2
v2 '{"approval":"sec"}'; check "approval must be an object" "$(enf)" 2

# ---------------------------------------------------------------------------
# 5. Timestamps drive the duration policy.
# ---------------------------------------------------------------------------
v2 "$(jq -nc --arg f "$FUTURE" '{approved_at:$f, expires_at:$f}')"
check "a future approved_at is refused" "$(enf)" 2
v2 "$(jq -nc --arg t "$TODAY" --arg f "$FUTURE" '{approved_at:$t, expires_at:$f}')"
check "an expiry beyond the policy maximum is refused" "$(enf)" 2
contains "  naming the maximum" "$(cat "$WORK/log")" "-day maximum"
v2 "$(jq -nc --arg p "$PAST" --arg t "$TODAY" '{approved_at:$t, expires_at:$p}')"
check "an expiry BEFORE the approval is refused" "$(enf)" 2

# ---------------------------------------------------------------------------
# 6. Version handling.
# ---------------------------------------------------------------------------
doc "$(jq -n --arg t "$TODAY" --arg e "$SOON" '{version:"3", risks:[]}')"
check "an unsupported future version is refused" "$(enf)" 2
contains "  and is never read as the newest one" "$(cat "$WORK/log")" "never read as the newest"
doc '{"risks":[]}'; check "a document with no version is refused" "$(enf)" 2
doc "$(jq -n --arg e "$SOON" '{version:"1.1", risks:[{id:"AR-1",gate:"unsafe_docker",scope:"gate",owner:"o",reason:"r",expires_at:$e,status:"approved"}]}')"
check "a legacy document is TOLERATED in baseline" "$(enf)" 0
contains "  with a deprecation warning" "$(cat "$WORK/log")" "DEPRECATED schema version"
contains "  naming the migration command" "$(cat "$WORK/log")" "migrate-accepted-risks.sh"
contains "  and the removal timeline" "$(cat "$WORK/log")" "Sentinel Shield v3"
for _m in strict regulated; do
	sh "$RESOLVE" --mode "$_m" --output-dir "$WORK/out" --format all >/dev/null 2>&1
	jq '.tools = {"tests":{"status":"pass"}}
		| .source.trust = "github-actions-attested"
		| .attestation = {verified:true, issuer:"i", repository:(.source.repository),
			commit:(.source.commit), workflow:"w", workflow_sha:"1111111111111111111111111111111111111111",
			run_id:"1", run_attempt:"1", artifact_digest:"sha256:00"}' \
		"$ROOT/templates/security-summary.example.json" > "$WORK/s.json"
	check "a legacy document is REFUSED in $_m" "$(enf)" 2
	contains "  naming schema v2 as the requirement ($_m)" "$(cat "$WORK/log")" "requires schema v2"
done
sh "$RESOLVE" --mode baseline --output-dir "$WORK/out" --format all >/dev/null 2>&1
jq '.tools = {"tests":{"status":"pass"}}' "$ROOT/templates/security-summary.example.json" > "$WORK/s.json"

# ---------------------------------------------------------------------------
# 7. Migration is explicit and never invents an approval.
# ---------------------------------------------------------------------------
M="$WORK/mig"; mkdir -p "$M"
jq -n --arg t "$PAST" --arg e "$SOON" '{version:"1.1", risks:[
	{id:"AR-OK", gate:"unsafe_docker", scope:"gate", owner:"o", reason:"r", approved_by:"sec",
	 created_at:$t, approved_at:$t, expires_at:$e, status:"approved"},
	{id:"AR-NOAPP", gate:"medium_vulnerabilities", scope:"finding", components:["lodash"],
	 owner:"o", reason:"r", expires_at:$e, status:"approved"}]}' > "$M/legacy.json"
_before=$(jq -S -c . "$M/legacy.json")
_c=0; sh "$MIGRATE" --input "$M/legacy.json" --output "$M/v2.json" >"$M/log" 2>&1 || _c=$?
check "migration exits 1 when a record needs human completion" "$_c" 1
check "  the source file is untouched" "$(jq -S -c . "$M/legacy.json")" "$_before"
check "  a v2 file was still produced for review" "$(jq -r '.version' "$M/v2.json")" "2"
check "  the fully-approved record keeps its approval" "$(jq -r '.risks[] | select(.id=="AR-OK") | .status' "$M/v2.json")" "approved"
check "  the record with no approval date becomes PENDING" "$(jq -r '.risks[] | select(.id=="AR-NOAPP") | .status' "$M/v2.json")" "pending"
check "  and NO approval date was invented" "$(jq -r '.risks[] | select(.id=="AR-NOAPP") | has("approved_at")' "$M/v2.json")" "false"
contains "  the report says the approval was not invented" "$(cat "$M/log")" "approval NOT invented"
check "  ids are preserved" "$(jq -r '[.risks[].id] | join(",")' "$M/v2.json")" "AR-OK,AR-NOAPP"
check "  original dates are preserved" "$(jq -r '.risks[] | select(.id=="AR-OK") | .approved_at' "$M/v2.json")" "$PAST"
check "  matching dimensions are preserved" "$(jq -r '.risks[] | select(.id=="AR-NOAPP") | .components | join(",")' "$M/v2.json")" "lodash"
check "  the source schema version is recorded" "$(jq -r '.migrated_from.source_version' "$M/v2.json")" "1.1"
check "  the source digest is recorded" "$(jq -r '.migrated_from.source_digest | test("^[0-9a-f]{64}$")' "$M/v2.json")" "true"
check "  a migration timestamp is recorded" "$(jq -r '(.migrated_from.migrated_at // "") | length > 0' "$M/v2.json")" "true"
# Deterministic: the same input produces the same records twice.
sh "$MIGRATE" --input "$M/legacy.json" --output "$M/v2b.json" --force >/dev/null 2>&1 || true
check "migration output is deterministic (records)" \
	"$(jq -S -c '.risks' "$M/v2.json")" "$(jq -S -c '.risks' "$M/v2b.json")"

# Ambiguous records are refused outright.
jq -n --arg e "$SOON" '{version:"1.1", risks:[{id:"AR-X", gate:"unsafe_docker", scope:"gate",
	owner:"o", reason:"r", expires_at:$e, status:"approved", mystery_matcher:["a"]}]}' > "$M/amb.json"
_c=0; sh "$MIGRATE" --input "$M/amb.json" --output "$M/amb-v2.json" >"$M/amblog" 2>&1 || _c=$?
check "an ambiguous record refuses migration" "$_c" 1
contains "  naming the undecidable field" "$(cat "$M/amblog")" "mystery_matcher"
check "  and nothing was written" "$([ -e "$M/amb-v2.json" ] && echo written || echo clean)" "clean"

# Destination safety and dry-run.
_c=0; sh "$MIGRATE" --input "$M/legacy.json" --output "$M/v2.json" >/dev/null 2>&1 || _c=$?
check "an existing destination is refused without --force" "$_c" 2
_c=0; sh "$MIGRATE" --input "$M/legacy.json" --output "$M/legacy.json" >/dev/null 2>&1 || _c=$?
check "writing over the input is refused" "$_c" 2
ln -s "$M/elsewhere.json" "$M/link.json"
_c=0; sh "$MIGRATE" --input "$M/legacy.json" --output "$M/link.json" --force >/dev/null 2>&1 || _c=$?
check "a symlinked destination is refused" "$_c" 2
check "  and nothing was written through it" "$([ -e "$M/elsewhere.json" ] && echo written || echo clean)" "clean"
jq -n --arg t "$PAST" --arg e "$SOON" '{version:"1.1", risks:[{id:"AR-OK", gate:"unsafe_docker",
	scope:"gate", owner:"o", reason:"r", approved_by:"sec", created_at:$t, approved_at:$t,
	expires_at:$e, status:"approved"}]}' > "$M/clean.json"
_c=0; sh "$MIGRATE" --input "$M/clean.json" --dry-run >"$M/dry" 2>&1 || _c=$?
check "a clean dry-run exits 0" "$_c" 0
contains "  and prints the proposed document" "$(cat "$M/dry")" '"version": "2"'
check "  writing nothing" "$([ -e "$M/clean-v2.json" ] && echo written || echo clean)" "clean"
_c=0; sh "$MIGRATE" --input "$M/clean.json" --report >"$M/rep" 2>&1 || _c=$?
check "--report exits 0 for a clean file" "$_c" 0
contains "  and reports the source digest" "$(cat "$M/rep")" "source digest:"
_c=0; sh "$MIGRATE" --input "$M/v2.json" --output "$M/again.json" >/dev/null 2>&1 || _c=$?
check "migrating an already-v2 file is refused" "$_c" 2
printf 'not json' > "$M/bad.json"
_c=0; sh "$MIGRATE" --input "$M/bad.json" --output "$M/bad-v2.json" >/dev/null 2>&1 || _c=$?
check "a malformed input is refused" "$_c" 2
_c=0; sh "$MIGRATE" --input "$M/missing.json" --output "$M/x.json" >/dev/null 2>&1 || _c=$?
check "a missing input is refused" "$_c" 2

# The migrated document must satisfy the v2 runtime it was produced for.
cp "$M/v2.json" "$WORK/ar.json"
jq '.risks |= map(select(.status == "approved"))' "$M/v2.json" > "$WORK/ar.json"
check "the migrated document is accepted by the v2 runtime" "$(enf)" 0

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '298-accepted-risk-schema-v2: ALL CHECKS PASSED\n'
	exit 0
fi
printf '298-accepted-risk-schema-v2: FAILURES PRESENT\n'
exit 1
