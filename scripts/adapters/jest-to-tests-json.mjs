#!/usr/bin/env node
// Sentinel Shield adapter — Jest JSON -> reports/raw/tests.json.
//
// Reads a Jest JSON report (`jest --json --outputFile=jest.json`) and writes the
// canonical Sentinel Shield tests shape: { "failures": N, "errors": N }. The `tests`
// collector maps that to test_failures (failures + errors).
//
// Usage:
//   node jest-to-tests-json.mjs <jest.json> [output.json]
//   node jest-to-tests-json.mjs -            # read JSON from stdin
//   (default output: reports/raw/tests.json)
//
// Exit: 0 ok; 2 missing/invalid input. NEVER fakes success.
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

function fail(msg) {
  process.stderr.write(`[sentinel-shield][error] jest-adapter: ${msg}\n`);
  process.exit(2);
}

const args = process.argv.slice(2);
if (args.length < 1) {
  process.stderr.write('Usage: node jest-to-tests-json.mjs <jest.json|-> [output.json]\n');
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

// Jest top-level aggregates: numFailedTests + numRuntimeErrorTestSuites (suites that
// could not run, e.g. import/transform errors) -> errors.
let failures;
let errors;
if (typeof data.numFailedTests === 'number') {
  failures = data.numFailedTests;
  errors = typeof data.numRuntimeErrorTestSuites === 'number' ? data.numRuntimeErrorTestSuites : 0;
} else if (Array.isArray(data.testResults)) {
  failures = 0;
  errors = 0;
  for (const tr of data.testResults) {
    if (Array.isArray(tr.assertionResults)) {
      failures += tr.assertionResults.filter((a) => a.status === 'failed').length;
    }
    if (tr.status === 'failed' && (!Array.isArray(tr.assertionResults) || tr.assertionResults.length === 0)) {
      errors += 1;
    }
  }
} else {
  fail('unrecognized Jest JSON shape (expected numFailedTests or testResults[])');
}

const result = { failures, errors };
const dir = dirname(output);
try {
  if (dir && dir !== '.') mkdirSync(dir, { recursive: true });
  writeFileSync(output, `${JSON.stringify(result, null, 2)}\n`);
} catch (e) {
  fail(`could not write output '${output}': ${e.message}`);
}
process.stderr.write(`[sentinel-shield] jest-adapter: wrote ${output} (failures=${failures}, errors=${errors})\n`);
