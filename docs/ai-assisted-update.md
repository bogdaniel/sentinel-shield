# AI-Assisted Update

An **optional** on-ramp for **upgrading** an existing Sentinel Shield install
through an AI coding agent — the update counterpart to
[`ai-assisted-install.md`](ai-assisted-install.md). Paste the update prompt
([`prompts/update-sentinel-shield.md`](../prompts/update-sentinel-shield.md)) into
an agent and let it drive the **same safe upgrade flow** a careful human follows
in [`upgrading.md`](upgrading.md) / [`v2-migration-guide.md`](v2-migration-guide.md).
This does **not** replace the manual path — it is an additional one.

> **AI-assisted update does NOT mean blind auto-upgrade.**
> - The agent **must dry-run and show drift before writing** (`sync-baseline.sh`).
> - The agent **must not overwrite project-owned files** or hand-edit managed ones.
> - The agent **must not suppress findings** to keep the gate green.
> - The agent **must not commit secrets** or private scanner artifacts.

## 1. What it is

A structured, copy-paste prompt that walks an agent through:
detect installed version/profile (from `.sentinel-shield/installation.json`) →
bump `SENTINEL_SHIELD_REF` → preview the tool plan → `sync-baseline.sh` dry-run →
review drift → `--apply --force` → provision any newly-required tools →
preflight + validate → bump the ref in the workflows → a final report.

## 2. When to use it

- Moving a repo from one release to a newer one (including `v1 → v2`).
- You have an AI agent and prefer guided copy-paste over manual steps.
- **Not** for: changing gate semantics, suppressing findings, or "just make CI
  pass".

## 3. What it does

```sh
# detect what's installed
jq '{version, profile, profile_schema, tool_mode}' .sentinel-shield/installation.json

# preview the new release's tool plan (read-only)
sh scripts/resolve-tool-plan.sh --profile <profile> --target . --format text

# sync managed files: DRY-RUN, then apply after review
sh scripts/sync-baseline.sh --target . --profile <profile>
sh scripts/sync-baseline.sh --target . --profile <profile> --apply --force

# provision newly-required tools (pick a mode — see tool-provisioning.md)
sh scripts/install-baseline.sh --target . --profile <profile> --tool-mode require-existing --apply

# preflight + confirm a real summary is produced
sh scripts/doctor.sh --target . --profile <profile>
```

It records the new installed tag and profile, and reports drift and any
`manual-review-needed` files honestly rather than force-resolving them.

## 4. What it must NOT do

- Rewrite git history, mutate tags, or force-push.
- Commit secrets, `.env`, `.claude/`, `vendor/`, `node_modules/`, or raw private
  scanner artifacts.
- Edit Sentinel Shield's **managed** scripts/workflows locally (override via
  `.sentinel-shield/profile.yaml` / `.sentinel-shield/tool-policy.yaml`, don't
  fork).
- **Suppress or remediate findings** just to turn the gate green.
- Force-install a dependency `conflict` — surface it for a human
  ([`tool-provisioning.md`](tool-provisioning.md#dependency-conflicts)).

## 5. Why dry-run before applying

`sync-baseline.sh` is dry-run by default and emits a drift report
(`created` / `updated` / `up-to-date` / `manual-review-needed` /
`project-local-preserved`). The agent reviews that report **before** any write,
so it never clobbers project-local decisions or your config.

## 6. How rollback works

Tags are immutable. If anything looks wrong, set `SENTINEL_SHIELD_REF` back to the
prior tag and re-run `sync-baseline.sh --apply --force`;
`bootstrap-profile-tools.sh` rolls back dependency files automatically on failure.
Full options: [`upgrading.md`](upgrading.md#rollback).

## 7. How to report honestly

If a step fails, the agent records the **exact** error and stops — it does not
fake a clean result or suppress findings. Share diagnostics safely with
`sh scripts/support-bundle.sh` ([`troubleshooting.md`](troubleshooting.md)).

---

The manual update path remains fully supported; AI-assisted update is an
**additional** path. Prompts:
[`prompts/update-sentinel-shield.md`](../prompts/update-sentinel-shield.md) for
updates, [`prompts/install-sentinel-shield.md`](../prompts/install-sentinel-shield.md)
for first installs (print it with `sh scripts/print-ai-install-prompt.sh`).
</content>
