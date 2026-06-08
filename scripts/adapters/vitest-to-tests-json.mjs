#!/usr/bin/env node
// Sentinel Shield adapter — Vitest JSON -> reports/raw/tests.json.
//
// Reads a Vitest JSON report (`vitest run --reporter=json --outputFile=vitest.json`)
// and writes the canonical Sentinel Shield tests shape: { "failures": N, "errors": N }.
// The `tests` collector maps that to test_failures (failures + errors).
//
// Usage:
//   node vitest-to-tests-json.mjs <vitest.json> [output.json]
//   node vitest-to-tests-json.mjs -            # read JSON from stdin
//   (default output: reports/raw/tests.json)
//
// Exit: 0 ok; 2 missing/invalid input. NEVER fakes success.
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

function fail(msg) {
  process.stderr.write(`[sentinel-shield][error] vitest-adapter: ${msg}\n`);
  process.exit(2);
}

const args = process.argv.slice(2);
if (args.length < 1) {
  process.stderr.write('Usage: node vitest-to-tests-json.mjs <vitest.json|-> [output.json]\n');
  process.exit(2);
}
const input = args[0];
const output = args[1] ?? 'reports/raw/tests.json';

let raw;
try {
  raw = input === '-' ? readFileSync(0, 'utf8') : readFileSync(input, 'utf8');
} catch (e) {
  fail(`could not read input '${input}': ${e.message}`);
}
if (!raw || raw.trim() === '') fail('input is empty');

let data;
try {
  data = JSON.parse(raw);
} catch (e) {
  fail(`input is not valid JSON: ${e.message}`);
}

// Vitest's JSON reporter is Jest-compatible. Prefer top-level aggregate counts.
// failures = failed tests; errors = failed test SUITES (compile/runtime errors).
let failures;
let errors;
if (typeof data.numFailedTests === 'number') {
  failures = data.numFailedTests;
  errors = typeof data.numFailedTestSuites === 'number' ? data.numFailedTestSuites : 0;
} else if (Array.isArray(data.testResults)) {
  // Fallback: derive from per-file results.
  failures = 0;
  errors = 0;
  for (const tr of data.testResults) {
    if (Array.isArray(tr.assertionResults)) {
      failures += tr.assertionResults.filter((a) => a.status === 'failed').length;
    }
    if (tr.status === 'failed' && (!Array.isArray(tr.assertionResults) || tr.assertionResults.length === 0)) {
      errors += 1; // suite failed without producing assertions (e.g. import error)
    }
  }
} else {
  fail('unrecognized Vitest JSON shape (expected numFailedTests or testResults[])');
}

const result = { failures, errors };
const dir = dirname(output);
try {
  if (dir && dir !== '.') mkdirSync(dir, { recursive: true });
  writeFileSync(output, `${JSON.stringify(result, null, 2)}\n`);
} catch (e) {
  fail(`could not write output '${output}': ${e.message}`);
}
process.stderr.write(`[sentinel-shield] vitest-adapter: wrote ${output} (failures=${failures}, errors=${errors})\n`);
