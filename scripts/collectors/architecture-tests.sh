#!/bin/sh
# Sentinel Shield collector — architecture-tests (generic architecture-test evidence).
# Maps violation count -> architecture_violations. v2.1.0: the normalized architecture
# contract (status preservation, rule/context metadata, fail-closed on unknown shape) is
# implemented once in collectors/architecture.sh; this stays the stable entry point.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$SCRIPT_DIR/architecture.sh" --tool-name "architecture-tests" --input "reports/raw/architecture-tests.json" "$@"
