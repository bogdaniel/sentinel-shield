#!/usr/bin/env node
// Sentinel Shield adapter — JUnit XML -> normalized acceptance-tests contract (v2.2.0).
//
// Usage: node junit-to-acceptance-tests.mjs <junit.xml> [<out.json>]
//
// The JS-side twin of scripts/adapters/junit-to-acceptance-tests.php, for JS/TS acceptance
// runners that emit JUnit (Cypress with the junit reporter, Playwright --reporter=junit,
// WebdriverIO, …). JUnit "errors" are counted as FAILURES: an errored scenario did not pass.
//
// Deliberately regex-based rather than pulling in an XML parser dependency: only the
// <testsuite(s)> aggregate ATTRIBUTES are read, which is a fixed, well-specified shape.
// ponytail: attribute scan, not a real parser; swap in a proper XML parser if a producer
// starts nesting aggregates in ways this cannot see.
//
// Honest output: an unreadable input writes status=execution-error with
// missing_acceptance_evidence=true — never a clean zero.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const [input, output = 'reports/raw/acceptance-tests.json'] = process.argv.slice(2);

// write — serialize the report to <output> (creating its directory) and to stdout.
function write(report) {
  mkdirSync(dirname(output), { recursive: true });
  const json = JSON.stringify({ tool: 'acceptance-tests', producer: 'junit', ...report }, null, 2);
  writeFileSync(output, json + '\n');
  process.stdout.write(json + '\n');
}

if (!input) {
  write({ status: 'execution-error', message: 'no input report given', missing_acceptance_evidence: true });
  process.exit(2);
}

let xml;
try {
  xml = readFileSync(input, 'utf8');
} catch (err) {
  write({
    status: 'execution-error',
    message: `could not read JUnit XML: ${err.message}`,
    missing_acceptance_evidence: true,
  });
  process.exit(0);
}

if (!/<testsuites?[\s>]/.test(xml)) {
  write({
    status: 'execution-error',
    message: 'input does not look like JUnit XML (no <testsuite> element)',
    missing_acceptance_evidence: true,
  });
  process.exit(0);
}

// attrs — numeric JUnit attributes of the first matching element, or null when absent.
function attrs(tagRegex) {
  const m = xml.match(tagRegex);
  if (!m) return null;
  const read = (name) => {
    const a = m[0].match(new RegExp(`${name}="(\\d+)"`));
    return a ? Number(a[1]) : 0;
  };
  return { tests: read('tests'), failures: read('failures'), errors: read('errors'), skipped: read('skipped') };
}

// Prefer the <testsuites> aggregate; fall back to summing every <testsuite> open tag.
let totals = attrs(/<testsuites[^>]*\btests="\d+"[^>]*>/);
if (!totals) {
  totals = { tests: 0, failures: 0, errors: 0, skipped: 0 };
  for (const tag of xml.match(/<testsuite\b[^>]*>/g) ?? []) {
    const read = (name) => {
      const a = tag.match(new RegExp(`${name}="(\\d+)"`));
      return a ? Number(a[1]) : 0;
    };
    totals.tests += read('tests');
    totals.failures += read('failures');
    totals.errors += read('errors');
    totals.skipped += read('skipped');
  }
}

const failures = totals.failures + totals.errors;
write({
  status: failures > 0 ? 'findings' : 'pass',
  tests: totals.tests,
  failures,
  skipped: totals.skipped,
  // tests=0 is resolved by the collector, which treats an empty run as MISSING evidence.
  missing_acceptance_evidence: totals.tests === 0,
});
