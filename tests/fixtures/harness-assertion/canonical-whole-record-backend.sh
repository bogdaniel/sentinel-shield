#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: newline-delimited records survive whole.
set -eu
printf 'consumer package.json coverage script\n' > "${TMPDIR:-/tmp}/ss-canon-backend"
while IFS= read -r _b; do [ -n "$_b" ] || continue; printf 'RECORD: %s\n' "$_b"; done < "${TMPDIR:-/tmp}/ss-canon-backend"
rm -f "${TMPDIR:-/tmp}/ss-canon-backend"
