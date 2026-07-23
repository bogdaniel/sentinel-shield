# Install / Sync Quickstart — Happy Path, Rollback, Troubleshooting (v0.1.24)

The fast on-ramp for onboarding a project onto Sentinel Shield with
`scripts/install-baseline.sh` and keeping it current with `scripts/sync-baseline.sh`.

This is the **quickstart**. For the full behavior reference see
[`install-sync-guide.md`](install-sync-guide.md); for the line-by-line write-path audit, the deep
rollback procedure, the full troubleshooting table, and the release checklist see
[`install-sync-reliability.md`](install-sync-reliability.md); for per-profile behavior and the test
matrix see [`install-sync-productization.md`](install-sync-productization.md). This doc does **not**
duplicate those — it gives the 4-command happy path, the everyday rollback moves, and the most common
install/sync failures with their fix.

Both scripts are **safe by default**: install is dry-run until `--apply`; sync is a dry-run drift
report until `--apply --force`. Neither ever creates or overwrites your risk decisions
(`accepted-risks.json`, `phpstan-baseline.neon`, profile `never_touch` entries).

---

## Quickstart — the 4-command happy path (task 60)

Run from inside your Sentinel Shield checkout (or set `SCRIPT_DIR` accordingly). Replace
`<project>` with your consuming project directory and `<profile>` with the profile from the table
below.

```sh
# 0. (once) pick the profile — detect-stack tells you the stacks present
sh scripts/detect-stack.sh <project>

# 1. DRY-RUN — preview every file install would write; writes NOTHING
sh scripts/install-baseline.sh --target <project> --profile <profile>

# 2. APPLY — actually create profile.yaml + workflow + example files (first install)
sh scripts/install-baseline.sh --target <project> --profile <profile> --apply

# 3. SYNC DRY-RUN — later, against a newer Sentinel Shield ref: preview managed drift
sh scripts/sync-baseline.sh --target <project>

# 4. SYNC APPLY — update managed files (the workflow) after reviewing the drift
sh scripts/sync-baseline.sh --target <project> --apply --force
```

Step 2 also accepts `--mode <report-only|baseline|strict|regulated>` (default `report-only`) which
is stamped into `.sentinel-shield/profile.yaml`. After step 2, complete the manual steps the script
prints (pin `SENTINEL_SHIELD_REF`, set `SENTINEL_SHIELD_REPOSITORY`, copy the example accepted-risks
only when accepting a risk) — these are detailed in
[`install-sync-guide.md`](install-sync-guide.md#manual-steps-still-required-after-install).

### Profile per project type

Use `detect-stack.sh` output, then pick:

| Detected stacks | `--profile` |
|---|---|
| `laravel node react docker` | `laravel-react-docker` (default) |
| `node react` | `node-react` |
| `laravel` | `laravel` |
| `react` | `react` |
| `node` | `node` |
| `php` (no framework) | `php-library` |
| `symfony` | `symfony` |
| `docker` (only) | `docker` |

Each profile's exact file set is in
[`install-sync-productization.md`](install-sync-productization.md#12-what-install-creates--sync-manages-per-profile).
The happy-path summary you should see on a clean apply (per profile): `profile.yaml`,
`accepted-risks.example.json`, the managed workflow, and the profile's stack config + docs created;
`accepted-risks.json` **never** created.

---

## Rollback (task 57)

Install/sync only ever write (a) the managed workflow and (b) project-local files on their **first**
creation — so rollback is narrowly scoped, and protected files have nothing to roll back. The
everyday moves:

```sh
# Undo a managed-workflow install/update — restore the file from your project's git
git -C <project> checkout <good-commit> -- .github/workflows/sentinel-shield.yml

# Undo a --force sync — restore managed files from git, then (optionally) re-sync an older ref
git -C <project> checkout <good-commit> -- .github/workflows/sentinel-shield.yml
#   or pin Sentinel Shield to the previous ref and re-run:
sh scripts/sync-baseline.sh --target <project> --apply --force
```

**Project-local files need no rollback.** `accepted-risks.json`, `phpstan-baseline.neon`, and
`never_touch` entries are never auto-created or overwritten (proven in the self-tests by the
checks `install --force preserves real accepted-risks.json` and
`sync preserves real accepted-risks.json` in `scripts/self-test.sh`).
An edited `profile.yaml` / `.semgrepignore` is `create-if-missing` and is preserved on sync, so a
forced sync cannot have clobbered it.

The full rollback procedure (revert-by-commit, re-sync-from-previous-ref, restore-from-sync) is in
[`install-sync-reliability.md`](install-sync-reliability.md#5-rollback-procedure-task-28).

---

## Install troubleshooting (task 58)

| Symptom | Cause | Fix |
|---|---|---|
| `error: jq is required` | `jq` not on `PATH` | `brew install jq` / `apt-get install jq` (required at install line 51). |
| `error: --target is required` | no `--target` | Pass an existing project dir: `--target <project>`. |
| `error: target '<dir>' is not a directory` | bad path | Create/point at a real directory first. |
| `error: no manifest for profile '<x>'` | wrong `--profile` | Use a valid profile (table above). Resolver checks `profiles/<name>/` then `profiles/combinations/`. |
| `manifest is not valid JSON` | edited/corrupt manifest | Validate: `jq -e . <manifest>`. |
| `skip (missing in Sentinel Shield): <path>` | manifest references a source not in this checkout | Check out the Sentinel Shield ref that matches the manifest. |
| Dry-run "looks like it did nothing" | **By design** — dry-run writes nothing | Re-run with `--apply`. Confirm with `find <project> -type f` (should be unchanged after dry-run). |
| `profile.yaml` mode not what I expected | `--mode` not passed (defaults to `report-only`) | Pass `--mode <X>` on first apply; after first write it is project-owned and `--force` won't revert it. |
| Re-install didn't update `.semgrepignore` / `profile.yaml` | **By design** — `create-if-missing`, project owns it | Edit it directly; `--force` does not touch `create-if-missing` files. |
| `manual` files (e.g. `psalm.xml`, extra workflows) not created | **By design** — `manual` mode prints a notice, writes nothing | Copy them yourself if you want them. |

---

## Sync troubleshooting (task 59)

| Symptom | Cause | Fix |
|---|---|---|
| `error: '<dir>/.sentinel-shield' not found — run install-baseline.sh first.` | running **sync** before install | Run `install-baseline.sh --target <project> --apply` first; sync never bootstraps. |
| Managed drift reported but file unchanged | sync is **dry-run by default** | After reviewing: `sync --target <project> --apply --force`. |
| `--apply` alone didn't update the workflow | managed updates need **both** flags | Use `--apply --force`; without `--force` you get `manual-review-needed` by design. |
| A protected file "won't sync" | **By design** | `accepted-risks.json`, `phpstan-baseline.neon`, `never_touch` paths are never written, even with `--force`. Edit by hand. |
| Edited `profile.yaml` / `.semgrepignore` shows `project-local-preserved` | **By design** — `create-if-missing` project-owned | This is correct; sync will not overwrite your edits. |
| `manual-review-needed` for a `manual`-mode file | that file is `manual` mode (never auto-written) | Update it by hand if wanted; sync intentionally won't. |

Drift categories sync prints: `created` · `updated` · `up-to-date` · `manual-review-needed` ·
`project-local-preserved` · `skipped`. The full troubleshooting table (with line citations) and the
release checklist are in
[`install-sync-reliability.md`](install-sync-reliability.md#6-troubleshooting-task-29).

---

## Cross-references

- [`install-sync-guide.md`](install-sync-guide.md) — behavior, file modes, manual post-install steps.
- [`install-sync-reliability.md`](install-sync-reliability.md) — write-path audit, full rollback, full troubleshooting, release checklist.
- [`install-sync-productization.md`](install-sync-productization.md) — per-profile audit + test-matrix spec.
- [`install-sync-status.md`](install-sync-status.md) — per-stack coverage, known gaps.
