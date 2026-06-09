# IaC & Architecture Readiness (v0.1.23)

How Sentinel Shield's Infrastructure-as-Code scanners (Checkov, Conftest/OPA,
Terrascan) and architecture-boundary checks (Deptrac, architecture tests) become
applicable, what they require, and how to wire Deptrac into Symfony and Laravel
projects.

> **Maturity — be honest.** These integrations are **experimental** and
> **only-if-configured**. Per [`product-status.md`](product-status.md): IaC scanners
> (Checkov/Conftest/Terrascan) are `experimental` — audit + collector + fixtures
> exist, but **no consumer with real IaC has been live-validated**. Deptrac is
> **not live-validated** (no pilot consumer has a `deptrac.yaml`). Nothing here is
> promoted to `supported`; promotion requires a real, cited run on a repo that
> actually contains IaC / defined architecture layers. **Never emit a clean result
> when there was nothing to scan.**

The fixtures referenced below live under `tests/fixtures/iac/`,
`tests/fixtures/deptrac/`, and `tests/fixtures/architecture/`. They exist so the
self-test harness can exercise collector mappings **without** installing real
binaries — they are not evidence of a live consumer run.

---

## 88. IaC scanner applicability

IaC scanners apply **only when the repository actually contains IaC**. With no IaC
present, the tool is **skipped / unavailable** — it must **never** report
fake-clean. This matches [`iac-security-policy.md`](iac-security-policy.md) and the
audit wrappers, which no-op (exit 0, log `unavailable`) when the binary is absent or
there is nothing to scan; the collector then reports `status=unavailable`.

| Scanner | Applies when these files exist | Audit wrapper | Raw report | Collector | Maps to |
|---|---|---|---|---|---|
| Checkov | `*.tf`, `*.tf.json`, Kubernetes manifests, Helm charts, `docker-compose.yml`/`compose.yml` | `scripts/audits/checkov.sh` | `reports/raw/checkov.json` | `scripts/collectors/checkov.sh` | `iac_violations` |
| Conftest/OPA | Same IaC surfaces (policy-tested via Rego) | `scripts/audits/conftest.sh` | `reports/raw/conftest.json` | `scripts/collectors/conftest.sh` | `iac_violations` |
| Terrascan | Terraform (`*.tf`), Kubernetes, Helm | `scripts/audits/terrascan.sh` | `reports/raw/terrascan.json` | `scripts/collectors/terrascan.sh` | `iac_violations` |

**Decision rule:**

- **IaC present** → run the scanner → collector emits `status: pass|fail` with an
  `iac_violations` count.
- **No IaC present** (or binary not installed) → wrapper no-ops → collector reports
  `unavailable`. This is the honest, non-gating outcome. Do **not** synthesize a
  `pass`/`0 violations` report for a repo that has no IaC to scan.

### Native report shapes the collectors accept

The collectors are defensive about each tool's native JSON. Confirmed against the
collector scripts:

- **Checkov** (`collectors/checkov.sh`): reads `.summary.failed` if present, else
  `.results.failed_checks | length`, else `0`.
  Fixture: [`tests/fixtures/iac/checkov-findings.json`](../tests/fixtures/iac/checkov-findings.json)
  carries both `summary.failed: 2` and a matching `results.failed_checks` array → maps to
  `iac_violations: 2`.
- **Conftest** (`collectors/conftest.sh`): sums `.failures | length` across the
  top-level array (or single object).
  Fixture: [`tests/fixtures/iac/conftest-findings.json`](../tests/fixtures/iac/conftest-findings.json)
  is `[{"failures":[...2...]}]` → `iac_violations: 2`.
- **Terrascan** (`collectors/terrascan.sh`): reads `.results.violations | length`,
  else `.results.scan_summary.violated_policies`, else `0`.
  Fixture: [`tests/fixtures/iac/terrascan-findings.json`](../tests/fixtures/iac/terrascan-findings.json)
  has 2 entries in `results.violations` (and `violated_policies: 2`) → `iac_violations: 2`.

The minimal scannable inputs are also provided so a real scanner has a target:
[`tests/fixtures/iac/terraform/main.tf`](../tests/fixtures/iac/terraform/main.tf),
[`tests/fixtures/iac/k8s/deployment.yaml`](../tests/fixtures/iac/k8s/deployment.yaml),
[`tests/fixtures/iac/compose/docker-compose.yml`](../tests/fixtures/iac/compose/docker-compose.yml).

---

## 89. Architecture-layer prerequisites

Architecture checks gate `architecture_violations`. There are two independent
sources (see [`architecture-policy.md`](architecture-policy.md)):

1. **Deptrac** — PHP architectural-boundary enforcement. **Prerequisites:**
   - A `deptrac.yaml` at the project root **with real layers defined** (an
     empty/placeholder config produces meaningless results).
   - The `deptrac` binary (or a pinned Action) to produce `reports/raw/deptrac.json`.
   - **Absent config or binary → `unavailable` (never fake).** The collector
     (`collectors/deptrac.sh`) reads `.report.violations`, `.Report.Violations`, or
     `.violations` (array length or number) from the **JSON report** and maps to
     `architecture_violations`.

2. **Architecture tests** (opt-in) — e.g. Pest arch tests via
   `$SENTINEL_SHIELD_ARCH_TEST_CMD`. **Prerequisites:** the command is set and emits
   a raw report shaped `{"violations": N}`.
   - The collector (`collectors/architecture-tests.sh`) reads `.violations` (falling
     back to `.failures`), treating an array as its length, → `architecture_violations`.
   - Fixture: [`tests/fixtures/architecture/architecture-tests.json`](../tests/fixtures/architecture/architecture-tests.json)
     is the clean case `{"violations": 0}` → `architecture_violations: 0`, `status: pass`.

> **Report shape note (task 86).** The architecture-tests collector's expected raw
> shape is `{"violations": N}` (it also tolerates `{"failures": N}` and array forms).
> The supplied fixture is the clean `{"violations": 0}` case. This file is the
> **runner's raw report**, distinct from Deptrac's `deptrac.json` and from the
> Deptrac **config** `deptrac.yaml`.

> **Config vs. report — do not confuse them.**
> [`tests/fixtures/deptrac/deptrac.yaml`](../tests/fixtures/deptrac/deptrac.yaml) is
> the Deptrac **configuration** (layers + ruleset) — the prerequisite input. The
> Deptrac **collector** consumes `deptrac.json`, the **output** of a Deptrac run.

---

## 90. Adding Deptrac to Symfony and Laravel projects

Deptrac stays `unavailable` until a project defines architecture layers. Add it only
when those layers genuinely exist — otherwise it produces noise, not signal.

### 1. Install

```sh
composer require --dev qossmic/deptrac-shim
# or download the pinned PHAR; prefer a pinned GitHub Action in CI.
```

### 2. Config location

Place `deptrac.yaml` at the project root (the same level as `composer.json`).
See [`tests/fixtures/deptrac/deptrac.yaml`](../tests/fixtures/deptrac/deptrac.yaml)
for a minimal valid layout.

### 3. Layer examples

**Symfony** (typical `src/` with `Controller`, `Domain`, `Infrastructure`):

```yaml
deptrac:
  paths:
    - ./src
  layers:
    - name: Controller
      collectors:
        - { type: directory, value: src/Controller/.* }
    - name: Domain
      collectors:
        - { type: directory, value: src/Domain/.* }
    - name: Infrastructure
      collectors:
        - { type: directory, value: src/Infrastructure/.* }
  ruleset:
    Controller:
      - Domain
    Domain: ~                # Domain must not depend on outer layers
    Infrastructure:
      - Domain
```

**Laravel** (PSR-4 `app/` namespaces — `Http`, `Domain`/`Models`, `Services`):

```yaml
deptrac:
  paths:
    - ./app
  layers:
    - name: Http
      collectors:
        - { type: directory, value: app/Http/.* }
    - name: Domain
      collectors:
        - { type: directory, value: app/Domain/.* }
    - name: Services
      collectors:
        - { type: directory, value: app/Services/.* }
  ruleset:
    Http:
      - Services
      - Domain
    Services:
      - Domain
    Domain: ~                # Domain stays dependency-free
```

Choose layers that reflect your **actual** module boundaries. A config that lists
layers nothing maps to (or a ruleset that permits everything) yields a green result
with no enforcement value.

### 4. Wire into the gate

1. Produce the JSON report:
   ```sh
   vendor/bin/deptrac analyse --config-file=deptrac.yaml \
     --report-type=json --output=reports/raw/deptrac.json
   ```
   (Or run it via a pinned Action in CI.)
2. Collect it:
   ```sh
   sh scripts/collectors/deptrac.sh --input reports/raw/deptrac.json
   ```
   The collector emits `{status, violations}` and maps to `architecture_violations`
   (baseline+ gating per `architecture-policy.md`).
3. If `deptrac.yaml` is absent or layers are undefined, leave Deptrac
   `unavailable` — do not commit a placeholder config to force a green gate.

---

## Honesty checklist

- IaC scanners run **only** when IaC files exist; no IaC → `unavailable`, never
  fake-clean.
- Deptrac runs **only** with a real `deptrac.yaml` + defined layers; absent →
  `unavailable`.
- The fixtures here exercise **collector mappings**, not live scanner runs. They are
  not promotion evidence.
- Maturity stays **experimental / only-if-configured** until a cited run on a real
  IaC / layered consumer (`product-status.md`).
