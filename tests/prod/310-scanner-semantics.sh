#!/bin/sh
# Sentinel Shield production test — Layer 3 scanner and collector semantics (#96-#105, #135-#137,
# #184, #185).
#
# LAYER 3 OF THREE. 308 proves the shared lifecycle once; 309 proves every adapter participates in
# it and honours its contract row. This suite proves only what NEITHER of those can: the meaning
# each tool assigns to its own output, and what a collector concludes from bound evidence.
#
# Nothing here re-runs a lifecycle scenario. Every case asserts a SEMANTIC state or serialized
# field, never an exit code alone, and every negative carries a control proving the guard it names
# was actually reached -- an earlier `unavailable` or parse failure is not evidence for a later
# semantic rule.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
SS_LIB_DIR="$ROOT/scripts/lib"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$ROOT/scripts/lib/normalized-evidence.sh"

assert_precondition "jq is available" command -v jq
assert_precondition "the e2e manifest exists" test -f "$ROOT/config/e2e-evidence-manifest.json"
assert_precondition "the evidence generator exists" test -f "$ROOT/scripts/generate-e2e-evidence.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT
MANIFEST="$ROOT/config/e2e-evidence-manifest.json"
GEN="$ROOT/scripts/generate-e2e-evidence.sh"

# prov <report> <tool> <state> <mode> <subject> — write a sidecar bound to the report as it is now.
prov() {
	_p_d=$(ne_sha256 "$1") || _p_d=""
	jq -n --arg t "$2" --arg d "$_p_d" --arg s "$3" --arg m "$4" --arg sub "${5:-}" \
		'{contract:"sentinel-shield/scanner-transaction@1", tool:$t, completion:{state:$s},
		  report:{sha256:$d}, target:{identity:$sub, mode:$m}}' > "${1%.json}.provenance.json"
}
# collect <collector> <report> [env...] — run a production collector, print its serialized output.
collect() {
	_c_col="$ROOT/scripts/collectors/$1.sh"; _c_rep="$2"; shift 2
	( for _e in "$@"; do export "${_e?}"; done
	  sh "$_c_col" --input "$_c_rep" 2>/dev/null ) || :
}
st_of()   { printf '%s' "$1" | jq -r '.status // "-"' 2>/dev/null || printf '?'; }
health()  { printf '%s' "$1" | jq -r '.tool_report.health // "-"' 2>/dev/null || printf '?'; }
field()   { printf '%s' "$1" | jq -r ".tool_report.$2 // \"-\"" 2>/dev/null || printf '?'; }

# ===========================================================================
# 1. THE COMMITTED FIXTURE SET IS CURRENT AND REPRODUCIBLE
# ===========================================================================
assert_true "the committed 20-row fixture set passes --check" sh "$GEN" --check

ROWS=$(jq -r '.rows | length' "$MANIFEST")
assert_equal "the manifest declares twenty rows" "20" "$ROWS"
_missing=""; _nosidecar=""
for _r in $(jq -r '.rows[].report' "$MANIFEST"); do
	[ -f "$ROOT/$_r" ] || _missing="$_missing $_r"
	[ -f "$ROOT/${_r%.json}.provenance.json" ] || _nosidecar="$_nosidecar $_r"
done
assert_equal "every manifest row resolves to a report" "" "$_missing"
assert_equal "every manifest row resolves to a sidecar" "" "$_nosidecar"
_dupes=$(jq -r '[.rows[].report] | group_by(.) | map(select(length>1)|.[0]) | join(" ")' "$MANIFEST")
assert_equal "no report is claimed by two manifest rows" "" "$_dupes"
# Every committed in-scope report is claimed by a row: an unreferenced fixture is coverage nobody
# checks, which is how the placeholder set survived unnoticed in the first place.
_unref=""
for _f in $(find "$ROOT/tests/e2e" -name 'syft.json' -o -name 'trivy-fs.json' -o -name 'grype.json' -o -name 'osv-scanner.json' 2>/dev/null); do
	_rel=${_f#"$ROOT"/}
	jq -e --arg p "$_rel" '[.rows[] | select(.report == $p)] | length == 1' "$MANIFEST" >/dev/null 2>&1 \
		|| _unref="$_unref $_rel"
done
assert_equal "every committed in-scope e2e report is claimed by exactly one row" "" "$_unref"

# --check must not write. Compared by digest over the whole fixture tree, not by trusting the mode.
_before=$(find "$ROOT/tests/e2e" -type f -exec ne_sha256 {} \; 2>/dev/null | sort | ne_sha256 /dev/stdin 2>/dev/null || printf 'a')
sh "$GEN" --check >/dev/null 2>&1 || :
_after=$(find "$ROOT/tests/e2e" -type f -exec ne_sha256 {} \; 2>/dev/null | sort | ne_sha256 /dev/stdin 2>/dev/null || printf 'b')
assert_equal "--check leaves the fixture tree byte-identical" "$_before" "$_after"

# Generation is deterministic: regenerating into a copy reproduces the committed bytes exactly.
cp -R "$ROOT/tests/e2e" "$TMP/e2e-copy" 2>/dev/null || :
assert_true "generation is byte-reproducible (a second --check still agrees)" sh "$GEN" --check

# ===========================================================================
# 2. BINDING REJECTIONS, ON AN ISOLATED COPY — never the committed fixtures.
# ===========================================================================
SB="$TMP/sandbox"; mkdir -p "$SB"
seed() { # seed <tool> <body> -> $SB/report.json with valid provenance
	printf '%s' "$2" > "$SB/report.json"
	prov "$SB/report.json" "$1" "completed-clean" "${3:-dir}" "subject-a"
}
SYFT_OK='{"spdxVersion":"SPDX-2.3","name":"subject-a","creationInfo":{"created":"2026-01-01T00:00:00Z"},"packages":[]}'
GRYPE_OK='{"matches":[],"source":{"type":"directory","target":"."},"descriptor":{"name":"grype","version":"1","db":{"built":"2026-01-01T00:00:00Z"}}}'
TRIVY_OK='{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[]}'

seed syft "$SYFT_OK"
assert_equal "CONTROL: bound Syft evidence is accepted" "pass" "$(st_of "$(collect syft "$SB/report.json")")"
rm -f "$SB/report.provenance.json"
assert_equal "a missing sidecar is refused" "execution-error" "$(st_of "$(collect syft "$SB/report.json")")"
seed syft "$SYFT_OK"; printf '%s ' "$SYFT_OK" > "$SB/report.json"
assert_equal "a report mutated after generation fails digest binding" "execution-error" "$(st_of "$(collect syft "$SB/report.json")")"
seed syft "$SYFT_OK"; prov "$SB/report.json" "grype" "completed-clean" "dir" "subject-a"
assert_equal "a wrong producer is refused" "execution-error" "$(st_of "$(collect syft "$SB/report.json")")"
seed syft "$SYFT_OK"; prov "$SB/report.json" "syft" "completed-clean" "dir" "someone-else"
assert_equal "a wrong subject is refused" "execution-error" \
	"$(st_of "$(collect syft "$SB/report.json" SENTINEL_SHIELD_SYFT_SUBJECT=subject-a)")"
seed syft "$SYFT_OK"; prov "$SB/report.json" "syft" "unavailable" "dir" "subject-a"
assert_equal "a non-scan completion state is refused" "execution-error" "$(st_of "$(collect syft "$SB/report.json")")"

# NE_KIND=fixture MUST NOT BUY AN EXEMPTION. The binding is absolute by design: a fixture that
# cannot prove what produced it is exactly the forged evidence this batch removes.
seed syft "$SYFT_OK"; rm -f "$SB/report.provenance.json"
assert_equal "NE_KIND=fixture without a sidecar is still refused" "execution-error" \
	"$(st_of "$(collect syft "$SB/report.json" NE_KIND=fixture)")"
seed syft "$SYFT_OK"; prov "$SB/report.json" "syft" "completed-clean" "dir" "subject-a"
printf '%s  ' "$SYFT_OK" > "$SB/report.json"
assert_equal "NE_KIND=fixture with forged provenance is still refused" "execution-error" \
	"$(st_of "$(collect syft "$SB/report.json" NE_KIND=fixture)")"
assert_false "ce_bind contains no fixture exemption" \
	grep -qE 'ne_fixture_allowed|NE_KIND|non_production' "$ROOT/scripts/lib/collector-evidence.sh"

# TRIVY: image evidence cannot satisfy the filesystem contract.
seed trivy-fs "$TRIVY_OK" filesystem
assert_equal "CONTROL: filesystem-mode Trivy evidence is accepted" "pass" "$(st_of "$(collect trivy "$SB/report.json")")"
prov "$SB/report.json" "trivy-fs" "completed-clean" "container-image" "subject-a"
assert_equal "image-mode provenance cannot satisfy the filesystem collector" "execution-error" \
	"$(st_of "$(collect trivy "$SB/report.json")")"

# ===========================================================================
# 3. TOOL SEMANTICS THAT ONLY A COLLECTOR CAN ESTABLISH
# ===========================================================================
# SYFT (#135): an inventory, never a findings verdict; `{}` is not an SBOM.
printf '{}' > "$SB/report.json"; prov "$SB/report.json" "syft" "completed-clean" "dir" "subject-a"
assert_equal "an empty-object placeholder is not an SBOM" "execution-error" "$(st_of "$(collect syft "$SB/report.json")")"
SYFT_POP='{"spdxVersion":"SPDX-2.3","name":"subject-a","creationInfo":{"created":"2026-01-01T00:00:00Z"},"packages":[{"name":"p"},{"name":"q"}]}'
seed syft "$SYFT_POP"
_out=$(collect syft "$SB/report.json")
assert_equal "a populated inventory is still clean, not findings" "pass" "$(st_of "$_out")"
assert_equal "and reports its package count as inventory" "2" "$(field "$_out" packages)"

# GRYPE (#137): the forgeable minimal object is refused even when its provenance is valid.
printf '{"matches":[]}' > "$SB/report.json"; prov "$SB/report.json" "grype" "completed-clean" "dir" "subject-a"
assert_equal "a forged minimal Grype object is refused" "execution-error" "$(st_of "$(collect grype "$SB/report.json")")"
seed grype "$GRYPE_OK"
assert_equal "CONTROL: a complete clean Grype report is accepted" "pass" "$(st_of "$(collect grype "$SB/report.json")")"

# OSV (#184, #185): no-targets vs clean, and low findings that survive to the emitted output.
OSV_CLEAN='{"results":[{"source":{"path":"go.mod","type":"lockfile"},"packages":[]}]}'
OSV_LOW='{"results":[{"source":{"path":"go.mod","type":"lockfile"},"packages":[{"package":{"name":"p"},"vulnerabilities":[{"id":"G-1","database_specific":{"severity":"LOW"}}]}]}]}'
OSV_MIX='{"results":[{"source":{"path":"go.mod","type":"lockfile"},"packages":[{"package":{"name":"p"},"vulnerabilities":[{"id":"G-1","database_specific":{"severity":"LOW"}},{"id":"G-2","database_specific":{"severity":"HIGH"}}]}]}]}'
printf '%s' "$OSV_CLEAN" > "$SB/report.json"; prov "$SB/report.json" "osv-scanner" "completed-clean" "lockfile" "subject-a"
_o=$(collect osv-scanner "$SB/report.json")
assert_equal "a clean applicable OSV scan is pass/ok" "ok" "$(health "$_o")"
printf '{"results":[]}' > "$SB/report.json"; prov "$SB/report.json" "osv-scanner" "completed-no-targets" "lockfile" "subject-a"
assert_equal "no-targets is its own outcome, not clean" "no-targets" "$(st_of "$(collect osv-scanner "$SB/report.json")")"
printf '{"results":[]}' > "$SB/report.json"; prov "$SB/report.json" "osv-scanner" "completed-clean" "lockfile" "subject-a"
assert_equal "empty results claiming clean is contradictory and refused" "execution-error" \
	"$(st_of "$(collect osv-scanner "$SB/report.json")")"
printf '%s' "$OSV_LOW" > "$SB/report.json"; prov "$SB/report.json" "osv-scanner" "completed-findings" "lockfile" "subject-a"
_o=$(collect osv-scanner "$SB/report.json")
assert_equal "a low-only result reports findings present" "findings" "$(health "$_o")"
assert_equal "and preserves the low count in the serialized output" "1" "$(field "$_o" low)"
assert_equal "while a gate excluding low still passes" "pass" "$(st_of "$_o")"
printf '%s' "$OSV_MIX" > "$SB/report.json"; prov "$SB/report.json" "osv-scanner" "completed-findings" "lockfile" "subject-a"
_o=$(collect osv-scanner "$SB/report.json")
assert_equal "mixed severities reconcile with their components" "2" "$(field "$_o" findings_total)"
assert_equal "and a gated severity fails the gate" "fail" "$(st_of "$_o")"

assert_summary "scanner-semantics (Layer 3: tool meaning and collector conclusions)"
