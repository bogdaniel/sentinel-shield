# Profile Tool Policy — the canonical contract

This is the human + machine contract for how a Sentinel Shield **profile** declares
the tools it expects, how those tools are detected, installed, configured, executed,
and finally **gated**. It is the source of truth that every downstream agent and
script (installer, sync, runners, `build-security-summary.sh`, `enforce-gates.sh`)
aligns to.

Machine schemas:

- `schemas/tool-policy.schema.json` — the per-tool policy object and the profile-level
  `tools` map (`$defs.toolPolicy`, `$defs.toolsMap`).
- `profiles/profile.manifest.schema.json` — adds optional `tools`, `extends`,
  `tool_policy_version` to a profile manifest.
- `schemas/installation.schema.json` — `.sentinel-shield/installation.json`.
- `schemas/tool-policy-override.schema.json` — project `.sentinel-shield/tool-policy.yaml`.
- `schemas/security-summary.schema.json` — per-tool `status` enum (the result states).

Tool **keys** are the keys of `TOOL_TABLE` in `scripts/build-security-summary.sh`
(e.g. `phpstan`, `psalm`, `tests`, `gitleaks`, `third-party-semgrep`).

---

## 1. Vocabulary

### Policies (what the profile *demands* of a tool)

| policy        | meaning                                                                                          |
| ------------- | ------------------------------------------------------------------------------------------------ |
| `required`    | Must be present, configured, and pass. Absence/error **fails the build**.                         |
| `recommended` | Should be present. Absence **warns**, does not fail.                                              |
| `optional`    | Nice to have. Absence is **informational** only.                                                 |
| `one-of`      | Satisfies a requirement *together with* its `alternatives` (e.g. `pest` \| `phpunit`). At least one of the set must be present and pass. |
| `disabled`    | Deliberately turned off for this profile/project. Never run; never gates.                         |
| `external`    | Provided/run outside Sentinel Shield (results may be imported). Not installed or executed by us.  |

**Precedence** (when a project override or `extends` merge conflicts), as ranked by
the canonical resolver (`scripts/lib/effective-profile.sh`):
`required > one-of > recommended > optional > external > disabled`.

### States (what actually *happened* to a tool — per-tool `status` in the summary)

| state             | meaning                                                            |
| ----------------- | ----------------------------------------------------------------- |
| `pass`            | Ran successfully, zero findings.                                   |
| `findings`        | Ran successfully, found issues (the JSON carries the counts).      |
| `fail`            | Ran, and the result fails the gate for its policy.                 |
| `unavailable`     | Tool not detected / no valid report produced. **Not** zero.       |
| `not-configured`  | Tool present but no config file where one is required.             |
| `not-applicable`  | The stack this tool targets is absent (e.g. no Dockerfile).       |
| `execution-error` | Tool crashed or produced invalid output.                          |
| `disabled`        | Turned off by policy; intentionally not run.                      |

(`skipped` and `warn` remain valid legacy values for backward compatibility.)

### `missing_behavior` (per-tool override of the absence reaction)

`fail` / `warn` / `info` / `skip`. Defaults follow policy: `required→fail`,
`recommended→warn`, `optional→info`, `disabled`/`external`→`skip`.

---

## 2. Lifecycle

A tool moves through these stages; each stage can short-circuit to a state:

```
declared → detected → compatible → installed → configured → executed → reported → gate-enforced
```

1. **declared** — present in the profile `tools` map (and any `extends` bases).
2. **detected** — one of `executable[]` is found (first match wins), e.g.
   `vendor/bin/phpstan` then `phpstan`. Not found ⇒ `unavailable`.
3. **compatible** — package `compatibility` (`auto` or a constraint) resolves
   against the project runtime. Incompatible ⇒ `unavailable` (with a reason).
4. **installed** — `packages[]` are installed in the right `scope` (dev/prod).
5. **configured** — the `config.path` exists per its `classification`. Required
   tool with no usable config ⇒ `not-configured`.
6. **executed** — the `runner` runs the tool **without mutating the project** and
   writes the normalized report to `report` (under `reports/raw/`). A crash or
   invalid output ⇒ `execution-error`. The runner still **exits 0** — the JSON is
   the signal — and on absence leaves the report **absent** (never a fake clean 0).
7. **reported** — `build-security-summary.sh` reads `reports/raw/<tool>.json`,
   folds counts into the `summary`, and records the per-tool `status`.
8. **gate-enforced** — `enforce-gates.sh` applies the policy + state rules below.

---

## 3. The state machine (policy × state ⇒ outcome)

Hard rules — these MUST hold:

- `required` + `unavailable` ⇒ **config failure** (the tool was demanded but is missing).
- `required` + `not-configured` ⇒ **config failure**.
- `required` + `execution-error` ⇒ **gate failure**.
- `required` + `findings`/`fail` ⇒ **gate failure**.
- `required` + `pass` ⇒ pass.
- `recommended` + `unavailable` ⇒ **warning** (never fails).
- `recommended` + `execution-error` ⇒ **warning**.
- `optional` + `unavailable` ⇒ **info** only.
- `one-of` ⇒ evaluate the set (`self` + `alternatives`): if **none** present ⇒
  treat as `required`/`recommended` absence per the group's policy; if at least one
  present, the group passes when one passes (others may be `not-applicable`).
- `disabled` / `external` ⇒ never executed by us; never gates (`external` results
  may be imported and counted, but absence is not our failure).
- **Zero findings are legitimate ONLY after a successful execution** (`pass`).
- **NEVER convert `unavailable` (or `execution-error`) into a `0`/clean report.**
  An absent tool stays absent; the gate reasons about the policy, not a fake count.

Outcome → exit semantics live in `enforce-gates.sh`; this doc fixes the
policy/state truth table it implements.

---

## 4. Worked example

A `laravel` profile manifest fragment. `phpstan` is required, `larastan` is the
package that provides PHPStan's Laravel rules, and `php-tests` is a `one-of` over
`pest`/`phpunit`.

> **Independent test groups (v2).** PHP and JavaScript test requirements are
> **separate** one-of groups — `php-tests` (`pest`|`phpunit`, report
> `reports/raw/tests.json`) and `js-tests` (`vitest`|`jest`, report
> `reports/raw/js-tests.json`). They never share a key, so a PHP test runner can
> never satisfy a JS requirement (or vice versa). `laravel`/`symfony`/`php-library`
> require `php-tests`; `node`/`react` require `js-tests`; a combined profile such
> as `laravel-react-docker` requires **both**, independently. Both reports feed the
> `test_failures` gate.

```yaml
# profiles/laravel/profile.manifest.json  (shown as YAML for readability)
profile: laravel
tool_policy_version: 2
extends: [php-base]
tools:
  phpstan:
    policy: required
    category: static-analysis
    packages:
      - { name: phpstan/phpstan, scope: dev, compatibility: auto }
      - { name: larastan/larastan, scope: dev, compatibility: auto }
    executable: ["vendor/bin/phpstan", "phpstan"]
    runner: scripts/runners/laravel-phpstan.sh
    report: reports/raw/phpstan.json
    missing_behavior: fail
    execution: { pr: true, main: true, scheduled: false }
    config: { path: phpstan.neon, classification: never-touch }

  php-tests:                 # JS projects use a separate `js-tests` group (vitest|jest)
    policy: one-of
    category: tests
    alternatives: [pest, phpunit]
    report: reports/raw/tests.json
    execution: { pr: true, main: true, scheduled: false }

  pest:
    policy: one-of
    category: tests
    packages: [{ name: pestphp/pest, scope: dev, compatibility: auto }]
    executable: ["vendor/bin/pest"]
    alternatives: [phpunit]
    report: reports/raw/tests.json

  phpunit:
    policy: one-of
    category: tests
    packages: [{ name: phpunit/phpunit, scope: dev, compatibility: auto }]
    executable: ["vendor/bin/phpunit"]
    alternatives: [pest]
    report: reports/raw/tests.json
```

Equivalent JSON (what actually ships in the manifest's `tools` object):

```json
{
  "phpstan": {
    "policy": "required",
    "category": "static-analysis",
    "packages": [
      { "name": "phpstan/phpstan", "scope": "dev", "compatibility": "auto" },
      { "name": "larastan/larastan", "scope": "dev", "compatibility": "auto" }
    ],
    "executable": ["vendor/bin/phpstan", "phpstan"],
    "runner": "scripts/runners/laravel-phpstan.sh",
    "report": "reports/raw/phpstan.json",
    "missing_behavior": "fail",
    "execution": { "pr": true, "main": true, "scheduled": false },
    "config": { "path": "phpstan.neon", "classification": "never-touch" }
  },
  "tests": {
    "policy": "one-of",
    "category": "tests",
    "alternatives": ["pest", "phpunit"],
    "report": "reports/raw/tests.json",
    "execution": { "pr": true, "main": true, "scheduled": false }
  }
}
```

How it gates:

- PHPStan binary absent ⇒ `phpstan` is `unavailable` ⇒ **config failure** (required).
- `phpstan.neon` missing ⇒ `not-configured` ⇒ **config failure** (required).
- PHPStan runs, 3 errors ⇒ `findings` (count 3) ⇒ **gate failure** (required).
- PHPStan runs, 0 errors ⇒ `pass`.
- Neither Pest nor PHPUnit present ⇒ the `tests` group is `unavailable` ⇒ gate per
  the group policy. If `pest` is present and passes, the group passes even though
  `phpunit` is `not-applicable`.

### Project override

`.sentinel-shield/tool-policy.yaml` may only tune the **policy** of a declared tool:

```yaml
tools:
  scorecard: { policy: optional }     # downgrade a noisy recommended check
  # gitleaks: { policy: disabled }    # REJECTED: secrets scanners (gitleaks,
                                       # trufflehog) are non-suppressible — the
                                       # resolver fails closed (exit 2)
  # phpstan:  { policy: disabled }    # allowed only if not non-suppressible;
                                       # cannot turn an execution-error into pass
```

The resolver applies precedence
`required > one-of > recommended > optional > external > disabled`, refuses to set a
non-suppressible control (`gitleaks`, `trufflehog`) to `disabled` (fail-closed,
exit 2), and refuses to convert `execution-error` to `pass`.

### Disabling a required control (control-waiver, not `disabled_tools`)

`tool-policy.yaml` cannot silence a **required** control by flipping it to
`disabled`: a required tool recorded as disabled in `installation.json`
(`disabled_tools`) still surfaces as `status: disabled` and **fails the gate**
unless covered by an unexpired **control-waiver**. A control-waiver lives in
`.sentinel-shield/control-waivers.json` ([schema](../schemas/control-waiver.schema.json)),
is owner-bound, justified, dated, expiring, and issue-linked, and is consumed by
`enforce-gates.sh`. It only downgrades a required-tool failure
(`unavailable`/`not-configured`/`disabled`) to a **prominently-reported, time-boxed
waiver** — it does **not** suppress findings (use accepted-risks for finding gates)
and is never auto-applied. Non-suppressible secrets scanners cannot be waived this
way.

## 4a. Engineering-quality tool policies (v2.1)

> **Unreleased, additive engine capability** — **not** part of `v2.0.1`/`v2.0.0` and **not** a new
> release claim. Full reference: [`engineering-quality-gates.md`](engineering-quality-gates.md).

The engineering-quality family adds tool keys that fold into a **separate counter channel** from
security (never mixed into `*_vulnerabilities`). They obey the same policy/state machine above:

Tool keys are stack-scoped (`php-*` on PHP profiles, `js-*` on JS profiles) so a combined profile
carries both without collision:

| Tool key | Typical policy | Runner | → gate key |
| --- | --- | --- | --- |
| `php-coverage` / `js-coverage` | `recommended` (coverage is the mandatory quality signal) | `php-coverage.sh` / `js-coverage.sh` (+ `clover-to-coverage-json.php` / `istanbul-summary-to-coverage-json.mjs`) | `coverage_threshold_violations`, `coverage_regression`, `missing_coverage_evidence` |
| `php-complexity` / `js-complexity` | `recommended` (PHP, PHPMD) / `optional` (JS, external) | `phpmd-complexity.sh` | `complexity_violations` |
| `php-duplication` / `js-duplication` | `recommended` | `phpcpd.sh` / `jscpd.sh` | `duplication_violations` |
| `php-mutation` / `js-mutation` | `optional` (slow) | `infection.sh` / `stryker.sh` | `mutation_score_violations` |
| `php-dead-code` / `js-dead-code` | `optional` | `knip.sh` (JS) / external (PHP) | `dead_code_violations` |
| `php-diff-coverage` / `js-diff-coverage` | `recommended` (PHP, deterministic runner) / `external` (JS, normalized input) | `php-diff-coverage.sh` (git diff × Clover via `clover-diff-to-coverage-json.php`) / external | `changed_lines_coverage_violations` |
| `focused-tests` | `recommended` (grep-based, always available) | `focused-tests.sh` | `focused_test_violations`, `skipped_test_marker_violations` |
| `debug-code` | `recommended` (grep-based, always available) | `debug-code.sh` | `debug_code_violations` |
| `source-size` | `recommended` (`wc -l`-based, always available) | `source-size.sh` | `large_file_violations`, `large_function_violations` (best-effort) |

The `tests` group is also extended to emit `test_count` + `skipped_tests`, and the profile builder
(`--profile`) derives the `missing_test_evidence`/`empty_test_suite` booleans from applicable test
stacks. Because `focused-tests`/`debug-code`/`source-size` are grep/`wc -l`-based they are **always
available**, so a clean scan is a real `pass` — not `unavailable`; `source-size` reports
`large_function_violations` as `0` (best-effort/external) until a real per-function counter is dropped
in.

**PR execution.** The **fast** quality tools now run on pull requests (`execution.pr: true`):
`php-coverage`/`php-complexity`/`php-duplication`, `js-coverage`/`js-duplication`, and the new
`php-diff-coverage`/`js-diff-coverage`, `focused-tests`, `debug-code`, and `source-size`. The **slow**
signals `php-mutation`/`js-mutation` and `php-dead-code`/`js-dead-code` stay `execution.pr: false`
(main/scheduled only).

Numeric thresholds and the coverage baseline live in `.sentinel-shield/quality-policy.yaml` (schema
`schemas/quality-policy.schema.json`, template `templates/quality-policy.example.yaml`); an **absent**
policy falls back to documented defaults, a **malformed** one fails closed (exit 2). Absent quality
tools stay `unavailable` (never a fake-clean 0); when the profile declares an APPLICABLE coverage tool
whose report is absent, the builder sets `missing_coverage_evidence` so strict/regulated fail on
ABSENT coverage (not only on bad coverage).

**Stack scoping:** the single-stack base profiles declare only their own stack —
`laravel`/`symfony`/`php-library` carry the `php-*` quality tools, `node`/`react` carry the `js-*`
tools. Only genuinely composed profiles (`node-react`, `laravel-react-docker`, `hardened-enterprise`,
which compose the bases via `extends`) declare **both** stacks; there a combined profile aggregates
them (violations SUM, percentages MINIMUM, regression = 1 if any stack regressed) without one stack
satisfying the other's coverage.

## 4b. Architecture-governance tool policies (v2.1)

> **Unreleased, additive engine capability** — **not** part of `v2.0.1`/`v2.0.0` and **not** a new
> release claim. Full reference: [`architecture-governance.md`](architecture-governance.md).

Sentinel Shield enforces architecture governance through normalized architecture evidence. Deptrac is
the PHP structural-boundary producer. dependency-cruiser and ESLint boundaries are JS/TS producers.
Custom architecture tests can also emit the same contract. These tool keys carry
`category: architecture` and fold into a **separate counter channel** from security (never mixed into
`*_vulnerabilities`). They obey the same policy/state machine above, and the architecture states are
exactly the ones in §1 — `pass`, `findings`, `unavailable`, `not-configured`, `execution-error`,
`disabled`, `not-applicable` — never collapsed into a fake-clean `pass`.

| Tool key | Profiles | Typical policy | Runner | Report | → gate key |
| --- | --- | --- | --- | --- | --- |
| `deptrac` | laravel, symfony, php-library | `recommended` | `deptrac.sh` | `reports/raw/deptrac.json` | `architecture_violations` |
| `php-arkitect` | laravel, symfony, php-library | `optional` | `php-arkitect.sh` | `reports/raw/php-arkitect.json` | `architecture_violations` |
| `php-architecture-tests` | laravel, symfony, php-library | `optional` | `php-architecture-tests.sh` | `reports/raw/php-architecture-tests.json` | `architecture_violations` |
| `dependency-cruiser` | node, react | `recommended` | `dependency-cruiser.sh` | `reports/raw/dependency-cruiser.json` | `architecture_violations` |
| `eslint-boundaries` | node, react | `recommended` | `eslint-boundaries.sh` | `reports/raw/eslint-boundaries.json` | `architecture_violations` |
| `js-architecture-tests` | node, react | `optional` | `js-architecture-tests.sh` | `reports/raw/js-architecture-tests.json` | `architecture_violations` |

`eslint-boundaries` counts **only** architecture-boundary rules (`boundaries/*`,
`import/no-restricted-paths`, `no-restricted-imports`); general ESLint findings map to their own
summary keys through the `eslint` tool key and are never double-counted.

**Evidence expectation.** `required`/`recommended`/`one-of` architecture producers are **expected**:
when the profile declares an APPLICABLE one and no valid report is produced, the builder
(`--profile`) sets `missing_architecture_evidence`, so strict/regulated fail on ABSENT architecture
evidence (not only on bad results). `optional` producers are **opt-in and never** set it. A consuming
project can opt out honestly in `.sentinel-shield/architecture-policy.yaml`
(`architecture.enabled: false` or `architecture.evidence_required: false`) — that is explicit, and it
never fakes a pass.

**PR execution.** The **fast** producers run on pull requests (`execution.pr: true`):
`dependency-cruiser` and `eslint-boundaries`. `deptrac`, `php-arkitect` and the custom architecture
suites run on the **main gate**.

**Stack scoping** works exactly as for the quality tools: `laravel`/`symfony`/`php-library` declare
the PHP producers, `node`/`react` declare the JS/TS producers, and composed profiles carry both — PHP
and JS architecture evidence are independent. Violations SUM across producers;
`architecture_context_count` aggregates as the **maximum** (producers describe the same codebase).

> Architecture tools detect dependency-boundary violations, not the quality of domain modeling
> itself. Architecture governance is supported by engine tests and fixtures. Do not claim real
> consumer proof until a real Laravel/Symfony/Node consumer validation exists.

---

## 5. Control-waivers (`.sentinel-shield/control-waivers.json`)

A control-waiver lets a **required** tool/control be temporarily absent without
the gate failing — it never suppresses *findings* from a tool that ran (use
accepted-risks for findings). Validated by the one shared library
`scripts/lib/control-waivers.sh`, which every consumer (doctor, maturity, gate,
bootstrap, resolver) calls — the SAME file gets the SAME verdict everywhere, and
that verdict does **not** depend on `jq` being on `PATH` (absent → success;
present-but-jq-missing → fail closed; malformed → fail closed).

```json
{ "version": "1",
  "waivers": [
    { "tool": "phpstan", "owner": "alice", "approved_by": "bob",
      "justification": "static-analysis upgrade in flight", "created_at": "2026-08-09",
      "expires_at": "2026-09-08", "tracking_issue": "SEC-123" } ] }
```

Rules (fail closed on any violation):

- `version` **must** be the string `"1"` (unsupported/missing/numeric ⇒ rejected).
- `tool` must match `^[A-Za-z0-9_.-]+$` — a single shell-safe token, so a value can
  never split into multiple waived controls; whitespace/tabs/slashes/`..`/metachars
  are rejected.
- `owner` ≠ `approved_by` (no self-approval — enforced in the validator, not just schema).
- `created_at`/`expires_at` are real calendar dates (`YYYY-MM-DD`), validated with
  POSIX `/bin/sh` arithmetic (portable to `dash`; leading-zero months like `08`/`09`
  are handled). `created_at <= expires_at`.
- A waiver **applies** only while `expires_at >= today` in **UTC** (a waiver expiring
  today is valid through the end of that UTC day); expired waivers validate but do not
  downgrade the control.
