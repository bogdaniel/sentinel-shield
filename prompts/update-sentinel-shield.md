# Prompt: Update / Upgrade Sentinel Shield (safe, AI-assisted)

Copy everything below the line into your AI coding agent, running in the target project's repo.
Companion: [`prompts/install-sentinel-shield.md`](install-sentinel-shield.md),
guide: [`docs/install-sync-guide.md`](../docs/install-sync-guide.md).

Set the target version once (immutable tag or full SHA — never a moving branch):

```sh
export SENTINEL_SHIELD_REF=v2.0.0
```

---

You are **upgrading an existing Sentinel Shield install** in THIS repository to
`${SENTINEL_SHIELD_REF}`, safely. Sentinel Shield normalizes and gates external scanner output; it
does **not** bundle scanners, and **upgrading a profile does NOT make its tools available**. Work in
small, reviewable steps. **Audit before you change anything. Never fake a clean gate. Never downgrade
the consumer's framework or packages. Stop and report on any failure.**

## Non-negotiables (hard stops)

- Do **not** rewrite git history, mutate/move tags, or force-push.
- Do **not** commit secrets, `.env`, `.claude/`, `vendor/`, `node_modules/`, or raw scanner artifacts.
- Do **not** edit Sentinel Shield's managed files locally — upgrade them via sync, override via
  `.sentinel-shield/profile.yaml` / `.sentinel-shield/tool-policy.yaml` only.
- Do **not** suppress, downgrade, or remediate findings just to make the gate green.
- Do **not** convert an `unavailable` / `execution-error` tool into a `0`/clean report.
- If anything is ambiguous or fails, **stop and report honestly** — do not guess.

## The upgrade, in order (do NOT skip or reorder)

**1. Audit the existing Sentinel Shield install.** Inventory what is currently present:
`.sentinel-shield/` (`installation.json`, `profile.yaml`, `tool-policy.yaml`), managed scripts,
`.github/workflows`, `reports/`, `accepted-risks.json`, baselines. Summarize; change nothing yet.

**2. Detect the installed version and profile.** Read `.sentinel-shield/installation.json` for the
current `version`, `profile`, `tool_mode`, `enabled_tools`, `disabled_tools`. Record the
**from-version** and **to-version** (`${SENTINEL_SHIELD_REF}`) and the active profile(s).

**3. Read the target migration guide.** Before touching files, read the migration/upgrade notes for
`${SENTINEL_SHIELD_REF}` (e.g. `docs/*onboarding-and-migration*.md`, the release notes for the target
tag). Note breaking changes, renamed managed files, and new required tools.

**4. Plan the upgrade.** Run the upgrade planner to see the version delta and required actions:

```sh
sh scripts/plan-upgrade.sh --target . --from "$(jq -r .version .sentinel-shield/installation.json)" --to "${SENTINEL_SHIELD_REF}"
```

Review the plan. Do not apply anything yet.

**5. Dry-run the baseline sync.** See exactly which managed files would change — **dry-run only**:

```sh
sh scripts/sync-baseline.sh --target . --profile <name>
```

(Dry-run is the default; `--apply` is NOT used in this step.) Review the drift report.

**6. Identify managed vs project-owned files.** From the sync drift and
`.sentinel-shield/installation.json` (`managed_files[]` vs `project_owned_files[]`), separate
Sentinel-Shield-**managed** files (safe to sync) from **project-owned** files
(`accepted-risks.json`, baselines, `deptrac.yaml`, `*.neon`, project configs) that must **not** be
overwritten. List both sets explicitly.

**7. Detect new required tools.** Diff the target profile's tool policy against what is installed to
find tools that became `required` (or `recommended`) in the new version:

```sh
sh scripts/resolve-tool-plan.sh --profile <name> --target . --format text
```

Classify each tool by `policy` and by whether its `executable[]` is detected. A newly-`required` tool
that is absent is a config failure you must surface — not silently pass.

**8. Produce a dependency install plan.** For any new/changed tools, generate the exact, **dry-run**
install plan (nothing is mutated):

```sh
sh scripts/resolve-tool-plan.sh --profile <name> --target . --format json
sh scripts/bootstrap-profile-tools.sh --profile <name> --target . --dry-run
```

Present the planned `composer require` / `npm install` commands and version constraints for review.

**9. Avoid framework / package downgrades.** Inspect the dependency plan for any change that would
**downgrade** the project's framework or an existing package. If the plan implies a downgrade, do
**not** apply it — report the conflict and stop. Tool versions must be compatible with the project's
current runtime, never the other way around.

**10. Apply managed changes only after review.** Once the human has reviewed steps 4–9, apply the
managed-file sync (managed files only; project-owned files stay untouched):

```sh
sh scripts/sync-baseline.sh --target . --profile <name> --apply --force
```

Confirm `accepted-risks.json`, baselines, and other project-owned files were **not** modified.

**11. Apply dependency changes only explicitly.** Install new tool packages **only** with explicit
opt-in, never as a side effect:

```sh
sh scripts/bootstrap-profile-tools.sh --profile <name> --target . --apply
```

Use `--apply` only after step 9 confirms no downgrade. Skip this entirely in `config-only` /
`require-existing` tool modes.

**12. Run doctor.** Validate the upgraded install end to end:

```sh
sh scripts/doctor.sh --target . --profile <name>
```

**13. Run the project's own tests.** Run the consumer's test suite (e.g. `composer test`,
`npm test`, `vendor/bin/pest`/`phpunit`) and confirm the upgrade did not break the project.

**14. Run all Sentinel Shield gates.** Produce a real `reports/security-summary.json` and enforce:

```sh
sh scripts/run-local-security.sh --target .   # or the wired gate entrypoint
sh scripts/enforce-gates.sh --target .
```

A real finding that blocks the gate is **correct behavior** — report it, do not suppress.

**15. Capture CI run IDs.** Trigger the gate in CI (PR or dispatch) and **record the run ID(s)** and
their result. Confirm the workflow references the pinned `${SENTINEL_SHIELD_REF}` (tag/SHA, not a
branch).

**16. Report failures honestly.** Produce the report below. Any failing gate, missing required tool,
or broken test is reported **verbatim** — never masked, suppressed, or converted to a clean count.

**17. Roll back if dependency resolution breaks the project.** If the dependency changes (step 11)
break the build or tests, **roll back**: restore the pre-upgrade lockfile / dependency manifests
(`git checkout -- composer.json composer.lock package.json package-lock.json`), re-run tests to
confirm the project is healthy again, and report the failed resolution instead of forcing it through.

## Final report (required)

```
Sentinel Shield upgrade report
- repo / stack detected:
- from-version -> to-version (${SENTINEL_SHIELD_REF}):
- profile(s) / tool provisioning mode:
- migration guide read? : yes/no (+ breaking changes noted)
- plan-upgrade.sh result:
- sync dry-run drift (managed files changed):
- managed vs project-owned files: (project-owned preserved? yes/no)
- new required tools detected:
- new recommended tools detected:
- dependency install plan (verbatim commands):
- downgrade conflicts? : MUST be no (else stopped)
- managed changes applied? : yes/no
- dependency changes applied (--apply)? : yes/no
- doctor result:
- project tests: pass/fail (verbatim)
- SS gates: pass / honest fail — findings NOT suppressed
- CI run id(s) + result:
- rolled back? : yes/no (+ why)
- blockers / failures (verbatim, honest):
```

Remember: **audit first, dry-run before apply, managed-only sync, no downgrades, never fake a clean
gate, roll back on breakage, stop and report on failure.**
