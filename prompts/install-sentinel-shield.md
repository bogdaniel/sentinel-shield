# Prompt: Install Sentinel Shield (safe, AI-assisted)

Copy everything below the line into your AI coding agent, running in the **consumer project's repo**
(the repo you want to protect). This prompt assumes **no Sentinel Shield source tree is present** —
you will *acquire* an immutable checkout first, then drive every Sentinel Shield command **out of that
acquired checkout**, never out of your own repo root.
Guide: [`docs/ai-assisted-install.md`](../docs/ai-assisted-install.md).

---

You are installing **Sentinel Shield** (a release-gate engine + security/quality baseline) into THIS
repository, safely. Sentinel Shield normalizes and gates external scanner output; it does **not**
bundle scanners. Work in small, reviewable steps. **Audit before you install. Never fake a clean
gate. Stop and report on any failure.**

**Installing a profile does NOT make its tools available.** A profile only *declares* a tool policy
(per `schemas/tool-policy.schema.json` / `docs/profile-tool-policy.md`): each tool has a `policy`
(`required` / `recommended` / `optional` / `one-of` / `disabled` / `external`), an `executable[]`
detection list, optional `packages[]`, and a `runner`. Whether those tools actually get installed is
controlled by the **tool provisioning mode** you pick at install time (`--tool-mode`). After install
you MUST report, per the tool policy, which **required** tools are installed vs missing and which
**recommended** tools are installed vs skipped — a missing `required` tool is a config failure, not a
silent pass.

## Non-negotiables (hard stops)

- Do **not** rewrite git history. Do **not** mutate or move tags. Do **not** force-push.
- Do **not** commit secrets, API keys, or the NVD key value.
- Do **not** commit `.env`, `.claude/`, `vendor/`, `node_modules/`, raw private scanner artifacts, or
  the acquired Sentinel Shield checkout (`.sentinel-shield-tools/`).
- Do **not** run Sentinel Shield scripts from your repo root. The consumer repo has **no** managed
  scripts yet; every Sentinel Shield command MUST be invoked through the acquired checkout via
  `$SENTINEL_SHIELD_PATH` (set below). A bare `sh scripts/<name>.sh` would either fail or, worse, run
  some unrelated same-named script from your project — never do it.
- Do **not** modify Sentinel Shield's managed scripts/workflows locally — override via
  `.sentinel-shield/profile.yaml`, never by editing managed files.
- Do **not** suppress, downgrade, or remediate findings just to make the gate green.
- Do **not** downgrade a framework or package to satisfy a tool; only `bootstrap-tools` with explicit
  consent may add dev tools, and it must roll back if it breaks the build.
- Do **not** pin to a **moving branch** (`main`, `master`, `HEAD`) or a not-yet-released "default"
  GA tag. Pin to an **immutable** ref only (a published tag or a full 40-char commit SHA).
- Do **not** enable AWS / Kubernetes / IaC **live** validation unless explicitly requested
  (IaC stays `ci-validated (evidence-fixture)`).
- If anything is ambiguous or fails, **stop and report honestly** — do not guess.

## Install flow (do NOT skip or reorder)

**1. Consumer repository audit.** In THIS repo, detect language/stack(s), package managers,
lockfiles, existing `.github/workflows`, any existing `.sentinel-shield/`, and `.gitignore`.
Summarize what's present. Do not change anything yet.

**2. Detect the stack & package managers.** Confirm PHP (`composer.json` + lockfile, PHP version) and
/or Node (`package.json` + lockfile, Node version), Docker, etc. Note which package managers are in
use — you will **not** switch them. Record gaps (e.g. no lockfile, private registry needing auth).
Do **not** auto-run `composer install` / `npm ci` against private registries without consumer auth.

**3. Select an IMMUTABLE Sentinel Shield version.** Choose a published **tag** (e.g. `v2.0.0`) or a
full **commit SHA** — never a moving branch, never a speculative future-GA default. Pin it once:

```sh
export SENTINEL_SHIELD_REF=v2.0.0   # or a full 40-char commit SHA
export SENTINEL_SHIELD_PATH=.sentinel-shield-tools
```

**4. Acquire an immutable checkout.** Fetch Sentinel Shield at the pinned ref into
`$SENTINEL_SHIELD_PATH` using the acquire bootstrap (the one script you obtain from the Sentinel
Shield repo at the pinned ref; it is the only Sentinel command not run from the checkout, because it
*creates* the checkout). Run with `--verify` so the resolved commit is checked:

```sh
sh scripts/acquire-sentinel-shield.sh \
  --repository bogdaniel/sentinel-shield \
  --ref "$SENTINEL_SHIELD_REF" \
  --destination "$SENTINEL_SHIELD_PATH" \
  --verify
```

**5. Verify the resolved commit SHA.** Record the exact commit the checkout resolved to and confirm
it matches your intended immutable ref (the acquire `--verify` output, or
`git -C "$SENTINEL_SHIELD_PATH" rev-parse HEAD`). This resolved SHA goes in the final report.

**6. Keep the checkout out of git.** Add `.sentinel-shield-tools/` to the consumer `.gitignore`. The
acquired checkout is **tooling**, not project source — it MUST NOT be committed. (Also ensure
`.gitignore` covers `.env`, `.claude/`, `vendor/`, `node_modules/`, `reports/`, build caches. If
secrets/artifacts are already tracked, **report** them and propose removal in a separate commit — do
**not** rewrite history to purge them.)

**7. Discover profiles FROM THE ACQUIRED CHECKOUT.** List profiles shipped at the pinned ref — not
from your repo root:

```sh
ls -d "$SENTINEL_SHIELD_PATH"/profiles/*/ \
      "$SENTINEL_SHIELD_PATH"/profiles/combinations/*.manifest.json
```

**8. Select a profile.** Pick the one matching the detected stack (or `hardened-enterprise` if asked).
State your choice + why.

**9. Resolve the tool policy** *before* installing, so you know what the profile demands and what the
consumer already has:

```sh
sh "$SENTINEL_SHIELD_PATH/scripts/resolve-tool-plan.sh" --profile <name> --target . --format text
```

Classify each tool by `policy` (`required` / `recommended` / `optional` / `one-of` / `disabled` /
`external`) and by whether its `executable[]` is already detected. This is the basis for the install
report — do **not** assume a declared tool is present.

**10. Choose a tool provisioning mode** (`--tool-mode`) and state why:

- `config-only` (default) — installs Sentinel Shield's managed files only; does **not** touch
  `composer.json` / `package.json`. Missing required tools are **reported, non-fatal**. Safest first
  step.
- `require-existing` — installs **no** packages but **fails preflight** if a `required` tool's
  executable is absent (recommended absent → warning). Use when tools are expected present already.
- `bootstrap-tools` — resolves compatible versions and prints the exact install plan (dry-run); with
  `--apply` it installs packages, validates the lockfile, runs tests, and **rolls back on failure**.
  Only with explicit consent (it mutates dependency manifests). Never downgrade a framework/package,
  never switch package managers.

Two **independent** flags: `--tool-mode` (`config-only` | `require-existing` | `bootstrap-tools`) is
*how tools are provisioned*; `--mode` (`report-only` | `baseline` | `strict` | `regulated`) is the
*adoption/gate strictness* written into `.sentinel-shield/profile.yaml`.

**11. Dry-run the install against the consumer target.** Default is dry-run — review before applying:

```sh
sh "$SENTINEL_SHIELD_PATH/scripts/install-baseline.sh" \
  --target . --profile <name> --tool-mode <mode> --emit-plan plan.json
```

**12. Review managed vs project-owned files.** From the dry-run output and `plan.json`, list every
file the installer would write (managed) and confirm it would **not** touch project-owned files
(`accepted-risks.json`, baselines, your `composer.json` / `package.json` unless `bootstrap-tools
--apply`). Do not proceed until this is reviewed.

**13. Apply only after explicit approval.** With consumer sign-off, write the managed files:

```sh
sh "$SENTINEL_SHIELD_PATH/scripts/install-baseline.sh" \
  --target . --profile <name> --tool-mode <mode> --mode baseline --apply [--non-interactive]
```

(`--non-interactive` for CI/automation; omit `--mode` to keep the default `report-only`.) Confirm
project-local files (`accepted-risks.json`, baselines) were **not** touched. Re-run
`resolve-tool-plan.sh` (or read `.sentinel-shield/installation.json`'s `enabled_tools` /
`disabled_tools`) to confirm what is actually present.

**14. Provision dependencies only with explicit `--apply`.** Dependency manifests are mutated **only**
when you run `--tool-mode bootstrap-tools` **with** `--apply` and explicit consent. It validates the
lockfile, runs tests, and rolls back on failure. Otherwise no `composer.json` / `package.json` change
happens. Never downgrade prod deps; never switch package managers.

**15. Doctor (preflight/environment).** Validate the installed state and the profile's tool
activation table:

```sh
sh "$SENTINEL_SHIELD_PATH/scripts/doctor.sh" --target . --profile <name>
```

A missing **required** tool is a config failure (doctor exit 3) — report it, do not mask it.

**16. Run the authoritative local pipeline.** This is the gate's local execution path — **not** an
ad-hoc scanner sweep. It produces the real `reports/security-summary.json`:

```sh
sh "$SENTINEL_SHIELD_PATH/scripts/run-local-pipeline.sh" --target .
```

A real finding that blocks the gate is **correct behavior** — report it, do not suppress it.

**17. Run the consumer project's own tests.** Run the project's existing test suite (its `composer
test` / `npm test` / CI equivalent) and confirm the install did not break the build.

**18. Trigger CI and capture run IDs.** Trigger the gate in CI (PR or `workflow_dispatch`). Confirm it
runs and produces the summary. Capture the **run ID(s)** for the report. An honest failing gate is a
pass for *this* task — record it, do not suppress findings to make it green.

**19. Document the installed version / profile / resolved SHA.** Add a short `SECURITY.md` / README
note recording the installed Sentinel Shield **tag-or-ref**, the **resolved commit SHA** (from step
5), the selected **profile**, the adoption **mode**, and the **sync/upgrade** command. State that the
checkout lives in `.sentinel-shield-tools/` and is git-ignored, and that upgrades re-acquire at a new
immutable ref.

**20. Final report.** Produce the report below.

## Upgradeability rules (restate in the report)

- Keep managed files separate from overrides (override via `.sentinel-shield/profile.yaml`).
- Document the installed Sentinel Shield **ref + resolved SHA** and the selected **profile**.
- Upgrades **re-acquire** at a new immutable ref into `$SENTINEL_SHIELD_PATH`, then run sync from the
  checkout: `sh "$SENTINEL_SHIELD_PATH/scripts/sync-baseline.sh" --target . --profile <name>`.
- **Dry-run sync before applying** any future upgrade; review drift first.
- Start **baseline / report-first** unless the repo is mature enough for `strict`.

## Final report (required)

```
Sentinel Shield install report
- repo / stack detected:
- package managers detected (NOT switched):
- immutable ref selected (tag or full SHA; NOT a branch):
- resolved commit SHA (verified):
- acquired checkout path (git-ignored, NOT committed): .sentinel-shield-tools/
- profile selected (+ why):
- adoption mode (report-only/baseline/strict/regulated):
- tool provisioning mode (config-only / require-existing / bootstrap-tools):
- required tools INSTALLED (executable detected):
- required tools MISSING (config failure — do NOT mask):
- recommended tools INSTALLED:
- recommended tools SKIPPED (warning only):
- files written (managed):    # from install-baseline dry-run/apply
- project-owned files preserved (accepted-risks.json, baselines, manifests): yes/no
- dependency manifests mutated? (only if bootstrap-tools --apply): yes/no
- doctor result (exit code / required-tool gate):
- local pipeline: run-local-pipeline produced security-summary.json? yes/no
- project tests: pass/fail
- CI validation: run id(s) / result (pass or honest fail — findings NOT suppressed):
- git hygiene: .gitignore covers .env/.claude/vendor/node_modules/reports/.sentinel-shield-tools? yes/no
- secrets/artifacts committed? : MUST be no
- version/profile/SHA documented? : yes/no
- sync/upgrade command documented? : yes/no
- blockers / failures (verbatim, honest):
```

Remember: **acquire an immutable checkout first, drive every command through `$SENTINEL_SHIELD_PATH`,
audit before you install, never fake a clean gate, never commit secrets or the checkout, stop and
report on failure.**
