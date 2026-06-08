# Accepted-Risk Suppression (v0.1.3+; finding-scoped v0.1.8+)

Sentinel Shield can suppress a **narrow, explicit** set of gate failures when a risk
has been formally accepted — owner-bound, with a reason and an expiry. This exists so
a team can knowingly accept a low-risk finding (e.g. a Docker hygiene warning) and
still ship under `baseline`, **without weakening enforcement or hiding the finding**.

> Accepted risks are **not** automatic suppressions. A Markdown draft does nothing.
> Only an **approved, unexpired, owner-bound** JSON record suppresses, and only for a
> **suppressible** gate. The raw finding count is preserved and the suppression is
> reported.

## Finding-scoped by default (v0.1.8)

Records are **finding-scoped by default**: a record suppresses **only the findings it
matches** — not the whole gate. Match on `rule_id` + `files`. This is implemented for
`unsafe_docker` (matched against `reports/raw/hadolint.json`).

```json
{
  "version": "1.1",
  "risks": [
    {
      "id": "dockerfile-prod-apk-unpinned",
      "gate": "unsafe_docker",
      "scope": "finding",
      "rule_id": "DL3018",
      "files": ["Dockerfile", "Dockerfile.prod"],
      "owner": "Bogdan Olteanu / platform-team",
      "severity": "medium",
      "reason": "Alpine APK pinning is brittle for the Chromium/headless-browser stack.",
      "mitigation": "Base images digest-pinned; Trivy + SBOM enabled; browser-stack split planned.",
      "expires_at": "2026-07-06",
      "status": "approved"
    }
  ]
}
```

This record suppresses **only** `DL3018` in `Dockerfile` and `Dockerfile.prod`. It does
**not** suppress `DL3008`/`DL3016`/`DL4006` in `docker/8.3/Dockerfile`, nor `DL3008` in
`docker/Dockerfile.node` — those remain **unaccepted** and fail the gate until fixed or
covered by their own finding-scoped record. (This fixes the v0.1.7 governance bug where
one gate-level DL3018 acceptance hid unrelated Docker findings.)

| Field | Meaning |
| --- | --- |
| `scope` | `finding` (default) or `gate`. `gate` is **broad** (whole gate) and **discouraged**. |
| `rule_id` | Single rule to match (e.g. `DL3018`). Omit to match any rule in `files`. |
| `rule_ids` | Optional list form of `rule_id`. |
| `files` | Paths to match (exact, path-suffix, or basename). Omit to match any file for the rule. |
| `components`, `fingerprints` | **Reserved** in v0.1.8 (declared in schema, not yet enforced). |

**Matching is conjunctive:** a finding is accepted iff (`rule_id` absent or equal) **and**
(`files` absent or one matches). A finding-scope record with **neither** `rule_id` nor
`files` is ambiguous and **does not suppress** (warned). Finding scope is implemented for
`unsafe_docker` **only**; a finding-scope record on another gate warns and does not
suppress.

### Broad (`scope: gate`) — discouraged

```json
{ "gate": "unsafe_docker", "scope": "gate", "owner": "...", "reason": "...", "expires_at": "...", "status": "approved" }
```

`scope: gate` suppresses the **entire** gate (every finding). It is reported as **broad**
in the enforcement output and should be avoided — prefer a finding-scoped record that
names `rule_id` + `files`.

### Backward compatibility / migration

A legacy record with only `gate`/`owner`/`reason`/`status`/`expires_at` (no `scope`, no
`rule_id`/`files`) is **ambiguous** under v0.1.8 and **does not suppress** — the enforcer
warns and the gate is evaluated normally. To restore suppression, either add
`scope: finding` + `rule_id`/`files` (preferred), or add explicit `scope: gate` for broad
suppression. Bump the file `version` to `"1.1"`.

## The file

`scripts/enforce-gates.sh` reads (default) `.sentinel-shield/accepted-risks.json`
(override with `--accepted-risks <path>`). Template:
[`templates/accepted-risks.example.json`](../templates/accepted-risks.example.json);
schema: [`schemas/accepted-risks.schema.json`](../schemas/accepted-risks.schema.json).

```json
{
  "version": "1.0",
  "risks": [
    {
      "id": "dockerfile-apk-unpinned",
      "gate": "unsafe_docker",
      "owner": "platform-team",
      "severity": "medium",
      "reason": "Alpine package pinning is brittle for this image; reviewed as hygiene.",
      "mitigation": "Base image pinned; image scanned by Trivy; revisit later.",
      "expires_at": "2026-07-06",
      "status": "approved"
    }
  ]
}
```

## When a record suppresses

A record suppresses its gate **only if all** hold:

- `status == "approved"` — `pending`/`rejected`/`expired` never suppress.
- `expires_at >= today` (UTC) — expired records never suppress.
- `owner` is non-empty.
- `reason` is non-empty.
- `gate` is a **suppressible** gate.

## Suppressible vs. never-suppressible

| Suppressible (v0.1.3) | Never suppressible |
| --- | --- |
| `unsafe_docker` | `secrets` |
| `medium_vulnerabilities` | `expired_exceptions` |
| | `missing_release_evidence` |
| | `missing_sbom`, `critical_vulnerabilities`, `high_vulnerabilities`, `type_errors`, `test_failures`, `architecture_violations`, `unsafe_github_actions` |

Only `unsafe_docker` and `medium_vulnerabilities` are honored. A record targeting any
other gate is loaded but **ignored** (counted as "invalid"). **Secrets are never
suppressible.**

## What happens at enforcement

When a gate is enabled and its finding count is > 0:

- **No valid approved record** → the gate **fails** (exit 1) as usual.
- **Valid approved record for that gate** → the gate is marked **`accepted-risk`**:
  it does **not** fail, the **raw count is preserved (not zeroed)**, and it is
  reported. Overall result stays `pass` if nothing else failed.

For a **finding-scoped** `unsafe_docker` record, the gate is `accepted-risk` **only when
every** finding is matched; if any finding is unaccepted, the gate **fails** (and the
report shows which findings were unaccepted). The summary count remains the total.

This is transparent in both reports:

- `reports/sentinel-shield-enforcement.json` → `accepted_risks` object
  (`loaded`, `applied_gates`, `applied_broad_gates`, `applied_finding_scoped`,
  `pending_ignored`, `expired_ignored`, `invalid_ignored`, `legacy_unscoped_ignored`, and
  an `unsafe_docker` sub-object with `scope`/`total`/`accepted`/`unaccepted`/`findings[]`)
  and the gate's `result: "accepted-risk"` in `evaluated_gates`.
- `reports/sentinel-shield-enforcement.md` → an **Accepted risks** section listing
  applied gates + the risk id, plus pending/expired/invalid counts.

## Important caveats

- **Baseline adoption still requires human approval.** Setting `status: approved` is
  a deliberate, reviewed human action — Sentinel Shield never sets it.
- **Not all gates are suppressible** — only `unsafe_docker` and
  `medium_vulnerabilities` in v0.1.3. Do not expect this to clear critical/high vulns.
- **Findings are never hidden.** Counts remain; suppression is explicit and logged.
- Prefer **fixing** over accepting. Acceptance is a time-boxed bridge, not a resolution.

## unsafe_docker finding sources (v0.1.10)

`unsafe_docker` is fed by **two** raw sources; finding-scoped matching normalizes both
(`{source, rule_id, file, severity}`) and matches records by `rule_id` + `files`:

| Source | Raw file | `rule_id`(s) |
| --- | --- | --- |
| Hadolint | `reports/raw/hadolint.json` | `DL3018`, `DL3008`, `DL3016`, `DL4006`, … |
| Docker base-digest detector | `reports/raw/docker-base-digest.json` | `SS_DOCKER_BASE_DIGEST` |

A record's `rule_id` matches only its own source — **a `DL3018` accepted-risk does NOT
suppress `SS_DOCKER_BASE_DIGEST` findings** (and vice versa). Each needs its own
finding-scoped record. Example:

```json
{
  "id": "docker-base-digest-dev-image",
  "gate": "unsafe_docker",
  "scope": "finding",
  "rule_id": "SS_DOCKER_BASE_DIGEST",
  "files": ["docker/dev/Dockerfile"],
  "owner": "platform-team", "severity": "medium",
  "reason": "…", "expires_at": "2026-07-06", "status": "approved"
}
```

**Fail-closed on missing sources:** if `summary.unsafe_docker` accounts for findings whose
raw source the enforcer cannot read (missing/invalid), that shortfall is treated as
**unaccepted** (the gate fails) — the enforcer never silently passes a source it could not
inspect. The release-gate job must therefore make `reports/raw/hadolint.json` and
`reports/raw/docker-base-digest.json` available (download them before enforcing). Prefer
**fixing** base-digest findings (digest-pin the base) over accepting them. Broad
`scope: gate` remains discouraged.
