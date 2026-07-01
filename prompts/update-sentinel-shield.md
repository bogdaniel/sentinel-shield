# Prompt: Update / Upgrade Sentinel Shield (safe, AI-assisted)

Copy everything below the line into your AI coding agent, running in the target project's repo.
Companion: [`prompts/install-sentinel-shield.md`](install-sentinel-shield.md),
guide: [`docs/install-sync-guide.md`](../docs/install-sync-guide.md).

Pin the target version and the acquisition path once. `SENTINEL_SHIELD_REF` **must** be an immutable
tag or a full commit SHA — never a moving branch, and never a placeholder for an unreleased GA. There
is no default: you supply the exact approved ref:

```sh
export SENTINEL_SHIELD_REF="<approved immutable tag or full SHA>"
export SENTINEL_SHIELD_PATH=".sentinel-shield-tools"
```

Every engine script below runs from the **acquired** checkout (`${SENTINEL_SHIELD_PATH}/scripts/...`),
never from the consumer repo's own `scripts/`. The one exception is the acquisition bootstrap itself
(`acquire-sentinel-shield.sh`), which is what *creates* `${SENTINEL_SHIELD_PATH}`.

---

You are **upgrading an existing Sentinel Shield install** in THIS repository to
`${SENTINEL_SHIELD_REF}`, safely. Sentinel Shield normalizes and gates external scanner output; it
does **not** bundle scanners, and **upgrading a profile does NOT make its tools available**. Work in
small, reviewable steps. **Acquire and verify the pinned engine FIRST. Audit before you change
anything. Never fake a clean gate. Never downgrade the consumer's framework or packages. Stop and
report on any failure.**

## Non-negotiables (hard stops)

- Do **not** run any engine script from the consumer repo's `scripts/`; run them only from the
  acquired, verified `${SENTINEL_SHIELD_PATH}`.
- Do **not** point `acquire-sentinel-shield.sh --destination` (or `--cleanup`) at anything but the
  dedicated tools dir. It validates the destination and **refuses** (exit 2, nothing deleted) `.`,
  `..`, `/`, `$HOME`, the repo root, an ancestor, or a symlink that escapes the tools dir.
- Do **not** set `SENTINEL_SHIELD_REF` to a moving branch (`main`, `master`, `HEAD`, `latest`) or to
  an unreleased / placeholder GA tag. Only an immutable tag or full SHA that already exists upstream.
- Do **not** rewrite git history, mutate/move tags, or force-push.
- Do **not** commit secrets, `.env`, `.claude/`, `vendor/`, `node_modules/`, the acquired
  `${SENTINEL_SHIELD_PATH}` tree, or raw scanner artifacts.
- Do **not** edit Sentinel Shield's managed files locally — upgrade them via sync, override via
  `.sentinel-shield/profile.yaml` / `.sentinel-shield/tool-policy.yaml` only.
- Do **not** suppress, downgrade, or remediate findings just to make the gate green.
- Do **not** convert an `unavailable` / `execution-error` tool into a `0`/clean report.
- Do **not** overwrite project-owned files (`accepted-risks.json`, baselines, `deptrac.yaml`,
  `*.neon`, project configs).
- If anything is ambiguous or fails, **stop and report honestly** — do not guess.

## The upgrade, in order (do NOT skip or reorder)

**1. Acquire and verify the pinned engine FIRST.** Before *anything* else, fetch the target source
for `${SENTINEL_SHIELD_REF}` into `${SENTINEL_SHIELD_PATH}` and verify it. Nothing below runs until
this succeeds:

```sh
sh acquire-sentinel-shield.sh --repository bogdaniel/sentinel-shield --ref "${SENTINEL_SHIELD_REF}" --destination "${SENTINEL_SHIELD_PATH}" --verify
```

`--verify` confirms the ref is immutable and the checkout matches it. Then independently confirm the
checkout, ref, and resolved commit before trusting it:

```sh
git -C "${SENTINEL_SHIELD_PATH}" rev-parse --verify "HEAD^{commit}"
git -C "${SENTINEL_SHIELD_PATH}" rev-parse --verify "${SENTINEL_SHIELD_REF}^{commit}"
# the two SHAs MUST match — if they differ, the checkout is not at the pinned ref; stop.
```

Record the **target resolved SHA** (`git -C "${SENTINEL_SHIELD_PATH}" rev-parse HEAD`). If acquisition
or verification fails, **stop and report** — do not fall back to the consumer's local `scripts/`.

**2. Preserve the current installed metadata.** Snapshot the existing install record *before* any
change, so you can compare and roll back:

```sh
cp .sentinel-shield/installation.json /tmp/ss-installation.before.json
jq '{version, profile, profile_schema, tool_mode, enabled_tools, disabled_tools, managed_files, project_owned_files}' \
    .sentinel-shield/installation.json
```

Record the **from-version** (`.version`), active profile(s), `tool_mode`, and the
`managed_files[]` / `project_owned_files[]` sets. Change nothing yet.

**3. Audit the existing Sentinel Shield install.** Inventory what is currently present:
`.sentinel-shield/` (`installation.json`, `profile.yaml`, `tool-policy.yaml`), `.github/workflows`,
`reports/`, `accepted-risks.json`, baselines. Summarize; change nothing yet.

**4. Compare the current resolved SHA vs the target resolved SHA.** Resolve the **installed**
version and the **target** ref to commits inside the acquired checkout and compare:

```sh
FROM_VER="$(jq -r .version /tmp/ss-installation.before.json)"
git -C "${SENTINEL_SHIELD_PATH}" rev-parse --verify "${FROM_VER}^{commit}"   # current resolved SHA
git -C "${SENTINEL_SHIELD_PATH}" rev-parse --verify "${SENTINEL_SHIELD_REF}^{commit}"  # target resolved SHA
```

If the two SHAs are identical the engine is already at the target — there is nothing to upgrade; report
that and stop. If `${FROM_VER}` does not resolve in the checkout, report it (the prior ref may be
unreachable) and proceed cautiously.

**5. Read the target migration guide.** Before touching files, read the migration/upgrade notes for
`${SENTINEL_SHIELD_REF}` *from the acquired checkout* (e.g.
`${SENTINEL_SHIELD_PATH}/docs/*onboarding-and-migration*.md`,
`${SENTINEL_SHIELD_PATH}/docs/v2-migration-guide.md`, the release notes for the target tag). Note
breaking changes, renamed managed files, and new required tools.

**6. Plan the upgrade.** Run the upgrade planner from the acquired checkout to see the version delta
and required actions (mutates nothing):

```sh
sh "${SENTINEL_SHIELD_PATH}/scripts/plan-upgrade.sh" --target . \
    --from "${FROM_VER}" --to "${SENTINEL_SHIELD_REF}" --profile <name>
```

Review the plan. Do not apply anything yet.

**7. Dry-run the baseline sync and detect drift in managed files.** See exactly which managed files
would change — **dry-run only** (dry-run is the default; `--apply` is NOT used in this step):

```sh
sh "${SENTINEL_SHIELD_PATH}/scripts/sync-baseline.sh" --target . --profile <name>
```

Review the drift report (`created` / `updated` / `up-to-date` / `manual-review-needed` /
`project-local-preserved`). **`manual-review-needed` means a managed file was edited locally** — the
local edit diverges from the release baseline. Treat every such file as a conflict.

**8. Produce a conflict report.** Cross-check the sync drift against the preserved `managed_files[]`
from step 2. For each managed file, classify it: `up-to-date`, `clean-update` (will sync cleanly), or
`local-edit-conflict` (`manual-review-needed` — a managed file was hand-edited and must be reconciled
before sync). List every `local-edit-conflict` explicitly with its path; do **not** silently
overwrite local edits. A local edit to a managed file is lost on `--apply --force`, so it must be
moved into an override (`.sentinel-shield/profile.yaml` / `tool-policy.yaml`) first.

**9. Identify managed vs project-owned files.** From the sync drift and the preserved
`managed_files[]` vs `project_owned_files[]`, separate Sentinel-Shield-**managed** files (safe to
sync) from **project-owned** files (`accepted-risks.json`, baselines, `deptrac.yaml`, `*.neon`,
project configs) that must **not** be overwritten. List both sets explicitly.

**10. Detect new required tools.** Diff the target profile's tool policy against what is installed to
find tools that became `required` (or `recommended`) in the new version:

```sh
sh "${SENTINEL_SHIELD_PATH}/scripts/resolve-tool-plan.sh" --profile <name> --target . --format text
```

Classify each tool by `policy` and by whether its `executable[]` is detected. A newly-`required` tool
that is absent is a config failure you must surface — not silently pass.

**11. Produce a dependency install plan.** For any new/changed tools, generate the exact, **dry-run**
install plan (nothing is mutated):

```sh
sh "${SENTINEL_SHIELD_PATH}/scripts/resolve-tool-plan.sh" --profile <name> --target . --format json
sh "${SENTINEL_SHIELD_PATH}/scripts/bootstrap-profile-tools.sh" --profile <name> --target . --dry-run
```

Present the planned `composer require` / `npm install` commands and version constraints for review.

**12. Avoid framework / package downgrades.** Inspect the dependency plan for any change that would
**downgrade** the project's framework or an existing package. If the plan implies a downgrade, do
**not** apply it — report the conflict and stop. Tool versions must be compatible with the project's
current runtime, never the other way around.

**13. Apply managed changes only after review.** Once the human has reviewed steps 6–12 and every
`local-edit-conflict` has been reconciled into an override, apply the managed-file sync (managed files
only; project-owned files stay untouched):

```sh
sh "${SENTINEL_SHIELD_PATH}/scripts/sync-baseline.sh" --target . --profile <name> --apply --force
```

Confirm `accepted-risks.json`, baselines, and other project-owned files were **not** modified.

**14. Apply dependency changes only explicitly.** Install new tool packages **only** with explicit
opt-in, never as a side effect:

```sh
sh "${SENTINEL_SHIELD_PATH}/scripts/bootstrap-profile-tools.sh" --profile <name> --target . --apply
```

Use `--apply` only after step 12 confirms no downgrade. Skip this entirely in `config-only` /
`require-existing` tool modes.

**15. Run doctor.** Validate the upgraded install end to end, from the acquired checkout:

```sh
sh "${SENTINEL_SHIELD_PATH}/scripts/doctor.sh" --target . --profile <name>
```

**16. Run the project's own tests.** Run the consumer's test suite (e.g. `composer test`,
`npm test`, `vendor/bin/pest`/`phpunit`) and confirm the upgrade did not break the project.

**17. Run the authoritative local pipeline + gates.** Produce a real `reports/security-summary.json`
and enforce, all from the acquired checkout:

```sh
sh "${SENTINEL_SHIELD_PATH}/scripts/run-local-pipeline.sh" --target .
sh "${SENTINEL_SHIELD_PATH}/scripts/enforce-gates.sh" --target .
```

A real finding that blocks the gate is **correct behavior** — report it, do not suppress.

**18. Capture CI run IDs.** Trigger the gate in CI (PR or dispatch) and **record the run ID(s)** and
their result. Confirm the workflow references the pinned `${SENTINEL_SHIELD_REF}` (tag/SHA, not a
branch).

**19. Report failures honestly.** Produce the report below. Any failing gate, missing required tool,
or broken test is reported **verbatim** — never masked, suppressed, or converted to a clean count.

**20. Roll back (package-manager aware) if dependency resolution breaks the project.** If the
dependency changes (step 14) break the build or tests, **roll back** by restoring the pre-upgrade
manifests for **each package manager actually used** in this repo, then re-run tests and report the
failed resolution instead of forcing it through:

```sh
# Composer (PHP) — restore manifest + lockfile if present.
[ -f composer.json ] && git checkout -- composer.json composer.lock 2>/dev/null

# Node — restore the manifest plus WHICHEVER lockfile this repo uses (npm / pnpm / yarn).
[ -f package.json ]      && git checkout -- package.json
[ -f package-lock.json ] && git checkout -- package-lock.json   # npm
[ -f pnpm-lock.yaml ]    && git checkout -- pnpm-lock.yaml       # pnpm
[ -f yarn.lock ]         && git checkout -- yarn.lock            # yarn

# Reinstall from the restored lockfile with the SAME package manager (do NOT switch managers):
#   composer install   |   npm ci   |   pnpm install --frozen-lockfile   |   yarn install --frozen-lockfile
```

`bootstrap-profile-tools.sh` already rolls back `composer.json/lock` + `package.json/lock`
(+ `pnpm-lock.yaml` / `yarn.lock`) automatically on any install/test failure; this manual step is the
fallback if you need to restore by hand. If the engine itself needs reverting, set
`SENTINEL_SHIELD_REF` back to the prior tag, re-acquire (step 1), and re-run sync `--apply --force`.

If a transactional sync/install/migration **cannot complete its own rollback**, it exits **4**,
**retains** its operation lock (`.sentinel-shield/operation-lock.json`, marked
`state:"rollback-incomplete"`) and snapshot directory, and prints the manual recovery steps — it
**never claims success and never deletes the recovery data**. When you see exit 4: report it
verbatim, restore project files from the named `snapshot_dir` (re-validate it is inside the project
first), verify the tree, and only then remove the lock + snapshot dir. Do not re-run the operation
blindly over a held lock.

## Final report (required)

```
Sentinel Shield upgrade report
- repo / stack detected:
- engine acquired + verified at ${SENTINEL_SHIELD_PATH} (ref/SHA): yes/no
- from-version -> to-version (${SENTINEL_SHIELD_REF}):
- current resolved SHA vs target resolved SHA: (same = no-op / differ = upgrade)
- profile(s) / tool provisioning mode:
- installed metadata preserved (installation.json snapshot)? : yes/no
- migration guide read? : yes/no (+ breaking changes noted)
- plan-upgrade.sh result:
- sync dry-run drift (managed files changed):
- managed-file conflict report (local-edit-conflicts):
- managed vs project-owned files: (project-owned preserved? yes/no)
- new required tools detected:
- new recommended tools detected:
- dependency install plan (verbatim commands):
- downgrade conflicts? : MUST be no (else stopped)
- managed changes applied? : yes/no
- dependency changes applied (--apply)? : yes/no
- doctor result:
- project tests: pass/fail (verbatim)
- SS gates (run-local-pipeline + enforce-gates): pass / honest fail — findings NOT suppressed
- CI run id(s) + result:
- rolled back? : yes/no (+ package manager(s) + why)
- blockers / failures (verbatim, honest):
```

Remember: **acquire and verify first, run everything from `${SENTINEL_SHIELD_PATH}`, audit, dry-run
before apply, managed-only sync, preserve project-owned files, no downgrades, never fake a clean gate,
roll back per package manager on breakage, stop and report on failure.**
