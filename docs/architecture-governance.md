# Architecture Governance (v2.1.0)

Sentinel Shield enforces architecture governance through normalized architecture evidence.
Deptrac is the PHP structural-boundary producer. dependency-cruiser and ESLint boundaries are
JS/TS producers. Custom architecture tests can also emit the same contract.

The gate is producer-agnostic: anything that can emit the normalized architecture report can
feed it — Deptrac, PHPArkitect, dependency-cruiser, ESLint boundary rules, a Pest arch suite, a
Vitest boundary test, or a 20-line script of your own.

```txt
Architecture Governance:
Clean Architecture, DDD boundaries, Hexagonal / Ports & Adapters,
modular-monolith boundaries, frontend feature boundaries,
and generic architecture-test evidence across PHP and JavaScript/TypeScript.
```

## What this does and does not prove

Architecture tools detect **dependency-boundary violations**. They do not prove domain modeling
quality or developer intent.

Sentinel Shield does **not** claim:

- that it proves Clean Architecture by itself;
- that it proves DDD correctness;
- that it replaces architectural review;
- that Deptrac validates BDD/TDD/ATDD.

A green architecture gate means "no declared boundary was crossed in the code we scanned, by the
rules you wrote". Whether those rules describe a good architecture is a human judgement.

Evidence status of the feature itself: **architecture governance is supported by engine tests and
fixtures** (`tests/prod/280-architecture-governance.sh`). Do not claim real consumer proof until a
real Laravel/Symfony/Node consumer validation exists.

## Summary keys

| Key | Type | Meaning |
| --- | --- | --- |
| `architecture_violations` | integer gate | Sum of all architecture-boundary violations across every producer (Deptrac, dependency-cruiser, ESLint boundaries, PHPArkitect, architecture-tests, …). |
| `missing_architecture_evidence` | boolean gate | True when an applicable architecture producer is expected but produced no valid evidence — no report, or status `unavailable` / `not-configured` / `execution-error` / `disabled`. |
| `architecture_rule_count` | informational | Architecture rules evaluated, summed across producers that expose it. |
| `architecture_tool_count` | informational | Producers that emitted valid evidence (status `pass` or `findings`). |
| `architecture_context_count` | informational | Bounded contexts / modules / layers detected or declared. Aggregated as the **maximum** across producers — they describe the same codebase, so summing would double-count. |

All four are optional and additive: an older summary that omits them stays valid, and an absent
key reads as `0` / `false`. Architecture findings are their own channel and are **never** folded
into vulnerability counters.

## Mode defaults

| Gate | report-only | baseline | strict | regulated |
| --- | ---: | ---: | ---: | ---: |
| `architecture_violations` | false | true | true | true |
| `missing_architecture_evidence` | false | false | true | true |

```txt
baseline:
  If architecture evidence exists and reports violations, fail.
  If architecture evidence is absent, do not fail yet.

strict:
  If architecture evidence is expected but missing/unavailable/errored, fail.
  If architecture evidence exists and reports violations, fail.

regulated:
  Same as strict, plus docs require retained raw evidence artifacts
  (reports/raw/*.json kept as release evidence).
```

Override per project in `.sentinel-shield/profile.yaml`:

```yaml
gates:
  mode: strict
  fail_on:
    missing_architecture_evidence: false   # temporary ramp while producers are wired up
```

The resolver emits `SENTINEL_SHIELD_FAIL_ON_MISSING_ARCHITECTURE_EVIDENCE` alongside the other
`SENTINEL_SHIELD_FAIL_ON_*` flags (docs/gate-resolution.md).

## The normalized architecture raw contract

Every producer writes `reports/raw/<producer>.json` in this shape (or a native shape the matching
collector understands):

```json
{
  "tool": "architecture",
  "status": "pass",
  "violations": 0,
  "rule_count": 12,
  "context_count": 4,
  "failures": []
}
```

Failure example:

```json
{
  "tool": "architecture",
  "status": "findings",
  "violations": 2,
  "rule_count": 12,
  "context_count": 4,
  "failures": [
    {
      "rule": "domain-must-not-depend-on-infrastructure",
      "from": "App\\Domain\\Order\\Order",
      "to": "App\\Infrastructure\\Persistence\\DoctrineOrderRepository",
      "message": "Domain layer depends on Infrastructure"
    }
  ]
}
```

Allowed statuses:

```txt
pass
findings
unavailable
not-configured
execution-error
disabled
not-applicable
```

Rules the engine enforces:

- `pass` with `violations: 0` means the suite ran and found no violations.
- `findings` with `violations > 0` means the suite ran and found violations.
- `unavailable`, `not-configured`, `execution-error`, `disabled`, `not-applicable` are preserved —
  never collapsed into a clean pass.
- An unknown status fails closed as `execution-error`.
- A missing or empty raw report becomes `unavailable`.
- Invalid JSON exits 2.
- An unknown native tool shape must not become `pass` — it becomes `execution-error`.

Only `pass` and `findings` count as evidence. "We never ran it" can never read as "we are clean".

## Producers

| Producer | Stack | Runner | Collector | Raw report |
| --- | --- | --- | --- | --- |
| Deptrac | PHP | `scripts/runners/deptrac.sh` | `scripts/collectors/deptrac.sh` | `deptrac.json` |
| PHPArkitect | PHP | `scripts/runners/php-arkitect.sh` | `scripts/collectors/php-arkitect.sh` | `php-arkitect.json` |
| Custom PHP architecture tests | PHP | `scripts/runners/php-architecture-tests.sh` | `scripts/collectors/php-architecture-tests.sh` | `php-architecture-tests.json` |
| dependency-cruiser | JS/TS | `scripts/runners/dependency-cruiser.sh` | `scripts/collectors/dependency-cruiser.sh` | `dependency-cruiser.json` |
| ESLint boundaries | JS/TS | `scripts/runners/eslint-boundaries.sh` | `scripts/collectors/eslint-boundaries.sh` | `eslint-boundaries.json` |
| Custom JS architecture tests | JS/TS | `scripts/runners/js-architecture-tests.sh` | `scripts/collectors/js-architecture-tests.sh` | `js-architecture-tests.json` |
| Generic architecture tests | any | `scripts/runners/architecture-tests.sh` | `scripts/collectors/architecture-tests.sh` | `architecture-tests.json` |

The normalized contract is implemented once in `scripts/collectors/architecture.sh`; the
per-producer collectors are entry points over it, exactly as `php-coverage` / `js-coverage` share
`collectors/coverage.sh`.

### Deptrac

Config detection: `--config`, then `architecture.tools.deptrac.config` from the policy, then
`deptrac.yaml`, `deptrac.yml`, `deptrac.php`. Binary detection: `vendor/bin/deptrac`, then a global
`deptrac`. Missing binary reports `unavailable`; missing config reports `not-configured`; a run that
produces no valid JSON reports `execution-error`. Native Deptrac output is preserved verbatim
(annotated with `producer`, `config`, `tool_version`); the collector reads either the native shape
or the normalized contract, and an unrecognized shape fails closed.

### ESLint boundaries

Only architecture-boundary rules are counted, so general lint findings are not double-charged as
architecture violations:

```txt
boundaries/*
import/no-restricted-paths
no-restricted-imports
```

### dependency-cruiser

Expected command:

```txt
npx depcruise src --output-type json
```

The package manager is detected from the lockfile — `package-lock.json` → npm, `pnpm-lock.yaml` →
pnpm, `yarn.lock` → yarn — so `npx` is never forced on a pnpm/yarn project.

### Custom architecture tests

Give the runner a command, either through the policy or the environment:

```yaml
architecture:
  tools:
    architecture_tests:
      command: "npm run test:architecture"
```

```env
SENTINEL_SHIELD_ARCH_TEST_CMD=          # PHP / generic
SENTINEL_SHIELD_PHP_ARCH_TEST_CMD=      # PHP-specific override
SENTINEL_SHIELD_JS_ARCH_TEST_CMD=       # JS/TS
```

The command must produce `reports/raw/<producer>.json` or print contract JSON on stdout. No
command → `unavailable`. Command fails without JSON → `execution-error`. Command passes with valid
JSON → normalized.

## Architecture policy

Copy `templates/architecture-policy.example.yaml` to `.sentinel-shield/architecture-policy.yaml`:

```yaml
architecture:
  enabled: true
  style: clean-architecture
  evidence_required: true

  bounded_contexts:
    enabled: true
    paths:
      - src
      - app

  tools:
    deptrac:
      enabled: true
      config: deptrac.yaml
    php_arkitect:
      enabled: false
      config: phparkitect.php
    architecture_tests:
      enabled: false
    dependency_cruiser:
      enabled: true
      config: .dependency-cruiser.js
    eslint_boundaries:
      enabled: true
      config: eslint.config.js
```

Loader behavior (`scripts/lib/architecture-policy.sh`), same strategy as the quality-policy loader:

- POSIX sh; mikefarah `yq` v4 is used when available but is **not required**.
- Without yq, a canonical (2-space, no anchors/aliases/inline collections/block scalars) file is
  parsed by a limited awk flatten. Both parser paths agree on quoting: `command: ""` is an empty
  value in each.
- **Fail closed** (exit 2) on malformed YAML, on a known boolean that is not a boolean, and on a
  known field that is present but empty.
- An absent policy is not an error — defaults apply (governance on, evidence required), and the
  profile still decides which producers are applicable.
- `architecture.enabled: false` or `architecture.evidence_required: false` opts out of the evidence
  requirement honestly and explicitly; it never fakes a pass.

Known boolean fields: `architecture.enabled`, `architecture.evidence_required`,
`architecture.bounded_contexts.enabled`, `architecture.tools.<tool>.enabled` for `deptrac`,
`php_arkitect`, `architecture_tests`, `dependency_cruiser`, `eslint_boundaries`.

Known scalar fields: `architecture.style`, `architecture.tools.deptrac.config`,
`architecture.tools.php_arkitect.config`, `architecture.tools.architecture_tests.command`,
`architecture.tools.dependency_cruiser.config`, `architecture.tools.eslint_boundaries.config`.

## Builder behavior

`scripts/build-security-summary.sh` treats architecture evidence like coverage/test evidence:

- A report with status `pass` or `findings` counts as evidence.
- A report with status `unavailable`, `not-configured`, `execution-error` or `disabled` does not.
- An unknown status fails closed as `execution-error` (in the collector).
- Multiple producers contribute to `architecture_violations`; the counts are **summed**.
- `architecture_tool_count` counts evidence-producing producers; `architecture_rule_count` sums the
  available rule counts; `architecture_context_count` takes the **maximum** across producers.
- With `--profile`, an applicable producer (`category: architecture`, policy required/recommended/
  one-of, applicability not `not-applicable`) that produced no valid evidence sets
  `missing_architecture_evidence: true`. `optional` producers are opt-in and never set it.
- Architecture violations are never folded into security vulnerability counters.

## Profiles

| Profile | Producers |
| --- | --- |
| laravel, symfony, php-library | `deptrac` (recommended), `php-arkitect` (optional), `php-architecture-tests` (optional) |
| node, react | `dependency-cruiser` (recommended), `eslint-boundaries` (recommended), `js-architecture-tests` (optional) |
| combinations | union of the stacks they extend; PHP and JS evidence are independent |

```txt
baseline:
  architecture tools recommended, not required as evidence.

strict:
  if architecture policy says architecture.enabled=true, evidence required.

regulated:
  evidence required, artifacts retained, unavailable fails.
```

dependency-cruiser and ESLint boundaries are fast and run on PRs; Deptrac, PHPArkitect and custom
suites run on the main gate.

## Style templates

Starting points under `templates/architecture/`:

```txt
clean-architecture/deptrac.yaml
hexagonal/deptrac.yaml
ddd-bounded-contexts/deptrac.yaml
modular-monolith/deptrac.yaml
node-clean-architecture/dependency-cruiser.js
node-ddd-bounded-contexts/dependency-cruiser.js
react-feature-boundaries/eslint.config.example.js
```

Every template says the same thing:

```txt
Template only. Adapt to your namespaces/folders. Do not enable as blocking until observed clean.
```

Sentinel Shield never installs or overwrites project-owned architecture files.

## Adoption path

1. **report-only / baseline** — add a producer and a config, observe the violation count.
2. Fix or accept what it finds; keep the count stable and visible.
3. **strict** — once producers emit evidence on every applicable stack, missing evidence starts
   blocking too.
4. **regulated** — retain the raw architecture reports with the release evidence.

Related: [architecture-policy.md](architecture-policy.md),
[architecture-tests-guide.md](architecture-tests-guide.md),
[deptrac-evidence-guide.md](deptrac-evidence-guide.md),
[architecture-deptrac-realism.md](architecture-deptrac-realism.md),
[gate-resolution.md](gate-resolution.md), [raw-report-contract.md](raw-report-contract.md).
