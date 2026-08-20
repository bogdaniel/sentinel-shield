#!/bin/sh
# FIXTURE for tests/prod/307. LEGACY SHAPE, runnable: IFS word-splitting destroys a multi-word
# record. Prints one line per iteration so the count is observable.
set -eu
_backends='consumer package.json coverage script'
_blist=$(printf '%s' "$_backends" | tr ',' ' ')
for _b in $_blist; do printf 'RECORD: %s\n' "$_b"; done
