# Workflow Execution Model

How a profile's tool policy becomes a CI execution plan, how the workflow is
migrated on upgrade, and how **required-tool enforcement** turns "a tool didn't
run" into a gate decision rather than a silent zero. The policy/state truth table
this builds on is [`profile-tool-policy.md`](profile-tool-policy.md).

## Policy → execution plan

A tool is only legitimately *active* in CI when a job actually invokes its runner
and produces its normalized report. `resolve-workflow-plan.sh` is the bridge: it
reads a (composed) profile manifest's `tools` map and emits, per execution stage,
the enabled tools the workflow must run.

```sh
sh scripts/resolve-workflow-plan.sh --profile laravel --stage all
sh scripts/resolve-workflow-plan.sh --profile laravel --stage pr     # one stage
sh scripts/resolve-workflow-plan.sh --manifest profiles/laravel/profile.manifest.json --stage main
```

Output (JSON) per tool: `tool`, `policy`, `category`, `runner`, `report`,
`missing_behavior`. Stages are `pr`, `main`, `scheduled` — taken from each tool's
`execution: { pr, main, scheduled }` object.

**Selection rule:** every tool whose `policy` is **not** `disabled`/`external`
and whose `execution.<stage>` is `true`. Each entry carries its `policy` so the
consumer can filter to the gating set (`required` / `one-of`).

**Composition:** all composition is delegated to the one canonical resolver
([`resolve-effective-profile.sh`](../scripts/resolve-effective-profile.sh)); no
other script merges manifests. If a manifest declares `extends: [base, …]`, the
base profiles' `tools` maps merge depth-first and the **strongest policy wins**
(`required > one-of > recommended > optional > external > disabled`) — a child can
**never** weaken a required parent tool by redeclaring it. The resolver is
**fail-closed**: an unknown/missing/invalid parent, an inheritance cycle (it
prints the path), an invalid policy value, or an illegal override all exit `2`
with **no plan** — never a warned-and-ignored weaker policy.

## Migrating the workflow on upgrade

The consumer does **not** copy workflow logic by hand — the managed workflow
templates (`templates/workflows/sentinel-shield*.yml`) are installed/synced like
any other managed file and call the engine scripts via `SENTINEL_SHIELD_PATH`.

```sh
# 1. Bump the engine ref.
SENTINEL_SHIELD_REF=v2.0.0
git -C "$SENTINEL_SHIELD_PATH" checkout "$SENTINEL_SHIELD_REF"

# 2. Sync the managed workflow files (dry-run, then apply).
sh scripts/sync-baseline.sh --target . --profile laravel
sh scripts/sync-baseline.sh --target . --profile laravel --apply --force

# 3. Bump SENTINEL_SHIELD_REF in the consumer's .github/workflows/*.yml to the same tag.

# 4. Confirm the stage plan matches what CI runs.
sh scripts/resolve-workflow-plan.sh --profile laravel --stage pr
```

Workflow files are **managed** (`overwrite-if-force` / `sync-managed-block`), so
`--force` is required to update them and your local edits to them are lost —
override behavior via `.sentinel-shield/profile.yaml`, never by forking the
workflow. The stages map to the shipped templates: PR-fast
(`sentinel-shield-pr-fast.yml`), main (`sentinel-shield-main.yml`), and the
scheduled / dependency-check / DAST / AI-review templates.

## <a id="required-tool-enforcement"></a>Required-tool enforcement

The hard rule (full table in [`profile-tool-policy.md`](profile-tool-policy.md)):
an absent or errored tool is **never** converted to a clean zero.

- `required` + `unavailable` / `not-configured` ⇒ **config failure**.
- `required` + `execution-error` / `findings` / `fail` ⇒ **gate failure**.
- `recommended` + `unavailable` ⇒ **warning** (never fails).
- `optional` + `unavailable` ⇒ **info** only.
- `one-of` ⇒ the group passes when at least one member passes; if **none** are
  present, it gates per the group's policy.
- Zero findings are legitimate **only** after a successful run (`pass`).

The **provisioning mode** — chosen at install time (`install-baseline.sh --tool-mode`),
recorded as `tool_mode` in `.sentinel-shield/installation.json`
([schema](../schemas/installation.schema.json)) and honored by `doctor.sh --tool-mode` —
selects how the absence of a required tool is treated:

| `tool_mode` | required tool absent |
| --- | --- |
| `config-only` | warning only — config installed but tools not provisioned yet; does not gate |
| `require-existing` | hard failure (exit 3): every required tool must be present and runnable |
| `bootstrap-tools` | hard failure (exit 3): after bootstrap the required tools are expected present |

A tool whose **policy** is `external` (provided/run outside Sentinel Shield) is never
gated regardless of mode — it ranks below `required` in the policy precedence.

```sh
sh scripts/doctor.sh --target . --profile laravel --tool-mode require-existing
```

This is distinct from the provisioning `--tool-mode` on `install-baseline.sh`
(`config-only` / `require-existing` / `bootstrap-tools`) — that one decides *how
tools get installed*; this one decides *how strictly their absence gates*. See
[`tool-provisioning.md`](tool-provisioning.md).

## Exit-code contract (v2)

The orchestrator/gate scripts share one exit-code vocabulary:

| code | meaning |
| --- | --- |
| `0` | success — a report may still contain findings |
| `1` | policy / gate failure |
| `2` | invalid invocation / configuration |
| `3` | a required tool / dependency is unavailable |
| `4` | execution failure / malformed-or-missing valid report |

**Runner honest-absent exception (do not "fix"):** the legacy runners in
`scripts/runners/*.sh` signal "unavailable" by leaving their report **absent** and
exiting **0** — their self-tests depend on this. `run-tool-plan.sh`,
`build-security-summary.sh`, and `enforce-gates.sh` then **derive** each tool's
status from report presence/validity. The gate is the final decision point:
`enforce-gates.sh` returns only `0/1/2`, folding a required tool that is
`unavailable` (would-be 3) or produced no valid report / `execution-error`
(would-be 4) into a **gate failure (exit 1)**. Codes `3`/`4` belong upstream
(`doctor.sh` exits 3 for absent required tools under `require-existing`/`bootstrap-tools`).

## Verifying the model holds

`resolve-workflow-plan.sh` (what *should* run) and the per-tool `status` in
`reports/security-summary.json` (what *did* run) must agree: a tool in the stage
plan that produced no report is exactly the `unavailable` / `execution-error`
case the gate must catch — not a silent pass.
</content>
