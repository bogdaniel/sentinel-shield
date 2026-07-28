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
- **Not all gates are suppressible** — only `unsafe_docker` and `medium_vulnerabilities`.
  Do not expect this to clear critical/high vulns; `secrets`, `expired_exceptions` and
  `missing_release_evidence` are never suppressible.
- **Findings are never hidden.** Counts remain; suppression is explicit and logged.
- Prefer **fixing** over accepting. Acceptance is a time-boxed bridge, not a resolution.

## medium_vulnerabilities finding identity (v2.3)

Finding scope used to exist **only** for `unsafe_docker`. For `medium_vulnerabilities` the
schema reserved `components` and `fingerprints` without enforcing them, so accepting ONE medium
vulnerability meant suppressing the **whole gate** — and that broad record then also covered
every unrelated medium finding that appeared later. That is exactly the governance failure this
document tells adopters to avoid.

`scripts/normalize-findings.sh` now derives one canonical identity per medium finding from the
raw scanner reports:

| Source | Raw file | Identity |
| --- | --- | --- |
| Grype | `reports/raw/grype.json` | advisory id, package, version, location |
| OSV-Scanner | `reports/raw/osv-scanner.json` | advisory id, package, version, manifest path |
| Trivy (fs) | `reports/raw/trivy-fs.json` | `VulnerabilityID`, `PkgName`, installed version, target |
| Composer audit | `reports/raw/composer-audit.json` | CVE/advisory id, package, affected range |
| npm audit | `reports/raw/npm-audit.json` | advisory sources, package, range |
| OWASP Dependency-Check | `reports/raw/dependency-check.json` | CVE, dependency file |

```
fingerprint = ss-fp/1|<source>|<rule_id>|<component>|<version>|<file>
```

The fingerprint is **readable, not a hash**, so a reviewer can see exactly what a record
accepts, and it is built only from stable identity fields — never array order, titles,
descriptions or line numbers. The algorithm is versioned (`ss-fp/1`) and reported in the
enforcement JSON, so records stay auditable across upgrades.

Every component is normalised the same way before it is joined: a missing value becomes the
empty string, a non-string is stringified, and a leading `./` is stripped. Nothing else is
rewritten — no case folding, no whitespace collapsing, no sorting of the value itself.

#### What `<version>` holds per source

Two sources report a **range**, not an installed version, and the range is what the fingerprint
carries — verbatim, exactly as the scanner printed it:

| Source | `<version>` | `<rule_id>` | `<file>` |
| --- | --- | --- | --- |
| Grype | installed `artifact.version` | advisory id | first reported location |
| OSV-Scanner | installed package version | advisory id | manifest path |
| Trivy (fs) | `InstalledVersion` | `VulnerabilityID` | `Target` |
| Composer audit | `affectedVersions` **range string** (e.g. `>=5.4.0,<5.4.15`) | first of `cve`, `advisoryId`, `title` | constant `composer.lock` |
| npm audit | `range` **range string** (e.g. `<4.17.21`) | every `via[]` source/url/title, **sorted** and comma-joined (duplicates kept) | constant `package-lock.json` |
| OWASP Dependency-Check | CVE-bearing dependency version | CVE | dependency file name |

Only npm applies an ordering, and it applies it to the advisory-id list so that a reordered
`via[]` array does not change the identity. No list is deduplicated and no range is parsed,
canonicalised or re-serialised: the engine records what the scanner said rather than inventing
a normal form it would then have to keep matching across scanner versions.

**A `fingerprints` record for Composer or npm therefore stops matching when the advertised
RANGE changes** — which a scanner database update can do on its own, without the installed
package changing at all. That is a re-review point, not a bug, but it makes fingerprints the
brittle choice for those two sources: prefer `components` (plus `rule_ids` when you mean one
advisory) so the record survives a database refresh and still fails on a genuinely new finding.

### Matching rules

A record matches a finding when **every dimension it declares** matches — declaring more can
only *narrow* an exception, never widen it:

| Field | Matches |
| --- | --- |
| `fingerprints` | the finding's exact canonical fingerprint |
| `components` | the package/component name (survives a version bump) |
| `rule_id` / `rule_ids` | the advisory or rule identifier |
| `files` | the path (exact, path suffix, or basename) |

**Within** a dimension the values are **any-match**: `components: ["a", "b"]` matches a finding
whose component is `a` *or* `b`. **Across** dimensions they **cross-gate**: every declared
dimension must be satisfied by the *same* finding, so a record declaring
`components: ["a","b"]` and `files: ["never.lock"]` accepts nothing at all if no finding sits at
`never.lock` — a dimension that matches nothing vetoes the record rather than being ignored.
Listing a value that matches no current finding is therefore harmless but never widening; it is
still a value a reviewer approved. `tests/prod/286-finding-scoped-suppression.sh` asserts both
halves with every dimension carrying more than one value.

A finding with **no path at all** — package-level advisories from OSV, Trivy and Grype carry
none — cannot satisfy a record that declares `files`. It is reported as unaccepted; it does not
silently match, and it does not disturb the accounting for the findings around it.

```json
{
  "id": "accept-one-medium",
  "gate": "medium_vulnerabilities",
  "scope": "finding",
  "components": ["symfony/http-kernel"],
  "rule_ids": ["CVE-2024-50340"],
  "owner": "platform-team",
  "severity": "medium",
  "reason": "No fixed release yet; the affected code path is not reachable from the web tier.",
  "mitigation": "Upgrade when 6.4.15 lands.",
  "expires_at": "2026-09-30",
  "status": "approved"
}
```

That record accepts **one advisory for one package**. Every other medium finding — including a
*different* advisory for the same package, and a *new* medium finding introduced tomorrow —
remains unaccepted and fails the gate.

**Version changes are deliberate re-review points.** A `fingerprints` record stops matching
once the package version changes, because the version is part of the identity. Use
`components` (optionally with `rule_ids`) when the acceptance is about the package rather than
one exact release.

**Fail-closed on unidentifiable findings.** If `summary.medium_vulnerabilities` counts more
findings than the raw reports can identify (missing, invalid, or a report format that only
carries aggregate counts), the shortfall is **unaccepted** and the gate fails. An unreadable
source never becomes a clean pass. Make the raw reports available to the enforcing job
(`--raw-dir`, default `<summary dir>/raw`).

**Ambiguous records never suppress.** A finding-scoped record that declares none of the four
matching fields is reported as `legacy_unscoped_ignored` and suppresses nothing.

**Broad `scope: gate` is still available, still discouraged, and now louder:** it is reported in
both the JSON (`accepted_risks.medium_vulnerabilities.scope = "gate"`) and the Markdown, with an
explicit warning that it also covers findings that appear later.

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
