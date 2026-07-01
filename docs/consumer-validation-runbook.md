# Consumer Validation Runbook (v2.0.0 — release-promotion evidence)

> **Scope note (read first).** This runbook defines the evidence required to promote under the
> **`framework-validated`** and **`full-platform`** release tracks. The v2 line currently ships
> under the **`engine-only`** track ([`v2-release-scope.md`](v2-release-scope.md)), which does **not**
> require these consumer runs — an engine-only beta is backed by the engine's own CI instead, and
> **cannot** claim framework-validated status. The five runs below remain **required for
> framework-validated / full-platform** promotion and are **deferred, not removed** (tracked in
> [`v2-tracking-issues.md`](v2-tracking-issues.md), items 9–10). Laravel and Symfony are **supported by
> profiles, fixtures and engine tests but not independently live-validated** until these runs exist.

**Status: MANDATORY for framework-validated / full-platform, currently UNMET (deferred for the
engine-only track).** Under `framework-validated`/`full-platform`, Sentinel Shield v2.0.0 may NOT be
promoted past `alpha` until the five real consumer CI runs below have been produced and their run IDs
captured under `evidence/releases/*.json`. This is a hard, fail-closed requirement enforced by
[`scripts/check-release-readiness.sh`](../scripts/check-release-readiness.sh) (which delegates
the evidence checks to `scripts/validate-release-evidence.sh`). No structural pass, no override,
and no "looks fine locally" substitutes for a **real CI run on a real consumer repository**.

These runs prove Sentinel Shield works on consumers it does not own, end to end, in CI — not just
that its own YAML parses.

## The five MANDATORY consumer profiles

All five are recorded as `consumer_runs[]` entries (one per `stack`) inside a SINGLE
version-keyed evidence file — `evidence/releases/<version>.json` (e.g.
`evidence/releases/v2.0.0.json`), the shape consumed by
[`scripts/validate-release-evidence.sh`](../scripts/validate-release-evidence.sh).

| # | `stack` key        | Consumer shape                                  |
|---|--------------------|-------------------------------------------------|
| 1 | `laravel`          | Laravel app (PHP)                               |
| 2 | `combined_profile` | Laravel + React + Docker (combination profile)  |
| 3 | `symfony`          | Symfony + Doctrine                              |
| 4 | `php_library`      | Framework-agnostic PHP library (Composer pkg)   |
| 5 | `node_react`       | Node / React (no PHP)                           |

`alpha` = structural only (handled by `check-release-readiness.sh`). The consumer runs gate the
higher stages: `laravel` + `symfony` land at **beta**; `php_library`, `node_react`, and
`combined_profile` land at **rc**; **ga** additionally needs `bootstrap_apply`, `rollback_npm`,
`rollback_pnpm`, and `rollback_yarn`. A `stack` only counts as MET when a matching `consumer_runs[]`
entry has a non-empty `workflow_run_id`, `result: "success"`, and `artifacts_verified: true`, AND
the corresponding `required_evidence.<stack>` flag is `true`. See the stage ladder in
`scripts/validate-release-evidence.sh --require-stage <stage>`.

## Per-consumer procedure (repeat for each of the five)

Do this against a **real** consumer repository you control (a throwaway fork of a representative
project is fine). Never run it against production infrastructure, and never commit consumer
secrets.

### 1. Acquire Sentinel Shield at the exact release ref

Pin to the **immutable tag/commit** being promoted — never a moving branch.

```sh
# In a scratch dir, NOT inside the consumer repo:
git clone --depth 1 --branch v2.0.0 https://github.com/<org>/sentinel-shield.git
SS_DIR=$(pwd)/sentinel-shield
```

Record the resolved commit SHA — it goes in the evidence file:

```sh
SS_SHA=$(git -C "$SS_DIR" rev-parse HEAD)
```

### 2. Run the AI-assisted install prompt against the consumer

From the consumer repo root, generate the install prompt and follow it (it inspects the stack,
selects the profile, and installs **config only** — it must not downgrade prod deps or switch
package managers):

```sh
cd /path/to/consumer
sh "$SS_DIR/scripts/print-ai-install-prompt.sh"   # feed this to the AI assistant, then apply
```

Verify the install was non-destructive (no prod dep downgrades, no package-manager switch,
project-owned config untouched). Confirm the chosen profile:

```sh
sh "$SS_DIR/scripts/doctor.sh" --target .
```

### 3. Run the local pipeline (pre-CI smoke)

Prove the scanners run locally before spending CI minutes:

```sh
sh "$SS_DIR/scripts/run-local-security.sh" .
```

Resolve any **tool unavailable** results (exit 3) by installing the tool — never by weakening a
gate or marking an unavailable tool as "passing".

### 4. Trigger the real CI run

Commit the Sentinel-Shield config the install step produced (config only) on a branch in the
consumer repo and open a PR (or push) so the wired workflow runs in CI:

```sh
git checkout -b sentinel-shield/v2.0.0-validation
git add .github/workflows .sentinel-shield
git commit -m "ci: validate Sentinel Shield v2.0.0"
git push -u origin sentinel-shield/v2.0.0-validation
gh pr create --fill           # or rely on push-triggered CI
```

Let CI complete. The run must be **green on a real provider** (GitHub Actions), exercising the
profile's gate — not a local re-run.

### 5. Capture the run ID into evidence/releases/<version>.json

Grab the canonical run identifiers — never copy a SHA by hand:

```sh
gh run list --branch sentinel-shield/v2.0.0-validation --limit 1 \
  --json databaseId,headSha,workflowName,conclusion,url
```

Add (or update) one `consumer_runs[]` entry per `stack` in the single version-keyed evidence file,
and flip the matching `required_evidence.<stack>` flag to `true`. The full file for v2.0.0 looks
like this once all five real runs exist (fields exactly match
`schemas/release-evidence.schema.json`):

```json
{
  "version": "2.0.0",
  "stage": "rc",
  "engine_commit": "<SS_SHA>",
  "required_evidence": {
    "laravel": true,
    "symfony": true,
    "php_library": true,
    "node_react": true,
    "combined_profile": true,
    "bootstrap_apply": false,
    "rollback_npm": false,
    "rollback_pnpm": false,
    "rollback_yarn": false
  },
  "consumer_runs": [
    {
      "stack": "laravel",
      "repository": "<org>/<laravel-consumer>",
      "commit": "<headSha from gh run>",
      "profile": "laravel",
      "tool_mode": "require-existing",
      "workflow_run_id": "<databaseId from gh run>",
      "result": "success",
      "artifacts_verified": true
    }
  ]
}
```

Append one entry each for `symfony`, `php_library`, `node_react`, and `combined_profile` (set
`required_evidence.bootstrap_apply` / `rollback_*` to `true` and add their runs only once those
runs exist — they are required for **ga**). A `stack` is only honored when its `workflow_run_id` is
non-empty, `result` is `"success"`, and `artifacts_verified` is `true`.

> Do NOT flip `result` to `"success"`, set `artifacts_verified: true`, reuse a stale
> `workflow_run_id`, or point at a run that did not actually exercise the profile. The evidence is
> only worth the real CI run behind it; the validator fails closed on an honest empty file.

## Structural vs GitHub-verified evidence

`validate-release-evidence.sh` proves evidence at two different strengths, and the
stage gate cares which one you used:

```sh
# STRUCTURAL only — schema shape + stage ladder, NO network. Proves the file is
# well-formed; it does NOT prove the referenced CI runs actually exist or passed.
sh scripts/validate-release-evidence.sh --file evidence/releases/v2.0.0.json \
   --require-stage beta --offline

# GitHub-VERIFIED — additionally confirms each workflow_run_id really exists, ran
# on the recorded commit, and concluded success (against the GitHub API).
sh scripts/validate-release-evidence.sh --file evidence/releases/v2.0.0.json \
   --require-stage beta --verify-github
```

`--offline` is structural proof only; **`beta` and every stage above it require
GitHub-verified evidence** (`--verify-github`, or a documented equivalent
out-of-band verification recorded in the evidence) before promotion. A structural
(`--offline`) pass is necessary but **not sufficient** for `beta`+ — the existence
of an evidence file or a local fixture is never proof that a real consumer CI run
happened.

## Verifying the gate

After the single evidence file records all five consumer runs, check each promotion stage:

```sh
sh scripts/check-release-readiness.sh --version v2.0.0 --stage alpha   # structural floor
sh scripts/check-release-readiness.sh --version v2.0.0 --stage beta    # + Laravel/Symfony CI
sh scripts/check-release-readiness.sh --version v2.0.0 --stage rc      # + library/node/combined + rollback
sh scripts/check-release-readiness.sh --version v2.0.0 --stage ga      # + clean soak, no open crit/high
```

Exit `0` = ready, `1` = not ready (unmet gate, fail closed), `2` = bad args/environment.

`check-release-readiness.sh` does **not** trust fixtures or a green-looking
checkout. Its structural floor runs the **full** test surface — the self-test
*syntax* pass, the *production-readiness* suite, the *e2e* suite, and the *all*
suite — plus the schema-validity, workflow-template, pinning, hygiene
(no tracked secrets / runtime artifacts), and evidence gates. The mere **existence**
of a fixture or evidence file is not proof; every gate must actually pass. For
`beta`+ it delegates evidence proof to `validate-release-evidence.sh` with
GitHub verification (above) and **fails closed** if that proof is missing or the
evidence is malformed.

## Override (break-glass) — policy DIFFERS by stage

Overrides are an audit event, not a shortcut, and what is permitted **depends on the
stage** you are promoting to:

| Stage | How an unmet gate may be overridden |
| --- | --- |
| `alpha` | CLI `--override-reason "<text>"` is accepted; the script prints a **LOUD** banner and records the bypass. Never a silent pass. |
| `beta` | CLI reason alone is **not** enough — a **version-controlled waiver record** (`.sentinel-shield/release-override.json`) is required: `requested_by` and `approved_by` must be **different** GitHub logins (no self-approval) and the waiver must be **unexpired**. |
| `rc` / `ga` | Overrides are **prohibited** (or require a strict, signed waiver per release policy). Promote only on genuinely met, GitHub-verified evidence. |

```sh
# alpha break-glass (loud, recorded):
sh scripts/check-release-readiness.sh --version v2.0.0 --stage alpha \
   --override-reason "SEC-123: exec sign-off, Symfony run rescheduled to <date>"
```

The version-controlled waiver record is the schema in SHARED CONTRACT #3
(`.sentinel-shield/release-override.json`): `version`, `stage`, `controls[]`,
`reason`, `requested_by`, `approved_by` (a **different** login), `created_at`,
`expires_at`.

**Some things can NEVER be overridden or waived, at any stage:** a tracked **secret**
finding, **malformed evidence**, a **failed rollback**, and any **path-safety** refusal.
An override never makes the missing consumer runs exist — those remain MANDATORY and
UNMET until captured as above.
