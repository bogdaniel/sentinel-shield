#!/bin/sh
# Sentinel Shield — generate a baseline Markdown report.
# POSIX sh. Writes reports/sentinel-shield-report.md with timestamp, detected
# stack, and placeholder sections to be filled by scan output.
set -eu

TARGET="${1:-.}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
OUT_DIR="$TARGET/reports"
OUT_FILE="$OUT_DIR/sentinel-shield-report.md"

ensure_dir "$OUT_DIR"

# Timestamp (UTC). `date` is available on POSIX systems.
TS=$(timestamp_utc)

# Collect detected stacks (best-effort; reuse detect-stack.sh).
STACKS=$(sh "$SCRIPT_DIR/detect-stack.sh" "$TARGET" 2>/dev/null | sed -n 's/^detected: //p' | tr '\n' ' ' || true)
if [ -z "$STACKS" ]; then
	STACKS="(none detected)"
fi

# Resolve gates via the authoritative resolver (best-effort; never fail the report).
MODE="(not resolved — run scripts/resolve-gates.sh)"
GATES_BLOCK="_Gate resolver did not run. Run \`scripts/resolve-gates.sh\` to populate this section._"
RESOLVER="$SCRIPT_DIR/resolve-gates.sh"
if [ -f "$RESOLVER" ]; then
	if ( cd "$TARGET" && sh "$RESOLVER" --output-dir reports --format all ) >/dev/null 2>&1; then
		ENVF="$OUT_DIR/sentinel-shield-gates.env"
		if [ -f "$ENVF" ]; then
			M=$(sed -n 's/^SENTINEL_SHIELD_MODE=//p' "$ENVF" | head -n1 || true)
			if [ -n "$M" ]; then MODE="$M"; fi
			GATES_BLOCK=$(cat "$ENVF")
		fi
	else
		log_warn "gate resolver failed; report will omit resolved gate values"
	fi
else
	log_warn "resolve-gates.sh not found next to this script; skipping gate resolution"
fi

# Enforcement summary (best-effort; never fail the report).
# Only runs if a security-summary.json is present and the enforcer + jq exist.
SUMMARY_STATUS="not present (a scanner workflow must produce reports/security-summary.json)"
ENFORCE_BLOCK="_Enforcement has not run. Provide \`reports/security-summary.json\` and run \`scripts/enforce-gates.sh\`._"
ENFORCER="$SCRIPT_DIR/enforce-gates.sh"
SUMMARY_FILE="$OUT_DIR/security-summary.json"
if [ -f "$SUMMARY_FILE" ]; then
	SUMMARY_STATUS="present (\`$SUMMARY_FILE\`)"
	if [ -f "$ENFORCER" ] && command -v jq >/dev/null 2>&1; then
		# Do not fail report generation on a failing gate (exit 1) or error (exit 2).
		( cd "$TARGET" && sh "$ENFORCER" --output-dir reports --format all ) >/dev/null 2>&1 || true
		ENFMD="$OUT_DIR/sentinel-shield-enforcement.md"
		if [ -f "$ENFMD" ]; then
			ENFORCE_BLOCK=$(cat "$ENFMD")
		else
			log_warn "enforcement did not produce a report; see scripts/enforce-gates.sh"
		fi
	else
		log_warn "enforce-gates.sh or jq unavailable; skipping enforcement summary"
		ENFORCE_BLOCK="_Enforcement skipped: enforce-gates.sh or jq not available._"
	fi
fi

# Tool availability summary (which scanners are installed locally).
tool_line() {
	if command -v "$1" >/dev/null 2>&1; then
		echo "| $1 | available |"
	else
		echo "| $1 | not installed |"
	fi
}
TOOLS=$(
	for t in gitleaks semgrep trivy osv-scanner syft grype hadolint conftest composer npm; do
		tool_line "$t"
	done
)

cat > "$OUT_FILE" <<EOF
# Sentinel Shield Report

- Generated: $TS
- Target: \`$TARGET\`
- Detected stacks: $STACKS
- Adoption mode: $MODE

> This is a generated baseline report. Populate the sections below from scanner
> output (\`scripts/run-local-security.sh\`, CI artifacts) and triage per
> \`docs/severity-policy.md\`.

## Tool availability (local)

| Tool | Status |
| --- | --- |
$TOOLS

> "not installed" tools are skipped by the local scripts; CI remains the source of
> truth. See README.md for the tooling matrix.

## Gate resolution

Resolved by \`scripts/resolve-gates.sh\` (mode: **$MODE**). Full artifacts:
\`reports/sentinel-shield-gates.{env,json,md}\`. A \`true\` value means the gate
blocks the build in this mode. See \`docs/gate-resolution.md\`.

\`\`\`
$GATES_BLOCK
\`\`\`

## Gate enforcement

- Security summary: $SUMMARY_STATUS
- Enforced by \`scripts/enforce-gates.sh\` against the resolved gate flags. See
  \`docs/security-summary-schema.md\`.

$ENFORCE_BLOCK

## Summary

| Category | Critical | High | Medium | Low | Info |
| --- | --- | --- | --- | --- | --- |
| Secrets |  |  |  |  |  |
| SAST (Semgrep/CodeQL) |  |  |  |  |  |
| Dependencies |  |  |  |  |  |
| Containers/IaC |  |  |  |  |  |
| Quality/Type |  |  |  |  |  |

## Secrets (Gitleaks)

_No data yet. Paste findings or attach the scan output._

## Static analysis (Semgrep / CodeQL)

_No data yet._

## Dependencies (composer audit / npm audit / OSV-Scanner / Grype)

_No data yet._

## Containers & IaC (Hadolint / Trivy / OPA)

_No data yet._

## Code quality & types (PHPStan / Psalm / tsc / ESLint)

_No data yet._

## Architecture (Deptrac)

_No data yet._

## Accepted risks / exceptions

_List open exceptions (owner, expiry, approval) per docs/exception-policy.md._

## Readiness

_Score against docs/project-readiness-checklist.md._

## Next steps

1. Run \`scripts/run-local-security.sh\` and \`scripts/run-php-quality.sh\` /
   \`scripts/run-node-quality.sh\` and paste results into the sections above.
2. Triage findings with \`docs/severity-policy.md\`; assign owners to critical/high.
3. Record any accepted risk via \`policies/exceptions/accepted-risk-template.md\`.
4. Confirm the adoption mode in \`.sentinel-shield/profile.yaml\` and the matching
   gates in \`RELEASE-GATES.md\`.
EOF

echo "Report written to: $OUT_FILE"
