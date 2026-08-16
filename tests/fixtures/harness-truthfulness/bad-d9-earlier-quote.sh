#!/bin/sh
# BROKEN: an earlier unrelated quoted expression, then an unsafe diagnostic.
# A detector starting at the FIRST quote on the line would scan the earlier string and miss it.
fail() { printf "FAIL: %s\n" "$1"; }
_x="harmless"; fail "unsafe `printf oops`"
