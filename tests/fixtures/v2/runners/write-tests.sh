#!/bin/sh
# Self-test fixture runner (v2-review): writes a minimal VALID tests report into
# the consuming project's reports/raw/ (run-tool-plan runs runners with the target
# as CWD). Stands in for a real pest/phpunit run so the one-of group can reach a
# deterministic 'ran' status without the actual test tool being installed.
set -eu
mkdir -p reports/raw
printf '%s' '{"failures":0,"errors":0}' > reports/raw/tests.json
exit 0
