#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: newline-delimited records survive whole.
#
# The record file is created with mktemp rather than a fixed name. A predictable path under a
# shared /tmp is followed through a pre-existing symlink -- verified: with TMPDIR unset this
# fixture overwrote an unrelated file -- and two concurrent runs collide on it.
set -eu
_f=$(mktemp) || exit 1
trap 'rm -f "$_f" 2>/dev/null || :' EXIT
printf 'consumer package.json coverage script\n' > "$_f"
while IFS= read -r _b; do [ -n "$_b" ] || continue; printf 'RECORD: %s\n' "$_b"; done < "$_f"
