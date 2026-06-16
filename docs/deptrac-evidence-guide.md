# Deptrac Consumer-Run Evidence-Readiness Guide (v1.2.0)

> **PLANNING ONLY — NO MATURITY CHANGE.** This guide describes *how to produce and
> cite* a real consumer Deptrac run. It does **not** promote Deptrac. On the
> main-branch registry ([`main-gate-live-evidence.md`](main-gate-live-evidence.md))
> Deptrac is **NOT promoted (not-configured)** — no pilot consumer ships a
> `deptrac.yaml`. It stays **`experimental`** until a real, cited consumer run
> exists and is recorded there. Nothing in this file changes
> [`product-status.md`](product-status.md) or
> [`enterprise-scanner-matrix.md`](enterprise-scanner-matrix.md) labels, and no
> `deptrac.yaml` is to be invented to force a pass.

This is the Deptrac analogue of the evidence path already proven for
Dependency-Check, Grype, and Dockle: a tool is promoted **only** when a real
`reports/raw/*` artifact from a real consumer is cited and its collector parsed it.

Scope note — what is already proven vs. what this guide closes:

- **Already proven (collector ↔ real artifact):** per
  [`deptrac-validation-v025.md`](deptrac-validation-v025.md), deptrac/deptrac
  **4.6.1** produced real `deptrac-clean.json` / `deptrac-violations.json` against a
  **controlled minimal fixture project**, and `scripts/collectors/deptrac.sh` mapped
  them to `architecture_violations` `0`/`pass` and `2`/`fail`.
- **Still outstanding (this guide):** a live run on a **real pilot consumer** that
  ships its **own** `deptrac.yaml` over its **own** architecture. That is the missing
  evidence; until it is cited in the registry, Deptrac remains experimental.

See [`deptrac-iac-promotion-plan.md`](deptrac-iac-promotion-plan.md) for the overall
promotion plan and [`architecture-deptrac-realism.md`](architecture-deptrac-realism.md)
for collector contract, boundary examples, and honest triage. This guide does not
duplicate those; it is the concrete readiness checklist for the consumer run.

---

## 1. Required consumer prerequisites

A consumer qualifies to produce Deptrac evidence only if **all** of these hold:

- A PHP source tree with **real architecture layers** (e.g. Domain / Application /
  Infrastructure / Presentation, or bounded-context modules). Layering must be a
  genuine design property, not retrofitted to pass.
- A committed **`deptrac.yaml`** that the consumer actually owns and maintains —
  layers + ruleset over its own namespaces. **Do not add one to a consumer just to
  manufacture a pass** (per the promotion-plan honesty guardrails).
- Deptrac 4 installable via Composer: `composer require --dev deptrac/deptrac:^4`
  (Deptrac dropped the standalone PHAR; Composer-only). `vendor/bin/deptrac` is what
  the runner probes.
- A clear understanding that a **clean OR non-zero** result both count as evidence —
  the goal is a real parsed count, not a green check.

Candidate per the plan: a layered Laravel/Symfony consumer, or `zenchron-tools`
**only if** it adds its own `deptrac.yaml` (it does not have one today). Otherwise a
clearly-labelled controlled layered fixture (which only yields fixture-backed, not
live-consumer, evidence).

## 2. Expected `deptrac.yaml` structure (layers + ruleset)

The collector needs a real `deptrac.json`, which requires the consumer to define:

- **`paths`** — source roots to analyse (`./src` for Symfony, `./app` for Laravel).
- **`layers`** — named layers, each with collectors (typically `classNameRegex` over
  `App\*` namespaces) that assign classes to a layer.
- **`ruleset`** — the allowed dependency edges between layers; a layer mapped to `~`
  may depend on nothing internal. Anything not listed is a violation.
- **`skip_violations`** (optional) — explicit, time-boxed accepted class pairs only;
  never an empty-but-permissive catch-all (see realism doc §96/§176).

Illustrative inward-only layout (**example, not shipped — do not commit this as a
consumer config**); start from the shipped `profiles/{symfony,laravel}/deptrac.yaml`
and adapt the regexes to real namespaces:

```yaml
# EXAMPLE ONLY — illustrative, NOT a shipped or required config.
paths: [ ./src ]
layers:
  - name: Domain
    collectors: [{ type: classNameRegex, value: '#^App\\Domain\\.*#' }]
  - name: Application
    collectors: [{ type: classNameRegex, value: '#^App\\Application\\.*#' }]
  - name: Infrastructure
    collectors: [{ type: classNameRegex, value: '#^App\\Infrastructure\\.*#' }]
  - name: Presentation
    collectors: [{ type: classNameRegex, value: '#^App\\Controller\\.*#' }]
ruleset:
  Presentation: [ Application ]
  Application:  [ Domain ]
  Infrastructure: [ Domain, Application ]
  Domain: ~        # depends on nothing internal
```

## 3. Raw artifact path and collector mapping

- **Runner:** [`scripts/runners/deptrac.sh`](../scripts/runners/deptrac.sh) →
  `reports/raw/deptrac.json`. If `vendor/bin/deptrac` is absent it logs *unavailable*
  and exits 0 — it does **not** fake-clean.
- **Raw artifact path:** `reports/raw/deptrac.json` (this is the file uploaded as
  evidence).
- **Collector:** [`scripts/collectors/deptrac.sh`](../scripts/collectors/deptrac.sh)
  reads the violation count defensively (`.report.violations` |
  `.Report.Violations` (number) | `.violations` (array→length, or number)) and maps it
  to **`architecture_violations`**. Nonzero → `status=fail`; zero → `status=pass`;
  missing/empty input → `status=unavailable` (exit 0); malformed JSON → exit 2.
- **Gating:** `architecture_violations` is gated in **baseline + strict + regulated**.

Direct invocation:

```sh
vendor/bin/deptrac analyse --config-file=deptrac.yaml --formatter=json \
  --output=reports/raw/deptrac.json --no-progress
scripts/collectors/deptrac.sh --input reports/raw/deptrac.json
```

(Deptrac 4 uses `--formatter=json --output=...`; older `--report-json=...` / the
`qossmic/deptrac-shim` package are pre-v4.)

## 4. What counts as evidence

An entry qualifies as promotion evidence only when:

- The run executed a **real** `deptrac analyse` (real `vendor/bin/deptrac`) on a real
  consumer source tree with the consumer's **own** `deptrac.yaml`.
- It produced a **valid** `reports/raw/deptrac.json` with a **known violation count**
  (clean `0` or a specific non-zero number) — not an `unavailable` outcome.
- `scripts/collectors/deptrac.sh` **parsed** that artifact and emitted
  `architecture_violations` with `status` `pass`/`fail` accordingly.
- The artifact was **uploaded** under `if: always()`; **no app code was changed** to
  obtain it; findings were **NOT remediated or suppressed** to turn it green.
- The **run ID + artifact** (size, validity) are **cited** in
  [`main-gate-live-evidence.md`](main-gate-live-evidence.md).

A fixture-only run (the v0.1.25 controlled project) is **fixture-backed, not live
consumer evidence** — it does not promote product-level adoption.

## 5. Promotion criteria

Promote Deptrac from `experimental` → `live-validated` **only** when a real cited
consumer run satisfies §4: the collector parsed a valid `deptrac.json` with a known
violation count (clean or non-zero), the artifact is uploaded, app code is unchanged,
and findings are not remediated/suppressed. Then — and only then — add the run ID +
artifact row to the registry and update the maturity labels. Until that row exists,
every status doc keeps Deptrac at `experimental` / not-configured.

## 6. Optional evidence workflow sketch (DESCRIBED — not added here)

This is a **description only**; do not add a real workflow file in this docs-only
change. Model it on the existing
[`templates/workflows/sentinel-shield-dependency-check.yml`](../templates/workflows/sentinel-shield-dependency-check.yml)
evidence pattern:

- **Evidence-only, non-required, off `main`** — a dedicated workflow (e.g.
  `sentinel-shield-deptrac-evidence.yml`) that does **not** gate merges and is not a
  required check. It exists to *produce a citable artifact*, not to enforce.
- **Steps:** checkout consumer → `composer require --dev deptrac/deptrac:^4` →
  `scripts/runners/deptrac.sh reports/raw/deptrac.json` (or the direct `analyse`
  invocation) → `scripts/collectors/deptrac.sh --input reports/raw/deptrac.json`.
- **Upload with `if: always()`** so the raw `reports/raw/deptrac.json` is retained as
  an artifact even when the collector reports `fail` (a non-zero count is still valid
  evidence) or `unavailable`.
- **No remediation / no suppression** inside the workflow — the count is recorded as
  found. Pin the runner image/digest as elsewhere in the suite.

## 7. Real-run checklist

```txt
[ ] consumer ships its OWN real deptrac.yaml (layers + ruleset over its namespaces)
[ ] composer require --dev deptrac/deptrac:^4  (vendor/bin/deptrac present)
[ ] run scripts/runners/deptrac.sh -> reports/raw/deptrac.json (valid JSON; clean or real violations)
[ ] scripts/collectors/deptrac.sh --input reports/raw/deptrac.json parses it
[ ] summary mapping: architecture_violations = violation count; status pass/fail
[ ] artifact uploaded if: always(); NO app code changed; findings NOT remediated/suppressed
[ ] cite run ID + artifact (size, validity) in main-gate-live-evidence.md
[ ] only AFTER the cited row exists: update product-status.md / enterprise-scanner-matrix.md
```

## 8. Troubleshooting

- **Deptrac not installed** (`vendor/bin/deptrac` absent): the runner logs *deptrac
  not available; skipping* and exits 0; the collector emits `status=unavailable`. This
  is **not** evidence and **not** a pass — install via `composer require --dev
  deptrac/deptrac:^4` and re-run. Never treat `unavailable` as green.
- **No `deptrac.yaml`**: `deptrac analyse` cannot define layers, so no usable
  `deptrac.json` is produced → wrapper reports unavailable. The fix is a **real**
  consumer config (see §2), not a fabricated one.
- **Invalid / malformed JSON**: the collector exits **2** (error path), not `pass`.
  Inspect the raw output — usually a truncated file, a wrong formatter flag, or a
  Deptrac error. Re-run with `--formatter=json --output=...`.
- **0 layers / everything uncovered**: if collectors match nothing, Deptrac reports
  classes as *uncovered* and the violation count can be misleading (often `0` for the
  wrong reason). Confirm the `classNameRegex` bounds match real namespaces before
  citing the count — a `0` from an empty layer map is **not** clean evidence.
- **Result is non-zero**: a `fail` with a real count is **valid evidence** — upload
  it; do **not** suppress or remediate to force `pass`. Triage per
  [`architecture-deptrac-realism.md`](architecture-deptrac-realism.md) §175–§178.

## 9. Captured CI evidence (v1.5.0)

The local-CLI evidence of v1.3.0 now has a **consumer-CI run ID**:

- **Consumer:** `bogdaniel/silver-potato` (public; Symfony DDD app, real `deptrac.yaml`).
- **Workflow / run ID:** `sentinel-shield-deptrac-evidence` / **27633798174** (success).
- **Tool:** deptrac 1.0.2 (`qossmic/deptrac-shim`).
- **Artifact:** `deptrac.json` → `scripts/collectors/deptrac.sh` → `architecture_violations = 4` (**fail**).
- **Fixture (committed, Report counts only):** `tests/fixtures/deptrac-v150/silver-potato-ci.json`.
- **Caveat:** severity binary (violation count). Raw `.files` (class/paths) kept out of the repo.

Recorded canonically in [`main-gate-live-evidence.md`](main-gate-live-evidence.md) (v1.5.0 section).
Deptrac stays `live-validated` — no label change; the evidence basis is upgraded (local + CI).
