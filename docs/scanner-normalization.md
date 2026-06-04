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
actionlint.json  zizmor.json
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
| `semgrep` | `.results[].extra.severity` | ERROR/CRITICAL→`critical_vulnerabilities`, WARNING/HIGH→`high_vulnerabilities`, INFO/MEDIUM→`medium_vulnerabilities` |
| `trivy` | `.Results[].Vulnerabilities[].Severity` | CRITICAL/HIGH/MEDIUM → matching `*_vulnerabilities` |
| `composer_audit` | `.advisories.<pkg>[].severity` | critical/high/medium(moderate) → `*_vulnerabilities` |
| `npm_audit` | `.metadata.vulnerabilities.{critical,high,moderate}` | → `*_vulnerabilities` (moderate→medium) |
| `phpstan` | `.totals.file_errors + .totals.errors` | `type_errors` |
| `psalm` | array / `.issues[]` | `type_errors` |
| `deptrac` | `.report.violations` (defensive) | `architecture_violations` |
| `tests` | `{ "failures", "errors" }` | `test_failures` |
| `hadolint` | array; level error/warning | `unsafe_docker` |
| `actionlint` | `{ "errors" }` or error array | `unsafe_github_actions` |
| `zizmor` | array / `.findings[]` | `unsafe_github_actions` |

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

## Adding a new collector (for consuming projects)

1. Create `scripts/collectors/<tool>.sh` following the contract (source the common
   lib, `ss_collector_guard`, compute counts with `jq`, `ss_emit_collector`).
2. Add a clean example to `templates/raw/<tool>.example.json`.
3. Add a row to `TOOL_TABLE` in `build-security-summary.sh`:
   `key|raw-filename|collector-script|emitted-tool-name`.
4. Map to an existing `summary` key — do not invent a new gate key without also
   updating the resolver, schema, example, and enforcer together
   ([`CONTRIBUTING.md`](../CONTRIBUTING.md)).
