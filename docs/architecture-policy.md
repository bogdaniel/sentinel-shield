# Architecture Policy (v2.1.0)

The policy layer of architecture governance: which producers apply, where their configs live,
and whether evidence is required. The full capability — contract, gates, producers, aggregation —
is documented in [architecture-governance.md](architecture-governance.md); this page is the
policy file itself.

Sentinel Shield enforces architecture governance through normalized architecture evidence.
Deptrac is the PHP structural-boundary producer. dependency-cruiser and ESLint boundaries are
JS/TS producers. Custom architecture tests can also emit the same contract.

Architecture tools detect dependency-boundary violations, not the quality of domain modeling
itself. They do not prove Clean Architecture or DDD correctness, and they do not replace
architectural review.

## Producers → `architecture_violations`

| Producer | Stack | Raw report | Policy in profiles |
| --- | --- | --- | --- |
| Deptrac | PHP | `deptrac.json` | recommended |
| PHPArkitect | PHP | `php-arkitect.json` | optional (opt-in) |
| Custom PHP architecture tests | PHP | `php-architecture-tests.json` | optional (opt-in) |
| dependency-cruiser | JS/TS | `dependency-cruiser.json` | recommended |
| ESLint boundaries | JS/TS | `eslint-boundaries.json` | recommended |
| Custom JS architecture tests | JS/TS | `js-architecture-tests.json` | optional (opt-in) |
| Generic architecture tests | any | `architecture-tests.json` | optional (opt-in) |

All producers sum into `architecture_violations`. Missing config/command → `not-configured` /
`unavailable` — never faked. Triage:
[`remediation/deptrac-architecture-triage.md`](remediation/deptrac-architecture-triage.md).

## Policy file

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

Loader: `scripts/lib/architecture-policy.sh` (POSIX sh).

- mikefarah `yq` v4 is used when present but is **not required**; without it the canonical
  (2-space, no anchors/aliases/inline collections/block scalars) format is parsed by a limited awk
  flatten. Both paths treat `""` as an empty value.
- **Fails closed (exit 2)** on malformed YAML, on a known boolean that is not a boolean, and on a
  known field that is present but empty. Leave a key out rather than empty.
- An **absent** policy is not an error: governance on, evidence required, profile decides which
  producers apply.
- `architecture.enabled: false` or `architecture.evidence_required: false` is the honest, explicit
  opt-out from the evidence requirement — it never fakes a clean result.

Known booleans: `architecture.enabled`, `architecture.evidence_required`,
`architecture.bounded_contexts.enabled`, and `architecture.tools.<tool>.enabled` for `deptrac`,
`php_arkitect`, `architecture_tests`, `dependency_cruiser`, `eslint_boundaries`.

Known scalars: `architecture.style`, `architecture.tools.deptrac.config`,
`architecture.tools.php_arkitect.config`, `architecture.tools.architecture_tests.command`,
`architecture.tools.dependency_cruiser.config`, `architecture.tools.eslint_boundaries.config`.

## Gating

| Gate | report-only | baseline | strict | regulated |
| --- | ---: | ---: | ---: | ---: |
| `architecture_violations` | false | true | true | true |
| `missing_architecture_evidence` | false | false | true | true |

Baseline blocks on violations reported by evidence that exists; strict and regulated also block
when expected evidence is missing, unavailable or errored. Regulated additionally requires the raw
architecture reports to be retained as release evidence.

## Status — honest

The **v2.1.0 architecture-governance layer** (the normalized contract, the new producers, the
`missing_architecture_evidence` gate, the policy loader) is supported by engine tests and fixtures
(`tests/prod/280-architecture-governance.sh`). Do not claim real consumer proof for that layer
until a real Laravel/Symfony/Node consumer validation exists.

**Deptrac itself is a separate, older question and is already `live-validated`**: a real Symfony
DDD consumer (`bogdaniel/silver-potato`, CI run `27633798174`, deptrac 1.0.2) produced a
`deptrac.json` that the collector mapped to `architecture_violations = 4`. That evidence — not
this page — is the source of truth for Deptrac's validation status; see
[`deptrac-evidence-guide.md`](deptrac-evidence-guide.md) §9 and
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). What is *not* yet consumer-validated is
Deptrac running **through the v2.1.0 runner/policy path**, and every producer added in v2.1.0
(PHPArkitect, dependency-cruiser, ESLint boundaries, the custom-test producers).

**Profile guidance:** Laravel/Symfony projects should add `deptrac.yaml` **only when architecture
layers are actually defined** — an empty/placeholder config produces meaningless results. The same
applies to the JS producers: a `.dependency-cruiser.js` with no real rules proves nothing. Promote
any producer to blocking only after a real cited run on a layered project.

Style starting points live under `templates/architecture/` and are marked "Template only. Adapt to
your namespaces/folders. Do not enable as blocking until observed clean." Sentinel Shield never
installs or overwrites project-owned architecture files.
