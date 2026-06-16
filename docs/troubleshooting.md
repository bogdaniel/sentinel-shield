# Troubleshooting

> Reference/support doc (v1.2.0)

Symptom → cause → fix for the most common Sentinel Shield operational failures. The goal
is self-diagnosis: a new team should be able to read a symptom here and resolve it without
escalation. This page **references** the deep-dive docs rather than duplicating them — follow
the links for full detail.

**Exit-code primer (STABLE — see [`product-contract.md`](product-contract.md)).** Engine
scripts return **`0` = success**, **`1` = a gate failed** (findings exist and block), and
**`2` = a config-or-input error** (bad/missing input, invalid JSON, missing required summary
key). When you read a failure, check the exit code first: `1` means "working as designed,
triage the finding"; `2` means "fix the input/config".

---

## How to read a failure

| Exit code | Meaning | First move |
|---|---|---|
| `0` | Success | Nothing — proceed. |
| `1` | Gate failed (findings block) | Triage the finding; accept-risk if justified. **Do not suppress.** |
| `2` | Config / input error | Fix the input, env var, or JSON. Re-run. |
| `3` | DAST guard fail-closed (runners) | Set target/allowlist correctly — see DAST section. |

---

## Install / sync failures

**Symptom: I ran install and nothing was written.**
Cause: install and sync are **dry-run by default** — they print a plan/drift report and exit
without touching the filesystem. Fix: re-run with `--apply` to write. See
[`install-sync-guide.md`](install-sync-guide.md).

**Symptom: sync reports `manual-review-needed` / "managed drift".**
Cause: a **managed** file (mode `overwrite-if-force`) drifted from the shipped baseline. Sync
will not silently overwrite it. Fix: review the drift, then resolve with `--apply --force` to
update managed files only. See [`install-sync-guide.md`](install-sync-guide.md).

**Symptom: my `accepted-risks.json` / `phpstan-baseline.neon` was not created (or I expected sync to overwrite it).**
Cause: **by design.** Project-local files (`.sentinel-shield/accepted-risks.json`,
`phpstan-baseline.neon`, mode `create-if-missing`) are **never created or overwritten** by
install/sync — the project owns them. On drift they are reported `project-local-preserved`.
Fix: create/edit these by hand; `--force` does **not** touch them.

**Symptom: `--force` did not overwrite the file I expected.**
Cause: `--force` overwrites **MANAGED files only**. Project-local files are exempt. Fix:
confirm the file's mode in the manifest; edit project-local files manually.

**Symptom: install/sync exits `2`.**
Cause: bad/missing profile manifest or an unreadable target path. Fix: verify the profile name
and `SENTINEL_SHIELD_REPOSITORY` / `SENTINEL_SHIELD_REF`. See
[`install-sync-guide.md`](install-sync-guide.md).

---

## Workflow failures

**Symptom: a workflow job fails immediately on permissions.**
Cause: workflow templates ship with **minimal permissions** and never use
`pull_request_target`. A consumer override that narrows permissions further can break a job.
Fix: use the shipped templates unmodified; if you must add a permission, add the least scope
needed. See [`security-hygiene.md`](security-hygiene.md) and
[`github-actions-security.md`](github-actions-security.md).

**Symptom: the workflow ran a scanner but the gate still failed.**
Cause: this is correct behaviour — see "gate failed but scanner succeeded" below.

**Symptom: a workflow pinned to a moving branch behaves unexpectedly between runs.**
Cause: `SENTINEL_SHIELD_REF` points at a branch, not a tag/SHA. Fix: pin `SENTINEL_SHIELD_REF`
to a tag or a full commit SHA — never a moving branch.

---

## Scanner failures (generic)

**Symptom: a scanner exited non-zero.**
Cause: depends — findings (exit `1`) vs. a real tool/config error (exit `2`). Fix: check the
exit code and whether a raw artifact was produced.

**Symptom: collector reports `unavailable` for a scanner.**
Cause: the raw input was missing or empty — the scanner did not run or produced no report.
This is **not** fake-clean: `unavailable` means "we do not know", counts are not asserted as
zero. Fix: confirm the scanner step ran and emitted its raw JSON. See
[`raw-report-contract.md`](raw-report-contract.md).

**Symptom: a scanner produced invalid JSON and the collector exited `2`.**
Cause: corrupt/truncated raw report. Fix: re-run the scanner; do not hand-edit the JSON to
make it parse.

---

## IaC: Checkov / Terrascan / Conftest

These are the v1.3.0/v1.4.0 IaC blockers, with the **root cause** of each (see
[`iac-local-evidence-v140.md`](iac-local-evidence-v140.md)). IaC scanners are `experimental`;
the consumer owns IaC remediation.

<a id="checkov-resource_count-0"></a>
**Symptom: Checkov reports `resource_count: 0` / `failed: 0` on real Terraform.**
Cause: the **Docker image** is not analyzing Terraform (this was the v1.3.0 blocker). It is **not**
the wrapper, the collector, or your TF. Fix: run Checkov via **`pip install checkov`** or the
**official GitHub Action** instead of the image. Verified locally: Checkov 3.3.1 via `pip` →
3 resources / 16 findings / 0 parsing errors on the same fixture the image scored 0 on.

**Symptom: Terrascan returns `0 passed / 0 violated` (no findings) on valid Terraform.**
Cause: **provider has no Terrascan policies.** Terrascan ships AWS/Azure/GCP/Kubernetes policies
only — **Hetzner (`hcloud`) is unsupported** (the v1.3.0 surface). Fix: point Terrascan at an
AWS/Azure/GCP/k8s surface (verified: 4 high violations on AWS TF), or use Checkov for `hcloud`.

**Symptom: Conftest produces no output / 0 failures despite a policy that should fire.**
Cause: **namespace + input-shape mismatch.** The repo Rego (`policies/opa/terraform.rego`) is
`package sentinel.terraform` and reads `input.resource_changes` (the `terraform show -json` plan
shape). Running it against raw HCL in the default `main` namespace yields 0. Fix: feed plan-JSON
(`terraform plan -out tfplan && terraform show -json tfplan > plan.json`) and select the namespace
(`conftest test --namespace sentinel.terraform plan.json`). Verified: 2 real failures.

**Reminder:** none of the above is fake-clean — a scanner that genuinely finds nothing maps to
`pass`/0; a scanner that cannot run maps to `unavailable`. IaC is **not** live-validated; promotion
requires a cited consumer-CI run ([`main-gate-live-evidence.md`](main-gate-live-evidence.md)).

---

## Deptrac: missing config / binary

**Symptom: Deptrac collector reports `unavailable`.**
Cause: no `deptrac.yaml` in the consumer, or the `deptrac` binary/PHP runtime is absent. This is
**not** fake-clean. Fix: add a real `deptrac.yaml` (layers + ruleset) and run
`vendor/bin/deptrac analyse --formatter=json`; the collector maps `.Report.Violations` →
`architecture_violations`. Deptrac is `live-validated` (v1.3.0, real consumers) — severity is
binary (violation count), not graded.

---

## Dependency-Check: NVD failures

**Symptom: HTTP 429 / rate-limited during the NVD update.**
Cause: no NVD API key, so DC uses the anonymous (throttled) NVD rate limit. Fix: provide the
GitHub secret `SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY`. The wrapper hands it to DC via a
`0600 --propertyfile`, never on the CLI, so it stays off process listings and logs. See
[`dependency-check-ci-cache.md`](dependency-check-ci-cache.md) and
[`dependency-check-hardening.md`](dependency-check-hardening.md). **Never print, log, or commit
the key value.**

**Symptom: DC failed but I still see a report — should I trust it?**
Cause: a non-zero DC exit is **normal when vulnerabilities are found**. The wrapper validates
the output and **keeps valid JSON on non-zero exit** (preserve-on-nonzero). Fix: trust the
report if it is valid JSON; if no JSON was produced, the collector reports `unavailable`
(never fake-clean). See "scanner failed but artifact exists" below.

**Symptom: transitive dependencies are not scanned.**
Cause: DC only sees what is installed. Transitive scanning needs the dependency tree
materialised. Fix: enable the opt-in install knobs
`SENTINEL_SHIELD_DEPENDENCY_CHECK_INSTALL_PHP` / `INSTALL_NODE` (default `false`) so the
wrapper runs `composer install` / `npm ci`. A **private registry** additionally needs the
consumer to provide registry auth. See [`dependency-check-ci-cache.md`](dependency-check-ci-cache.md)
and [`v1.1-onboarding-and-migration.md`](v1.1-onboarding-and-migration.md).

---

## Dependency-Check: cache / H2 lock

**Symptom: `Unable to obtain an exclusive lock on the H2 database` or `No documents exist`.**
Cause: either a **poisoned cache** (a previous run saved an empty NVD data dir) or a **stale
lock** (`odc.update.lock` / H2 `*.lock`) left by a run killed mid-update (CI timeout /
cancelled job). Fix:
1. The wrapper already deletes stale `*.lock` / `odc.update.lock` from the cache dir before
   running — confirm it executed.
2. Use a **fresh cache namespace** (bump the cache key) so the poisoned empty cache is not
   restored.
3. Ensure the mounted NVD data dir is **container-writable** — the wrapper runs
   `chmod -R a+rwX` on the cache and output dirs (the NVD dataset and reports are not secret;
   the key lives only in the propertyfile).

See [`dependency-check-ci-cache.md`](dependency-check-ci-cache.md).

---

## Dependency-Check: permission issues (container UID)

**Symptom: `propertyfile ... permission denied` inside the container.**
Cause: the propertyfile (or its dir) is not readable by the container user. Fix: the shipped
wrapper already creates a **container-readable** propertyfile (`chmod 755` dir, `644` file);
use the shipped wrapper unmodified rather than supplying your own path.

**Symptom: DC cannot write/update the NVD dataset (bind-mounted data dir).**
Cause: the host cache dir is not writable by the container user, so the H2 dataset cannot be
written or updated. Fix: ensure the mounted data dir is **container-writable**; the wrapper
applies `chmod -R a+rwX` to the cache/output dirs to make this reliable. See
[`dependency-check-hardening.md`](dependency-check-hardening.md).

---

## Semgrep: parser errors

**Symptom: Semgrep parser errors / noisy findings in vendored or generated code.**
Cause: (a) running an un-pinned Semgrep, or (b) scanning `vendor/`, `node_modules/`, build
output, or published assets (e.g. `public/js/filament/**`). Fix:
1. Pin Semgrep to **`1.165.0`** (the version that resolved the parser errors).
2. Copy the profile `.semgrepignore` template to your repo root and run Semgrep from the repo
   root so it takes effect.
3. Use the **curated app rules** — **never** `--config=auto` (see "what NOT to do").

See [`semgrep-scoping.md`](semgrep-scoping.md) and
[`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md).

---

## Artifact missing

**Symptom: I expected a report artifact and there is none.**
Cause: the scanner did not run, or it produced no valid JSON (collector → `unavailable`). This
is **not** the same as a clean result. Fix: confirm the scanner step executed; check logs for a
tool error (exit `2`). Reports live under `reports/` (normalized summary at
`reports/security-summary.json`; raw tool output under `reports/raw/`). See
[`raw-report-contract.md`](raw-report-contract.md).

---

## "Gate failed but scanner succeeded"

**This is correct.** The scanner ran fine **and found something**; the gate exists to block on
findings, so it returns exit `1`. The system is working as designed. Fix: **triage** the
finding — fix it, or record a properly-scoped accepted risk if the team knowingly accepts it.
**Do not suppress** the finding to make the gate green. See
[`gate-resolution.md`](gate-resolution.md).

---

## "Scanner failed but artifact exists"

**This is expected.** A non-zero scanner exit (most commonly Dependency-Check or another
audit) is normal when findings are present. The wrapper **preserves the valid partial/findings
report** (preserve-on-nonzero) rather than discarding it. Fix: trust the artifact if it is
valid JSON. If **no** JSON was produced, the collector reports `unavailable` — it never writes
a fake-clean report. See [`dependency-check-hardening.md`](dependency-check-hardening.md).

---

## Accepted-risk mismatch

**Symptom: I added an accepted risk but the gate still fails.**
Cause: the record does not meet **all** suppression conditions. A record suppresses only when
it is **approved + unexpired + owner-bound + scoped** (matched on `rule_id` + `files`).
Records that are pending, expired, or legacy-unscoped **do not** suppress. Fix:
- Confirm the record is **approved** (a Markdown draft does nothing — only an approved JSON
  record suppresses).
- Confirm it is **unexpired** and **owner-bound**.
- Confirm `rule_id` + `files` actually **match** the finding.
- Note: **secrets are never suppressible** under any accepted-risk record.

See [`accepted-risk-suppression.md`](accepted-risk-suppression.md) and
[`exception-policy.md`](exception-policy.md).

---

## Strict-mode red

**Symptom: I flipped `gates.mode: strict` and now the build is red.**
Cause: **expected** — strict turns medium/style/and other lower-severity categories into hard
blockers. If those were never triaged, strict will go red. Strict is **opt-in**, not required.
Fix: either triage the lower-severity findings first, or stay on `baseline` until you have
completed the strict pre-flight. See [`strict-mode-readiness.md`](strict-mode-readiness.md).

---

## DAST / Nuclei: manual run notes

DAST (OWASP ZAP, Nuclei) is **manual / allowlisted / fail-closed** — never a PR check and
never run by default.

**Symptom: the DAST runner SKIPPED.**
Cause: no `SENTINEL_SHIELD_DAST_TARGET_URL` → no scan (exit `0`, fail-safe). Fix: set a target
you control (staging, not production).

**Symptom: the DAST runner failed closed (exit `3`) on host mismatch.**
Cause: missing `SENTINEL_SHIELD_DAST_ALLOWED_HOST`, the target host ≠ the allowlisted host, or
a non-`http(s)` scheme. Fix: set the allowlist to exactly the target host; use `http`/`https`
only. Nuclei additionally enforces a **controlled template path** guard. See
[`dast-policy.md`](dast-policy.md), [`nuclei-readiness.md`](nuclei-readiness.md), and
[`nuclei-guard.md`](nuclei-guard.md).

**Note:** the AI review step is **non-gating** — it never blocks a build.

---

## What NOT to do

- **Do not suppress findings to go green.** A failing gate with findings is the product
  working. Triage or record a properly-scoped accepted risk — never blanket-suppress.
- **Do not run Semgrep with `--config=auto`.** Use the curated app rules; `auto` reintroduces
  noise and the parser issues that pinning `1.165.0` fixed.
- **Do not print, log, paste, or commit the NVD key value.** It is consumer-provided via a
  GitHub secret and handed to DC only through a `0600` propertyfile. See
  [`security-hygiene.md`](security-hygiene.md).
- **Do not fake-clean.** Never hand-write a zero-finding report when a scanner was
  `unavailable`. `unavailable` ≠ clean.
- **Do not edit project-local files via `--force`.** `--force` is for managed files only;
  `.sentinel-shield/accepted-risks.json` and `phpstan-baseline.neon` stay project-owned.
