#!/bin/sh
# Sentinel Shield — security-summary builder.
#
# Runs the per-tool collectors over raw scanner artifacts in reports/raw/ and merges
# their results into reports/security-summary.json (conforming to
# schemas/security-summary.schema.json), which scripts/enforce-gates.sh then judges.
#
# Responsibilities (kept separate): this script does NOT run scanners. Scanner
# workflows produce reports/raw/*.json; collectors parse one file each; this builder
# merges. See docs/scanner-normalization.md.
#
# Design goals: deterministic, explicit, safe. jq is required.
#
# Exit codes:
#   0  summary generated
#   1  required tool artifact missing, or a collector failed
#   2  configuration / input / tooling error
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

die_cfg() { log_error "$*"; exit 2; }

# tool-key | raw-filename | collector-script | emitted-tool-name
TOOL_TABLE='gitleaks|gitleaks.json|gitleaks.sh|gitleaks
semgrep|semgrep.json|semgrep.sh|semgrep
trivy|trivy.json|trivy.sh|trivy
composer-audit|composer-audit.json|composer-audit.sh|composer_audit
npm-audit|npm-audit.json|npm-audit.sh|npm_audit
phpstan|phpstan.json|phpstan.sh|phpstan
psalm|psalm.json|psalm.sh|psalm
deptrac|deptrac.json|deptrac.sh|deptrac
tests|tests.json|tests.sh|tests
hadolint|hadolint.json|hadolint.sh|hadolint
actionlint|actionlint.json|actionlint.sh|actionlint
zizmor|zizmor.json|zizmor.sh|zizmor'

# --- defaults / CLI ----------------------------------------------------------
RAW_DIR="reports/raw"
OUTPUT="reports/security-summary.json"
PNAME="unknown"
PTYPE="unknown"
CRIT="medium"
COMMIT="unknown"
BRANCH="master"
WORKFLOW="local"
STRICT_TOOLS=0
REQUIRE_TOOLS=" "   # space-padded list for substring matching

usage() {
	cat <<'EOF'
Usage: build-security-summary.sh [options]

Merge collector results over reports/raw/*.json into reports/security-summary.json.

Options:
  --raw-dir <path>        Directory of raw artifacts (default: reports/raw)
  --output <path>         Output summary path (default: reports/security-summary.json)
  --project-name <name>   Project name (default: unknown)
  --project-type <type>   Project type (default: unknown)
  --criticality <level>   low | medium | high | critical (default: medium)
  --commit <sha>          Source commit (default: unknown)
  --branch <branch>       Source branch (default: master)
  --workflow <name>       Producing workflow (default: local)
  --strict-tools          Fail (exit 1) if ANY expected raw artifact is missing
  --require-tool <tool>   Fail (exit 1) if this tool's artifact is missing (repeatable)
  -h, --help              Show this help

Requires jq. Exit: 0 ok, 1 missing-required/collector-failure, 2 config/tooling error.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--raw-dir) RAW_DIR="${2:?--raw-dir requires a value}"; shift 2 ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--project-name) PNAME="${2:?--project-name requires a value}"; shift 2 ;;
		--project-type) PTYPE="${2:?--project-type requires a value}"; shift 2 ;;
		--criticality) CRIT="${2:?--criticality requires a value}"; shift 2 ;;
		--commit) COMMIT="${2:?--commit requires a value}"; shift 2 ;;
		--branch) BRANCH="${2:?--branch requires a value}"; shift 2 ;;
		--workflow) WORKFLOW="${2:?--workflow requires a value}"; shift 2 ;;
		--strict-tools) STRICT_TOOLS=1; shift ;;
		--require-tool) REQUIRE_TOOLS="${REQUIRE_TOOLS}${2:?--require-tool requires a value} "; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die_cfg "unknown argument: $1" ;;
	esac
done

case "$CRIT" in
	low | medium | high | critical) ;;
	*) die_cfg "invalid --criticality '$CRIT' (expected: low | medium | high | critical)" ;;
esac

command_exists jq || die_cfg "jq is required but was not found. Install jq."

REPORTS_DIR=$(dirname -- "$OUTPUT")
ensure_dir "$REPORTS_DIR"
TS=$(timestamp_utc)

# --- run collectors ----------------------------------------------------------
COLLECTED=""        # newline-delimited collector JSON objects
MISSING_REQUIRED="" # space list of required-but-missing tool keys

# Iterate the table in the CURRENT shell (not a pipeline subshell) so the COLLECTED
# and MISSING_REQUIRED accumulators persist. Split each row on '|' via IFS.
OLD_IFS=$IFS
IFS='
'
for row in $TOOL_TABLE; do
	IFS='|'
	# shellcheck disable=SC2086
	set -- $row
	IFS=$OLD_IFS
	key=$1; file=$2; script=$3; emit=$4
	raw="$RAW_DIR/$file"
	collector="$SCRIPT_DIR/collectors/$script"

	required=0
	if [ "$STRICT_TOOLS" -eq 1 ]; then required=1; fi
	case "$REQUIRE_TOOLS" in *" $key "*) required=1 ;; esac

	if [ ! -f "$raw" ] || [ ! -s "$raw" ]; then
		if [ "$required" -eq 1 ]; then
			log_error "required tool artifact missing or empty: $key ($raw)"
			MISSING_REQUIRED="$MISSING_REQUIRED $key"
			continue
		fi
		# Non-required: still invoke the collector, which emits "unavailable".
	fi

	if [ ! -f "$collector" ]; then
		die_cfg "collector not found: $collector"
	fi

	out=$(sh "$collector" --input "$raw" --tool-name "$emit") || {
		log_error "collector failed for '$key' ($collector)"
		exit 1
	}
	COLLECTED="${COLLECTED}${out}
"
done
IFS=$OLD_IFS

if [ -n "$MISSING_REQUIRED" ]; then
	log_error "missing required tool artifacts:$MISSING_REQUIRED"
	exit 1
fi

# --- merge -------------------------------------------------------------------
ARR=$(printf '%s' "$COLLECTED" | jq -s '.')

COUNTS=$(printf '%s' "$ARR" | jq '
	reduce .[] as $c (
		{secrets:0, critical_vulnerabilities:0, high_vulnerabilities:0,
		 medium_vulnerabilities:0, architecture_violations:0, type_errors:0,
		 test_failures:0, unsafe_docker:0, unsafe_github_actions:0, expired_exceptions:0};
		reduce ($c.summary | keys_unsorted[]) as $k (.; .[$k] = ((.[$k] // 0) + ($c.summary[$k] // 0)))
	)')

TOOLSOBJ=$(printf '%s' "$ARR" | jq 'reduce .[] as $c ({}; .[$c.tool] = $c.tool_report)')

# --- evidence ----------------------------------------------------------------
SBOM_PATH="$REPORTS_DIR/sbom.spdx.json"
RELEASE_PATH="$REPORTS_DIR/release-evidence.md"
if [ -f "$SBOM_PATH" ]; then SP=true; MS=false; else SP=false; MS=true; fi
if [ -f "$RELEASE_PATH" ]; then RP=true; MR=false; else RP=false; MR=true; fi

# --- exceptions --------------------------------------------------------------
EXC="$REPORTS_DIR/exceptions.json"
EA=0
EE=0
if [ -f "$EXC" ] && [ -s "$EXC" ]; then
	if jq -e . "$EXC" >/dev/null 2>&1; then
		EA=$(jq '(.active // 0)' "$EXC")
		EE=$(jq '(.expired // 0)' "$EXC")
		case "$EA" in '' | *[!0-9]*) die_cfg "exceptions.active must be a non-negative integer in $EXC" ;; esac
		case "$EE" in '' | *[!0-9]*) die_cfg "exceptions.expired must be a non-negative integer in $EXC" ;; esac
	else
		die_cfg "invalid JSON in $EXC"
	fi
fi

# --- assemble ----------------------------------------------------------------
jq -n \
	--argjson counts "$COUNTS" \
	--argjson tools "$TOOLSOBJ" \
	--arg version "1.0" \
	--arg gen "$TS" \
	--arg pname "$PNAME" --arg ptype "$PTYPE" --arg crit "$CRIT" \
	--arg commit "$COMMIT" --arg branch "$BRANCH" --arg workflow "$WORKFLOW" \
	--argjson ms "$MS" --argjson mr "$MR" \
	--argjson sp "$SP" --argjson rp "$RP" \
	--arg sbom_path "$SBOM_PATH" --arg rel_path "$RELEASE_PATH" \
	--argjson ea "$EA" --argjson ee "$EE" '
	{
		version: $version,
		project: { name: $pname, type: $ptype, criticality: $crit },
		generated_at: $gen,
		source: { commit: $commit, branch: $branch, workflow: $workflow },
		summary: ($counts + { missing_sbom: $ms, missing_release_evidence: $mr, expired_exceptions: $ee }),
		tools: $tools,
		exceptions: { active: $ea, expired: $ee },
		evidence: {
			sbom: { present: $sp, path: $sbom_path },
			release_evidence: { present: $rp, path: $rel_path }
		}
	}' > "$OUTPUT"

# Final self-check: valid JSON and consistent evidence booleans.
jq -e '
	(.summary.missing_sbom == (.evidence.sbom.present | not))
	and (.summary.missing_release_evidence == (.evidence.release_evidence.present | not))
	and (.summary.expired_exceptions == .exceptions.expired)
' "$OUTPUT" >/dev/null || die_cfg "internal consistency check failed for $OUTPUT"

log_info "wrote $OUTPUT (mode-agnostic findings; enforce with scripts/enforce-gates.sh)"
log_info "summary: $(printf '%s' "$COUNTS" | jq -c '.')  missing_sbom=$MS missing_release_evidence=$MR"
