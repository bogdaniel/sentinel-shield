#!/bin/sh
# VALID: conditional keywords appear only in comments and quoted prose, never as structure.
pass() { printf "PASS: %s\n" "$1"; }
# if this were structural, else it would confuse the parser, fi
pass "a message mentioning if/else/fi as prose"
pass 'single-quoted if else fi prose'
