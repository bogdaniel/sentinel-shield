#!/usr/bin/env node
// Sentinel Shield — Node test report -> tests.json normalizer.
//
// Reads a Vitest or Jest JSON report and writes the shape the `tests` collector
// expects:
//     { "failures": <int>, "errors": <int> }
//
// Usage:
//   node scripts/sentinel/vitest-to-tests-json.mjs [input.json] [output.json]
//   defaults: reports/raw/node-tests.json -> reports/raw/tests.json
//
// Produce the input first, e.g.:
//   npx vitest run --reporter=json --outputFile=reports/raw/node-tests.json
//   npx jest --json --outputFile=reports/raw/node-tests.json
//
// Exit codes: 0 ok, 2 input missing/unreadable/invalid. It does NOT fake success
// when the report is absent — a missing report is an error, not "0 failures".
import { readFileSync, writeFileSync } from "node:fs";

const input = process.argv[2] ?? "reports/raw/node-tests.json";
const output = process.argv[3] ?? "reports/raw/tests.json";

let raw;
try {
  raw = readFileSync(input, "utf8");
} catch {
  console.error(`[sentinel-shield][error] Node test report not found/readable: ${input}`);
  process.exit(2);
}

let data;
try {
  data = JSON.parse(raw);
} catch {
  console.error(`[sentinel-shield][error] invalid JSON: ${input}`);
  process.exit(2);
}

// Vitest and Jest JSON reporters both expose these aggregate counts at the root.
const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);
const failures = num(data.numFailedTests ?? data.numFailedAssertions);
const errors = num(data.numFailedTestSuites ?? data.numRuntimeErrorTestSuites);

writeFileSync(output, JSON.stringify({ failures, errors }, null, 2) + "\n");
console.error(`[sentinel-shield] wrote ${output} (failures=${failures}, errors=${errors})`);
