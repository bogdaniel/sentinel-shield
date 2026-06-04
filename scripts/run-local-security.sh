#!/bin/sh
# Sentinel Shield — run available local security scanners.
# POSIX sh. Skips tools that are not installed with a clear warning.
# This is a convenience sweep for developers; CI remains the source of truth.
set -eu

TARGET="${1:-.}"
cd "$TARGET"

OVERALL=0

have() { command -v "$1" >/dev/null 2>&1; }

run_tool() {
	label="$1"
	bin="$2"
	shift 2
	if have "$bin"; then
		echo ">> $label ($bin)"
		if "$bin" "$@"; then
			echo "   $label: ok"
		else
			echo "   $label: findings or error (review output)" >&2
			OVERALL=1
		fi
	else
		echo ">> $label: '$bin' not installed, skipping"
	fi
}

echo "Sentinel Shield local security sweep — target: $TARGET"
echo "===="

# Secret scanning (always relevant).
run_tool "Gitleaks (secrets)" gitleaks detect --no-banner --redact

# SAST.
if have semgrep; then
	echo ">> Semgrep"
	# Prefer bundled rules if this repo's semgrep/ dir is reachable; else registry.
	if [ -d semgrep ]; then
		semgrep --error --config ./semgrep || OVERALL=1
	else
		semgrep --error --config "p/owasp-top-ten" || OVERALL=1
	fi
else
	echo ">> Semgrep: not installed, skipping"
fi

# Vulnerability / IaC scanning.
run_tool "Trivy (filesystem)" trivy fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL --ignore-unfixed .

# Dependency vulnerability scanning.
run_tool "OSV-Scanner" osv-scanner --recursive .

# Language-native audits.
if [ -f composer.json ] && have composer; then
	echo ">> composer audit"
	composer audit --locked || OVERALL=1
fi

if [ -f package.json ] && have npm; then
	echo ">> npm audit"
	npm audit --audit-level=high || OVERALL=1
fi

echo "===="
if [ "$OVERALL" -eq 0 ]; then
	echo "Local security sweep: no blocking findings from installed tools."
else
	echo "Local security sweep: findings reported. Review output above." >&2
fi

# Local convenience script: do not hard-fail the developer shell by default.
# CI uses the workflows in github/workflows for authoritative blocking.
exit 0
