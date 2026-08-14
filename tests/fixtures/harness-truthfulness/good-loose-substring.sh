#!/bin/sh
# Anchored on the exact assignment, so a rename fails.
grep -qE '^[[:space:]]*SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION:[[:space:]]' "$1" || exit 1
