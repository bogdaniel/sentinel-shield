#!/usr/bin/env node
// Sentinel Shield adapter — Cucumber.js JSON -> normalized behavior-specs contract (v2.2.0).
//
// Usage: node cucumber-json-to-behavior-specs.mjs <cucumber.json> [<out.json>]
//
// Cucumber's JSON formatter emits an array of FEATURES, each with an `elements` array of
// scenarios. A scenario FAILS when any of its steps has result.status === "failed".
//
// Honest output: an unreadable or non-array input writes status=execution-error with
// missing_behavior_specification=true — never a clean zero. Counting scenarios says nothing
// about whether they describe the right behavior (docs/bdd-atdd-evidence.md).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const [input, output = 'reports/raw/behavior-specs.json'] = process.argv.slice(2);

// write — serialize the report to <output> (creating its directory) and to stdout.
function write(report) {
  mkdirSync(dirname(output), { recursive: true });
  const json = JSON.stringify({ tool: 'behavior-specs', producer: 'cucumber-js', ...report }, null, 2);
  writeFileSync(output, json + '\n');
  process.stdout.write(json + '\n');
}

if (!input) {
  write({ status: 'execution-error', message: 'no input report given', missing_behavior_specification: true });
  process.exit(2);
}

let doc;
try {
  doc = JSON.parse(readFileSync(input, 'utf8'));
} catch (err) {
  write({
    status: 'execution-error',
    message: `could not read Cucumber JSON: ${err.message}`,
    missing_behavior_specification: true,
  });
  process.exit(0);
}

if (!Array.isArray(doc)) {
  write({
    status: 'execution-error',
    message: 'Cucumber JSON is not an array of features',
    missing_behavior_specification: true,
  });
  process.exit(0);
}

const failures = [];
let scenarioCount = 0;

for (const feature of doc) {
  for (const el of feature?.elements ?? []) {
    // Backgrounds are setup, not behavior descriptions — they must not inflate the count.
    if (el?.type === 'background') continue;
    scenarioCount += 1;
    const failed = (el?.steps ?? []).some((s) => s?.result?.status === 'failed');
    if (failed) failures.push(`${feature?.name ?? 'unknown feature'}: ${el?.name ?? 'unnamed scenario'}`);
  }
}

const specCount = doc.length;
write({
  status: failures.length > 0 ? 'findings' : 'pass',
  spec_count: specCount,
  scenario_count: scenarioCount,
  // Orphan detection needs a spec->implementation map Cucumber's JSON does not carry. Reporting
  // 0 here is a truthful "this producer cannot determine it", per the raw-report contract.
  orphan_behavior_specifications: 0,
  missing_behavior_specification: specCount === 0 && scenarioCount === 0,
  failures,
});
