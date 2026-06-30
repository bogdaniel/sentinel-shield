# AI-Assisted Install (v1.9.0)

An **optional** on-ramp: paste a ready-made prompt
([`prompts/install-sentinel-shield.md`](../prompts/install-sentinel-shield.md)) into an AI coding agent
and let it install Sentinel Shield into your project **safely**. This does **not** replace the manual
path ([`quickstart.md`](quickstart.md), [`install-sync-quickstart.md`](install-sync-quickstart.md)) —
it's an additional one.

> **AI-assisted install does NOT mean blind auto-install.**
> - The agent **must inspect the project first** (audit before installing).
> - The agent **must not suppress findings** to make the gate green.
> - The agent **must not commit secrets or private artifacts**.
> - The agent **must not modify Sentinel Shield's managed scripts** locally.

## 1. What it is

A structured, copy-paste prompt that drives an AI agent through the **same safe install flow** a
careful human would follow: audit → git hygiene → **acquire an immutable engine checkout** →
profile selection → `install-baseline` → practical gate wiring → local + CI validation → docs →
a final report.

The agent pins an **immutable** ref (a tag or full 40-char SHA — never a moving branch, never an
unreleased-GA placeholder) and acquires the engine into `$SENTINEL_SHIELD_PATH` with
`acquire-sentinel-shield.sh --verify`. **Every** engine script then runs from that checkout
(`"$SENTINEL_SHIELD_PATH/scripts/…"`) — the acquire bootstrap is the only exception, because it
*creates* the checkout:

```sh
SENTINEL_SHIELD_REF=<immutable tag or full SHA>      # never main/master/HEAD/latest
SENTINEL_SHIELD_PATH=.sentinel-shield-tools
sh scripts/acquire-sentinel-shield.sh --repository bogdaniel/sentinel-shield \
  --ref "$SENTINEL_SHIELD_REF" --destination "$SENTINEL_SHIELD_PATH" --verify
```

## 2. When to use it

- Onboarding a new repo and you want a guided, repeatable install.
- You have an AI coding agent available and prefer copy-paste over manual steps.
- **Not** for: changing gate semantics, IaC/AWS/Kubernetes live validation, or "just make CI pass".

## 3. What it does

- Reads the repo to detect stack(s) and existing CI.
- Picks a **profile** and runs `install-baseline.sh` (dry-run first, then `--apply`).
- Wires a **practical, non-IaC** gate (PR-fast first), in `report-only`/`baseline` to start.
- Runs **local validation** and confirms a real `security-summary.json` is produced.
- Writes adoption notes (version/tag, profile, sync command) and a **final report**.

## 4. What it must NOT do

- Rewrite git history, mutate tags, force-push.
- Commit secrets, `.env`, `.claude/`, `vendor/`, `node_modules/`, or raw private scanner artifacts.
- Edit Sentinel Shield's **managed** scripts/workflows locally (override via config, don't fork).
- **Suppress or remediate findings** just to turn the gate green.
- Enable AWS/Kubernetes/IaC **live** validation (IaC stays `ci-validated (evidence-fixture)`).

## 5. Why audit before installing

Installing blind can clobber CI, miss the real stack, or create noise. The agent first inventories the
stack, existing workflows, lockfiles, and `.gitignore` so the profile and gate fit the repo — and so
it never overwrites project-local decisions.

## 6. How to pick a profile

Match the stack: `laravel`, `symfony`, `react`, `node`, `docker`, `php-library`, combinations
(`laravel-react-docker`, `node-react`), or the opt-in `hardened-enterprise`. List them:

```sh
# list profiles FROM THE ACQUIRED CHECKOUT (not the consumer repo root)
ls -d "$SENTINEL_SHIELD_PATH"/profiles/*/ "$SENTINEL_SHIELD_PATH"/profiles/combinations/*.manifest.json
```
See [`install-sync-ux.md`](install-sync-ux.md) and [`profile-adoption-guide.md`](profile-adoption-guide.md).

## 7. How to keep upgrades easy

- Record the **installed tag** (e.g. `v1.9.0`) and the **selected profile** in the repo.
- Keep **managed files separate from overrides** — never hand-edit managed files; override via
  `.sentinel-shield/profile.yaml`.
- Upgrade with **`sync-baseline.sh` dry-run first**, then `--apply --force` after reviewing drift
  ([`install-sync-ux.md`](install-sync-ux.md)).

## 8. How to avoid editing managed files

Managed files carry the shipped behavior; edits are lost on sync. Put project choices in
`.sentinel-shield/profile.yaml` and project-local config (e.g. `phpstan.neon`) which is `never_touch`.

## 9. How accepted risks are handled

Real findings are fixed by the **consumer**, not suppressed. If a risk is genuinely accepted, record
it in `.sentinel-shield/accepted-risks.json` with justification — it is **never auto-created**, and
`secrets` are **never suppressible**. See [`accepted-risk-suppression.md`](accepted-risk-suppression.md).

## 10. How CI is integrated

Start with the **PR-fast** gate (proven), pinned. Add main-gate scanners as advisory, then tighten to
`strict` per readiness. DAST/AI stay manual/non-gating. See [`gate-promotion-policy.md`](gate-promotion-policy.md).

## 11. How to validate locally

```sh
sh "$SENTINEL_SHIELD_PATH/scripts/doctor.sh" --target .          # preflight

# Authoritative local check: reproduces the CI release gate (produces a REAL
# reports/security-summary.json and runs enforce-gates). The opportunistic
# run-local-scanner-sweep.sh is NOT authoritative — a clean sweep never proves a pass.
sh "$SENTINEL_SHIELD_PATH/scripts/run-local-pipeline.sh" --profile <profile> --target . --stage pr

sh "$SENTINEL_SHIELD_PATH/scripts/self-test.sh" all              # engine self-test (run inside the checkout)
```

## 12. How to report failures honestly

If a step fails, the agent records the **exact** error and stops — it does **not** fake a clean
result or suppress findings. Share diagnostics safely with
`sh "$SENTINEL_SHIELD_PATH/scripts/support-bundle.sh"` ([`troubleshooting.md`](troubleshooting.md)).

---

The manual path remains fully supported; AI-assisted install is an **additional** path. Prompt:
[`prompts/install-sentinel-shield.md`](../prompts/install-sentinel-shield.md) (or print it with
`sh scripts/print-ai-install-prompt.sh`).
