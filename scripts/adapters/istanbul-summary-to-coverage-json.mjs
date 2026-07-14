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

// num01 — a finite number in 0..100, or exit 2 (invalid thresholds never silently disable a gate).
function num01(flag, raw) {
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0 || n > 100) fail(`${flag} must be a finite number in 0..100, got '${raw}'`);
  return n;
}
// boolArg — a recognized boolean, or exit 2 (an unrecognized value never becomes a silent false).
function boolArg(flag, raw) {
  const s = String(raw).toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(s)) return true;
  if (['0', 'false', 'no', 'off'].includes(s)) return false;
  fail(`${flag} must be a boolean, got '${raw}'`);
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
    case '--line-min': thr.line_min = num01(a, argv[++i]); break;
    case '--branch-min': thr.branch_min = num01(a, argv[++i]); break;
    case '--method-min': thr.method_min = num01(a, argv[++i]); break;
    case '--class-min': thr.class_min = num01(a, argv[++i]); break;
    case '--baseline': baselineFile = argv[++i]; break;
    case '--fail-on-decrease': failOnDecrease = boolArg(a, argv[++i]); break;
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

// measured(metric): [pct, measured] — Istanbul sets total:0 when nothing to cover. An ABSENT
// metric object (metric not reported) is "not measured"; a PRESENT but malformed metric object
// (non-numeric total/pct) is a hard error (exit 2), never silently coerced to 0.
function measured(m) {
  if (m === undefined || m === null) return [0, false];
  if (typeof m !== 'object' || !Number.isFinite(m.total) || !Number.isFinite(m.pct)) {
    fail('coverage metric requires numeric total and pct');
  }
  if (m.total === 0) return [0, false];
  return [m.pct, true];
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

// An EXPLICITLY configured baseline must be valid: a readable JSON object with at least one
// finite line_percent/branch_percent. Otherwise exit 2 — a broken baseline must not silently
// bypass the regression gate (fail closed), especially with fail_on_decrease enabled.
let regression = false;
let baselineOut = null;
if (baselineFile) {
  if (!existsSync(baselineFile)) fail(`--baseline file not found: ${baselineFile}`);
  let b;
  try {
    b = JSON.parse(readFileSync(baselineFile, 'utf8'));
  } catch (e) {
    fail(`--baseline is not valid JSON: ${e.message}`);
  }
  if (!b || typeof b !== 'object' || Array.isArray(b)) fail('--baseline must be a JSON object');
  const hasLine = b.line_percent !== undefined;
  const hasBranch = b.branch_percent !== undefined;
  if (hasLine && !Number.isFinite(b.line_percent)) fail('--baseline line_percent must be a finite number');
  if (hasBranch && !Number.isFinite(b.branch_percent)) fail('--baseline branch_percent must be a finite number');
  if (!hasLine && !hasBranch) fail('--baseline must contain a finite line_percent and/or branch_percent');
  const bLine = hasLine ? b.line_percent : null;
  const bBranch = hasBranch ? b.branch_percent : null;
  baselineOut = { line_percent: bLine, branch_percent: bBranch };
  if (failOnDecrease) {
    if (bLine !== null && lineM && linePct < bLine) regression = true;
    if (bBranch !== null && brM && branchPct < bBranch) regression = true;
  }
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
