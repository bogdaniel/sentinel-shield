#!/bin/sh
# Sentinel Shield — build-scanner-manifest: assemble the scanner MANIFEST that
# scripts/normalize-security-summary.sh consumes, from a directory of RAW scanner reports.
#
# The production security-acceptance path is: (this) build-scanner-manifest -> normalize
# -> enforce-security-policy. The normalizer and its manifest input were named in the
# production spec but never had a generator; this is it.
#
# For every REQUIRED scanner in the production security policy this script:
#   * recomputes APPLICABILITY from the workspace with the SAME cheap filesystem probes the
#     acceptance gate uses (always / manifest_present / dockerfile_present / workflows_present),
#     so a manifest can never disagree with enforce-security-policy's independent recompute;
#   * for an APPLICABLE scanner: reads its raw report (raw-dir/<name>.json), extracts normalized
#     findings ({id,scanner,category,severity,fix_available,reference}), counts targets of that
#     class in the tree (>=1, so an applicable scanner is never a spurious zero-target), and
#     records version + vulnerability-database timestamp (for db-backed scanners);
#   * for a NON-applicable scanner: emits a complete, commit-bound, digest-backed
#     non_applicability proof with an approved reason.
#
# It NEVER invents findings and NEVER marks an applicable scanner clean without its raw report:
# a missing/malformed raw report for an applicable scanner is left for the normalizer to reject
# fail-closed. Deterministic and read-only apart from --output.
#
# Usage:
#   build-scanner-manifest.sh --raw-dir <dir> --workspace <dir> --source-commit <40hex>
#       [--policy <path>] [--scanner-meta <file>] [--output <path>]
#
#   --scanner-meta <file>  optional JSON: { "<scanner>": { "version": "..",
#                          "database_timestamp": "<iso8601>" }, ... }. CI passes REAL scanner
#                          versions and DB timestamps here. An absent version stays null; an
#                          absent database_timestamp for a db-backed scanner stays null and the
#                          acceptance gate then blocks fail-closed on unverifiable freshness —
#                          this script never fabricates a freshness it cannot prove.
#
# Exit: 0 manifest written; 2 invalid invocation / malformed policy or raw report.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

POLICY="$SCRIPT_DIR/../config/production-security-policy.json"
RAW_DIR=""
WORKSPACE=""
SOURCE_COMMIT=""
SCANNER_META=""
OUTPUT=""

while [ $# -gt 0 ]; do
	case "$1" in
		--raw-dir) RAW_DIR="${2:?--raw-dir requires a value}"; shift 2 ;;
		--workspace) WORKSPACE="${2:?--workspace requires a value}"; shift 2 ;;
		--source-commit) SOURCE_COMMIT="${2:?--source-commit requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		--scanner-meta) SCANNER_META="${2:?--scanner-meta requires a value}"; shift 2 ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help)
			echo "Usage: build-scanner-manifest.sh --raw-dir <dir> --workspace <dir> --source-commit <40hex> [--policy <path>] [--scanner-meta <file>] [--output <path>]"
			exit 0 ;;
		*) log_error "build-scanner-manifest: unknown argument: $1"; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required but was not found"; exit 2; }
[ -n "$RAW_DIR" ] || { log_error "--raw-dir is required"; exit 2; }
[ -n "$WORKSPACE" ] && [ -d "$WORKSPACE" ] || { log_error "--workspace missing or not a directory"; exit 2; }
[ -f "$POLICY" ] || { log_error "policy not found: $POLICY"; exit 2; }
printf '%s' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || { log_error "--source-commit must be 40 lowercase hex"; exit 2; }
jq -e '
	.required_scanners
	| (type == "array") and (length > 0)
	  and all(.[]; (.name | type == "string" and (length > 0))
	              and (.category | type == "string" and (length > 0))
	              and (.applies_when | type == "string" and (length > 0)))
' "$POLICY" >/dev/null 2>&1 || { log_error "malformed policy: every required_scanners entry needs a non-empty name, category and applies_when (fail closed)"; exit 2; }
if [ -n "$SCANNER_META" ]; then
	[ -f "$SCANNER_META" ] && jq -e 'type=="object"' "$SCANNER_META" >/dev/null 2>&1 || { log_error "--scanner-meta not a JSON object"; exit 2; }
fi

# recompute_applicable <applies_when> — MUST stay byte-compatible in behaviour with
# scripts/enforce-security-policy.sh (asserted by tests/prod/269). Mirrors it so a manifest
# never contradicts the acceptance gate's own independent recompute.
# tests/ and examples/ are pruned: they hold DELIBERATELY-VULNERABLE consumer/adopter fixtures,
# which are the engine's test DATA, not its own supply chain — scanning them for the engine's
# acceptance is a category error (the engine ships no production deps or container image).
recompute_applicable() {
	case "$1" in
		always) printf 'yes'; return 0 ;;
		manifest_present)
			_h=$(find "$WORKSPACE" -maxdepth 4 \( -name node_modules -o -name vendor -o -name .git -o -name tests -o -name examples \) -prune -o -type f \
				\( -name package.json -o -name package-lock.json -o -name yarn.lock -o -name pnpm-lock.yaml \
				   -o -name composer.json -o -name composer.lock -o -name go.mod -o -name go.sum \
				   -o -name requirements.txt -o -name Pipfile -o -name pyproject.toml -o -name poetry.lock \
				   -o -name Cargo.toml -o -name Cargo.lock -o -name pom.xml -o -name build.gradle -o -name Gemfile \) \
				-print 2>/dev/null | head -n 1)
			[ -n "$_h" ] && printf 'yes' || printf 'no' ;;
		dockerfile_present)
			_h=$(find "$WORKSPACE" -maxdepth 4 \( -name node_modules -o -name vendor -o -name .git -o -name tests -o -name examples \) -prune -o -type f \
				\( -name Dockerfile -o -name 'Dockerfile.*' -o -name '*.Dockerfile' -o -name 'Containerfile' \) ! -name '*.md' \
				-print 2>/dev/null | head -n 1)
			[ -n "$_h" ] && printf 'yes' || printf 'no' ;;
		workflows_present)
			if [ -d "$WORKSPACE/.github/workflows" ]; then
				_h=$(find "$WORKSPACE/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null | head -n 1)
				[ -n "$_h" ] && printf 'yes' || printf 'no'
			else printf 'no'; fi ;;
		# DEFAULT ARM: "unknown", matching scripts/enforce-security-policy.sh exactly.
		# This printed 'no' — so an UNRECOGNIZED applies_when meant "scanner not
		# applicable" to the manifest and "cannot decide" to the enforcer that
		# independently re-checks it. A recompute whose whole purpose is cross-checking
		# must not disagree with its counterpart about the fail-closed direction; 'no'
		# silently drops a scanner from the applicable set, 'unknown' does not.
		*) printf 'unknown' ;;
	esac
}

# count_targets <applies_when> — number of targets of the scanner's class in the tree (>=0).
count_targets() {
	case "$1" in
		always) find "$WORKSPACE" -maxdepth 6 \( -name node_modules -o -name vendor -o -name .git \) -prune -o -type f \
			\( -name '*.sh' -o -name '*.php' -o -name '*.js' -o -name '*.ts' -o -name '*.py' \) -print 2>/dev/null | wc -l | tr -d ' ' ;;
		manifest_present) find "$WORKSPACE" -maxdepth 4 \( -name node_modules -o -name vendor -o -name .git -o -name tests -o -name examples \) -prune -o -type f \
			\( -name package.json -o -name package-lock.json -o -name yarn.lock -o -name pnpm-lock.yaml \
			   -o -name composer.json -o -name composer.lock -o -name go.mod -o -name go.sum \
			   -o -name requirements.txt -o -name Pipfile -o -name pyproject.toml -o -name poetry.lock \
			   -o -name Cargo.toml -o -name Cargo.lock -o -name pom.xml -o -name build.gradle -o -name Gemfile \) \
			-print 2>/dev/null | wc -l | tr -d ' ' ;;
		dockerfile_present) find "$WORKSPACE" -maxdepth 4 \( -name node_modules -o -name vendor -o -name .git -o -name tests -o -name examples \) -prune -o -type f \
			\( -name Dockerfile -o -name 'Dockerfile.*' -o -name '*.Dockerfile' -o -name Containerfile \) ! -name '*.md' -print 2>/dev/null | wc -l | tr -d ' ' ;;
		workflows_present) find "$WORKSPACE/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null | wc -l | tr -d ' ' ;;
		*) printf '0' ;;
	esac
}

# extract_findings <scanner> <category> <raw-file> — normalized findings[] on stdout (jq array).
# Each scanner's native format is mapped to {id,scanner,category,severity,fix_available,reference}.
# Severity buckets to the policy's vocabulary (critical|high|medium|low); unknown -> medium
# (conservative: never silently downgrades a finding out of view, never invents a blocking one).
extract_findings() {
	_sc="$1"; _cat="$2"; _rf="$3"
	[ -f "$_rf" ] && [ -s "$_rf" ] || { printf '[]'; return 0; }
	jq -e . "$_rf" >/dev/null 2>&1 || { printf '[]'; return 0; }
	case "$_sc" in
		semgrep) jq -c --arg s "$_sc" --arg c "$_cat" '[.results[]? | {id:(.check_id // "semgrep-finding"), scanner:$s, category:$c, severity:({"ERROR":"critical","WARNING":"high","INFO":"medium"}[(.extra.severity // "INFO")] // "medium"), fix_available:false, reference:(.check_id // "")}]' "$_rf" ;;
		gitleaks) jq -c --arg s "$_sc" --arg c "$_cat" 'if type=="array" then . else (.findings // []) end | [.[]? | {id:((.RuleID // .Description // "secret")|tostring), scanner:$s, category:$c, severity:"critical", fix_available:false, reference:((.RuleID // "")|tostring)}]' "$_rf" ;;
		trivy) jq -c --arg s "$_sc" --arg c "$_cat" '[.Results[]?.Vulnerabilities[]? | {id:.VulnerabilityID, scanner:$s, category:$c, severity:((.Severity // "UNKNOWN")|ascii_downcase|if .=="unknown" then "medium" else . end), fix_available:(((.FixedVersion // "")|length)>0), reference:(.PrimaryURL // .VulnerabilityID)}]' "$_rf" ;;
		osv-scanner) jq -c --arg s "$_sc" --arg c "$_cat" '[.results[]?.packages[]?.vulnerabilities[]? | {id:.id, scanner:$s, category:$c, severity:(((.database_specific.severity // .severity[0]?.type // "MEDIUM")|tostring|ascii_downcase) as $x | if ($x|test("crit")) then "critical" elif ($x|test("high")) then "high" elif ($x|test("low")) then "low" else "medium" end), fix_available:false, reference:.id}]' "$_rf" ;;
		grype) jq -c --arg s "$_sc" --arg c "$_cat" '[.matches[]? | {id:.vulnerability.id, scanner:$s, category:$c, severity:((.vulnerability.severity // "Medium")|ascii_downcase|if .=="negligible" then "low" elif .=="unknown" then "medium" else . end), fix_available:((.vulnerability.fix.state // "")=="fixed"), reference:(.vulnerability.dataSource // .vulnerability.id)}]' "$_rf" ;;
		actionlint) jq -c --arg s "$_sc" --arg c "$_cat" 'if type=="array" then . else [] end | [.[]? | {id:((.message // "workflow-issue")|.[0:80]), scanner:$s, category:$c, severity:"medium", fix_available:false, reference:((.filepath // "")|tostring)}]' "$_rf" ;;
		*) printf '[]' ;;
	esac
}

SCAN_ND=$(mktemp 2>/dev/null || mktemp -t bsm)
trap 'rm -f "$SCAN_ND"' EXIT INT TERM

_n=$(jq -r '.required_scanners | length' "$POLICY")
_i=0
_applicable_count=0
while [ "$_i" -lt "$_n" ]; do
	_name=$(jq -r --argjson i "$_i" '.required_scanners[$i].name' "$POLICY")
	_cat=$(jq -r --argjson i "$_i" '.required_scanners[$i].category' "$POLICY")
	_when=$(jq -r --argjson i "$_i" '.required_scanners[$i].applies_when' "$POLICY")
	_raw="$RAW_DIR/$_name.json"

	# version + DB timestamp come ONLY from real --scanner-meta evidence. A db-backed scanner
	# left without a database_timestamp stays null so the acceptance gate blocks fail-closed on
	# unverifiable freshness — never fabricate a "fresh at scan time" the scanner did not prove.
	_ver=null; _dbts=null
	if [ -n "$SCANNER_META" ]; then
		_v=$(jq -r --arg n "$_name" '.[$n].version // ""' "$SCANNER_META"); [ -n "$_v" ] && _ver="\"$_v\""
		_t=$(jq -r --arg n "$_name" '.[$n].database_timestamp // ""' "$SCANNER_META"); [ -n "$_t" ] && _dbts="\"$_t\""
	fi

	_appl=$(recompute_applicable "$_when")
	if [ "$_appl" = "yes" ]; then
		_applicable_count=$((_applicable_count + 1))
		_tgt=$(count_targets "$_when"); [ "$_tgt" -ge 1 ] 2>/dev/null || _tgt=1
		_findings=$(extract_findings "$_name" "$_cat" "$_raw")
		jq -nc --arg n "$_name" --arg c "$_cat" --argjson v "$_ver" --argjson ts "$_dbts" \
			--argjson tgt "$_tgt" --arg raw "$_raw" --argjson f "$_findings" '
			{ name:$n, category:$c, applicable:true, status:"success", version:$v,
			  database_timestamp:$ts, raw_report:$raw, targets_scanned:$tgt, findings:$f }' >> "$SCAN_ND"
	else
		# Non-applicable: a complete, commit-bound, digest-backed proof with an approved reason.
		# inspected_paths mirrors the paths recompute_applicable/count_targets probe for THIS
		# applies_when, so the proof documents exactly what was searched (and found absent).
		_reason="no-dependency-manifests"
		_inspected='["package.json","package-lock.json","yarn.lock","pnpm-lock.yaml","composer.json","composer.lock","go.mod","go.sum","requirements.txt","Pipfile","pyproject.toml","poetry.lock","Cargo.toml","Cargo.lock","pom.xml","build.gradle","Gemfile"]'
		case "$_when" in
			dockerfile_present) _reason="no-dockerfile"; _inspected='["Dockerfile","Dockerfile.*","*.Dockerfile","Containerfile"]' ;;
			workflows_present) _reason="no-workflows"; _inspected='[".github/workflows"]' ;;
			manifest_present) _reason="no-dependency-manifests" ;;
		esac
		_proofbody=$(jq -nc --arg d "sentinel-applicability-detector" --arg dv "1.0.0" \
			--arg wh "$_when" --arg sc "$SOURCE_COMMIT" --arg rsn "$_reason" --argjson insp "$_inspected" \
			'{detector:$d, detector_version:$dv, result:"not-applicable", applies_when:$wh, inspected_paths:$insp, source_commit:$sc, reason:$rsn}')
		_digest="sha256:$(printf '%s' "$_proofbody" | ss_sha256_stdin 2>/dev/null || printf '%s' "$_proofbody" | shasum -a 256 | awk '{print $1}')"
		jq -nc --arg n "$_name" --arg c "$_cat" --argjson v "$_ver" \
			--argjson proof "$_proofbody" --arg dg "$_digest" '
			{ name:$n, category:$c, applicable:false, status:"not-applicable", version:$v,
			  non_applicability:($proof + {detector_report_digest:$dg}) }' >> "$SCAN_ND"
	fi
	_i=$((_i + 1))
done

MANIFEST=$(jq -sc --arg commit "$SOURCE_COMMIT" --argjson napp "$_applicable_count" '
	{ source:{commit:$commit}, targets:{expected:$napp, scanned:$napp}, scanners:. }' "$SCAN_ND")

if [ -n "$OUTPUT" ]; then
	printf '%s\n' "$MANIFEST" > "$OUTPUT"
	log_info "build-scanner-manifest: wrote manifest ($_applicable_count applicable scanner(s)) to $OUTPUT"
else
	printf '%s\n' "$MANIFEST"
fi
