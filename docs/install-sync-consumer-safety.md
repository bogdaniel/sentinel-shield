# Install / Sync Consumer-Safety Guide (v0.1.25)

> ## CORRECTION (audit)
>
> **The recovery advice below was actively wrong.** For "Partial write (interrupted)" it said
> to "re-run dry-run … then re-apply" — but `tx_detect_stale` refuses to mutate and **exits 4**
> while a prior operation lock exists. Following the documented procedure fails. Use
> `scripts/recover-operation.sh` first; see [`recovery.md`](recovery.md).
>
> The "Honesty banner" below was also inaccurate — it claimed the scripts take no backup and
> that manifest modes were the only safety. `install-baseline.sh`, `sync-baseline.sh` and
> `migrate-v1.sh` all use `scripts/lib/transaction.sh` (12 / 12 / 9 call sites): an operation
> lock, a per-file snapshot taken **before** each write (`tx_install_file`), rollback on
> failure, and `scripts/recover-operation.sh` for a stale lock. **The banner has now been
> rewritten** to describe that transaction accurately, so this note is history rather than an
> outstanding contradiction.


Operator-facing safety playbook for adopting and upgrading Sentinel Shield in a consuming
project: rollback recipes, the self-tests the captain should wire, safe-branch and PR workflow,
version upgrades and pinning, multi-project rollout, and failure recovery.

Companion to [`install-sync-guide.md`](install-sync-guide.md),
[`install-sync-reliability.md`](install-sync-reliability.md),
[`install-sync-quickstart.md`](install-sync-quickstart.md),
[`install-sync-status.md`](install-sync-status.md), and the
[`managed-file-inventory.md`](managed-file-inventory.md).

> **Honesty banner — read this first.** The install/sync scripts implement their safety
> through **manifest modes + a hard-coded protection list** (see the inventory) **and a
> file-snapshot transaction** (`scripts/lib/transaction.sh`, sourced by
> `install-baseline.sh`), which copies each managed file before overwriting it and restores
> it if the operation fails partway.
>
> They still do **NOT**:
> - check whether the target git working tree is clean (no dirty-tree guard),
> - detect or special-case a pre-existing `.github/workflows/sentinel-shield.yml` collision
>   beyond the normal managed-mode rules,
> - run any git command against the target at all.
>
> So the transaction protects you from a **half-applied install**; it does not protect you
> from a **dirty tree**, because it only snapshots the files it is about to manage. Anything
> uncommitted elsewhere in your project is still yours to protect. Keep committing before
> you `--apply` and keep running dry-run first — the rollback recipes below still assume the
> consuming project is a git repo with your work committed.
>
> An earlier revision of this banner said the scripts take **no** backup at all and that git
> was your only net. That predates the transaction layer and was wrong; an operator following
> it would have skipped a recovery path that exists.

---

## 1. Rollback command examples (182–183)

All rollback relies on the **consuming project's** git history. Always commit or stash before
`--apply`.

### 1.1 Rollback a fresh install (182)

A first-time `install-baseline.sh --apply` only **creates** files (it never overwrites without
`--force`). To undo it cleanly:

```sh
# Preferred: you committed before installing, so just discard the install commit's files.
git -C <project> restore --staged --worktree \
  .sentinel-shield/ .github/workflows/sentinel-shield.yml \
  .semgrepignore docs/security/

# Remove newly-created untracked files the install added (review first!):
git -C <project> clean -nd .sentinel-shield/ .github/workflows/ docs/security/   # dry-run preview
git -C <project> clean -fd .sentinel-shield/ .github/workflows/ docs/security/   # actually remove

# Nuclear option if the install was the only change since a known-good commit:
git -C <project> reset --hard <known-good-sha>
git -C <project> clean -fd        # drop untracked install artifacts
```

### 1.2 Rollback a managed-file update from sync `--force` (183)

`sync-baseline.sh --apply --force` overwrites **managed** files in place (today: the workflow,
plus any `overwrite-if-force` entry). There is **no script-side backup**, so use git:

```sh
# See exactly what sync changed:
git -C <project> status
git -C <project> diff -- .github/workflows/sentinel-shield.yml

# Revert just the managed workflow to the committed version:
git -C <project> restore --source=HEAD -- .github/workflows/sentinel-shield.yml

# Or revert everything sync touched in one shot (untracked + tracked):
git -C <project> restore --source=HEAD -- .
git -C <project> clean -fd
```

Because `create-if-missing` and protected files are never overwritten, sync rollback in practice
only ever concerns the managed workflow file(s).

---

## 2. Self-tests the captain should wire (184–189)

These are **specifications**. The captain owns `scripts/self-test.sh` and the test harness; this
section states the intended behavior and the assertion each test must make. For tests that assert
current behavior, the spec first records the **ACTUAL behavior verified against the scripts**.

> The existing self-test already exercises install/sync round-trips (managed drift detect,
> `--apply --force` update, project-local preservation) for the default and `react` profiles and
> in the per-profile matrix loop. The tests below are the **safety-specific** additions.

### 2.1 Dirty-tree behavior (184) — ACTUAL behavior, stated honestly

**Verified against the scripts:** neither `install-baseline.sh` nor `sync-baseline.sh` runs any
git command. `grep -nE 'git |rev-parse|status|stash|HEAD' scripts/install-baseline.sh
scripts/sync-baseline.sh` returns **no matches**. Therefore:

> **Current behavior: the scripts proceed regardless of the target's git state.** A dirty
> working tree, staged changes, or even a non-git target directory does not stop or warn the
> operator. `--apply` / `--apply --force` will write into a dirty tree.

**Test spec (assert the truth, do not pretend a guard exists):**
- Given a target that is a git repo with uncommitted changes, run `install-baseline.sh --apply`.
- Assert exit code `0` and that the install **completed** (files written) — i.e. confirm there is
  **no dirty-tree abort today**.
- Mark the test name to make the gap visible, e.g.
  `install proceeds on dirty tree (no guard — git is the operator's safety net)`.
- **If/when a guard is added later**, flip this test to assert a non-zero exit + a clear message
  and update the Honesty banner above. Until then, the test must document reality.

### 2.2 Missing `.github/workflows` (185)

**Verified:** install creates parent dirs with `mkdir -p "$(dirname "$_tgt")"` before `cp`, so a
target without `.github/workflows/` is fine.

**Test spec:**
- Target has **no** `.github/` directory. Run `install-baseline.sh --apply` (default profile).
- Assert exit `0`, `.github/workflows/sentinel-shield.yml` now exists, and SUMMARY shows the
  workflow under `created`.

### 2.3 Existing-workflow collision (186)

**Verified:** the workflow is `overwrite-if-force`. With a pre-existing
`.github/workflows/sentinel-shield.yml` and **no** `--force`, install reports
`skip (managed, exists; use --force to update)` and does **not** modify the file.

**Test spec:**
- Pre-create `.github/workflows/sentinel-shield.yml` with sentinel content (e.g. `# LOCAL EDIT`).
- Run `install-baseline.sh --apply` (no `--force`). Assert the file is **unchanged** (byte-compare)
  and SUMMARY shows it under `managed-skipped`.
- Run again with `--apply --force`. Assert the file is **overwritten** (sentinel content gone) and
  SUMMARY shows it under `created`.

### 2.4 Sync detects manual edits to a managed file (187)

**Verified:** on drift of an `overwrite-if-force` file without `--force`, sync prints
`manual-review-needed (managed drift; --apply --force to update)`.

**Test spec:**
- Install + apply, then hand-edit `.github/workflows/sentinel-shield.yml`.
- Run `sync-baseline.sh --target <t>` (dry-run). Assert output contains
  `manual-review-needed (managed drift` for that path and the file is **not** modified.

### 2.5 Sync preserves project-local files (188)

**Verified:** on drift of a `create-if-missing` file, sync prints
`project-local-preserved (project owns it; NOT overwritten)`; protected paths print
`project-local-preserved (protected)`. Neither is ever overwritten, even with `--apply --force`.

**Test spec:**
- Install + apply. Hand-edit `.sentinel-shield/profile.yaml` (create-if-missing) and create
  `.sentinel-shield/accepted-risks.json` (protected) with custom content.
- Run `sync-baseline.sh --target <t> --apply --force`.
- Assert **both files are byte-for-byte unchanged**, and SUMMARY counts them under
  `project-local-preserved`.

### 2.6 Sync `--force` updates managed files (189)

**Verified:** on drift of an `overwrite-if-force` file with `--apply --force`, sync copies the
source over the target and reports `updated (managed)`.

**Test spec:**
- Install + apply, hand-edit the managed workflow to drift it.
- Run `sync-baseline.sh --target <t> --apply --force`. Assert the workflow now matches the
  Sentinel Shield source (byte-compare) and SUMMARY shows `updated=1`.

> **Known cosmetic quirk to assert around, not on:** the SUMMARY line is built with
> `grep -c ... || echo 0`, which emits a stray `0` on a new line when grep *does* match. Tests
> should assert on the per-line category tokens (`created`, `updated`, `manual`, `preserved`)
> rather than parsing the SUMMARY line, to stay robust against that formatting artifact.

---

## 3. Safe-branch workflow (190)

Never install or sync onto a consuming project's default branch directly.

```sh
cd <project>
git checkout -b chore/sentinel-shield-install        # isolate the change
sh <sentinel-shield>/scripts/install-baseline.sh --target . --profile <name>   # DRY-RUN first
git status                                            # confirm tree is clean before --apply
sh <sentinel-shield>/scripts/install-baseline.sh --target . --profile <name> --apply
git add -A && git commit -m "chore: adopt Sentinel Shield (<profile>) baseline"
# push the branch and open a PR — do not merge to main without review
```

For sync the same pattern applies: branch, dry-run drift report, review, then `--apply --force`,
commit, PR.

---

## 4. PR review checklist (191)

Before merging an install/sync PR into a consuming project:

- [ ] Branch is **not** the default branch; tree was clean before `--apply`.
- [ ] Dry-run output (install) or drift report (sync) is attached to the PR description.
- [ ] `.sentinel-shield/accepted-risks.json` is **absent or unchanged** (must never come from the tool).
- [ ] `phpstan-baseline.neon` / `phpstan.neon` (PHP profiles) are **unchanged**.
- [ ] `.github/workflows/sentinel-shield.yml` sets `SENTINEL_SHIELD_REPOSITORY` and a **pinned**
      `SENTINEL_SHIELD_REF` (tag or full SHA — **not** a moving branch).
- [ ] No project source files were modified (diff touches only `.sentinel-shield/`,
      `.github/workflows/`, `docs/security/`, and stack config it owns).
- [ ] `profile.yaml` `mode:` matches the intended rollout stage (report-only → baseline → strict).
- [ ] For combination profile: any **manual** split workflows you actually want were copied
      deliberately (they are not auto-installed).
- [ ] Sync PRs only: every `manual-review-needed` entry was reviewed; nothing was force-updated blindly.

---

## 5. Upgrade v0.1.22 → v0.1.25 (192)

```sh
cd <sentinel-shield> && git fetch --tags && git checkout v0.1.25     # update the engine checkout

cd <project> && git checkout -b chore/ss-upgrade-0.1.25
# 1. Drift report against the new release (no writes):
sh <sentinel-shield>/scripts/sync-baseline.sh --target . --profile <name>
# 2. Review every 'manual-review-needed (managed drift ...)' line.
# 3. Update managed files (workflow) after review:
sh <sentinel-shield>/scripts/sync-baseline.sh --target . --profile <name> --apply --force
# 4. Bump the pin in the workflow so CI uses the matching engine:
#    edit .github/workflows/sentinel-shield.yml -> SENTINEL_SHIELD_REF: v0.1.25
git add -A && git commit -m "chore: sync Sentinel Shield baseline to v0.1.25"
```

Notes:
- `accepted-risks.json`, `phpstan-baseline.neon`, and any `create-if-missing` file you've since
  edited are **preserved** automatically — the upgrade only touches managed files.
- The split workflow templates (`pr-fast`, `main`, `scheduled`, ...) are `manual`; if you adopted
  them, re-copy the new versions by hand and re-pin their `SENTINEL_SHIELD_REF` (several ship
  pinned to older tags — see [§6](#6-pinning-sentinel_shield_ref-193)).

---

## 6. Pinning `SENTINEL_SHIELD_REF` (193)

The consuming workflow checks out Sentinel Shield at `SENTINEL_SHIELD_REF`. **Pin it.**

- The main template `templates/workflows/sentinel-shield.yml` ships with `SENTINEL_SHIELD_REF: v0.1.0`
  as a placeholder — **you must change it** to the release you adopted.
- Split workflow templates currently ship pinned to assorted older tags (e.g. `main`/`pr-fast`/
  `scheduled` at `v0.1.21`, `dependency-check` at `v0.1.22`, `ai-review` at `v0.1.12`). If you use
  any of them, re-pin to your adopted release.
- **Strongest pin: a full commit SHA.** A tag is acceptable; a moving branch (`main`) is **not**
  for production — it lets upstream changes execute in your CI without review.

```yaml
env:
  SENTINEL_SHIELD_REPOSITORY: your-org/sentinel-shield
  SENTINEL_SHIELD_REF: <full-40-char-sha>   # or v0.1.25; never a branch name in prod
```

---

## 7. Rollback to a previous Sentinel Shield version (194)

To move a consumer **back** from v0.1.25 to a prior release:

```sh
cd <sentinel-shield> && git checkout v0.1.22         # the engine version you want to return to
cd <project> && git checkout -b chore/ss-rollback-0.1.22
sh <sentinel-shield>/scripts/sync-baseline.sh --target . --profile <name>            # drift vs older release
sh <sentinel-shield>/scripts/sync-baseline.sh --target . --profile <name> --apply --force
# Re-pin the workflow back:
#   SENTINEL_SHIELD_REF: v0.1.22
git add -A && git commit -m "chore: roll Sentinel Shield baseline back to v0.1.22"
```

Sync is symmetric: pointing the engine checkout at an older tag makes the older file versions the
"source", so `--apply --force` rewrites managed files to the older content. Project-local and
protected files are still never touched. If you'd rather not re-sync, simply `git revert` the
upgrade commit in the consumer and re-pin the `REF` — that restores the exact prior managed files.

---

## 8. Multi-project rollout (195)

Onboarding many repos from one Sentinel Shield checkout:

```sh
SS=<sentinel-shield-checkout>
for proj in /path/to/repoA /path/to/repoB /path/to/repoC; do
  echo "=== $proj ==="
  git -C "$proj" checkout -b chore/sentinel-shield-install
  sh "$SS/scripts/install-baseline.sh" --target "$proj" --profile <name>          # DRY-RUN, inspect
done
# After reviewing all dry-runs, apply per-repo on its branch:
for proj in /path/to/repoA /path/to/repoB; do
  sh "$SS/scripts/install-baseline.sh" --target "$proj" --profile <name> --apply
  git -C "$proj" add -A && git -C "$proj" commit -m "chore: adopt Sentinel Shield baseline"
done
```

Guidance:
- **Pin the same `SENTINEL_SHIELD_REF` across the fleet** so every consumer runs the same engine.
- Start every repo in `report-only` mode; promote to `baseline`/`strict` per-repo only after a
  clean run. Use a different `--mode` per repo as needed; it is stamped into each `profile.yaml`.
- Roll out in waves (a canary repo first); the scripts give **no transactional/all-or-nothing**
  guarantee across repos — each is independent, so a failure in one does not roll back others.

---

## 9. Failure recovery (196)

| Failure | What happened | Recovery |
|---|---|---|
| `error: jq is required` | `jq` not installed | Install `jq`; no files were written (the check is before any write). |
| `error: target '<dir>' is not a directory` / `--target is required` | Bad/missing `--target` | Fix the path; nothing was written. |
| `error: no manifest for profile '<name>'` | Unknown `--profile` | Use a valid profile (see inventory); nothing was written. |
| sync: `'<t>/.sentinel-shield' not found — run install-baseline.sh first` | Sync before install | Run `install-baseline.sh --apply` first. |
| `--apply` run into a **dirty tree** by mistake | No guard stopped it (see §2.1) | `git restore`/`git clean` the tool's paths (§1); your other uncommitted work is intermingled, so review `git status` carefully. **Prevent next time: commit before `--apply`.** |
| `--force` overwrote a workflow you'd hand-edited | Managed-file overwrite, no backup taken | `git restore --source=HEAD -- .github/workflows/sentinel-shield.yml` (§1.2). |
| Partial write (interrupted) | `cp` per-file; no transaction | Re-run dry-run to see drift, then re-apply; `git status` shows exactly which files landed. |

General principle: because there is **no script-side backup or transaction**, recovery is always
"use the consuming project's git history." Keep `--apply` runs on a dedicated branch.

---

## 10. Accepted-risk preservation (197)

`.sentinel-shield/accepted-risks.json` is the one file that must **never** originate from or be
modified by the tool — it is your owner-approved risk ledger.

- It is **hard-protected** in both scripts (hard default + every manifest's `never_touch` + an
  extra basename guard). Install reports `PROTECTED`; sync reports `project-local-preserved`.
- Install only ever ships `accepted-risks.example.json` (a template). You copy it to
  `accepted-risks.json` **by hand, when accepting a risk, with owner approval** — never via the tool.
- **Verify after any install/sync/upgrade:** `git -C <project> status --short
  .sentinel-shield/accepted-risks.json` must show **no change**. If it ever shows a modification,
  stop and investigate — that would be a protection regression.

---

## 11. Per-profile install / sync examples (198)

Replace `.` with the project path and `<SS>` with the Sentinel Shield checkout. Always dry-run
first; commit before `--apply`.

```sh
# laravel
sh <SS>/scripts/install-baseline.sh --target . --profile laravel                 # dry-run
sh <SS>/scripts/install-baseline.sh --target . --profile laravel --apply --mode report-only
sh <SS>/scripts/sync-baseline.sh    --target . --profile laravel --apply --force

# react  (also covers Node via stacks: react, node)
sh <SS>/scripts/install-baseline.sh --target . --profile react --apply --mode report-only

# node
sh <SS>/scripts/install-baseline.sh --target . --profile node --apply --mode report-only

# docker
sh <SS>/scripts/install-baseline.sh --target . --profile docker --apply --mode report-only

# php-library
sh <SS>/scripts/install-baseline.sh --target . --profile php-library --apply --mode report-only

# symfony  (psalm.xml / deptrac.yaml / .php-cs-fixer / rector are MANUAL — copy by hand)
sh <SS>/scripts/install-baseline.sh --target . --profile symfony --apply --mode report-only

# laravel-react-docker  (DEFAULT; split workflows are MANUAL — copy the ones you want)
sh <SS>/scripts/install-baseline.sh --target . --apply --mode report-only

# node-react
sh <SS>/scripts/install-baseline.sh --target . --profile node-react --apply --mode report-only
```

PHP profiles: `phpstan.neon` is **not** auto-installed (it is protected). Copy
`<SS>/profiles/<stack>/phpstan.neon` by hand if you want the curated config. See the
[inventory](managed-file-inventory.md) per-profile notes.

---

## 12. For the captain: install/sync-status + readiness-checklist updates (199–200)

Wiring notes so the captain can keep the status/readiness docs honest after this lane lands.

### 12.1 `install-sync-status.md` updates (199)

- The header still reads **v0.1.16**; bump it to the current release and re-confirm the
  per-profile table (the matrix now includes `node-react`, `symfony`, `php-library`).
- Add a **Consumer safety** row/section pointing at this guide and the
  [`managed-file-inventory.md`](managed-file-inventory.md).
- Record the **honest gap** under "Known gaps": *no dirty-tree guard, no backup, no transaction;
  consumer git is the safety net.* (See the Honesty banner.) This is a behavior statement, not a
  bug to fix in this lane.
- Once the captain wires the §2 self-tests, update the status of each safety scenario from
  "spec'd" to "covered by self-test."

### 12.2 Readiness checklist updates (200)

For the relevant readiness checklist(s) (e.g. `docs/product-readiness-checklist.md`,
`docs/project-readiness-checklist.md`), add install/sync consumer-safety line items:

- [ ] Consumer-safety guide + managed-file inventory published (this lane).
- [ ] Self-tests wired for: dirty-tree (asserts current no-guard reality), missing
      `.github/workflows`, existing-workflow collision, sync manual-edit detection, sync
      project-local preservation, sync `--force` managed update (§2).
- [ ] `SENTINEL_SHIELD_REF` pinning documented and the main template's placeholder pin flagged.
- [ ] Rollback recipes validated against a real consumer fixture.
- [ ] Decision recorded on whether to **add** a dirty-tree guard / `--backup` flag, or to keep
      "git is the safety net" as the documented contract. If kept as-is, this guide and the
      Honesty banner are the canonical statement of that contract.
