#!/bin/sh
# VALID: an earlier quoted expression, then a SAFE diagnostic.
fail() { printf "FAIL: %s\n" "$1"; }
_x="harmless"; fail "a perfectly ordinary message"
