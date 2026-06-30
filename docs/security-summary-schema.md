# Security Summary Schema

`security-summary.json` is the **contract** between scanners and Sentinel Shield's
enforcement layer. Scanner workflows normalize their output into this one document;
[`scripts/enforce-gates.sh`](../scripts/enforce-gates.sh) maps the resolved
`SENTINEL_SHIELD_FAIL_ON_*` flags onto its `summary` keys and decides pass/fail.

- JSON Schema: [`schemas/security-summary.schema.json`](../schemas/security-summary.schema.json)
  (Draft 2020-12).
- Example: [`templates/security-summary.example.json`](../templates/security-summary.example.json).

---

## Purpose

The gate **resolver** says *what should fail* (per adoption mode). The gate
**enforcer** needs *normalized findings* to decide *whether it actually fails*.
`security-summary.json` is that normalized findings document. One shape, produced by
whatever scanners a project runs, consumed by one enforcer.

---

## Required fields

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `version` | string | ✅ | e.g. `"1.0"` |
| `generated_at` | string | ✅ | ISO-8601 UTC |
| `summary` | object | ✅ | all 12 keys required (below) |
| `project` | object | optional | name/type/criticality |
| `source` | object | optional | commit/branch/workflow |
| `tools` | object | optional | per-tool detail |
| `exceptions` | object | optional | active/expired counts |
| `evidence` | object | optional | sbom/release_evidence presence |

A missing `summary` key is an **error** (exit 2), never a silent zero.

---

## Summary key meanings

All keys are required. Integer keys are non-negative counts; two are booleans.

| Key | Type | Meaning |
| --- | --- | --- |
| `secrets` | integer | Leaked-secret findings (Gitleaks). |
| `critical_vulnerabilities` | integer | Critical dependency/code vulns. |
| `high_vulnerabilities` | integer | High vulns. |
| `medium_vulnerabilities` | integer | Medium vulns. |
| `architecture_violations` | integer | Deptrac / import-boundary violations. |
| `type_errors` | integer | PHPStan/Psalm/tsc errors. |
| `test_failures` | integer | Failing tests. |
| `unsafe_docker` | integer | Hadolint/Trivy misconfig findings (v0.1.7: Hadolint scans ALL discovered Dockerfiles, merged into one report — see [`docker-security-standard.md`](docker-security-standard.md)). |
| `unsafe_github_actions` | integer | actionlint/zizmor findings. |
| `missing_sbom` | boolean | `true` if no SBOM was produced. |
| `missing_release_evidence` | boolean | `true` if no readiness report. |
| `expired_exceptions` | integer | Lapsed accepted-risk records. |
| `third_party_suspicious_code` | integer | (v0.1.5+, optional) Third-party suspicious-code findings — separate channel. |
| `third_party_install_script_risk` | integer | (v0.1.5+, optional) Dependency install-script (pre/post/install) risks. |
| `third_party_obfuscation` | integer | (v0.1.5+, optional) Third-party obfuscation indicators. |
| `third_party_network_behavior` | integer | (v0.1.5+, optional) Third-party env-read / outbound-network indicators. |

---

## How flags map to summary keys

The enforcer evaluates each gate only when its resolved flag is `true`:

| Gate flag (`SENTINEL_SHIELD_FAIL_ON_…`) | Fails when |
| --- | --- |
| `SECRETS` | `summary.secrets > 0` |
| `CRITICAL_VULNERABILITIES` | `summary.critical_vulnerabilities > 0` |
| `HIGH_VULNERABILITIES` | `summary.high_vulnerabilities > 0` |
| `MEDIUM_VULNERABILITIES` | `summary.medium_vulnerabilities > 0` |
| `ARCHITECTURE_VIOLATIONS` | `summary.architecture_violations > 0` |
| `TYPE_ERRORS` | `summary.type_errors > 0` |
| `TEST_FAILURES` | `summary.test_failures > 0` |
| `UNSAFE_DOCKER` | `summary.unsafe_docker > 0` |
| `UNSAFE_GITHUB_ACTIONS` | `summary.unsafe_github_actions > 0` |
| `MISSING_SBOM` | `summary.missing_sbom == true` OR `evidence.sbom.present == false` |
| `MISSING_RELEASE_EVIDENCE` | `summary.missing_release_evidence == true` OR `evidence.release_evidence.present == false` |
| `EXPIRED_EXCEPTIONS` | `summary.expired_exceptions > 0` OR `exceptions.expired > 0` |

Disabled gates (flag `false`) are recorded as `skipped` and never fail the build.

A gate that would fail may instead be marked **`accepted-risk`** (v0.1.3+) when an
approved, unexpired accepted-risk record covers it (only `unsafe_docker` /
`medium_vulnerabilities`; never `secrets`/`expired_exceptions`/
`missing_release_evidence`). The raw count is preserved. **v0.1.8:** records are
**finding-scoped by default** — for `unsafe_docker` a record matches `rule_id` + `files`
(read from `reports/raw/hadolint.json`) and the gate is `accepted-risk` only when **every**
finding is matched; unaccepted findings still fail. **v0.1.10:** unsafe_docker has TWO raw sources — `reports/raw/hadolint.json` (DL*) and `reports/raw/docker-base-digest.json` (SS_DOCKER_BASE_DIGEST); both are normalized and matched, and a missing source is treated as unaccepted (fail-closed). The release-gate job must provide both raw files. Broad gate-wide suppression needs
explicit `scope: gate`. See [`accepted-risk-suppression.md`](accepted-risk-suppression.md).

---

## Tool-specific sections

`tools` is optional and open-ended — not every project has every stack. Node/React
adds two entries (see [`node-react-normalization.md`](node-react-normalization.md)):

```json
"typescript": { "status": "pass", "errors": 0 },
"eslint":     { "status": "pass", "errors": 0, "warnings": 0, "security_errors": 0 }
```

These are optional (not globally required). When a tool is present, the schema
validates its common fields. Recognized status values:

```txt
pass | fail | warn | skipped | unavailable
```

`tools` is informational for reporting/triage; **enforcement reads `summary`**, not
`tools`. Keep the two consistent in your producing workflow (e.g. the sum of
semgrep/trivy/composer_audit critical counts should equal
`summary.critical_vulnerabilities`).

---

## Evidence fields

```json
"evidence": {
  "sbom": { "present": true, "path": "reports/sbom.spdx.json" },
  "release_evidence": { "present": true, "path": "reports/release-evidence.md" }
}
```

Used by the `MISSING_SBOM` / `MISSING_RELEASE_EVIDENCE` gates. If the `evidence`
section is omitted, those gates rely solely on the corresponding `summary` boolean.

---

## Exception fields

```json
"exceptions": { "active": 0, "expired": 0 }
```

`exceptions.expired` augments `summary.expired_exceptions` for the
`EXPIRED_EXCEPTIONS` gate. See [`exception-policy.md`](exception-policy.md).

---

## How scanner workflows map their outputs

Each scanner workflow is responsible for translating its native output into the
`summary` counts. Sketch (a producing job collects per-tool results and writes one
document):

| Stack | Tools → summary keys |
| --- | --- |
| Laravel | Gitleaks→`secrets`; Semgrep+`composer audit`+Trivy→`*_vulnerabilities`; PHPStan/Psalm→`type_errors`; Deptrac→`architecture_violations`; PHPUnit→`test_failures` |
| React | Gitleaks→`secrets`; Semgrep+`npm audit`→`*_vulnerabilities`; tsc→`type_errors`; ESLint boundaries→`architecture_violations`; test runner→`test_failures` |
| Docker | Hadolint/Trivy→`unsafe_docker`; Trivy image→`*_vulnerabilities`; Syft→`evidence.sbom` |

> **Semgrep scope vs. dependency scope (v0.1.4+):** the `Semgrep` part of
> `*_vulnerabilities` is **SAST over application source** and is scoped by a
> project-local `.semgrepignore` (excludes vendored/generated assets). The
> `composer audit` / `npm audit` / `Trivy` parts are **dependency** findings and are
> **not** narrowed by `.semgrepignore`. See [`semgrep-scoping.md`](semgrep-scoping.md).

Sentinel Shield ships a first-pass builder and collectors that produce this file
from raw artifacts — see below and [`scanner-normalization.md`](scanner-normalization.md).

## How `build-security-summary.sh` populates fields

[`scripts/build-security-summary.sh`](../scripts/build-security-summary.sh) runs the
per-tool collectors over `reports/raw/*.json` and merges them:

- **`summary` counts** = the sum of every collector's count for that key.
- **`tools.<tool>`** = each collector's `tool_report` (carrying a `status` of
  `pass`/`fail`/`unavailable`).
- **`evidence`** = set by file existence: `reports/sbom.spdx.json` and
  `reports/release-evidence.md`.
- **`summary.missing_sbom` / `summary.missing_release_evidence`** = the inverse of
  the corresponding `evidence.*.present`.
- **`exceptions` + `summary.expired_exceptions`** = read from
  `reports/exceptions.json` if present, else 0.
- **`project` / `source` / `generated_at` / `version`** = from CLI flags and the
  clock.

### Tool status meanings

`pass` (ran, no findings in its buckets), `fail` (ran, found something), `warn`
(ran, advisory), `skipped` (intentionally not run), `unavailable` (no/empty raw
artifact). Enforcement reads `summary`, not `tools`.

### Consistency rules

The builder guarantees (and self-checks) that `summary.missing_sbom ==
not evidence.sbom.present`, `summary.missing_release_evidence ==
not evidence.release_evidence.present`, and `summary.expired_exceptions ==
exceptions.expired`. A contradiction aborts with exit 2 — no inconsistent summary is
written.

> The collectors are a **first-pass, conservative** normalization layer. Severity
> mappings and tool output shapes vary by version and will need tuning; this is not
> a claim of perfect scanner coverage. See
> [`scanner-normalization.md`](scanner-normalization.md).

## Real summary required for baseline and above

`security-summary.json` must be produced from **real scanner artifacts** for
`baseline`, `strict`, and `regulated`. The all-zero example
(`templates/security-summary.example.json`) is **not evidence** — it exists only so
templates run and is accepted **only** in `report-only` (with a loud warning).

The release gate enforces this via
[`select-security-summary.sh`](../scripts/select-security-summary.sh): in
`baseline`+ a missing summary — or one byte-identical to the example — **fails the
gate**. See [`gate-resolution.md`](gate-resolution.md) and
[`../RELEASE-GATES.md`](../RELEASE-GATES.md).

In the recommended pipeline
([`.github/workflows/ci-pipeline.yml`](../.github/workflows/ci-pipeline.yml)),
`security-summary.json` is produced by the `build-security-summary` job (running
`build-security-summary.sh` over the merged raw artifacts) and uploaded as
`sentinel-shield-security-summary`. The example is never used in that job.

---

## Common failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| `jq is required …` (exit 2) | jq not installed | Install jq |
| `missing required summary key: summary.X` (exit 2) | Producer omitted a key | Emit all 12 keys |
| `summary.X must be a non-negative integer` (exit 2) | Wrong type (string/float) | Emit integer counts |
| `not valid JSON` (exit 2) | Malformed document | Validate against the schema |
| Gate unexpectedly `skipped` | Flag is `false` for the mode | Check the resolver / profile |

---

## Validate locally

```sh
# With Python + jsonschema:
python3 -m pip install jsonschema  # if needed
python3 - <<'PY'
import json
from jsonschema import validate
schema = json.load(open("schemas/security-summary.schema.json"))
doc = json.load(open("templates/security-summary.example.json"))
validate(doc, schema)
print("valid")
PY

# Enforce against resolved gates:
sh scripts/resolve-gates.sh --mode baseline
cp templates/security-summary.example.json reports/security-summary.json
sh scripts/enforce-gates.sh --format all
```
