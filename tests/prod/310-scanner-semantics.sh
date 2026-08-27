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
# ne_sha256 is a SHELL FUNCTION, so `find -exec ne_sha256` never resolves it, and `ne_sha256
# /dev/stdin` is not a regular file — both sides of this comparison were the empty string, and the
# assertion could not have detected a write. Digests are computed by a real hasher over a sorted
# file list, through a temporary file rather than a pipe.
ft_digest() { # ft_digest <dir> -> one digest over every file's path+content
	find "$1" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 \
		sh -c 'for f do { command -v sha256sum >/dev/null 2>&1 && sha256sum "$f" || shasum -a 256 "$f"; } 2>/dev/null; done' sh \
		> "$TMP/ft.list" 2>/dev/null || : 
	{ command -v sha256sum >/dev/null 2>&1 && sha256sum "$TMP/ft.list" || shasum -a 256 "$TMP/ft.list"; } 2>/dev/null | awk '{print $1}'
}
_before=$(ft_digest "$ROOT/tests/e2e")
sh "$GEN" --check >/dev/null 2>&1 || :
_after=$(ft_digest "$ROOT/tests/e2e")
assert_false "fixture-tree digest is actually computed, not an empty string" test -z "$_before"
assert_equal "--check leaves the fixture tree byte-identical" "$_before" "$_after"
# MUTATION CONTROL: the digest must CHANGE when a fixture changes, otherwise the assertion above
# would hold for any implementation that returns a constant.
_ft_probe="$ROOT/tests/e2e/.ft-mutation-probe"
printf 'mutation\n' > "$_ft_probe"
_mutated=$(ft_digest "$ROOT/tests/e2e")
rm -f "$_ft_probe"
assert_false "MUTATION: changing a fixture changes the tree digest" test "$_before" = "$_mutated"
assert_equal "MUTATION: removing the probe restores the original digest" "$_before" "$(ft_digest "$ROOT/tests/e2e")"

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
SYFT_OK='{"dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","documentNamespace":"https://sentinel-shield.invalid/spdx/t","spdxVersion":"SPDX-2.3","name":"subject-a","creationInfo":{"created":"2026-01-01T00:00:00Z"},"packages":[]}'
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
SYFT_POP='{"dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","documentNamespace":"https://sentinel-shield.invalid/spdx/t","spdxVersion":"SPDX-2.3","name":"subject-a","creationInfo":{"created":"2026-01-01T00:00:00Z"},"packages":[{"name":"p"},{"name":"q"}]}'
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
# The distinction lives in HEALTH, not in the top-level status. This assertion originally pinned
# the status to "no-targets", and the collector was shaped to match it — but that token is outside
# the vocabulary build-security-summary.sh consumes, so it fell through the builder's default arm
# and a scan that correctly found nothing to scan was recorded as execution-error. Health carries
# the distinction; the status stays consumable.
_o_nt=$(collect osv-scanner "$SB/report.json")
assert_equal "no-targets is its own outcome, not clean" "no-targets" "$(health "$_o_nt")"
assert_equal "no-targets reports a status the summary builder can consume" "pass" "$(st_of "$_o_nt")"
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
# A REAL 64-hex digest. 'sha256:abc123' is six characters and is now refused as malformed before
# docker is reached — correctly, so the control needs a digest that actually is one.
_gy_legit=$(gy_run "registry.example/img@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd")
assert_true "grype-injection CONTROL: the docker boundary was reached for a digest-pinned image" \
	test -f "$GD/argv"
assert_true "grype-injection CONTROL: the image survived as a single argument" \
	grep -qxF 'registry.example/img@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' "$GD/argv"
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

# ===========================================================================
# #136-AC5 TOTAL SOURCE ITEMS = CLASSIFIED + INTENTIONALLY IGNORED LOW/INFO
#
# The extraction reads CRITICAL/HIGH/MEDIUM, FAIL misconfigurations and secrets. Everything else
# it simply does not match, and an unmatched item leaves no trace: the gate sees the same "0" it
# would see for a genuinely clean scan.
#
# Ignoring low/info is a policy decision and is preserved. What the invariant forbids is an item
# that is NEITHER classified NOR intentionally ignored -- a severity the vocabulary does not
# cover, or a vulnerability with no Severity field at all. Those now fail closed.
# ===========================================================================
tv_seed() { seed trivy-fs "$1" filesystem; collect trivy "$SB/report.json"; }

# CONTROL: a report whose items all reconcile is accepted and gates on the classified ones.
TV_MIX='{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[{"Target":"go.mod","Vulnerabilities":[
	{"VulnerabilityID":"A","Severity":"CRITICAL"},{"VulnerabilityID":"B","Severity":"HIGH"},
	{"VulnerabilityID":"C","Severity":"MEDIUM"},{"VulnerabilityID":"D","Severity":"LOW"},
	{"VulnerabilityID":"E","Severity":"UNKNOWN"}]}]}'
_tv_out=$(tv_seed "$TV_MIX")
assert_equal "reconcile CONTROL: a fully accounted report is accepted" "fail" "$(st_of "$_tv_out")"
assert_equal "reconcile CONTROL: the three gating severities are classified" "1" "$(field "$_tv_out" critical)"
assert_equal "reconcile CONTROL: five source items are recorded" "5" "$(field "$_tv_out" source_items)"

# THE IGNORED SET IS REPORTED, NOT SILENT. "0 findings" and "0 gating findings plus 2 low/info we
# chose not to gate" are different statements, and only one of them is what the scan found.
assert_equal "reconcile: intentionally ignored low/info items are reported, not dropped" \
	"2" "$(field "$_tv_out" low_info_ignored)"
_tv_low=$(tv_seed '{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[{"Target":"go.mod","Vulnerabilities":[{"VulnerabilityID":"L","Severity":"LOW"}]}]}')
assert_equal "reconcile: a low-only report still passes the gate" "pass" "$(st_of "$_tv_low")"
assert_equal "reconcile: a low-only report reports the item it did not gate" "1" "$(field "$_tv_low" low_info_ignored)"

# THE HOLE THE INVARIANT EXISTS TO CATCH: an item that is neither classified nor ignored.
# A vulnerability with NO Severity field is read as `empty` by the overlay and vanishes entirely.
# Before the invariant this returned a clean pass.
assert_equal "reconcile: a vulnerability with no Severity is unaccounted and fails closed" \
	"execution-error" "$(st_of "$(tv_seed '{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[{"Target":"go.mod","Vulnerabilities":[{"VulnerabilityID":"X"}]}]}')")"
assert_equal "reconcile: an unaccounted item fails closed even alongside classified findings" \
	"execution-error" "$(st_of "$(tv_seed '{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[{"Target":"go.mod","Vulnerabilities":[{"VulnerabilityID":"A","Severity":"CRITICAL"},{"VulnerabilityID":"X"}]}]}')")"

# MISCONFIGURATIONS: only FAIL is classified, so the other statuses must be accounted as ignored
# rather than silently discarded.
_tv_mis=$(tv_seed '{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[{"Target":"Dockerfile","Misconfigurations":[
	{"ID":"DS001","Status":"FAIL"},{"ID":"DS002","Status":"PASS"},{"ID":"DS003","Status":"EXCEPTION"}]}]}')
assert_equal "reconcile: a FAIL misconfiguration gates" "fail" "$(st_of "$_tv_mis")"
assert_equal "reconcile: only the FAIL misconfiguration is classified" "1" "$(field "$_tv_mis" iac_violations)"
assert_equal "reconcile: non-FAIL misconfigurations are accounted, not discarded" "2" "$(field "$_tv_mis" low_info_ignored)"
assert_equal "reconcile: all three misconfigurations are counted as source items" "3" "$(field "$_tv_mis" source_items)"

# An empty report reconciles trivially and must stay a clean pass -- the invariant must not turn
# "nothing to classify" into a failure.
_tv_empty=$(tv_seed "$TRIVY_OK")
assert_equal "reconcile: an empty report reconciles and stays a pass" "pass" "$(st_of "$_tv_empty")"
assert_equal "reconcile: an empty report reports zero source items" "0" "$(field "$_tv_empty" source_items)"

# ===========================================================================
# #103-AC4 THE SCANNER CONTAINER IS DIGEST-PINNED FOR GATED USE
#
# A mutable tag names different bytes tomorrow, so evidence produced by an unpinned scanner
# cannot support a gated verdict. This was previously a log warning, which satisfies nobody:
# the run continued and the verdict was published anyway.
#
# The criterion scopes enforcement to GATED USE, so these cases prove BOTH directions -- the
# gated modes (strict, regulated) refuse, and the non-gated modes (report-only, baseline) warn
# and still produce evidence. Enforcing everywhere would be easier and would fail the criterion
# as written. Reference forms the criterion permits -- registry ports, repository paths -- must
# keep working, so a pinned control is asserted to reach 'completed-clean' rather than merely to
# avoid the gate; a control that only proves "not rejected" would also pass if the scanner never
# ran at all.
# ===========================================================================
dp_run() { # dp_run <case> <mode> <scanner-image>
	_dp_d="$TMP/digestpin-$1"; _dp_p=$(sf_project "$_dp_d"); mkdir -p "$_dp_d/bin"
	# The scanner runs as a container, so the stub emulates the bind mount and writes the report
	# where -v HOSTDIR:/ssreport actually points. A stub that only exits 0 would make every case
	# fail identically and prove nothing.
	cat > "$_dp_d/bin/docker" <<'DPSTUB'
#!/bin/sh
host=""
while [ "$#" -gt 0 ]; do
	case "$1" in -v) case "$2" in *:/ssreport) host="${2%:/ssreport}" ;; esac; shift ;; esac
	shift
done
[ -n "$host" ] && printf %s '{"summary":{"fatal":0,"warn":0,"info":0,"pass":3},"details":[]}' > "$host/report.json"
exit 0
DPSTUB
	chmod +x "$_dp_d/bin/docker"
	sf_run "$_dp_p" "$_dp_d/bin" "$AD/dockle.sh" reports/raw/dockle.json \
		"SENTINEL_SHIELD_IMAGE=app@sha256:bbb" \
		"SENTINEL_SHIELD_DOCKLE_IMAGE=$3" "SENTINEL_SHIELD_MODE=$2" || :
	sf_state "$_dp_p" reports/raw/dockle.json
}
DP_A="reg.example:5000/ns/dockle@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DP_B="docker.io/aquasec/dockle@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# CONTROL: a pinned scanner produces evidence in the strictest mode. Registry PORTS and
# repository PATHS are valid pinned references and must not be collateral damage.
assert_equal "digest-pin CONTROL: a digest-pinned scanner with a registry port scans in regulated mode" \
	"completed-clean" "$(dp_run pinned-port regulated "$DP_A")"
assert_equal "digest-pin CONTROL: a digest-pinned scanner with a repository path scans in strict mode" \
	"completed-clean" "$(dp_run pinned-path strict "$DP_B")"

# GATED USE: the criterion's actual subject.
assert_equal "digest-pin: a mutable tag is REFUSED in strict mode" \
	"execution-error" "$(dp_run tag-strict strict aquasec/dockle:latest)"
assert_equal "digest-pin: a mutable tag is REFUSED in regulated mode" \
	"execution-error" "$(dp_run tag-regulated regulated aquasec/dockle:v0.4.14)"

# NON-GATED USE: the criterion says "for gated use", so these warn and still scan.
assert_equal "digest-pin: a mutable tag WARNS and still produces evidence in baseline mode" \
	"completed-clean" "$(dp_run tag-baseline baseline aquasec/dockle:latest)"
assert_equal "digest-pin: a mutable tag WARNS and still produces evidence in report-only mode" \
	"completed-clean" "$(dp_run tag-report report-only aquasec/dockle:latest)"

# A digest reference must carry a real digest; '@sha256:' is a shape, not a pin.
assert_equal "digest-pin: an empty digest is malformed, not pinned" \
	"execution-error" "$(dp_run empty-digest regulated 'img@sha256:')"
assert_equal "digest-pin: a truncated digest is malformed, not pinned" \
	"execution-error" "$(dp_run short-digest regulated 'img@sha256:abc123')"
assert_equal "digest-pin: a 64-character non-hex digest is malformed, not pinned" \
	"execution-error" "$(dp_run nonhex-digest regulated 'img@sha256:zzzzaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')"

# A WARN IS NOT A BYPASS: the non-gated modes downgrade the PIN requirement only. An injected
# argument is refused in every mode, because "warn" must never become a path to docker run.
assert_equal "digest-pin: an option-injection scanner reference is refused in baseline mode" \
	"execution-error" "$(dp_run inject-baseline baseline -- '--privileged evil')"
assert_equal "digest-pin: argument smuggling after a tag is refused in report-only mode" \
	"execution-error" "$(dp_run smuggle-report report-only 'img:tag --rm -v /:/hostfs')"
assert_equal "digest-pin: argument smuggling after a valid digest is refused in regulated mode" \
	"execution-error" "$(dp_run smuggle-regulated regulated "$DP_A --rm -v /:/hostfs")"

# An unrecognised mode is a configuration error, never a silent downgrade to the most
# permissive behaviour -- the engine's existing rule, applied here rather than reinvented.
assert_equal "digest-pin: an unknown SENTINEL_SHIELD_MODE is a configuration error" \
	"execution-error" "$(dp_run unknown-mode nonsense-mode "$DP_A")"

# ===========================================================================
# #137-AC5 DATABASE METADATA FOLLOWS A DOCUMENTED FAIL/WARN POLICY BY MODE
#
# "No matches" from a scanner whose vulnerability database is absent, unreadable or a year old is
# not a clean result -- it is an unanswered question wearing a clean result's clothes. The build
# timestamp was recorded in provenance and otherwise ignored, so all five conditions produced an
# unqualified pass.
#
# The criterion names five conditions and asks for a policy BY MODE, so both halves are proven:
# every condition fails closed in a gated mode, and every condition still reports in a non-gated
# one. Asserting only the failures would pass a build that simply refused everything.
# ===========================================================================
gdb_run() { # gdb_run <descriptor-db-fragment> <mode> [env-assignment]
	printf '%s' "{\"matches\":[],\"source\":{\"type\":\"directory\",\"target\":\".\"},\"descriptor\":{\"name\":\"grype\",\"version\":\"1\"$1}}" > "$SB/report.json"
	prov "$SB/report.json" "grype" "completed-clean" "dir" ""
	( [ -n "${3:-}" ] && export "${3?}"
	  SENTINEL_SHIELD_MODE="$2"; export SENTINEL_SHIELD_MODE
	  sh "$ROOT/scripts/collectors/grype.sh" --input "$SB/report.json" 2>/dev/null ) | jq -r '.status // "-"'
}
gdb_db() { printf ',"db":{"built":"%sT00:00:00Z"}' "$1"; }
GDB_TODAY=$(date -u +%Y-%m-%d)
GDB_OLD=$(date -u -v-400d +%Y-%m-%d 2>/dev/null || date -u -d '400 days ago' +%Y-%m-%d)
GDB_FUTURE=$(date -u -v+30d +%Y-%m-%d 2>/dev/null || date -u -d '+30 days' +%Y-%m-%d)
GDB_3DAY=$(date -u -v-3d +%Y-%m-%d 2>/dev/null || date -u -d '3 days ago' +%Y-%m-%d)

# CONTROL: a current database scans normally in every mode, including the strictest. Without this
# the group would also pass if the collector had simply started refusing every report.
assert_equal "db-policy CONTROL: a current database scans in regulated mode" \
	"pass" "$(gdb_run "$(gdb_db "$GDB_TODAY")" regulated)"
assert_equal "db-policy CONTROL: a current database scans in report-only mode" \
	"pass" "$(gdb_run "$(gdb_db "$GDB_TODAY")" report-only)"

# All five conditions the criterion enumerates, failing closed where the verdict gates a release.
assert_equal "db-policy: MISSING database metadata fails closed in a gated mode" \
	"execution-error" "$(gdb_run "" strict)"
assert_equal "db-policy: MALFORMED database metadata fails closed in a gated mode" \
	"execution-error" "$(gdb_run ',"db":{"built":"not-a-date"}' strict)"
assert_equal "db-policy: an impossible calendar date is malformed, not merely old" \
	"execution-error" "$(gdb_run "$(gdb_db 2026-02-31)" strict)"
assert_equal "db-policy: a FUTURE-DATED database fails closed in a gated mode" \
	"execution-error" "$(gdb_run "$(gdb_db "$GDB_FUTURE")" strict)"
assert_equal "db-policy: an EXPIRED database fails closed in a gated mode" \
	"execution-error" "$(gdb_run "$(gdb_db "$GDB_OLD")" regulated)"

# The same five conditions WARN rather than fail where the mode does not gate a release. This is
# the half of the criterion that "fail on everything" would get wrong.
assert_equal "db-policy: MISSING metadata warns and still reports in baseline mode" \
	"pass" "$(gdb_run "" baseline)"
assert_equal "db-policy: MALFORMED metadata warns and still reports in report-only mode" \
	"pass" "$(gdb_run ',"db":{"built":"not-a-date"}' report-only)"
assert_equal "db-policy: an EXPIRED database warns and still reports in baseline mode" \
	"pass" "$(gdb_run "$(gdb_db "$GDB_OLD")" baseline)"

# A warn that is silent is not a warn. The non-gated path must SAY the evidence is not
# gate-quality, otherwise the operator has no way to learn the database was stale.
_gdb_warn=$( ( SENTINEL_SHIELD_MODE=baseline; export SENTINEL_SHIELD_MODE
	printf '%s' "{\"matches\":[],\"source\":{\"type\":\"directory\",\"target\":\".\"},\"descriptor\":{\"name\":\"grype\",\"version\":\"1\"$(gdb_db "$GDB_OLD")}}" > "$SB/report.json"
	prov "$SB/report.json" "grype" "completed-clean" "dir" ""
	sh "$ROOT/scripts/collectors/grype.sh" --input "$SB/report.json" 2>&1 >/dev/null ) | grep -c 'database is expired' || true)
assert_true "db-policy: the non-gated path actually warns about the stale database" test "$_gdb_warn" -ge 1

# regulated tightens the threshold, exactly as the waiver ceiling does. A database that is
# acceptable under strict can be too old for regulated.
assert_equal "db-policy: a 3-day-old database is acceptable under strict" \
	"pass" "$(gdb_run "$(gdb_db "$GDB_3DAY")" strict)"
assert_equal "db-policy: the same database is too old under regulated" \
	"execution-error" "$(gdb_run "$(gdb_db "$GDB_3DAY")" regulated)"

# The threshold is operator-controllable, so the policy is a policy and not a hardcoded verdict.
assert_equal "db-policy: an explicit threshold lets an operator accept an older database" \
	"pass" "$(gdb_run "$(gdb_db "$GDB_OLD")" regulated SENTINEL_SHIELD_GRYPE_DB_MAX_AGE_DAYS=500)"
# ...but a SET-BUT-EMPTY value is a configuration error rather than a silent fallback to the
# default, which is the same distinction the waiver library goes out of its way to preserve.
assert_equal "db-policy: a set-but-empty threshold is a configuration error, not a default" \
	"execution-error" "$(gdb_run "$(gdb_db "$GDB_TODAY")" baseline SENTINEL_SHIELD_GRYPE_DB_MAX_AGE_DAYS=)"
assert_equal "db-policy: a non-numeric threshold is a configuration error" \
	"execution-error" "$(gdb_run "$(gdb_db "$GDB_TODAY")" baseline SENTINEL_SHIELD_GRYPE_DB_MAX_AGE_DAYS=soon)"
assert_equal "db-policy: an unknown adoption mode is a configuration error" \
	"execution-error" "$(gdb_run "$(gdb_db "$GDB_TODAY")" nonsense-mode)"

# ===========================================================================
# FILE-INPUT COLLECTORS ARE UNAFFECTED BY AN INHERITED OPEN STDIN
#
# This group exists because of a WRONG diagnosis, and encodes the property that diagnosis was
# missing. All four binding collectors were reported as having an indefinite-hang path on an
# inherited stdin. They do not. The reproduction was `sleep N | collector`, and a shell waits for
# every member of a pipeline -- the construct hung on the sleep long after the collector had
# exited. The corroborating evidence was a suite watchdog set below the suite's real runtime.
#
# The collectors are file-input-only: no `--input -`, no stdin read, no stdin mode. That is worth
# holding still, because a helper or subprocess added later could quietly acquire a blocking read
# and the symptom would be a CI job that never finishes.
#
# Stdin is held open here by a FIFO whose writer is detached, so nothing but the collector itself
# can delay completion, and each run carries its own bound so a real regression FAILS rather than
# hanging the suite.
# ===========================================================================
SIO_BOUND=15
sio_run() { # sio_run <collector-path> <report> <open|closed> -> output, or the literal TIMEOUT
	_sio_o="$SB/sio.out"; : > "$_sio_o"; _sio_w=""
	if [ "$3" = open ]; then
		_sio_f="$SB/sio.fifo"; rm -f "$_sio_f"; mkfifo "$_sio_f"
		( sleep 60 > "$_sio_f" ) & _sio_w=$!
		( sh "$1" --input "$2" >"$_sio_o" 2>/dev/null <"$_sio_f" ) & _sio_b=$!
	else
		( sh "$1" --input "$2" >"$_sio_o" 2>/dev/null </dev/null ) & _sio_b=$!
	fi
	_sio_i=0
	while [ "$_sio_i" -lt "$SIO_BOUND" ] && kill -0 "$_sio_b" 2>/dev/null; do
		sleep 1; _sio_i=$((_sio_i + 1))
	done
	if kill -0 "$_sio_b" 2>/dev/null; then kill "$_sio_b" 2>/dev/null; printf 'TIMEOUT'
	else cat "$_sio_o"; fi
	[ -n "$_sio_w" ] && kill "$_sio_w" 2>/dev/null
	return 0
}

# Each collector gets valid, correctly bound evidence so the assertion is about stdin and nothing
# else -- a collector that refused the report would "complete" too.
SIO_DIR="$SB/stdin-cases"; mkdir -p "$SIO_DIR"
printf '%s' "$SYFT_OK" > "$SIO_DIR/syft.json"; prov "$SIO_DIR/syft.json" syft completed-clean dir "subject-a"
printf '%s' "$TRIVY_OK" > "$SIO_DIR/trivy-fs.json"; prov "$SIO_DIR/trivy-fs.json" trivy-fs completed-clean filesystem "subject-a"
printf '%s' '{"matches":[],"source":{"type":"directory","target":"."},"descriptor":{"name":"grype","version":"1","db":{"built":"'"$(date -u +%Y-%m-%d)"'T00:00:00Z"}}}' > "$SIO_DIR/grype.json"
prov "$SIO_DIR/grype.json" grype completed-clean dir ""
printf '%s' '{"results":[{"source":{"path":"go.mod"},"packages":[]}]}' > "$SIO_DIR/osv.json"
prov "$SIO_DIR/osv.json" osv-scanner completed-clean dir ""

for _sio_c in syft:syft.json trivy:trivy-fs.json grype:grype.json osv-scanner:osv.json; do
	_sio_n=${_sio_c%%:*}; _sio_r="$SIO_DIR/${_sio_c##*:}"
	_sio_open=$(sio_run "$ROOT/scripts/collectors/$_sio_n.sh" "$_sio_r" open)
	_sio_closed=$(sio_run "$ROOT/scripts/collectors/$_sio_n.sh" "$_sio_r" closed)
	# Completes at all, within its own bound rather than because something killed it.
	assert_false "$_sio_n completes with an inherited open stdin" test "$_sio_open" = TIMEOUT
	# The evidence verdict is unchanged, so this is not "it exits early by refusing the report".
	assert_equal "$_sio_n still accepts valid bound evidence with stdin open" \
		"pass" "$(st_of "$_sio_open")"
	# Byte-identical: stdin shape must not reach the serialized output or the diagnostics.
	assert_equal "$_sio_n produces identical output with stdin open and closed" \
		"$_sio_closed" "$_sio_open"
	# It must not swallow input intended for the next reader either.
	assert_equal "$_sio_n does not consume inherited stdin" "keep-me" \
		"$(printf 'keep-me\n' | sh -c "sh '$ROOT/scripts/collectors/$_sio_n.sh' --input '$_sio_r' >/dev/null 2>&1; cat")"
done

# Invalid evidence must still be refused with stdin open — the property is "stdin is ignored",
# not "everything passes".
printf '%s' '{}' > "$SIO_DIR/bad.json"; prov "$SIO_DIR/bad.json" syft completed-clean dir "subject-a"
assert_equal "an invalid report is still refused with an inherited open stdin" \
	"execution-error" "$(st_of "$(sio_run "$ROOT/scripts/collectors/syft.sh" "$SIO_DIR/bad.json" open)")"

# MUTATION CONTROL: a collector that DOES acquire a blocking read must make this group fail.
# Without this the four assertions above would also pass if sio_run silently never blocked.
sed '2i\
cat >/dev/null
' "$ROOT/scripts/collectors/trivy.sh" > "$SIO_DIR/blocking-trivy.sh"
assert_equal "MUTATION: a collector that reads stdin is caught by this group, not hidden by it" \
	"TIMEOUT" "$(sio_run "$SIO_DIR/blocking-trivy.sh" "$SIO_DIR/trivy-fs.json" open)"

# ===========================================================================
# THE PROVENANCE TEST HELPER IS NOT A BACK DOOR
#
# tests/lib/collector-provenance.sh exists so suites about severity mapping or fail-closed
# arithmetic can satisfy the absolute binding instead of tripping over it. A helper that hands out
# valid-looking provenance is exactly the shape of the exemption this batch refused to add, so it
# is audited rather than trusted.
# ===========================================================================
CPH="$ROOT/tests/lib/collector-provenance.sh"
CPD="$SB/helper-audit"; mkdir -p "$CPD"

# 1. The digest is DERIVED from the report, never accepted as a stated fact. Two different reports
#    must therefore never carry the same digest, and no parameter may inject one.
printf '%s' "$SYFT_OK" > "$CPD/a.json"
printf '%s' '{"dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","documentNamespace":"https://sentinel-shield.invalid/spdx/t","spdxVersion":"SPDX-2.3","name":"subject-a","creationInfo":{"created":"2026-01-01T00:00:00Z"},"packages":[{"name":"other"}]}' > "$CPD/b.json"
( . "$ROOT/scripts/lib/normalized-evidence.sh"; . "$CPH"; cp_write "$CPD/a.json" syft.sh; cp_write "$CPD/b.json" syft.sh )
_cp_da=$(jq -r '.report.sha256' "$CPD/a.provenance.json")
_cp_db=$(jq -r '.report.sha256' "$CPD/b.provenance.json")
assert_equal "helper: the recorded digest is the report's own digest" \
	"$(ne_sha256 "$CPD/a.json")" "$_cp_da"
assert_false "helper: two different reports cannot share a digest" test "$_cp_da" = "$_cp_db"
assert_false "helper: no parameter accepts a caller-supplied digest" \
	grep -qE 'sha256=|--digest|_cp_dig=\$[1-9]' "$CPH"

# 2. It produces the binding shape PRODUCTION consumes — every field ce_bind reads is present.
for _cp_f in .contract .tool .report.sha256 .completion.state .target.mode; do
	assert_false "helper: provenance carries $_cp_f" \
		test "$(jq -r "$_cp_f // \"\"" "$CPD/a.provenance.json")" = ""
done

# 3. It cannot make an INVALID native report valid. The binding and the tool validator are
#    separate gates, and the helper only ever satisfies the first.
printf '%s' '{}' > "$CPD/empty.json"
( . "$ROOT/scripts/lib/normalized-evidence.sh"; . "$CPH"; cp_write "$CPD/empty.json" syft.sh )
assert_equal "helper: a perfectly bound empty object is still not an SBOM" \
	"execution-error" "$(st_of "$(collect syft "$CPD/empty.json")")"

# 4. It grants no fixture exemption — the same assertion made of ce_bind itself.
assert_false "helper: contains no fixture-exemption vocabulary" \
	grep -qE 'ne_fixture_allowed|NE_KIND|non_production' "$CPH"

# 5. Provenance is bound to the report AS IT WAS. A report edited afterwards must stop verifying,
#    otherwise the helper would let a suite mutate evidence under its own attestation.
printf '%s' "$SYFT_OK" > "$CPD/drift.json"
( . "$ROOT/scripts/lib/normalized-evidence.sh"; . "$CPH"; cp_write "$CPD/drift.json" syft.sh )
assert_equal "helper CONTROL: the freshly generated pairing verifies" \
	"pass" "$(st_of "$(collect syft "$CPD/drift.json")")"
printf '%s' '{"dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","documentNamespace":"https://sentinel-shield.invalid/spdx/t","spdxVersion":"SPDX-2.3","name":"subject-a","creationInfo":{"created":"2026-01-01T00:00:00Z"},"packages":[{"name":"injected"}]}' > "$CPD/drift.json"
assert_equal "helper: a report edited after generation no longer verifies" \
	"execution-error" "$(st_of "$(collect syft "$CPD/drift.json")")"

# ===========================================================================
# CLUSTER D — THE INPUT SHAPES THE CRITERIA NAME AND THE SUITES DID NOT EXERCISE
# ===========================================================================

# --- #102-AC7 TERRASCAN: input kinds beyond Terraform ----------------------------
# The criterion names Kubernetes and Compose inputs explicitly. Only Terraform providers were
# exercised, so "an IaC kind terrascan supports" was an assumption rather than a measurement.
assert_equal "terrascan-kubernetes: a scanned Kubernetes manifest with no violations is clean" \
	"completed-clean" "$(ts_run k8s '{"results":{"violations":[],"scan_summary":{"file/folder":"deploy.yaml","iac_type":"k8s"}}}' 0)"
assert_equal "terrascan-kubernetes: violations in a Kubernetes manifest reach findings" \
	"completed-findings" "$(ts_run k8sfind '{"results":{"violations":[{"rule_id":"AC_K8S_1","category":"Kubernetes"}],"scan_summary":{"file/folder":"deploy.yaml","iac_type":"k8s"}}}' 3 findings)"
assert_equal "terrascan-compose: a scanned Compose file with no violations is clean" \
	"completed-clean" "$(ts_run compose '{"results":{"violations":[],"scan_summary":{"file/folder":"docker-compose.yml","iac_type":"docker"}}}' 0)"
assert_equal "terrascan-compose: violations in a Compose file reach findings" \
	"completed-findings" "$(ts_run composefind '{"results":{"violations":[{"rule_id":"AC_DOCKER_1","category":"Docker"}],"scan_summary":{"file/folder":"docker-compose.yml","iac_type":"docker"}}}' 3 findings)"

# --- #135-AC2/AC6 SYFT: the document must be the schema it claims -----------------
# `{}` was already refused. A document that is well-formed but a DIFFERENT schema is the subtler
# case: CycloneDX is a real SBOM, just not the one this contract reads, and silently accepting it
# would report an inventory nobody produced.
SYFT_CDX='{"bomFormat":"CycloneDX","specVersion":"1.5","components":[{"name":"p"},{"name":"q"}]}'
seed syft "$SYFT_CDX"
assert_equal "syft-schema: a CycloneDX document does not satisfy the SPDX contract" \
	"execution-error" "$(st_of "$(collect syft "$SB/report.json")")"
seed syft '{"dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","documentNamespace":"https://sentinel-shield.invalid/spdx/t","spdxVersion":"SPDX-2.3","packages":[{"name":"p"}]}'
assert_equal "syft-schema: an SPDX document missing its creation info is incomplete, not empty" \
	"execution-error" "$(st_of "$(collect syft "$SB/report.json")")"
seed syft "$SYFT_OK"
assert_equal "syft-schema CONTROL: a complete SPDX document is still accepted" \
	"pass" "$(st_of "$(collect syft "$SB/report.json")")"

# --- #136-AC3/AC4/AC6 TRIVY: case, partial scans and future versions ---------------
# AC3 asks for case-SAFE normalization of documented values. The extraction upper-cases severities,
# so lowercase must map identically rather than fall into the unclassified hole.
_tv_lower=$(tv_seed '{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[{"Target":"go.mod","Vulnerabilities":[{"VulnerabilityID":"A","Severity":"critical"},{"VulnerabilityID":"B","Severity":"low"}]}]}')
assert_equal "trivy-case: a lowercase CRITICAL is classified, not unclassified" "1" "$(field "$_tv_lower" critical)"
assert_equal "trivy-case: a lowercase LOW is intentionally ignored, not unclassified" "1" "$(field "$_tv_lower" low_info_ignored)"
assert_equal "trivy-case: the lowercase report reconciles and gates on the critical" "fail" "$(st_of "$_tv_lower")"
# An UNDOCUMENTED misconfiguration status must still fail closed — case-safety is not permission
# to accept anything.
assert_equal "trivy-case: an unknown misconfiguration status still fails closed" \
	"execution-error" "$(st_of "$(tv_seed '{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[{"Target":"Dockerfile","Misconfigurations":[{"ID":"D1","Status":"MAYBE"}]}]}')")"
# AC4: a report that records its own failure is not a clean scan, however well-formed it is.
assert_equal "trivy-partial: a result-level scan error prevents a clean pass" \
	"execution-error" "$(st_of "$(tv_seed '{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[{"Target":"go.mod","Vulnerabilities":[]}],"Error":"scan aborted"}')")"
# AC6: a future schema version is not something this collector may silently reinterpret.
assert_equal "trivy-future: an unrecognised future SchemaVersion fails closed" \
	"execution-error" "$(st_of "$(tv_seed '{"SchemaVersion":99,"ArtifactName":"subject-a","Results":[{"Target":"go.mod","Vulnerabilities":[{"VulnerabilityID":"A","Severity":"CRITICAL"}]}]}')")"

# --- #137-AC6 GRYPE: an unknown descriptor version --------------------------------
GRYPE_NOVER='{"matches":[],"source":{"type":"directory","target":"."},"descriptor":{"name":"grype","db":{"built":"2026-01-01T00:00:00Z"}}}'
seed grype "$GRYPE_NOVER"
assert_equal "grype-descriptor: a report with no scanner version cannot be a clean gated result" \
	"execution-error" "$(st_of "$(collect grype "$SB/report.json")")"

# --- #184-AC6 OSV: evidence about a different target ------------------------------
printf '%s' '{"results":[{"source":{"path":"go.mod"},"packages":[]}]}' > "$SB/report.json"
prov "$SB/report.json" "osv-scanner" "completed-clean" "lockfile" "subject-a"
assert_equal "osv-target CONTROL: evidence for the requested subject is accepted" \
	"pass" "$(st_of "$(collect osv-scanner "$SB/report.json" "SENTINEL_SHIELD_OSV_SUBJECT=subject-a")")"
assert_equal "osv-target: evidence describing ANOTHER subject is refused" \
	"execution-error" "$(st_of "$(collect osv-scanner "$SB/report.json" "SENTINEL_SHIELD_OSV_SUBJECT=subject-b")")"

# --- #185-AC3/AC4/AC6 OSV: every severity reconciles and stays visible -------------
osv_sev_report() { # osv_sev_report <severity-json-fragments...>
	printf '{"results":[{"source":{"path":"go.mod"},"packages":[{"vulnerabilities":[%s]}]}]}' "$1" > "$SB/report.json"
	prov "$SB/report.json" "osv-scanner" "completed-findings" "lockfile" "subject-a"
	collect osv-scanner "$SB/report.json"
}
_ov=$(osv_sev_report '{"id":"I1","database_specific":{"severity":"MODERATE"}}')
assert_equal "osv-reconcile: a MODERATE vulnerability lands in medium" "1" "$(field "$_ov" medium)"
# An info-only report still has findings present: "no gating findings" and "nothing found" are
# different statements, and only one of them is true here.
_ov=$(osv_sev_report '{"id":"I1","database_specific":{"severity":"LOW"}},{"id":"I2","database_specific":{"severity":"LOW"}}')
assert_equal "osv-info-only: a low-only report reports findings present" "findings" "$(health "$_ov")"
assert_equal "osv-info-only: both low findings are preserved, not collapsed" "2" "$(field "$_ov" low)"
assert_equal "osv-info-only: and the gate still passes under current defaults" "pass" "$(st_of "$_ov")"
# AC4: an unknown severity must stay VISIBLE. Dropping it would understate the scan; silently
# gating on it would overstate it. The conservative documented policy is to keep it countable.
_ov=$(osv_sev_report '{"id":"U1","database_specific":{"severity":"BANANA"}}')
assert_equal "osv-unknown-severity: an unrecognised severity is still counted as a finding" \
	"findings" "$(health "$_ov")"
assert_equal "osv-unknown-severity: it reconciles into the total rather than vanishing" \
	"1" "$(field "$_ov" findings_total)"
_ov=$(osv_sev_report '{"id":"N1"}')
assert_equal "osv-missing-severity: a vulnerability with no severity at all is still counted" \
	"1" "$(field "$_ov" findings_total)"
# AC6 policy promotion. Promotion is a GATE decision, not a collector decision -- the collector
# has no business deciding which severities block a release. What it owes the gate is a report in
# which low findings are countable SEPARATELY from the gating buckets, so a policy can promote
# them without re-parsing the native scanner output. That separation is the testable part here.
_ov=$(osv_sev_report '{"id":"L1","database_specific":{"severity":"LOW"}},{"id":"H1","database_specific":{"severity":"HIGH"}}')
assert_equal "osv-promotion: low is reported separately from the gating buckets" "1" "$(field "$_ov" low)"
assert_equal "osv-promotion: and is excluded from the gating high count" "1" "$(field "$_ov" high)"
assert_equal "osv-promotion: while the total still accounts for it" "2" "$(field "$_ov" findings_total)"
_ov=$(osv_sev_report '{"id":"L1","database_specific":{"severity":"LOW"}}')
assert_equal "osv-promotion CONTROL: low findings alone do not gate under current defaults" \
	"pass" "$(st_of "$_ov")"
assert_equal "osv-promotion CONTROL: but they are visible as findings for a policy to promote" \
	"findings" "$(health "$_ov")"

# --- #101-AC7 THE FIXTURE INDEX AGREES WITH THE COLLECTOR IT DESCRIBES ------------
# INDEX.md is a hand-written description of what each fixture should produce, which makes it
# exactly the kind of document that silently stops being true. It claimed trufflehog counts only
# `Verified == true` items (2) — the superseded filter. The collector counts every finding (3) and
# reports verified/unverified separately, because TruffleHog emits unverified findings by default
# and non-verifiable custom detectors always report Verified:false, so a verified-only count drops
# real secrets. The row is now reconciled against a MEASURED run rather than re-read.
TH_FIX="$ROOT/tests/fixtures/collectors-v024/trufflehog.json"
TH_IDX="$ROOT/tests/fixtures/collectors-v024/INDEX.md"
_th_out=$(sh "$ROOT/scripts/collectors/trufflehog.sh" --input "$TH_FIX" 2>/dev/null)
_th_actual=$(printf '%s' "$_th_out" | jq -r '.summary.secrets // "-"')
_th_claim=$(awk -F'|' '/^\| trufflehog \|/ { gsub(/ /, "", $6); print $6; exit }' "$TH_IDX")
assert_equal "index-agreement: INDEX.md's trufflehog count is what the collector actually emits" \
	"$_th_actual" "$_th_claim"
assert_equal "index-agreement: the collector counts unverified findings too" "3" "$_th_actual"
assert_equal "index-agreement: verified findings remain separately reportable" \
	"2" "$(printf '%s' "$_th_out" | jq -r '.tool_report.verified // "-"')"
assert_equal "index-agreement: and so do unverified ones" \
	"1" "$(printf '%s' "$_th_out" | jq -r '.tool_report.unverified // "-"')"
assert_false "index-agreement: INDEX.md no longer documents the superseded verified-only filter" \
	grep -qF 'counts items where `Verified == true`' "$TH_IDX"

# ===========================================================================
# REVIEW-DRIVEN PRODUCTION CORRECTIONS
# ===========================================================================

# --- Grype scanner image: digest-pinned for gated use, on dockle's terms ---------
gyi_run() { # gyi_run <case> <mode> <scanner-image>
	_gi_d="$TMP/gyimg-$1"; rm -rf "$_gi_d"; _gi_p=$(sf_project "$_gi_d"); mkdir -p "$_gi_d/bin"
	cat > "$_gi_d/bin/docker" <<'GIS'
#!/bin/sh
printf '%s' '{"matches":[],"source":{"type":"directory","target":"."},"descriptor":{"name":"grype","version":"0.74.0","db":{"built":"2026-01-01T00:00:00Z"}}}'
exit 0
GIS
	chmod +x "$_gi_d/bin/docker"
	sf_run "$_gi_p" "$_gi_d/bin" "$AD/grype.sh" reports/raw/grype.json \
		"SENTINEL_SHIELD_GRYPE_MODE=fs" "SENTINEL_SHIELD_GRYPE_IMAGE=$3" "SENTINEL_SHIELD_MODE=$2" || :
	sf_state "$_gi_p" reports/raw/grype.json
}
GYI_PIN="anchore/grype@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
assert_equal "grype-image CONTROL: a digest-pinned scanner runs in regulated mode" \
	"completed-clean" "$(gyi_run pinned regulated "$GYI_PIN")"
assert_equal "grype-image: a mutable tag is REFUSED in a gated mode" \
	"execution-error" "$(gyi_run tag-strict strict anchore/grype:v0.114.0)"
assert_equal "grype-image: a mutable tag WARNS and still scans in baseline" \
	"completed-clean" "$(gyi_run tag-base baseline anchore/grype:v0.114.0)"
assert_equal "grype-image: a malformed digest is refused" \
	"execution-error" "$(gyi_run baddig regulated 'anchore/grype@sha256:abc')"

# --- Grype target binding: the report must describe what we asked for ------------
gyt_run() { # gyt_run <case> <requested-target> <source.target in the report>
	_gt_d="$TMP/gytgt-$1"; rm -rf "$_gt_d"; _gt_p=$(sf_project "$_gt_d")
	sf_make "$_gt_d" grype stdout clean \
		"{\"matches\":[],\"source\":{\"type\":\"directory\",\"target\":\"$3\"},\"descriptor\":{\"name\":\"grype\",\"version\":\"1\",\"db\":{\"built\":\"2026-01-01T00:00:00Z\"}}}" 0 >/dev/null
	mkdir -p "$_gt_p/$2" 2>/dev/null || :
	sf_plant_stale "$_gt_p" reports/raw/grype.json
	sf_run "$_gt_p" "$_gt_d/bin" "$AD/grype.sh" reports/raw/grype.json \
		"SENTINEL_SHIELD_GRYPE_MODE=fs" "SENTINEL_SHIELD_GRYPE_TARGET=$2" || :
	sf_state "$_gt_p" reports/raw/grype.json
}
assert_equal "grype-target CONTROL: a report describing the requested target is accepted" \
	"completed-clean" "$(gyt_run match . .)"
assert_equal "grype-target CONTROL: grype's scheme-qualified echo is the same target" \
	"completed-clean" "$(gyt_run scheme . 'dir:.')"
assert_equal "grype-target: a report about a DIFFERENT tree is refused" \
	"execution-error" "$(gyt_run other src /etc)"
# Substring matching is what this replaces: "app" must not satisfy a request for "app-fork".
assert_equal "grype-target: a prefix of the requested target is not the target" \
	"execution-error" "$(gyt_run prefix app-fork app)"
assert_equal "grype-target: a report recording no source at all is refused" \
	"execution-error" "$(gyt_run nosrc . '')"
# The case directory is derived, not captured: gyt_run's assignments happen inside a command
# substitution, so a variable set there never reaches this scope — and under `set -u` that turned
# the assertion into an unbound-variable error rather than a failure.
assert_false "grype-target: a refused target mismatch leaves no stale report" \
	sf_stale_survived "$(sf_project "$TMP/gytgt-other")" reports/raw/grype.json

# --- Scorecard identity and inconclusive results ---------------------------------
sci_run() { # sci_run <case> <requested-repo> <payload>
	_si_d="$TMP/scid-$1"; rm -rf "$_si_d"; _si_p=$(sf_project "$_si_d")
	sf_make "$_si_d" scorecard stdout clean "$3" 0 >/dev/null
	sf_run "$_si_p" "$_si_d/bin" "$AD/scorecard.sh" reports/raw/scorecard.json \
		"SENTINEL_SHIELD_SCORECARD_REPO=$2" || :
	sf_state "$_si_p" reports/raw/scorecard.json
}
SCI_OK='{"repo":{"name":"github.com/o/repo"},"score":9,"checks":[{"name":"Pinned-Dependencies","score":10}]}'
assert_equal "scorecard-id CONTROL: the exact repository is accepted" \
	"completed-clean" "$(sci_run exact github.com/o/repo "$SCI_OK")"
assert_equal "scorecard-id CONTROL: an https:// prefix is an equivalent form" \
	"completed-clean" "$(sci_run scheme https://github.com/o/repo "$SCI_OK")"
# The collisions substring matching allowed.
assert_equal "scorecard-id: repo cannot satisfy a request for repo-fork" \
	"execution-error" "$(sci_run fork github.com/o/repo-fork "$SCI_OK")"
assert_equal "scorecard-id: repo cannot satisfy a request for repo-docs" \
	"execution-error" "$(sci_run docs github.com/o/repo-docs "$SCI_OK")"
# score -1 is UNEVALUATED. All-inconclusive is not a clean scan.
assert_equal "scorecard-inconclusive: every check unevaluated is unavailable, not clean" \
	"unavailable" "$(sci_run allbad github.com/o/repo '{"repo":{"name":"github.com/o/repo"},"score":-1,"checks":[{"name":"A","score":-1},{"name":"B","score":-1}]}')"
assert_equal "scorecard-inconclusive CONTROL: one usable high score is a genuine clean scan" \
	"completed-clean" "$(sci_run onegood github.com/o/repo '{"repo":{"name":"github.com/o/repo"},"score":8,"checks":[{"name":"A","score":-1},{"name":"B","score":9}]}')"
assert_equal "scorecard-inconclusive CONTROL: a low usable score is still findings" \
	"completed-findings" "$(sci_run onelow github.com/o/repo '{"repo":{"name":"github.com/o/repo"},"score":2,"checks":[{"name":"A","score":-1},{"name":"B","score":1}]}')"

# --- Trivy Results must be an array before anything maps it ----------------------
assert_equal "trivy-type CONTROL: an empty array is a readable result set" \
	"pass" "$(st_of "$(tv_seed "$TRIVY_OK")")"
assert_equal "trivy-type: an OBJECT Results is refused, not silently mapped to zero" \
	"execution-error" "$(st_of "$(tv_seed '{"SchemaVersion":2,"ArtifactName":"a","Results":{}}')")"
assert_equal "trivy-type: a scalar Results is refused" \
	"execution-error" "$(st_of "$(tv_seed '{"SchemaVersion":2,"ArtifactName":"a","Results":"none"}')")"
assert_equal "trivy-type: a null Results is refused" \
	"execution-error" "$(st_of "$(tv_seed '{"SchemaVersion":2,"ArtifactName":"a","Results":null}')")"

# --- the shared derivation counts misconfigurations as findings -------------------
# A Trivy report with only failing misconfigurations has zero vulnerabilities and zero secrets, so
# the derivation called it completed-clean — provenance contradicting its own report.
_mc_dir="$SB/misconf"; mkdir -p "$_mc_dir"
printf '%s' '{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[{"Target":"Dockerfile","Misconfigurations":[{"ID":"DS002","Status":"FAIL"}]}]}' > "$_mc_dir/r.json"
( . "$ROOT/tests/lib/collector-provenance.sh"; cp_write "$_mc_dir/r.json" trivy.sh )
assert_equal "derivation: a misconfiguration-only report is completed-findings, not clean" \
	"completed-findings" "$(jq -r '.completion.state' "$_mc_dir/r.provenance.json")"
printf '%s' '{"SchemaVersion":2,"ArtifactName":"subject-a","Results":[{"Target":"Dockerfile","Misconfigurations":[{"ID":"DS002","Status":"PASS"}]}]}' > "$_mc_dir/r.json"
( . "$ROOT/tests/lib/collector-provenance.sh"; cp_write "$_mc_dir/r.json" trivy.sh )
assert_equal "derivation CONTROL: a passing misconfiguration is not a finding" \
	"completed-clean" "$(jq -r '.completion.state' "$_mc_dir/r.provenance.json")"

# --- zero-package e2e SBOMs are validated, not repopulated (#135-AC3) ------------
# Two e2e Syft fixtures carry `packages: []`. They are NOT given invented packages — that would
# hide the question rather than answer it. What makes them evidence is the proof around them, so
# that proof is asserted directly: the sidecar's digest matches the report bytes, the producer is
# syft, the target identity and mode are right, the completion state is a completed CLEAN scan
# (not no-targets, which would mean nothing was examined), and the SPDX metadata is complete and
# correctly typed.
for _z in tests/e2e/laravel/reports/raw/syft.json tests/e2e/laravel-react-docker/reports/raw/syft.json; do
	_zr="$ROOT/$_z"; _zp="${_zr%.json}.provenance.json"
	_zn=$(basename "$(dirname "$(dirname "$(dirname "$_zr")")")")
	assert_equal "e2e[$_zn]: the fixture really is zero-package" "0" "$(jq '.packages|length' "$_zr")"
	assert_equal "e2e[$_zn]: provenance records the report's own digest" \
		"$(ne_sha256 "$_zr")" "$(jq -r '.report.sha256 // ""' "$_zp")"
	assert_equal "e2e[$_zn]: the producer identity is syft" "syft" "$(jq -r '.tool // ""' "$_zp")"
	assert_equal "e2e[$_zn]: a completed CLEAN scan, not no-targets" \
		"completed-clean" "$(jq -r '.completion.state // ""' "$_zp")"
	assert_false "e2e[$_zn]: a target identity is recorded" \
		test -z "$(jq -r '.target.identity // ""' "$_zp")"
	assert_false "e2e[$_zn]: a target mode is recorded" \
		test -z "$(jq -r '.target.mode // ""' "$_zp")"
	# Complete AND correctly typed: a number or object in these fields is not a declaration.
	assert_true "e2e[$_zn]: SPDX metadata is present and string-typed" \
		jq -e '(.dataLicense|type=="string" and (length>0)) and (.SPDXID|type=="string" and (length>0)) and (.documentNamespace|type=="string" and (length>0))' "$_zr"
	# The collector is the arbiter: bound, complete, zero-package evidence is accepted.
	assert_equal "e2e[$_zn]: the collector accepts it as an empty inventory" \
		"pass" "$(st_of "$(collect syft "$_zr")")"
done

# The type check is real: coerced values must not satisfy it.
_ztmp="$SB/spdx-typed.json"
printf '%s' '{"spdxVersion":"SPDX-2.3","name":"x","dataLicense":"CC0-1.0","SPDXID":0,"documentNamespace":"https://x.invalid/1","creationInfo":{"created":"2026-01-01T00:00:00Z"},"packages":[]}' > "$_ztmp"
( . "$ROOT/tests/lib/collector-provenance.sh"; cp_write "$_ztmp" syft.sh >/dev/null 2>&1 )
assert_equal "spdx-typed: a numeric SPDXID is not a declared identifier" \
	"execution-error" "$(st_of "$(collect syft "$_ztmp")")"
printf '%s' '{"spdxVersion":"SPDX-2.3","name":"x","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","documentNamespace":{},"creationInfo":{"created":"2026-01-01T00:00:00Z"},"packages":[]}' > "$_ztmp"
( . "$ROOT/tests/lib/collector-provenance.sh"; cp_write "$_ztmp" syft.sh >/dev/null 2>&1 )
assert_equal "spdx-typed: an object documentNamespace is not a declared namespace" \
	"execution-error" "$(st_of "$(collect syft "$_ztmp")")"

# No adapter left a workspace behind across any of the groups above.
_l3_temp=$(find "$TMP" -name '.ss-tmp.*' 2>/dev/null | wc -l | tr -d ' ')
assert_equal "no Layer 3 case left an owned workspace behind" "0" "$_l3_temp"

assert_summary "scanner-semantics (Layer 3: tool meaning and collector conclusions)"
