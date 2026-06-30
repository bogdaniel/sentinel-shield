#!/bin/sh
# Sentinel Shield — DEPRECATED alias for scripts/run-local-scanner-sweep.sh.
#
# This name is retained ONLY for backward compatibility. It is a thin wrapper that
# prints a deprecation notice to stderr and execs run-local-scanner-sweep.sh with the
# same arguments. The sweep is a NON-AUTHORITATIVE developer convenience: it MAY skip
# missing tools, does NOT produce gate evidence, and does NOT replace
# run-local-pipeline.sh. New callers must use run-local-scanner-sweep.sh directly.
#
# Exit codes pass through unchanged from run-local-scanner-sweep.sh.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
printf '%s\n' "[sentinel-shield][warn] run-local-security.sh is DEPRECATED; use scripts/run-local-scanner-sweep.sh (NON-authoritative sweep; not gate evidence)." >&2
exec sh "$SCRIPT_DIR/run-local-scanner-sweep.sh" "$@"
