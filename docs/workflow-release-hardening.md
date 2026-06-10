# Workflow Release-Hardening — Verification + Self-Test Specs (v0.1.25)

Lane L (tasks 221–240). This document **verifies** the 7 workflow templates against 10 release
rules and records the exact assertions the captain should wire into the `workflow-sanity`
self-test. It extends — does not replace — `docs/workflow-hardening-v024.md` (rules 201–211) and
`docs/workflow-template-adoption.md` (212–219). **No template was edited in this lane; no gate was
weakened.** All evidence below is reproduced verbatim from `grep` over `templates/workflows/*.yml`.

## Scope

Templates verified (7):
`sentinel-shield.yml`, `sentinel-shield-pr-fast.yml`, `sentinel-shield-main.yml`,
`sentinel-shield-scheduled.yml`, `sentinel-shield-dast.yml`, `sentinel-shield-ai-review.yml`,
`sentinel-shield-dependency-check.yml`.

State of the existing self-test: `scripts/self-test.sh workflow-sanity` (function
`run_workflow_sanity`, `ws_check` helper) already asserts **17 checks, all PASS** as of this lane
(captain-owned — verify only, do not edit). The per-rule mapping below names the existing check or
specifies the new/tightened assertion the captain should add.

```
$ sh scripts/self-test.sh workflow-sanity
... 17 checks ...
[sentinel-shield] self-test 'workflow-sanity': PASS
```

---

## Per-rule verification (221–230)

Each rule: PASS verdict, the `grep` evidence, and the **exact `workflow-sanity` assertion**
(in `ws_check "label" "<actual>" "<expected>"` form).

### 221 — Every workflow declares `permissions:` — PASS
`grep -c '^permissions:'` per file = **1** for all 7:
```
ai-review=1  dast=1  dependency-check=1  main=1  pr-fast=1  scheduled=1  sentinel-shield=1
```
All are `contents: read`; `sentinel-shield-main.yml` adds the single documented
`security-events: write` (CodeQL SARIF upload). No write/`id-token`/`packages` scopes anywhere.

**Self-test assertion** (already wired, `run_workflow_sanity`):
`ws_check "all workflows declare permissions" "$_noperm" "0"` where `$_noperm` = count of templates
having **no** `^permissions:` block. Expected `0`.

### 222 — No `pull_request_target` trigger — PASS
No template uses `pull_request_target` as an `on:` trigger:
```
$ grep -rn '^  pull_request_target' templates/workflows/*.yml   ->  NONE (0)
```
Two textual hits exist and are both **comments warning against it**, not triggers:
```
sentinel-shield-dependency-check.yml:19:  contents: read   # minimal — no pull_request_target, no write scopes
sentinel-shield.yml:20:# actions to verified commit SHAs before production. Do not use pull_request_target.
```

**Self-test assertion** (already wired):
`ws_check "no pull_request_target trigger" "$_prt" "0"` where `$_prt` counts
`^[[:space:]]*pull_request_target:` lines across all templates. Expected `0`. (The anchored regex
correctly ignores the two comment mentions.)

### 223 — Every artifact upload uses `if: always()` — PASS
`upload-artifact` step count vs `if: always()` per file:
```
ai-review:         upload=1   if:always()=1
dast:              upload=1   if:always()=1
dependency-check:  upload=1   if:always()=1
main:              upload=1   if:always()=1
pr-fast:           upload=1   if:always()=1
scheduled:         upload=2   if:always()=3   (extra: build-summary step is also if:always())
sentinel-shield:   upload=11  if:always()=12  (extra: gate/release-evidence steps also if:always())
```
Every `upload-artifact` step is immediately guarded by `if: always()` (verified by `-A1`/`-B2`
context: single-upload files carry it on the next line; the combined file's 11 uploads each have
`if: always()` on the preceding line). The surplus `if: always()` counts in `scheduled`/combined are
on **non-upload** steps (build-summary, gate-summary), which is fine. **0** uploads are unguarded.

**Self-test assertion** (already wired):
`ws_check "all artifact uploads use if: always()" "$_noalways" "0"` where `$_noalways` = number of
templates that contain an `upload-artifact` line **without** an adjacent `if: always()`. Expected `0`.
Captain note (carried from 211): the current heuristic is "≥1 `if: always()` per template that
uploads"; tighten to "every upload step has an adjacent `if: always()`" if you want the assertion to
match the rule's intent exactly (today all templates pass either way).

### 224 — Digest env override exists — PASS (scoped)
Every template that runs a **containerized scanner** exposes a `SENTINEL_SHIELD_*_IMAGE` override
(readable tag default, `@sha256:` digest in an adjacent comment):
```
pr-fast:           SENTINEL_SHIELD_SEMGREP_IMAGE          (env + docker run ${VAR:-default})
sentinel-shield:   SENTINEL_SHIELD_SEMGREP_IMAGE          (env + 2 docker run sites)
main:              SENTINEL_SHIELD_GRYPE_IMAGE            (env, + commented container-mode example)
scheduled:         SENTINEL_SHIELD_GRYPE_IMAGE, _DOCKLE_IMAGE, _DEPENDENCY_CHECK_IMAGE
dependency-check:  SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE
ai-review:         (none — no containerized scanner; calls an external AI tool)
dast:              (none — calls runner scripts: zap-baseline/zap-full/nuclei.sh)
```
Honest scope: ai-review and dast legitimately have **no** image-override env var because they run no
scanner container directly. The override exists for **every template that needs one**.

**Self-test assertion** (already wired, 3 checks):
```
ws_check "templates expose SEMGREP image override" ... "yes"
ws_check "templates expose GRYPE image override"   ... "yes"
ws_check "templates expose DOCKLE image override"  ... "yes"
```
each asserting `grep -rl 'SENTINEL_SHIELD_<X>_IMAGE' "$WF_TPL"` count ≥ 1.
Captain (optional add): `ws_check "dep-check exposes DEPENDENCY_CHECK image override"
"$(grep -rl 'SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE' "$WF_TPL" | wc -l)" ...` ≥1 — closes the matrix.

### 225 — DAST manual-only — PASS
`sentinel-shield-dast.yml` `on:` block = **`workflow_dispatch:` only** (with `target_url`,
`allowed_host`, `scan` inputs); no `pull_request`/`push`/`schedule`. Header documents fail-closed on
host mismatch; `SENTINEL_SHIELD_DAST_ALLOWED_HOST` guard present.

**Self-test assertion** (already wired, 2 checks):
```
ws_check "DAST template is workflow_dispatch-only (no pull_request:)" \
         "$(grep -cE '^[[:space:]]*pull_request:' "$_dast")" "0"
ws_check "DAST template references ALLOWED_HOST" \
         "$(grep -c 'SENTINEL_SHIELD_DAST_ALLOWED_HOST' "$_dast")" "1"
```
Captain (optional tighten): also assert `grep -cE '^[[:space:]]*(push|schedule):' "$_dast"` == `0`
so a future `push`/`schedule` trigger can't slip in.

### 226 — Nuclei manual-only — PASS
`nuclei` is referenced **only** in `sentinel-shield-dast.yml` (which is dispatch-only):
```
sentinel-shield-dast.yml:3   (header: requires nuclei-target-allowlist.md)
sentinel-shield-dast.yml:15  (scan input enum: "... | nuclei")
sentinel-shield-dast.yml:46  (nuclei) sh .../scripts/runners/nuclei.sh ...
```
No other template invokes Nuclei, so Nuclei inherits the DAST dispatch-only + allowlist guard.

**Self-test assertion** (new — captain to add):
`ws_check "nuclei only in dispatch-only DAST template"
"$(grep -rl 'runners/nuclei.sh' "$WF_TPL" | grep -vc 'sentinel-shield-dast.yml')" "0"` —
i.e. the Nuclei runner appears in **no** template other than the DAST one. (Today the existing
"DAST uses guarded runners" check already proves `nuclei.sh` is guarded inside DAST; this new check
proves it appears **nowhere else**.)

### 227 — AI non-gating — PASS
`sentinel-shield-ai-review.yml` marks itself `ASSISTIVE … NON-GATING` (header + `::notice::`), and
contains **no** `fail_on.ai_review_findings: true`:
```
:1   # ... ASSISTIVE, NON-DETERMINISTIC, NON-GATING by default.
:28  echo "::notice::AI review is ASSISTIVE and NON-GATING by default. ..."
:31  ... '{"findings":[],"note":"no AI tool wired; non-gating"}' ...
```

**Self-test assertion** (already wired, 2 checks):
```
ws_check "AI review template marked NON-GATING" ... "yes"   (grep -c 'NON-GATING' ≥ 1)
ws_check "AI review template does not force-enable ai gate" \
         "$(grep -vE '^[[:space:]]*#' "$_ai" | grep -c 'fail_on.ai_review_findings: true')" "0"
```
(The `grep -vE '^#'` strips comments so a documentary mention of the flag doesn't false-trip.)

### 228 — Dependency-Check not in PR-fast — PASS
`grep -c 'dependency-check' sentinel-shield-pr-fast.yml` = **0**. PR-fast runs the fast deterministic
`audits/dependency-policy.sh` (a different, fast check) — **not** the slow NVD-backed OWASP
Dependency-Check. Dependency-Check lives only in `scheduled` (RECOMMENDED), `main`
(`MODE: disabled` by default), and the dedicated `dependency-check` evidence workflow.

**Self-test assertion** (new — captain to add):
`ws_check "pr-fast excludes OWASP Dependency-Check"
"$(grep -c 'audits/dependency-check.sh' "$_prfast")" "0"` — asserts the slow scanner's audit wrapper
is **not** invoked in PR-fast. (Match `audits/dependency-check.sh` specifically so `dependency-policy.sh`
is not mistaken for it.)

### 229 — Scheduled scans dispatchable — PASS
Every template with a `schedule:` trigger also has `workflow_dispatch:`:
```
sentinel-shield-scheduled.yml:   schedule (cron "23 3 * * *") + workflow_dispatch   ✓
sentinel-shield-dependency-check.yml: schedule is COMMENTED OUT; active on: = workflow_dispatch ✓
```
Additionally **all 7 templates** expose `workflow_dispatch` (counts: ai-review/dast=2 incl. inputs,
main=3, scheduled/pr-fast/dependency-check/sentinel-shield=1), so every workflow is on-demand runnable.

**Self-test assertion** (existing + new):
- Existing (evidence wf): `ws_check "dep-check evidence has workflow_dispatch"
  "$(grep -cE '^[[:space:]]*workflow_dispatch:' "$_dce")" "1"`.
- New (captain to add — general rule): `ws_check "scheduled template is dispatchable"
  "$(grep -cE '^[[:space:]]*workflow_dispatch:' "$_sched")" "1"` for any template containing an
  active `^[[:space:]]*schedule:` — assert `workflow_dispatch:` present (≥1).

### 230 — Workflow `name:` == filename — PASS
All 7 match (name == filename sans `.yml`):
```
PASS  sentinel-shield            PASS  sentinel-shield-pr-fast
PASS  sentinel-shield-main       PASS  sentinel-shield-scheduled
PASS  sentinel-shield-dast       PASS  sentinel-shield-ai-review
PASS  sentinel-shield-dependency-check
```

**Self-test assertion** (already wired):
`ws_check "workflow name matches filename" "$_namemismatch" "0"` where `$_namemismatch` = number of
templates whose `name:` value ≠ basename without `.yml`. Expected `0`.

---

## Self-test wiring summary (221–230)

| Rule | Existing `workflow-sanity` check | Captain action |
|------|----------------------------------|----------------|
| 221 permissions present | "all workflows declare permissions" | none — covered |
| 222 no pull_request_target | "no pull_request_target trigger" | none — covered |
| 223 upload if:always() | "all artifact uploads use if: always()" | optional: tighten to per-step |
| 224 digest override | SEMGREP/GRYPE/DOCKLE override (×3) | optional: add DEPENDENCY_CHECK override |
| 225 DAST manual-only | dispatch-only + ALLOWED_HOST (×2) | optional: assert no push/schedule |
| 226 Nuclei manual-only | (DAST guarded runners) | **add**: nuclei.sh in no non-DAST template |
| 227 AI non-gating | NON-GATING + no force-enable (×2) | none — covered |
| 228 Dep-Check not in PR-fast | — | **add**: `audits/dependency-check.sh` count==0 in pr-fast |
| 229 scheduled dispatchable | dep-check evidence dispatch (×1) | **add**: any `schedule:` template has workflow_dispatch |
| 230 name == filename | "workflow name matches filename" | none — covered |

Net new captain-owned assertions to add to `run_workflow_sanity`: **226, 228, 229 (general)** — three
checks; **224/223/225 are optional tightenings**. None weakens an existing assertion.

---

## Deltas (231–240)

Concise deltas against the existing docs. Several target docs are **captain-owned / shared** (noted);
this lane records the delta, the captain folds it in.

### 231 — Workflow inventory — `docs/workflow-template-inventory.md` (captain-owned)
Delta: inventory still lists **7 templates** (no add/remove this lane). The v0.1.22 section already
records the dedicated `sentinel-shield-dependency-check.yml` evidence workflow and the `if: always()`
hardening. v0.1.25 delta to fold in: **all 10 release rules (221–230) verified PASS**, and the
`workflow-sanity` self-test now stands at **17 checks PASS** with three new assertions
(226/228/229-general) recommended. No maturity-label, pinning-status, or trigger-scope change.

### 232 — Template adoption — `docs/workflow-template-adoption.md` (captain-owned, v0.1.24)
Delta: §212–§219 remain accurate and complete; **no change required**. This lane confirms §216
("Safe defaults") and §212 ("Template pinning") match the verified template state 1:1 (permissions,
no `pull_request_target`, DAST fail-closed, AI non-gating, digest overrides). Reference, don't
duplicate.

### 233 — Runtime budget — `docs/workflow-template-adoption.md §217` (captain-owned)
Delta: budgets unchanged and accurate. Key invariant re-verified: Dependency-Check is **foreground
only** (`timeout-minutes: 45` + `SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT: 40m`); cold ≤45 min, warm
~5–15 min via monthly NVD `actions/cache`. PR-fast remains the fast lane (~3–8 min) and carries **no**
Dependency-Check (rule 228), preserving its budget. No edit needed.

### 234 — Artifact naming policy — `docs/workflow-template-adoption.md §218` (captain-owned)
Delta: artifact-name table is current. Re-verified invariants: each template's primary artifact name
== the workflow filename (`sentinel-shield-<x>`), `retention-days: 30`, `if-no-files-found: warn`
everywhere **except** the combined file's `security-summary` upload which keeps `error` (surfaces an
empty summary instead of silently passing). `upload-artifact@v4` forbids two jobs sharing one artifact
name — the combined file uploads resolved gates once (from `prepare`). No edit needed.

### 235 — Failure behavior — `docs/workflow-template-adoption.md §219` (captain-owned)
Delta: accurate. Re-verified: gate decision = `enforce-gates.sh` exit `0/1/2`; scanners are
best-effort (`|| true` / `continue-on-error: true`) so a scanner crash never fake-passes (tool stays
`unavailable`, never a fake clean report); every upload is `if: always()` so `reports/**` survives a
failed gate; scheduled + Dependency-Check are report-only; DAST fails closed on host mismatch; AI never
blocks unless the profile opts in. No edit needed.

### 236 — Required secrets — `docs/workflow-template-adoption.md §214` (captain-owned)
Delta: table is correct. Re-verified: **no secret is required for any core gate.** The only secret any
template reads is `ANTHROPIC_API_KEY`, and only in the non-gating AI review (absent → emits an empty
non-gating report). `SENTINEL_SHIELD_RO_TOKEN` is optional (private Sentinel Shield repo);
`vars.SENTINEL_SHIELD_IMAGE` is a repo **var** (not a secret) gating the nightly Dockle step. No edit
needed.

### 237 — Required inputs — `docs/workflow-template-adoption.md §215` (captain-owned)
Delta: accurate. Re-verified the only template with **required `workflow_dispatch` inputs** is
`sentinel-shield-dast.yml`: `target_url` (required), `allowed_host` (required), `scan` (required,
default `zap-baseline`, enum `zap-baseline|zap-full|nuclei`). AI review is opt-in via the `ai-review`
PR label or manual dispatch. All gating templates consume `.sentinel-shield/profile.yaml`. No edit
needed.

### 238 — Template pinning — `docs/workflow-template-adoption.md §212` + `docs/scanner-image-digest-pinning.md` + `docs/pinned-tool-references.md` (captain-owned)
Delta: pinning guidance is current and matches template state. Re-verified honesty caveat: templates
ship **readable tags + `YOUR_ORG`/`TODO` placeholders by default** — consumers MUST pin
`SENTINEL_SHIELD_REF` to a full SHA, pin all third-party `uses:` actions to SHAs, and override
`SENTINEL_SHIELD_*_IMAGE` with `@sha256:` digests (digests live in adjacent comments) before relying on
any template as a production gate. `audit-github-actions-pins.sh` flags unpinned refs into
`unsafe_github_actions`. No edit needed.

### 239 — Main-gate strategy — `docs/main-gate-validation-strategy.md` + `docs/main-gate-live-evidence.md` + `docs/main-gate-execution-hardening-v0.1.19.md` (captain-owned)
Delta: strategy unchanged. Re-verified the chicken-and-egg invariant: `sentinel-shield-main.yml` is
`push` + `workflow_dispatch` only, so it cannot be dispatched from a feature branch until it exists on
the default branch — validate the **same scanners** first with the branch-safe harness
`sh scripts/run-main-gate-validation.sh --target . --output-dir reports/raw --all`, review
`reports/raw/*`, then merge. Main-gate defaults verified: `GRYPE_MODE: sbom`,
`DEPENDENCY_CHECK_MODE: disabled`, `security-events: write` for CodeQL SARIF. Honest maturity: Grype /
Dependency-Check / Dockle remain **attempted, NOT live-validated** (no consumer artifact yet). No edit
needed.

### 240 — Product contract — `docs/product-contract.md` (captain-owned, pre-1.0)
Delta: contract unchanged by this lane. Re-verified consistency: this is a **pre-1.0** project, no
`v1.0` readiness claim is made or implied here. The workflow templates' stability surface
(triggers, permissions, artifact names, gate exit codes `0/1/2`) matches the contract; maturity labels
defer to the single source of truth in the contract / `docs/product-status.md`. DAST/Nuclei/AI remain
manual / non-gating and are explicitly **not** default gates. No edit needed.

---

## Honesty notes

- **No template edited, no gate weakened** in this lane. No `continue-on-error` added to any enforce
  step; `enforce-gates.sh` exit codes (`0` pass / `1` fail / `2` config) unchanged.
- All 10 rules **PASS** against the current templates; evidence is reproduced verbatim from `grep`.
- Rule 224 is **scoped**: ai-review and dast have no image-override env var because they run no scanner
  container — this is correct, not a gap.
- Rules **226, 228, and a general 229** are **not yet** dedicated `workflow-sanity` checks (the
  existing 17 cover them indirectly); the captain should add the three assertions specified above.
- Captain owns and wires `scripts/self-test.sh` `run_workflow_sanity` and the shared docs
  (`workflow-template-inventory.md`, `workflow-template-adoption.md`, `main-gate-*`, `product-*`); this
  lane only records the verification + assertion specs + deltas.
- Templates still ship readable tags / `YOUR_ORG`/`TODO` placeholders — production consumers must pin
  per §238.
