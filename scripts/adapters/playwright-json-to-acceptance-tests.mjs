#!/usr/bin/env node
// Sentinel Shield adapter — Playwright JSON -> normalized acceptance-tests contract (v2.2.0).
//
// Usage: node playwright-json-to-acceptance-tests.mjs <playwright.json> [<out.json>]
//
// Playwright's `json` reporter emits nested suites; each spec has `tests[].results[].status`
// and `tests[].status` ("expected" | "unexpected" | "flaky" | "skipped"). A spec counts as a
// FAILURE when its outcome is "unexpected"; "flaky" is reported separately but not failed
// (it passed on retry) so a flaky suite does not silently become a red gate.
//
// Honest output: an unreadable input writes status=execution-error with
// missing_acceptance_evidence=true — never a clean zero. Passing acceptance tests do not mean
// a product owner accepted anything (docs/acceptance-test-evidence.md).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const [input, output = 'reports/raw/acceptance-tests.json'] = process.argv.slice(2);

// write — serialize the report to <output> (creating its directory) and to stdout.
function write(report) {
  mkdirSync(dirname(output), { recursive: true });
  const json = JSON.stringify({ tool: 'acceptance-tests', producer: 'playwright', ...report }, null, 2);
  writeFileSync(output, json + '\n');
  process.stdout.write(json + '\n');
}

if (!input) {
  write({ status: 'execution-error', message: 'no input report given', missing_acceptance_evidence: true });
  process.exit(2);
}

let doc;
try {
  doc = JSON.parse(readFileSync(input, 'utf8'));
} catch (err) {
  write({
    status: 'execution-error',
    message: `could not read Playwright JSON: ${err.message}`,
    missing_acceptance_evidence: true,
  });
  process.exit(0);
}

let tests = 0;
let failures = 0;
let skipped = 0;
let flaky = 0;
const failed = [];

// walk — Playwright suites nest arbitrarily deep; recurse over suites and their specs.
function walk(suite) {
  for (const spec of suite?.specs ?? []) {
    for (const test of spec?.tests ?? []) {
      tests += 1;
      switch (test?.status) {
        case 'unexpected':
          failures += 1;
          failed.push(spec?.title ?? 'unnamed spec');
          break;
        case 'skipped':
          skipped += 1;
          break;
        case 'flaky':
          flaky += 1;
          break;
        default:
          break;
      }
    }
  }
  for (const child of suite?.suites ?? []) walk(child);
}

for (const suite of doc?.suites ?? []) walk(suite);

write({
  status: failures > 0 ? 'findings' : 'pass',
  tests,
  failures,
  skipped,
  flaky,
  // tests=0 is resolved by the collector, which treats an empty run as MISSING evidence.
  missing_acceptance_evidence: tests === 0,
  failed_tests: failed,
});
