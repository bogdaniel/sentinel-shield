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

# ===========================================================================
# 4. ADAPTER-LEVEL TOOL SEMANTICS
#
# These five groups were implemented and verified by hand in earlier sessions, then found missing
# from this suite by the acceptance audit. A behaviour proven only by a command someone once ran is
# not evidence, so each is captured here against the production adapter.
# ===========================================================================
. "$ROOT/tests/lib/scanner-fake.sh"
AD="$ROOT/scripts/audits"

# --- #104 GRYPE: Docker option/image injection -----------------------------------
# A docker STUB is required: with no docker on PATH the adapter reports unavailable and never
# reaches the argument boundary, which is how an earlier probe of mine "passed" while proving
# nothing. The stub records the exact argument vector it received.
GD="$TMP/grype-docker"; mkdir -p "$GD/bin"
cat > "$GD/bin/docker" <<'DOCKEOF'
#!/bin/sh
printf '%s\n' "$@" > "${SS_ARGV_SINK:-/dev/null}"
exit 0
DOCKEOF
chmod +x "$GD/bin/docker"
gy_run() { # gy_run <image> -> state; argv captured to $GD/argv
	_g_p=$(sf_project "$GD/$1x" 2>/dev/null) || _g_p="$GD/run/proj"
	mkdir -p "$_g_p/reports/raw"
	( cd "$_g_p" || exit 1
	  PATH="$GD/bin:/usr/bin:/bin"; export PATH
	  SS_ARGV_SINK="$GD/argv"; export SS_ARGV_SINK
	  SENTINEL_SHIELD_GRYPE_MODE=fs; export SENTINEL_SHIELD_GRYPE_MODE
	  SENTINEL_SHIELD_GRYPE_IMAGE="$1"; export SENTINEL_SHIELD_GRYPE_IMAGE
	  sh "$AD/grype.sh" reports/raw/grype.json >/dev/null 2>&1 ) || :
	sf_state "$_g_p" reports/raw/grype.json
}
assert_equal "grype-injection: an option-bearing image value is refused" \
	"execution-error" "$(gy_run -- "--privileged evil")"
assert_equal "grype-injection: a leading-dash image value is refused" \
	"execution-error" "$(gy_run "-v /:/host")"
# The legitimate control must reach the docker boundary: the stub was invoked, and the image
# arrived as ONE argument rather than being split.
_gy_legit=$(gy_run "registry.example/img@sha256:abc123")
assert_true "grype-injection CONTROL: the docker boundary was reached for a digest-pinned image" \
	test -f "$GD/argv"
assert_true "grype-injection CONTROL: the image survived as a single argument" \
	grep -qxF 'registry.example/img@sha256:abc123' "$GD/argv"
assert_false "grype-injection CONTROL: no argument was split on whitespace" \
	grep -qxF '--privileged' "$GD/argv"

# --- #98 CONFTEST: no-targets versus clean ---------------------------------------
ct_run() { # ct_run <case> <payload> <exit> <with-policy>
	_c_d="$TMP/conftest-$1"; _c_p=$(sf_project "$_c_d")
	sf_make "$_c_d" conftest stdout "${4:-clean}" "$2" "$3" >/dev/null
	[ "${5:-yes}" = yes ] && { mkdir -p "$_c_p/policy"; printf 'package main\n' > "$_c_p/policy/p.rego"; }
	sf_run "$_c_p" "$_c_d/bin" "$AD/conftest.sh" reports/raw/conftest.json || :
	sf_state "$_c_p" reports/raw/conftest.json
}
assert_equal "conftest-no-targets: an empty result array with exit 0 is no-targets, not clean" \
	"completed-no-targets" "$(ct_run empty '[]' 0)"
assert_equal "conftest-clean: evaluated targets with no failures are clean" \
	"completed-clean" "$(ct_run clean '[{"filename":"a.yaml","successes":1}]' 0)"
assert_equal "conftest-findings: evaluated targets with failures are findings" \
	"completed-findings" "$(ct_run find '[{"filename":"a.yaml","failures":[{"msg":"deny"}]}]' 1 findings)"
assert_equal "conftest-malformed: truncated output is an error, never no-targets" \
	"execution-error" "$(ct_run malformed '[{"filena' 0 malformed)"
assert_equal "conftest-not-applicable: no policy directory is not-applicable" \
	"not-applicable" "$(ct_run nopolicy '[]' 0 clean no)"

# --- #102 TERRASCAN: unsupported provider ----------------------------------------
ts_run() { # ts_run <case> <payload> <exit> <mode>
	_t_d="$TMP/terrascan-$1"; _t_p=$(sf_project "$_t_d")
	sf_make "$_t_d" terrascan stdout "${4:-clean}" "$2" "$3" >/dev/null
	sf_run "$_t_p" "$_t_d/bin" "$AD/terrascan.sh" reports/raw/terrascan.json || :
	sf_state "$_t_p" reports/raw/terrascan.json
}
assert_equal "terrascan-unsupported: a scan that evaluated no file is not-applicable" \
	"not-applicable" "$(ts_run none '{"results":{"violations":[],"scan_summary":{}}}' 0)"
assert_equal "terrascan-clean: a supported provider with no violations is clean" \
	"completed-clean" "$(ts_run clean '{"results":{"violations":[],"scan_summary":{"file/folder":"."}}}' 0)"
assert_equal "terrascan-findings: violations reach findings" \
	"completed-findings" "$(ts_run find '{"results":{"violations":[{"rule_id":"AC_1"}],"scan_summary":{"file/folder":"."}}}' 3 findings)"
assert_equal "terrascan-operational: a parser failure is an error, NOT not-applicable" \
	"execution-error" "$(ts_run fail '' 0 fail)"

# --- #101 TRUFFLEHOG: NDJSON stream semantics ------------------------------------
th_run() { # th_run <case> <payload> <exit> <mode>
	_h_d="$TMP/trufflehog-$1"; _h_p=$(sf_project "$_h_d")
	sf_make "$_h_d" trufflehog stdout "${4:-clean}" "$2" "$3" >/dev/null
	sf_run "$_h_p" "$_h_d/bin" "$AD/trufflehog.sh" reports/raw/trufflehog.json || :
	sf_state "$_h_p" reports/raw/trufflehog.json
}
TH1='{"DetectorName":"AWS","Verified":false,"SourceMetadata":{"Data":{"Filesystem":{"file":"a"}}}}'
TH2='{"DetectorName":"GCP","Verified":true,"SourceMetadata":{"Data":{"Filesystem":{"file":"b"}}}}'
assert_equal "trufflehog-empty-stream: no records is a clean scan" \
	"completed-clean" "$(th_run empty '' 0)"
assert_equal "trufflehog-valid-stream: a complete multi-record stream is accepted as findings" \
	"completed-findings" "$(th_run valid "$TH1
$TH2" 183 findings)"
assert_equal "trufflehog-truncated: a truncated final record is rejected, not read as fewer findings" \
	"execution-error" "$(th_run trunc "$TH1
{\"DetectorName\":\"AWS\",\"Verif" 183 findings)"
assert_equal "trufflehog-mid-corrupt: a malformed intermediate record is rejected" \
	"execution-error" "$(th_run midbad "$TH1
not-json
$TH2" 183 findings)"
assert_equal "trufflehog-forged-scalar: a bare scalar that parses as JSON is not a finding object" \
	"execution-error" "$(th_run scalar '"just-a-string"' 183 findings)"

# --- #100 SCORECARD: repository identity -----------------------------------------
sc_run() { # sc_run <case> <payload> <requested-repo>
	_s_d="$TMP/scorecard-$1"; _s_p=$(sf_project "$_s_d")
	sf_make "$_s_d" scorecard stdout clean "$2" 0 >/dev/null
	sf_run "$_s_p" "$_s_d/bin" "$AD/scorecard.sh" reports/raw/scorecard.json \
		"SENTINEL_SHIELD_SCORECARD_REPO=$3" || :
	sf_state "$_s_p" reports/raw/scorecard.json
}
SC_OK='{"repo":{"name":"github.com/o/r"},"score":9,"checks":[{"name":"Pinned-Dependencies","score":10}]}'
SC_OTHER='{"repo":{"name":"github.com/evil/other"},"score":9,"checks":[{"name":"Pinned-Dependencies","score":10}]}'
SC_NOID='{"score":9,"checks":[{"name":"Pinned-Dependencies","score":10}]}'
assert_equal "scorecard-identity CONTROL: a report for the requested repository is accepted" \
	"completed-clean" "$(sc_run match "$SC_OK" github.com/o/r)"
assert_equal "scorecard-identity: a valid report describing ANOTHER repository is refused" \
	"execution-error" "$(sc_run other "$SC_OTHER" github.com/o/r)"
assert_equal "scorecard-identity: a report with no repository identity is refused" \
	"execution-error" "$(sc_run noid "$SC_NOID" github.com/o/r)"
assert_equal "scorecard-findings: a low check score is a finding, not an error" \
	"completed-findings" "$(sc_run low '{"repo":{"name":"github.com/o/r"},"score":2,"checks":[{"name":"Pinned-Dependencies","score":1}]}' github.com/o/r)"

# No adapter left a workspace behind across any of the groups above.
_l3_temp=$(find "$TMP" -name '.ss-tmp.*' 2>/dev/null | wc -l | tr -d ' ')
assert_equal "no Layer 3 case left an owned workspace behind" "0" "$_l3_temp"

assert_summary "scanner-semantics (Layer 3: tool meaning and collector conclusions)"
