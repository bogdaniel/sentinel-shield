# Production security acceptance policy

This document describes the production security acceptance gate: the canonical policy
(`config/production-security-policy.json`, schema
`schemas/production-security-policy.schema.json`), the enforcer
(`scripts/enforce-security-policy.sh`), the normalizer
(`scripts/normalize-security-summary.sh`) and the machine-readable acceptance report it
proves (`schemas/security-acceptance.schema.json`).

Everything here **fails closed**: when evidence is missing, malformed, stale, unverifiable,
or ambiguous, the gate rejects. There are no advisory-only checks.

## Pipeline

```
raw scanner reports ──▶ normalize-security-summary.sh ──▶ normalized security summary
                                                              │
config/production-security-policy.json ─┐                     │
.sentinel-shield/accepted-risks.json ───┼──▶ enforce-security-policy.sh ──▶ security-acceptance.json
security regression baseline ───────────┘                     │
                                                              ▼
                                            exit 0 accepted / 1 rejected / 2 config / 4 timeout
```

`normalize-security-summary.sh` turns a scanner manifest + raw reports into the normalized
summary: it computes each raw report's **sha256 digest**, computes vulnerability-database
**freshness** (`age_days`) from the database timestamp, carries normalized per-finding
records, and **fails closed** if a declared raw report is missing or malformed JSON (a
malformed report must never normalize into a clean, empty summary).

## What the gate blocks

| Class | Signal | Default action |
| --- | --- | --- |
| Source vulnerabilities | finding severity ≥ blocking | block unless narrowly waived |
| Dependency vulnerabilities | finding severity ≥ blocking | block unless narrowly waived |
| Leaked secrets | any `leaked_secrets` finding | **block — never waivable** |
| Workflow vulnerabilities | finding severity ≥ blocking | block unless narrowly waived |
| Container / image findings | finding severity ≥ blocking | block unless narrowly waived |
| License-policy violations | `license_violations` finding | block unless narrowly waived |
| Scanner failure / crash | applicable scanner `status: error` | block (`SCANNER_FAILURE`) |
| Stale scanner database | `age_days` absent or > cap | block (`SCANNER_DB_STALE`) |
| Malformed report | summary not conformant | fail closed (exit 2) |
| Missing applicable scanner | required scanner absent from summary | block (`SCANNER_MISSING`) |
| Scanner success, zero targets | applicable scanner scanned 0 targets | block (`SCANNER_ZERO_TARGETS`) |
| Missing raw digest | applicable scanner has no verifiable digest | block (`SCANNER_NO_DIGEST`) |
| Unverifiable provenance | required-but-unsigned/unverifiable | block (`PROVENANCE_UNVERIFIABLE`) |
| Security regression | coverage/finding drop vs baseline | block (`SECURITY_REGRESSION`) |

Blocking severities, waivable severities, per-scanner freshness caps and the never-waivable
categories are all declared in the policy — not hard-coded in the enforcer.

## Fix-available handling

`fix_available_handling` records the stance per severity/fix combination. A **high with a
fix** is expected to be remediated (upgrade); a **high without a fix** may be accepted only
via a narrowly-scoped accepted-risk record. A **critical** is never accepted on the normal
path — only through the documented emergency-release process.

## Accepted-risk (waiver) requirements

A suppression is honoured only when the accepted-risk record is **valid**. The policy
mandates (`waivers` block) and the enforcer verifies:

- **Mandatory owner** and **mandatory approver** — and `owner != approved_by` (no
  self-approval).
- **Issue/reference linkage** (`issue`) to a remediation ticket.
- **Review + approval** (`status: approved`).
- **Maximum waiver lifetime** — `expires_at - created_at` must not exceed
  `waivers.max_lifetime_days` (default 90).
- **Narrow scope only** — `scope: finding` with a `scanner`, `category` and `finding_id`
  that match the finding. **Blanket package/scanner suppression is prohibited** and rejects
  the whole file (fail closed).
- **Unexpired** — `expires_at >= today` at apply time.
- Secrets are **never** waivable, regardless of any record.

A record for the wrong scanner, an expired record, or an over-lifetime record does not
suppress the finding.

## Security regression baseline

When a baseline (previous accepted `security-acceptance.json` or a dedicated baseline file
with `targets.scanned` + `findings.total`) is supplied and `regression_baseline.enabled`:

- **Coverage reduction** — fewer targets scanned than the baseline → block
  (`SECURITY_REGRESSION`). This catches the classic "the numbers look better because we
  scanned less" failure.
- **Unexplained finding drop** — fewer findings **and** fewer targets scanned (i.e. the drop
  is explained by reduced coverage, not by fixes) is flagged.
- An absolute coverage floor (`regression_baseline.min_coverage_ratio`, default 1.0) applies
  even without a baseline.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | accepted (decision `accepted` or `accepted-emergency`) |
| 1 | rejected — one or more blocking violations |
| 2 | configuration / input error (missing/malformed/non-conformant policy, summary, or waiver file) — fail closed |
| 4 | timeout — a bounded evaluation step timed out; run is unverifiable |

## Redaction

The policy, normalized summary, acceptance report, and all diagnostics carry no credentials,
tokens, signing-key paths, or repo-local absolute paths. The disclosure contact in the
committed policy is a redacted placeholder.

## Tests

`tests/prod/261-production-security.sh` is the deterministic, network-free contract for this
gate (critical vuln; high with/without fix; expired / missing-owner / wrong-scanner waivers;
stale database; zero-target scanner; scanner crash; malformed report; secret finding;
coverage regression; valid narrow acceptance; emergency-release path). CI runs it as a
blocking job in `.github/workflows/ci-security.yml`.
