#!/bin/sh
# Self-test fixture runner (v2-review): a genuine no-op. Produces NO report and
# exits 0 — the signal run-tool-plan must read as "unavailable" (never fabricate a
# pass from a stale report). Deliberately writes nothing.
set -eu
exit 0
