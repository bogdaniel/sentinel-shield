#!/bin/sh
# Example architecture-test PRODUCER for Sentinel Shield.
#
# Sentinel Shield does NOT run your architecture suite for you. Any test runner
# (a PHPUnit/PHPArkitect rule set, a custom Node dependency-cruiser check, a
# bespoke shell linter, etc.) is the *producer*: it decides what a "violation"
# is and writes the raw JSON contract that the collector then consumes.
#
# Raw contract (what the collector reads):
#   {"violations": N}                         # canonical: a single integer count
#   {"failures": [ ... ], "tests": N}         # fallback: array length is counted
# The collector parses `(.violations // .failures // 0)`: `.violations` wins when
# present (even 0); otherwise a `.failures` array is counted by length.
#
# This script is a stand-in producer. It emits a deterministic violations.json so
# the contract is reproducible without installing a real architecture runner. In a
# real project you would replace the body with the JSON your runner emits.
#
# Usage:
#   sh tests/fixtures/architecture-v025/example-producer.sh > reports/raw/architecture-tests.json
#   sh scripts/collectors/architecture-tests.sh --input reports/raw/architecture-tests.json
set -eu

# --- Stand in for a real architecture suite -------------------------------------
# Imagine each check below is one assertion your runner evaluated. Here we hardcode
# two failing boundary rules so the output is deterministic and testable.
cat <<'JSON'
{
  "tool": "architecture-tests",
  "tests": 6,
  "passed": 4,
  "violations": 2,
  "failures": [
    {
      "rule": "domain-must-not-depend-on-infrastructure",
      "from": "App\\Domain\\Order\\Order",
      "to": "App\\Infrastructure\\Persistence\\DoctrineOrderRepository",
      "message": "Domain depends on Infrastructure"
    },
    {
      "rule": "presentation-must-not-depend-on-infrastructure",
      "from": "App\\Http\\Controller\\CheckoutController",
      "to": "App\\Infrastructure\\Http\\StripeClient",
      "message": "Presentation reaches Infrastructure directly"
    }
  ]
}
JSON
