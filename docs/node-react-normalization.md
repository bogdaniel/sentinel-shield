# Node / React Normalization

This page documents how Node/React quality signals — TypeScript errors, ESLint
findings, and test failures — become enforceable Sentinel Shield summary keys. It
complements [`scanner-normalization.md`](scanner-normalization.md) (the general
collector contract) and [`security-summary-schema.md`](security-summary-schema.md).

Collectors: [`scripts/collectors/typescript.sh`](../scripts/collectors/typescript.sh),
[`scripts/collectors/eslint.sh`](../scripts/collectors/eslint.sh), and the existing
[`scripts/collectors/tests.sh`](../scripts/collectors/tests.sh) /
[`scripts/collectors/npm-audit.sh`](../scripts/collectors/npm-audit.sh).

---

## TypeScript

`tsc --noEmit` does not emit JSON, so the **normalized** raw input is:

```json
{ "errors": 0 }
```

Write it to `reports/raw/typescript.json`. The CI step counts `error TS####` lines
on failure and writes the real count; on success it writes `{"errors":0}`.

| Input | → summary key | Status |
| --- | --- | --- |
| `.errors` | `type_errors` | `fail` if `errors > 0`, else `pass` |

Missing file → `unavailable` (count 0). Invalid JSON or non-integer `.errors` →
error (exit 2). Fixture: [`templates/raw/typescript.example.json`](../templates/raw/typescript.example.json).

---

## ESLint

Input is ESLint's native JSON (`eslint . --format json`): an array of file results,
each with `errorCount`, `warningCount`, and `messages[]`.

```json
[
  {
    "filePath": "resources/js/App.tsx",
    "messages": [
      { "ruleId": "security/detect-object-injection", "severity": 2, "message": "..." }
    ],
    "errorCount": 1,
    "warningCount": 0
  }
]
```

**First-pass, conservative, tunable mapping:**

| Source | → summary key |
| --- | --- |
| total `errorCount` | `type_errors` |
| total `warningCount` | `medium_vulnerabilities` |
| severity-2 messages with `ruleId` starting `security/` or `no-unsanitized/` | `high_vulnerabilities` |

> **Honest caveat:** ESLint severity is not a security severity. This mapping is a
> pragmatic first pass, not a precise security-severity model. A security-rule error
> counts toward **both** `type_errors` (it is an `errorCount`) and
> `high_vulnerabilities` (it is a security finding) — deliberately conservative so
> both gates can fire. Tune the rule-prefix list and the double-count behavior in
> your fork. The collector is the single place to change it.

Status: `fail` if any error or security error; `warn` if only warnings; else `pass`.
Missing file → `unavailable`; invalid JSON → error; `[]` → `pass`. Fixture:
[`templates/raw/eslint.example.json`](../templates/raw/eslint.example.json).

`tool_report`: `{ status, errors, warnings, security_errors }`.

---

## Node test normalization (Vitest / Jest)

The `tests` collector expects:

```json
{ "failures": 0, "errors": 0 }
```

at `reports/raw/tests.json`. Sentinel Shield does **not** run your test runner.
Produce a JSON report, then normalize it — example helper:
[`examples/laravel-react-docker/scripts/sentinel/vitest-to-tests-json.mjs`](../examples/laravel-react-docker/scripts/sentinel/vitest-to-tests-json.mjs).

```sh
# Vitest
npx vitest run --reporter=json --outputFile=reports/raw/node-tests.json
node scripts/sentinel/vitest-to-tests-json.mjs reports/raw/node-tests.json reports/raw/tests.json

# Jest
npx jest --json --outputFile=reports/raw/node-tests.json
node scripts/sentinel/vitest-to-tests-json.mjs reports/raw/node-tests.json reports/raw/tests.json
```

The normalizer maps `numFailedTests → failures` and
`numFailedTestSuites/numRuntimeErrorTestSuites → errors`. A missing report is an
**error** (exit 2), never silent "0 failures". **Do not fake `tests.json`.**

---

## How to wire npm scripts

See [`examples/laravel-react-docker/package.json`](../examples/laravel-react-docker/package.json):

```json
{
  "scripts": {
    "sentinel:npm-audit": "npm audit --json > reports/raw/npm-audit.json",
    "sentinel:typescript": "tsc --noEmit && echo '{\"errors\":0}' > reports/raw/typescript.json",
    "sentinel:eslint": "eslint . --format json --output-file reports/raw/eslint.json || true",
    "sentinel:test:node": "node scripts/sentinel/vitest-to-tests-json.mjs reports/raw/node-tests.json reports/raw/tests.json"
  }
}
```

In CI prefer capturing the real `tsc` error count on failure (the workflow step does
this) rather than the simple local script, which only records 0 on success.

---

## Gates affected

| Summary key | Gate flag | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- | --- |
| `type_errors` (tsc + eslint errors) | `*_TYPE_ERRORS` | off | block | block | block |
| `test_failures` (vitest/jest) | `*_TEST_FAILURES` | off | block | block | block |
| `medium_vulnerabilities` (eslint warnings) | `*_MEDIUM_VULNERABILITIES` | off | off | block | block |
| `high_vulnerabilities` (eslint security errors) | `*_HIGH_VULNERABILITIES` | off | block | block | block |

---

## Limitations and tuning

- ESLint severity → security severity is approximate; tune the `security/` /
  `no-unsanitized/` prefix list and whether security errors also count as
  `type_errors`.
- TypeScript input is a normalized count, not the raw compiler stream; the count's
  accuracy depends on the producing step.
- The Node test normalizer covers Vitest/Jest aggregate fields; other runners need
  their own normalizer to the same `{ failures, errors }` shape.
- `knip` and other Node tools are not yet collected.
