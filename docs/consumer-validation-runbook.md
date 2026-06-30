# Consumer Validation Runbook (v2.0.0 — release-promotion evidence)

**Status: MANDATORY and currently UNMET.** Sentinel Shield v2.0.0 may NOT be promoted past
`alpha` until the five real consumer CI runs below have been produced and their run IDs
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
  "version": "v2.0.0",
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

## Verifying the gate

After all five evidence files exist, check each promotion stage:

```sh
sh scripts/check-release-readiness.sh --version v2.0.0 --stage alpha   # structural floor
sh scripts/check-release-readiness.sh --version v2.0.0 --stage beta    # + Laravel/Symfony CI
sh scripts/check-release-readiness.sh --version v2.0.0 --stage rc      # + library/node/combined + rollback
sh scripts/check-release-readiness.sh --version v2.0.0 --stage ga      # + clean soak, no open crit/high
```

Exit `0` = ready, `1` = not ready (unmet gate, fail closed), `2` = bad args/environment.

## Override (break-glass only)

If — and only if — a documented business decision forces promotion with unmet evidence, pass an
explicit reason. The script prints a LOUD banner and records the bypass; it never silently passes:

```sh
sh scripts/check-release-readiness.sh --version v2.0.0 --stage beta \
   --override-reason "SEC-123: exec sign-off, Symfony run rescheduled to <date>"
```

An override is an audit event, not a shortcut. It does not make the missing consumer runs exist —
those remain MANDATORY and UNMET until captured as above.
