#!/bin/sh
# Sentinel Shield — main-gate validation harness (v0.1.17).
#
# PURPOSE. Run the deterministic main-gate scanner wrappers/audits from ANY branch or PR,
# locally or in CI, producing the same reports/raw/* contracts the summary builder consumes.
# This sidesteps the workflow_dispatch limitation that blocks first-time validation of
# templates/workflows/sentinel-shield-main.yml (a dispatch can only target a branch once the
# workflow file already exists on the default branch). See docs/main-gate-validation-strategy.md.
#
# SAFETY. POSIX sh. Read-only scans of the target. NO DAST / Nuclei / AI tools. A missing binary
# or unmet precondition -> status "unavailable" with NO file written (never a fake clean report).
# It does not modify the target's source.
#
# Usage:
#   sh scripts/run-main-gate-validation.sh --target . --output-dir reports/raw --all
#   sh scripts/run-main-gate-validation.sh --target . --output-dir reports/raw --tool osv-scanner --tool trivy-fs
#
# Each run also writes <output-dir>/main-gate-validation-tools.json describing every tool's
# status (pass | fail | unavailable | skipped) + reason + report path.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# Known DETERMINISTIC main-gate tools. NO DAST/Nuclei/AI — by design.
KNOWN="codeql-export osv-scanner trivy-fs syft grype dependency-check deptrac architecture-tests checkov conftest terrascan dockle"

TARGET="."
OUTPUT_DIR="reports/raw"
PROFILE=""
ALL=0
SELECTED=" "   # space-padded membership string

usage() {
	cat <<EOF
Usage: run-main-gate-validation.sh [--target <dir>] [--output-dir <dir>] [--profile <name>] (--all | --tool <name> ...)

  --target <dir>      Project directory to scan (default: .). Wrappers scan its working tree.
  --output-dir <dir>  Where reports/raw/* are written (default: reports/raw).
  --profile <name>    Informational label recorded in the tools JSON (optional).
  --tool <name>       Run one tool (repeatable). One of: $KNOWN
  --all               Run every deterministic main-gate tool above.
  -h, --help          Show this help.

Behavior: missing binary / unmet precondition -> "unavailable" (no report written, never faked).
NO DAST, Nuclei, or AI tools are included. Read-only; the target source is not modified.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--all) ALL=1; shift ;;
		--tool)
			_t="${2:?--tool requires a value}"
			case " $KNOWN " in
				*" $_t "*) SELECTED="$SELECTED$_t " ;;
				*) echo "error: unknown tool '$_t' (known: $KNOWN)" >&2; exit 2 ;;
			esac
			shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
	esac
done

[ -d "$TARGET" ] || { echo "error: --target '$TARGET' is not a directory" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
if [ "$ALL" -eq 0 ] && [ "$SELECTED" = " " ]; then
	echo "error: pass --all or at least one --tool <name>" >&2; usage; exit 2
fi
[ "$ALL" -eq 1 ] && SELECTED=" $KNOWN "

# Make target + output dir absolute (wrappers run with cwd=target and write to an absolute path).
TARGET_ABS=$(CDPATH= cd -- "$TARGET" && pwd)
mkdir -p "$OUTPUT_DIR"
OUTDIR_ABS=$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)
# The summary builder reads the SBOM from <dirname(summary output)>/sbom.spdx.json. When the raw
# dir is <reports>/raw, that is <reports>/sbom.spdx.json — keep Syft compatible by writing there.
REPORTS_ROOT=$(dirname -- "$OUTDIR_ABS")
SBOM_PATH="$REPORTS_ROOT/sbom.spdx.json"

is_selected() { case "$SELECTED" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

REC=$(mktemp); : > "$REC"; trap 'rm -f "$REC"' EXIT INT TERM
record() { # tool status reason report
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$REC"
}

# Resolve a tool to: wrapper path, output file, and a human requirement string.
tool_meta() { # sets WRAP OUT REQ KIND for $1
	case "$1" in
		osv-scanner)        WRAP="scripts/audits/osv-scanner.sh";        OUT="$OUTDIR_ABS/osv-scanner.json";      REQ="osv-scanner CLI on PATH"; KIND=pos ;;
		trivy-fs)           WRAP="scripts/audits/trivy-fs.sh";           OUT="$OUTDIR_ABS/trivy.json";            REQ="trivy CLI on PATH"; KIND=pos ;;
		syft)               WRAP="scripts/audits/syft.sh";               OUT="$SBOM_PATH";                        REQ="syft CLI on PATH"; KIND=pos ;;
		grype)              WRAP="scripts/audits/grype.sh";              OUT="$OUTDIR_ABS/grype.json";            REQ="grype CLI on PATH"; KIND=pos ;;
		dependency-check)   WRAP="scripts/audits/dependency-check.sh";   OUT="$OUTDIR_ABS/dependency-check.json"; REQ="dependency-check CLI on PATH (slow; large NVD download)"; KIND=pos ;;
		checkov)            WRAP="scripts/audits/checkov.sh";            OUT="$OUTDIR_ABS/checkov.json";          REQ="checkov CLI on PATH + IaC files in target"; KIND=pos ;;
		conftest)           WRAP="scripts/audits/conftest.sh";           OUT="$OUTDIR_ABS/conftest.json";         REQ="conftest CLI on PATH + OPA policies"; KIND=pos ;;
		terrascan)          WRAP="scripts/audits/terrascan.sh";          OUT="$OUTDIR_ABS/terrascan.json";        REQ="terrascan CLI on PATH + IaC files in target"; KIND=pos ;;
		dockle)             WRAP="scripts/audits/dockle.sh";             OUT="$OUTDIR_ABS/dockle.json";           REQ="dockle CLI on PATH + SENTINEL_SHIELD_IMAGE (built image ref)"; KIND=dockle ;;
		deptrac)            WRAP="scripts/runners/deptrac.sh";           OUT="$OUTDIR_ABS/deptrac.json";          REQ="vendor/bin/deptrac in target (PHP project with deptrac installed)"; KIND=pos ;;
		architecture-tests) WRAP="scripts/runners/architecture-tests.sh"; OUT="$OUTDIR_ABS/architecture-tests.json"; REQ="SENTINEL_SHIELD_ARCH_TEST_CMD env (e.g. 'vendor/bin/pest --group=arch')"; KIND=pos ;;
		codeql-export)      WRAP="scripts/runners/codeql-export.sh";     OUT="$OUTDIR_ABS/codeql.json";           REQ="a CodeQL SARIF present in target (CodeQL runs via the github/codeql-action)"; KIND=codeql ;;
		*) WRAP=""; OUT=""; REQ="unknown"; KIND=none ;;
	esac
}

run_tool() { # $1=tool
	tool="$1"; tool_meta "$tool"
	# dockle needs a built image ref; do not invoke its `:?` guard with set -eu (would look like a crash).
	if [ "$KIND" = dockle ] && [ -z "${SENTINEL_SHIELD_IMAGE:-}" ]; then
		record "$tool" unavailable "requires SENTINEL_SHIELD_IMAGE (built image ref); not set" ""
		echo "[main-gate] $tool: unavailable (needs SENTINEL_SHIELD_IMAGE)" >&2
		return
	fi
	rc=0
	if [ "$KIND" = codeql ]; then
		( cd "$TARGET_ABS" && sh "$ROOT/$WRAP" --output "$OUT" ) >&2 || rc=$?
	else
		( cd "$TARGET_ABS" && sh "$ROOT/$WRAP" "$OUT" ) >&2 || rc=$?
	fi
	if [ -s "$OUT" ]; then
		record "$tool" pass "ran; report produced" "$OUT"
		echo "[main-gate] $tool: pass -> $OUT" >&2
	elif [ "$rc" -eq 0 ]; then
		record "$tool" unavailable "$REQ; no report written" ""
		echo "[main-gate] $tool: unavailable ($REQ)" >&2
	else
		record "$tool" fail "wrapper exited $rc" ""
		echo "[main-gate] $tool: FAIL (wrapper exit $rc)" >&2
	fi
}

echo "[main-gate] target=$TARGET_ABS output-dir=$OUTDIR_ABS profile=${PROFILE:-<none>}" >&2
echo "[main-gate] selected:$([ "$ALL" -eq 1 ] && echo ' (all)')$SELECTED" >&2
echo "------------------------------------------------------------" >&2

for tool in $KNOWN; do
	if is_selected "$tool"; then
		run_tool "$tool"
	else
		record "$tool" skipped "not selected this run" ""
	fi
done

TOOLS_JSON="$OUTDIR_ABS/main-gate-validation-tools.json"
jq -Rn --arg target "$TARGET_ABS" --arg outdir "$OUTDIR_ABS" --arg profile "${PROFILE:-}" '
	{
		version: "1.0",
		generated_by: "run-main-gate-validation.sh",
		target: $target,
		output_dir: $outdir,
		profile: ($profile | select(. != "") // null),
		tools: (
			[ inputs | split("\t")
			  | { key: .[0],
			      value: { status: .[1], reason: .[2], report: (.[3] | select(. != "") // null) } } ]
			| from_entries
		)
	}
' "$REC" > "$TOOLS_JSON"

echo "------------------------------------------------------------" >&2
echo "[main-gate] wrote $TOOLS_JSON" >&2
# Availability summary (counts + per-tool line).
jq -r '
	(.tools | to_entries) as $t
	| ( ["pass","fail","unavailable","skipped"]
	    | map(. as $s | "\($s)=\([ $t[] | select(.value.status == $s) ] | length)") | join("  ") ) as $counts
	| "SUMMARY: " + $counts,
	  ( $t[] | "  \(.key): \(.value.status)" + (if .value.report then " -> \(.value.report)" else "" end) )
' "$TOOLS_JSON" >&2

# Honest exit policy: an unexpected wrapper FAIL is the only non-zero exit. "unavailable" is a
# valid, expected outcome (a tool the local/CI env cannot run) and must not break a branch run.
FAILS=$(jq -r '[ .tools[] | select(.status == "fail") ] | length' "$TOOLS_JSON")
[ "$FAILS" -eq 0 ] || { echo "[main-gate] $FAILS tool wrapper(s) FAILED unexpectedly" >&2; exit 1; }
exit 0
