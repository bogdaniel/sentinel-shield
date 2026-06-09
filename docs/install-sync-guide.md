# Install / Sync Productization Guide (v0.1.22)

How `scripts/install-baseline.sh` and `scripts/sync-baseline.sh` onboard and update a consuming
project safely, what they will and will not touch, the managed-file marker strategy, and the manual
steps that remain the operator's responsibility. This is the adoption companion to
[`profile-driven-adoption.md`](profile-driven-adoption.md).

## What install/sync do

Both read a **profile manifest** (`profiles/<name>/profile.manifest.json` or
`profiles/combinations/<name>.manifest.json`) and reconcile the files it declares into a consuming
project. The consuming project never copies workflow logic by hand — it checks Sentinel Shield out
via `SENTINEL_SHIELD_REPOSITORY` / `SENTINEL_SHIELD_REF` and calls its scripts.

- **install-baseline.sh** — first-time onboarding. **Dry-run by default**; writes only with `--apply`.
- **sync-baseline.sh** — update an already-installed project from a newer Sentinel Shield release.
  **Dry-run drift report by default**; updates managed files only with `--apply --force`.

## File modes (manifest `mode`)

| Mode | Install behavior | Sync behavior |
|---|---|---|
| `create-if-missing` | write only if absent; project owns it after | never overwritten — reported `project-local-preserved` on drift |
| `overwrite-if-force` | **managed**: create if absent; overwrite only with `--force` | updated only with `--apply --force`; else `manual-review-needed` |
| `sync-managed-block` | reserved (treated as managed today) | reserved (treated as managed today) |
| `manual` | never auto-written; printed for the maintainer | `manual-review-needed` |

## Managed-file marker strategy

Sentinel Shield uses a **managed-file** strategy (not in-file managed blocks) for whole files it
owns. A managed file is declared `overwrite-if-force` in the manifest and carries a visible banner
so a human reading it knows not to hand-edit it:

```
# === MANAGED BY SENTINEL SHIELD === installed/synced via install-baseline.sh / sync-baseline.sh.
```

Present today in `templates/workflows/sentinel-shield.yml` and `sentinel-shield-pr-fast.yml`. The
contract: **local edits to a managed file are overwritten on `sync --apply --force`.** Keep
project-specific logic out of managed files; put risk decisions in the protected project-local files
below. The `sync-managed-block` mode is reserved for a future in-file marker-block merge; until then
it behaves like `overwrite-if-force` (whole-file managed).

## Files that are NEVER created or overwritten (protected)

Hard-protected by both scripts regardless of `--force`:

- `.sentinel-shield/accepted-risks.json` — your risk acceptances (owner-approved).
- `phpstan-baseline.neon` — your static-analysis baseline.
- Anything listed in the manifest's `never_touch` (e.g. `phpstan.neon` for PHP stacks).
- Any `create-if-missing` file that already exists — the project owns it after first write.

These appear as `PROTECTED` (install) / `project-local-preserved` (sync). This is why you can run
`sync --apply --force` safely: it touches only managed (`overwrite-if-force`) files and never your
decisions or code.

## Manual steps still required after install

`install-baseline.sh --apply` prints these; they are NOT automated by design:

1. **Review `.sentinel-shield/profile.yaml`** — confirm `mode` and project metadata.
2. **Set `SENTINEL_SHIELD_REPOSITORY` and pin `SENTINEL_SHIELD_REF`** (tag, then a full SHA before
   production) in `.github/workflows/sentinel-shield.yml`.
3. **Pin scanner images by digest** before production
   ([`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md)) — override the
   `SENTINEL_SHIELD_*_IMAGE` env vars.
4. **Copy `.sentinel-shield/accepted-risks.example.json` → `accepted-risks.json` only when accepting
   a specific risk** (owner-approved, with expiry) — never as a blanket file.
5. **Wire any stack tools the profile recommends** (see the manifest's
   `recommended_pr_fast_tools` / `recommended_main_gate_tools` / `recommended_scheduled_tools`) and
   confirm a real `tests.json` step.
6. **Run the pipeline** (push/PR or `workflow_dispatch`) and review `reports/`.

## Sync drift categories

`sync-baseline.sh` reports: `created` (was missing) · `updated` (managed file refreshed) ·
`up-to-date` · `manual-review-needed` (managed drift awaiting `--apply --force`, or a `manual`
entry) · `project-local-preserved` (protected/project-owned, untouched). Review a dry-run drift
report before applying.

## Round-trip coverage

Install→sync round-trips are exercised by `scripts/self-test.sh install-sync` (laravel-react-docker)
and `scripts/self-test.sh install-matrix` (docker-only, php-library, node-react) — proving
create-if-missing is preserved, managed files update only with `--force`, and protected files are
never written. See [`install-sync-status.md`](install-sync-status.md).
