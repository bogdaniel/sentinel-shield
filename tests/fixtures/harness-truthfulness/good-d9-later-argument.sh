#!/bin/sh
# VALID: dangerous-looking syntax appears only in a LATER argument, not the diagnostic.
log_warn() { printf "WARN: %s %s\n" "$1" "$2"; }
log_warn "safe diagnostic" "second arg with `date`"
