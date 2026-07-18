# Scanner Normalization

Sentinel Shield enforces a **normalized** findings document (`security-summary.json`),
not raw scanner output. This page documents the layer that turns raw tool artifacts
into that document: the collectors and the builder.

```txt
profile.yaml → resolve-gates.sh → gates.env
reports/raw/*.json → collectors → build-security-summary.sh → security-summary.json
gates.env + security-summary.json → enforce-gates.sh → pass/fail
```

- Builder: [`scripts/build-security-summary.sh`](../scripts/build-security-summary.sh)
- Collectors: [`scripts/collectors/`](../scripts/collectors/)
- Contract/schema: [`security-summary-schema.md`](security-summary-schema.md),
  [`schemas/security-summary.schema.json`](../schemas/security-summary.schema.json)

---

## Purpose

Keep responsibilities separate and testable:

1. **Scanner workflows run the tools** and write raw output to `reports/raw/`.
2. **Collectors** parse one raw artifact each and emit a tiny normalized object.
3. **The builder** merges collector outputs, adds evidence/exception state, and
   writes `reports/security-summary.json`.
4. **The enforcer** applies policy and decides pass/fail.

The builder does **not** run scanners. (A future `--run-tools` flag may, but is not
implemented; execution stays in the scanner workflows.)

---

## Input directory

Default raw input: `reports/raw/`. Expected artifacts (all optional by default):

```txt
gitleaks.json  semgrep.json  trivy.json  composer-audit.json  npm-audit.json
phpstan.json   psalm.json    deptrac.json  tests.json  hadolint.json
actionlint.json  zizmor.json  github-actions-pins.json  docker-base-digest.json
```

A **missing** artifact (in non-strict mode) is not an error: the tool is recorded as
`unavailable`, contributes zero counts, and a warning is logged.

Canonical clean examples live in [`templates/raw/`](../templates/raw/).

---

## Collector contract

Every collector is executable and supports `--input <path>`, `--tool-name <name>`,
and `--help`. It emits one JSON object on stdout:

```json
{
  "tool": "gitleaks",
  "status": "pass",
  "summary": {
    "secrets": 0, "critical_vulnerabilities": 0, "high_vulnerabilities": 0,
    "medium_vulnerabilities": 0, "architecture_violations": 0, "type_errors": 0,
    "test_failures": 0, "unsafe_docker": 0, "unsafe_github_actions": 0,
    "expired_exceptions": 0
  },
  "tool_report": { "status": "pass", "findings": 0 }
}
```

Rules:

- Missing/empty input → `status: "unavailable"`, all counts 0, exit 0 (the builder
  decides whether that is fatal via strict mode).
- Invalid JSON → exit **2** with a clear error. Collectors never silently ignore a
  parse error.
- All JSON parsing uses `jq`. Mappings are conservative.

---

## Supported tools and severity mappings

| Collector | Reads | → summary key(s) |
| --- | --- | --- |
| `gitleaks` | array of findings / `.findings[]` | `secrets` |
| `semgrep` | `.results[].extra.severity` | ERROR/CRITICAL→`critical_vulnerabilities`, WARNING/HIGH→`high_vulnerabilities`, INFO/MEDIUM→`medium_vulnerabilities` (scanned paths are scoped by a project-local `.semgrepignore` — SAST only; see [`semgrep-scoping.md`](semgrep-scoping.md)) |
| `trivy` | `.Results[].Vulnerabilities[].Severity` | CRITICAL/HIGH/MEDIUM → matching `*_vulnerabilities` |
| `composer_audit` | `.advisories.<pkg>[].severity` | critical/high/medium(moderate) → `*_vulnerabilities` |
| `npm_audit` | `.metadata.vulnerabilities.{critical,high,moderate}` | → `*_vulnerabilities` (moderate→medium) |
| `phpstan` | `.totals.file_errors + .totals.errors` | `type_errors` |
| `psalm` | array / `.issues[]` | `type_errors` |
| `deptrac` | `.report.violations` (defensive) | `architecture_violations` |
| `tests` | `{ "failures", "errors" }` | `test_failures` |
| `typescript` | `{ "errors": N }` (normalized) | `type_errors` |
| `eslint` | native ESLint JSON array | `type_errors` (errorCount), `medium_vulnerabilities` (warningCount), `high_vulnerabilities` (security severity-2) |
| `hadolint` | array; level error/warning | `unsafe_docker` (v0.1.7: produced by `scripts/run-hadolint.sh`, which discovers ALL Dockerfiles — `Dockerfile`, `Dockerfile.*`, `docker/**`, `.docker/**` — and merges their findings into one `hadolint.json`; the collector is unchanged and counts error+warning across the merged array) |
| `actionlint` | `{ "errors" }` or error array | `unsafe_github_actions` |
| `zizmor` | array / `.findings[]` | `unsafe_github_actions` |
| `github_actions_pins` (v0.1.9) | array from `scripts/audit-github-actions-pins.sh` | `unsafe_github_actions` (unpinned `uses:`/images; complementary to actionlint/zizmor — counts are SUMMED) |
| `docker_base_digest` (v0.1.9) | array from `scripts/audit-docker-base-digest.sh` | `unsafe_docker` (un-digested `FROM image:tag`; distinct from Hadolint DL3018/DL3008 — counts are SUMMED) |
| `third_party_semgrep` | `.results[].extra.metadata.sentinel_shield_category` (separate dependency scan; see [`third-party-supply-chain-scan.md`](third-party-supply-chain-scan.md)) | `third_party_install_script_risk` / `third_party_obfuscation` / `third_party_network_behavior`; missing category → `third_party_suspicious_code`. **Never** mixed into app `*_vulnerabilities`. |

TypeScript and ESLint normalization (including the conservative ESLint
severity mapping) is documented in
[`node-react-normalization.md`](node-react-normalization.md).

### Engineering-quality collectors (v2.1)

> **Unreleased, additive engine capability** — **not** part of `v2.0.1`/`v2.0.0` and **not** a new
> release claim. Full reference: [`engineering-quality-gates.md`](engineering-quality-gates.md).

Five additional collectors map coverage/mutation/complexity/duplication/dead-code raw reports into the
engineering-quality summary keys. These are a **separate counter channel** from security — they are
never mixed into `*_vulnerabilities` or any other security key:

| Collector | Reads (via runners/adapters) | → summary key(s) |
| --- | --- | --- |
| `coverage` | `reports/raw/php-coverage.json` / `js-coverage.json` (from `php-coverage.sh` / `js-coverage.sh` + `clover-to-coverage-json.php` / `istanbul-summary-to-coverage-json.mjs`) | `coverage_threshold_violations`, `coverage_regression` (+ informational `coverage_*_percent`) |
| `mutation` | `reports/raw/*` from `infection.sh` (PHP) / `stryker.sh` (JS) | `mutation_score_violations` (+ `mutation_score_percent`) |
| `complexity` | `reports/raw/*` from `phpmd-complexity.sh` (+ optional external JS complexity) | `complexity_violations` (+ `complexity_max`/`complexity_average`) |
| `duplication` | `reports/raw/*` from `phpcpd.sh` (PHP) / `jscpd.sh` (JS) | `duplication_violations` (+ `duplication_percent`) |
| `dead_code` | `reports/raw/*` from `knip.sh` (JS; PHP optional/external) | `dead_code_violations` (+ `dead_code_count`) |

Each runner leaves its report **absent** when its tool is not installed (recorded `unavailable`, never
a fake-clean 0); missing quality keys resolve to 0. Coverage is the mandatory quality signal; mutation,
complexity, duplication, and dead-code are optional. Deptrac remains `architecture_violations`,
PHPStan/Psalm remain `type_errors`, and Pint/PHP-CS-Fixer remain `style_violations` — none move into
the quality channel.

**Combined-profile aggregation.** In combined profiles (e.g. `laravel-react-docker`) PHP and JS
coverage are independent (`php-coverage.json` and `js-coverage.json` never overwrite each other) and
the builder aggregates them: `coverage_threshold_violations` is the **sum** of per-stack violations,
the `coverage_*_percent` informational metrics take the **minimum** across applicable stacks (the
weakest-covered stack drives the gate), and `coverage_regression` is **1 if any** stack regressed.

#### Second-round quality collectors (v2.1)

Four more collectors, in the **same separate channel**, cover diff-coverage, focused/skip markers,
debug residue, and source size:

| Collector | Reads (via runners) | → summary key(s) |
| --- | --- | --- |
| `diff-coverage` | `reports/raw/diff-coverage.json` (per-stack `php-diff-coverage.json` / `js-diff-coverage.json`) — PHP from `php-diff-coverage.sh` (`git diff` × Clover per-line via `clover-diff-to-coverage-json.php`); JS is external/normalized | `changed_lines_coverage_violations` (+ informational `changed_lines_coverage_percent`) |
| `focused-tests` | `reports/raw/focused-tests.json` (from `focused-tests.sh`, grep-based) | `focused_test_violations`, `skipped_test_marker_violations` |
| `debug-code` | `reports/raw/debug-code.json` (from `debug-code.sh`, grep-based) | `debug_code_violations` |
| `source-size` | `reports/raw/source-size.json` (from `source-size.sh`, `wc -l`-based) | `large_file_violations`, `large_function_violations` (+ informational `max_file_lines`/`max_function_lines`) |

The `tests` collector is **extended** to also emit `test_count` (total tests executed) and
`skipped_tests` alongside `test_failures`; the profile builder (`--profile`) additionally derives the
`missing_test_evidence` and `empty_test_suite` booleans from applicable test stacks. The
grep/`wc -l`-based runners (`focused-tests`, `debug-code`, `source-size`) are **always available**, so a
clean scan is a real `pass` (not `unavailable`); `source-size` implements large-**file** detection fully
but holds `large_function_violations`/`max_function_lines` at `0` (large-function is best-effort/external
for now — the collector accepts an externally-normalized value). **Per-stack independence** holds here
too: `php-diff-coverage.json` and `js-diff-coverage.json` never overwrite each other, PHP test evidence
never satisfies a JS requirement (or vice-versa), and `changed_lines_coverage_violations` **sums** across
stacks while `changed_lines_coverage_percent` takes the **minimum**.

> Severity→bucket mappings are first-pass and **conservative**. They will need
> tuning per project (e.g. how you treat Semgrep `INFO`, or composer `low`). These
> are starting points, not a claim of perfect coverage. Output formats also vary by
> tool version — `deptrac`, `actionlint`, and `zizmor` parsing is deliberately
> defensive and documented inline.

---

## Strict vs. non-strict mode

| Mode | Missing artifact behavior |
| --- | --- |
| default | tool `unavailable`, counts 0, warning, exit 0 |
| `--require-tool <key>` | exit 1 if that tool's artifact is missing |
| `--strict-tools` | exit 1 if ANY expected artifact is missing |

`<key>` is the hyphenated tool key (e.g. `composer-audit`, `npm-audit`).

---

## Evidence mapping

The builder sets evidence by file existence (relative to the output's directory):

| File | Sets |
| --- | --- |
| `reports/sbom.spdx.json` present | `evidence.sbom.present=true`, `summary.missing_sbom=false` |
| `reports/sbom.spdx.json` absent | `evidence.sbom.present=false`, `summary.missing_sbom=true` |
| `reports/release-evidence.md` present | `evidence.release_evidence.present=true`, `summary.missing_release_evidence=false` |
| absent | the inverse |

`summary.missing_*` and `evidence.*.present` are kept consistent **by construction**
and verified by a final self-check in the builder.

---

## Exceptions mapping

If `reports/exceptions.json` exists and is valid:

```json
{ "active": 0, "expired": 0 }
```

then `exceptions.active`/`exceptions.expired` are read from it and
`summary.expired_exceptions = exceptions.expired`. Otherwise both default to 0.

---

## Consistency rules (enforced by the builder)

- `summary.<count>` equals the **sum** of all collectors' counts for that key.
- `tools.<tool>` is each collector's `tool_report`.
- `summary.missing_sbom == not evidence.sbom.present`.
- `summary.missing_release_evidence == not evidence.release_evidence.present`.
- `summary.expired_exceptions == exceptions.expired`.

A failed self-check aborts with exit 2 — no contradictory summary is ever written.

---

## Common failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| `jq is required …` (exit 2) | jq missing | install jq |
| `required tool artifact missing` (exit 1) | strict mode + missing raw file | produce the artifact or drop strict |
| `collector failed for '<tool>'` (exit 1) | invalid JSON in a present raw file | fix the producing step |
| tool shows `unavailable` | raw artifact missing (non-strict) | run that scanner / write its raw file |
| counts look wrong | severity mapping mismatch | tune the collector for your tool/version |

---

## CI artifact handoff

In CI the layers communicate via artifacts (see README "CI artifact handoff"):

- **Raw artifacts are uploaded** by the scanner workflows:
  `ci-security.yml` → `sentinel-shield-raw-security`; `ci-php`/`ci-node`/`ci-docker`
  → `sentinel-shield-raw-security-php`/`-node`/`-docker` (each holding
  `reports/raw/*.json`).
- **`security-summary.json` is produced** by `ci-security.yml` running
  `build-security-summary.sh` and uploaded as `sentinel-shield-security-summary`.
  (A fuller pipeline downloads the per-stack raw artifacts into `reports/raw/` first
  so one summary covers all stacks.)
- **The release gate consumes it**: `ci-release-gate.yml` downloads
  `sentinel-shield-security-summary` (same-run), applies the fallback policy
  ([`select-security-summary.sh`](../scripts/select-security-summary.sh)), then runs
  `enforce-gates.sh`.

### How `ci-pipeline.yml` gathers and merges raw artifacts

The combined pipeline ([`.github/workflows/ci-pipeline.yml`](../.github/workflows/ci-pipeline.yml))
is the reference for this in one run:

1. Stack jobs (`php-quality`, `node-quality`, `docker-security`, `security-scan`)
   each write `reports/raw/*.json` and upload it as
   `sentinel-shield-raw-security[-php|-node|-docker]`. `security-scan` also produces
   the SPDX SBOM (`sentinel-shield-sbom`).
2. `build-security-summary` downloads **all** `sentinel-shield-raw-security*`
   artifacts with `pattern: sentinel-shield-raw-security*` + `merge-multiple: true`
   into a single `reports/raw/`, downloads the SBOM into `reports/`, then runs
   `build-security-summary.sh`. The builder **sums** each `summary` key across every
   collector, so per-stack raw outputs combine into one document. Tools whose raw
   files are absent are `unavailable` (counts 0) — not faked.
3. `release-gate` consumes the resulting `sentinel-shield-security-summary`.

### Why the example fallback is report-only

The all-zero example (`templates/security-summary.example.json`) exists so the
template *runs* without scanners. It is **not evidence**. In `baseline`, `strict`,
and `regulated` a real summary is required and a missing/example summary **fails the
gate** — fail-closed. Only `report-only` may continue on the example, and only with
a loud warning. The policy detects a copied example (byte-identical) and refuses it
in baseline+, so it cannot be used to spoof a pass.

### Accepted-risk suppression vs. the summary

Normalization never zeroes a finding. If a finding is intentionally accepted, that is
handled at **enforcement** time (v0.1.3+) via an approved accepted-risk record, which
marks the gate `accepted-risk` while **preserving** the raw count in the summary —
the count is never reduced in `security-summary.json`. **v0.1.8:** acceptance is
**finding-scoped** by default — for `unsafe_docker` the enforcer reads the raw
`reports/raw/hadolint.json` and accepts only findings matching a record's `rule_id` +
`files`; unaccepted findings still fail the gate. The collector and summary are
unchanged (still the total). See
[`accepted-risk-suppression.md`](accepted-risk-suppression.md).

### Fixtures and the self-test

The clean examples in [`templates/raw/`](../templates/raw/) are not just
documentation — they are the fixtures the self-test runs on. `ci-self-test.yml`
(via [`scripts/self-test.sh`](../scripts/self-test.sh)) copies `templates/raw/*.example.json`
into `reports/raw/`, builds a real `security-summary.json`, and runs it through the
full lifecycle on every push/PR. Keep the examples valid and representative: if you
change a collector's expected input shape, update its example too.

**Negative fixture cases** (`sh scripts/self-test.sh negative`) go further: they
craft summaries carrying a single gated finding (high vuln, secret, type errors,
test failures, architecture violations) and assert that `enforce-gates.sh` actually
fails. This proves normalized findings *influence enforcement* — that the counts a
collector emits are not cosmetic.

## Adding a new collector (for consuming projects)

1. Create `scripts/collectors/<tool>.sh` following the contract (source the common
   lib, `ss_collector_guard`, compute counts with `jq`, `ss_emit_collector`).
2. Add a clean example to `templates/raw/<tool>.example.json`.
3. Add a row to `TOOL_TABLE` in `build-security-summary.sh`:
   `key|raw-filename|collector-script|emitted-tool-name`.
4. Map to an existing `summary` key — do not invent a new gate key without also
   updating the resolver, schema, example, and enforcer together
   ([`CONTRIBUTING.md`](../CONTRIBUTING.md)).
