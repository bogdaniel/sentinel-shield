#!/bin/sh
# Sentinel Shield — print the AI-assisted install prompt to stdout (v1.9.0).
# ADDITIVE, read-only: no network, no mutation, no config changes.
#   exit 0 -> prompt printed
#   exit 2 -> prompt file missing
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROMPT="$ROOT/prompts/install-sentinel-shield.md"
if [ ! -f "$PROMPT" ]; then
  printf '%s\n' "[sentinel-shield][error] prompt not found: $PROMPT" >&2
  exit 2
fi
cat "$PROMPT"
