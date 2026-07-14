#!/usr/bin/env node
// Sentinel Shield adapter — Istanbul/Vitest/Jest coverage-summary.json -> coverage.json.
//
// Reads the standard Istanbul `coverage/coverage-summary.json` (`.total.{lines,branches,
// functions,statements}.pct`) and writes the canonical Sentinel Shield coverage shape
// consumed by scripts/collectors/coverage.sh:
//   { "tool":"coverage", "status":"pass|findings", "line_percent":.., "branch_percent":..,
//     "method_percent":.., "class_percent":.., "thresholds":{..}, "violations":N,
//     "regression":bool, "baseline":{..} }
//
// method_percent maps to Istanbul functions.pct; Istanbul has no class metric, so
// class_percent is 0 (never gated unless class_min > 0, which cannot be measured here).
// A metric whose denominator is 0 (`total === 0`) is NOT MEASURED: percent 0, never a
// violation.
//
// Usage:
//   node istanbul-summary-to-coverage-json.mjs <coverage-summary.json|-> \
//       [--line-min N] [--branch-min N] [--method-min N] [--class-min N] \
//       [--baseline <file.json>] [--fail-on-decrease true|false] [--output <path>]
//   (default output: stdout)
//
// Exit: 0 ok; 2 missing/invalid input. NEVER fakes success.
import { readFileSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';

function fail(msg) {
  process.stderr.write(`[sentinel-shield][error] istanbul-adapter: ${msg}\n`);
  process.exit(2);
}

const argv = process.argv.slice(2);
if (argv.length < 1) {
  process.stderr.write('Usage: node istanbul-summary-to-coverage-json.mjs <coverage-summary.json|-> [--line-min N] [--branch-min N] [--method-min N] [--class-min N] [--baseline <file>] [--fail-on-decrease true|false] [--output <path>]\n');
  process.exit(2);
}

const input = argv[0];
let output = '-';
const thr = { line_min: 0, branch_min: 0, method_min: 0, class_min: 0 };
let baselineFile = '';
let failOnDecrease = false;

for (let i = 1; i < argv.length; i++) {
  const a = argv[i];
  const withVal = ['--line-min', '--branch-min', '--method-min', '--class-min', '--baseline', '--fail-on-decrease', '--output'];
  if (withVal.includes(a) && i + 1 >= argv.length) fail(`${a} requires a value`);
  switch (a) {
    case '--line-min': thr.line_min = Number(argv[++i]); break;
    case '--branch-min': thr.branch_min = Number(argv[++i]); break;
    case '--method-min': thr.method_min = Number(argv[++i]); break;
    case '--class-min': thr.class_min = Number(argv[++i]); break;
    case '--baseline': baselineFile = argv[++i]; break;
    case '--fail-on-decrease': failOnDecrease = ['1', 'true', 'yes', 'on'].includes(String(argv[++i]).toLowerCase()); break;
    case '--output': output = argv[++i]; break;
    default: fail(`unknown argument: ${a}`);
  }
}

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
const total = data && data.total;
if (!total || typeof total !== 'object') fail('unrecognized coverage-summary JSON (expected .total)');

// measured(metric): [pct, measured] — Istanbul sets total:0 when nothing to cover.
function measured(m) {
  if (!m || typeof m !== 'object') return [0, false];
  const denom = typeof m.total === 'number' ? m.total : null;
  const pct = typeof m.pct === 'number' ? m.pct : 0;
  if (denom === 0) return [0, false];
  return [pct, true];
}
const [linePct, lineM] = measured(total.lines);
const [branchPct, brM] = measured(total.branches);
const [methodPct, mM] = measured(total.functions);
const classPct = 0, cM = false;

let violations = 0;
if (lineM && thr.line_min > 0 && linePct < thr.line_min) violations++;
if (brM && thr.branch_min > 0 && branchPct < thr.branch_min) violations++;
if (mM && thr.method_min > 0 && methodPct < thr.method_min) violations++;
if (cM && thr.class_min > 0 && classPct < thr.class_min) violations++;

let regression = false;
let baselineOut = null;
if (baselineFile && existsSync(baselineFile)) {
  try {
    const b = JSON.parse(readFileSync(baselineFile, 'utf8'));
    if (b && typeof b === 'object') {
      const bLine = typeof b.line_percent === 'number' ? b.line_percent : null;
      const bBranch = typeof b.branch_percent === 'number' ? b.branch_percent : null;
      baselineOut = { line_percent: bLine, branch_percent: bBranch };
      if (failOnDecrease) {
        if (bLine !== null && lineM && linePct < bLine) regression = true;
        if (bBranch !== null && brM && branchPct < bBranch) regression = true;
      }
    }
  } catch { /* a malformed baseline is treated as "no baseline" (never a fake regression). */ }
}

const result = {
  tool: 'coverage',
  status: (violations > 0 || regression) ? 'findings' : 'pass',
  line_percent: linePct,
  branch_percent: branchPct,
  method_percent: methodPct,
  class_percent: classPct,
  thresholds: thr,
  violations,
  regression,
};
if (baselineOut !== null) result.baseline = baselineOut;

const json = `${JSON.stringify(result, null, 2)}\n`;
if (output === '-') {
  process.stdout.write(json);
} else {
  try {
    const dir = dirname(output);
    if (dir && dir !== '.') mkdirSync(dir, { recursive: true });
    writeFileSync(output, json);
  } catch (e) {
    fail(`could not write output '${output}': ${e.message}`);
  }
  process.stderr.write(`[sentinel-shield] istanbul-adapter: wrote ${output} (line=${linePct}%, branch=${branchPct}%, violations=${violations}, regression=${regression})\n`);
}
