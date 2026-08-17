#!/bin/sh
# VALID: helper names appear only in a comment, a grep pattern, and a declaration.
# fail "this is a comment mentioning the helper"
fail() { printf "FAIL: %s\n" "$1"; }
grep -q 'fail "`x`"' /dev/null || true
fail "an ordinary diagnostic"
