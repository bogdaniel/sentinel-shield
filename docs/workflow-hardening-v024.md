# Workflow Template Hardening — Verification Report (v0.1.24)

Lane K (tasks 201–220). Scope: `templates/workflows/*.yml` only. This is a **verification**
pass — the v0.1.22/v0.1.23 hardening (minimal permissions, no `pull_request_target`,
`if: always()` uploads, `SENTINEL_SHIELD_*_IMAGE` overrides, `name == filename`) is re-checked
and only **real** gaps are fixed. No gate was weakened. DAST/Nuclei stay manual-only and AI review
stays non-gating.

Templates audited (7):
`sentinel-shield.yml`, `sentinel-shield-pr-fast.yml`, `sentinel-shield-main.yml`,
`sentinel-shield-scheduled.yml`, `sentinel-shield-dast.yml`, `sentinel-shield-ai-review.yml`,
`sentinel-shield-dependency-check.yml`.

## YAML validity

```
$ ruby -ryaml -e 'ARGV.each{|f| YAML.load_stream(File.read(f))};puts "yaml ok"' templates/workflows/*.yml
yaml ok
```

## Change made this lane

One real gap fixed in `templates/workflows/sentinel-shield.yml`: **8 of its 10 artifact-upload
steps had no `if: always()`** (only the two `release-gate` uploads carried it). The rule "every
artifact upload uses `if: always()`" intends that a failing scan/gate step never erases the raw
reports. The combined template's scanner steps mostly use `continue-on-error: true`/`|| true`, but
an unguarded `set -eu` step (e.g. metadata resolve, summary build) or a checkout failure could
abort the job before the upload and lose the evidence. Added `if: always()` to:

- `Upload gate resolution` (prepare)
- `Upload PHP raw reports` (php-quality)
- `Upload Node raw reports` (node-quality)
- `Upload Docker raw reports` (docker-security)
- `Upload generic raw reports` (security-scan)
- `Upload SBOM` (security-scan)
- `Upload security summary` (build-security-summary) — `if-no-files-found: error` still gates emptiness
- `Upload merged raw artifacts` (build-security-summary)

No other template was modified. The change is upload-resilience only; it does **not** alter trigger
scope, permissions, gate logic, or enforcement exit codes. The self-test `workflow-sanity` suite
(check #6) requires at least one `if: always()` per template; this fix makes **every** upload
guarded, exceeding that bar.

## Per-rule verification (201–211)

### 201 — Every template has minimal `permissions:` — PASS
```
sentinel-shield-ai-review.yml:        permissions: { contents: read }
sentinel-shield-dast.yml:             permissions: { contents: read }
sentinel-shield-dependency-check.yml: permissions: { contents: read }   # minimal — no PRT, no write scopes
sentinel-shield-main.yml:             permissions: { contents: read; security-events: write }   # CodeQL upload
sentinel-shield-pr-fast.yml:          permissions: { contents: read }
sentinel-shield-scheduled.yml:        permissions: { contents: read }
sentinel-shield.yml:                  permissions: { contents: read }
```
All read-only. `sentinel-shield-main.yml` adds the single documented `security-events: write` scope
required to upload CodeQL SARIF — least-privilege for its purpose, not weakened.

### 202 — No `pull_request_target` trigger — PASS
```
$ grep -nE '^\s+pull_request_target\s*:' templates/workflows/*.yml
NONE as trigger (PASS)
```
The only `pull_request_target` string matches are in **comments** (`sentinel-shield.yml` line 20:
"Do not use pull_request_target."; `sentinel-shield-dependency-check.yml` line 19: "no
pull_request_target"). No template declares it as a trigger.

### 203 — Every artifact upload uses `if: always()` — PASS (after fix)
```
sentinel-shield-ai-review.yml:        upload-artifact=1  if:always()=1
sentinel-shield-dast.yml:             upload-artifact=1  if:always()=1
sentinel-shield-dependency-check.yml: upload-artifact=1  if:always()=1
sentinel-shield-main.yml:             upload-artifact=1  if:always()=1
sentinel-shield-pr-fast.yml:          upload-artifact=1  if:always()=1
sentinel-shield-scheduled.yml:        upload-artifact=2  if:always()=3   (extra always() on a Build-summary step)
sentinel-shield.yml:                  upload-artifact=10 if:always()=12   (post-fix; every upload guarded)
```
Per-step confirmation that all 10 uploads in `sentinel-shield.yml` are guarded:
```
ALL uploads guarded by if: always() (PASS)
```

### 204 — Scanner image env vars overridable (`SENTINEL_SHIELD_*_IMAGE`) — PASS
```
sentinel-shield-pr-fast.yml:18  SENTINEL_SHIELD_SEMGREP_IMAGE: semgrep/semgrep:1.165.0
sentinel-shield-pr-fast.yml:57  docker run ... ${SENTINEL_SHIELD_SEMGREP_IMAGE:-semgrep/semgrep:1.165.0}
sentinel-shield.yml:44          SENTINEL_SHIELD_SEMGREP_IMAGE: semgrep/semgrep:1.165.0
sentinel-shield.yml:293/316     docker run ... ${SENTINEL_SHIELD_SEMGREP_IMAGE:-semgrep/semgrep:1.165.0}
sentinel-shield-main.yml:27     SENTINEL_SHIELD_GRYPE_IMAGE: anchore/grype:v0.114.0
sentinel-shield-scheduled.yml:23 SENTINEL_SHIELD_GRYPE_IMAGE: anchore/grype:v0.114.0
sentinel-shield-scheduled.yml:24 SENTINEL_SHIELD_DOCKLE_IMAGE: goodwithtech/dockle:v0.4.15
sentinel-shield-scheduled.yml:87 SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE: owasp/dependency-check:latest
sentinel-shield-dependency-check.yml:55 SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE: owasp/dependency-check:latest
```
Images are declared as env defaults (overridable per repo/secret/var) and either consumed inline via
`${VAR:-default}` (Semgrep) or passed to the `scripts/audits/*.sh` wrappers that read them (Grype,
Dockle, Dependency-Check). Each ships a readable tag with the digest form in an adjacent comment.
`self-test workflow-sanity` independently asserts SEMGREP/GRYPE/DOCKLE overrides are present.

### 205 — Main-gate template can run the harness — PASS
`sentinel-shield-main.yml` documents and points to the branch-safe harness (lines 8–9):
```
#   sh scripts/run-main-gate-validation.sh --target . --output-dir reports/raw --all
```
The harness exists (`scripts/run-main-gate-validation.sh`, executable) and the gate job runs the same
scanner set via `scripts/audits/{osv-scanner,grype,dependency-check,checkov,conftest,terrascan}.sh`
plus CodeQL/Syft/Deptrac. Chicken-and-egg note (workflow_dispatch+push only) is documented so the
template is validated from a branch before it is merged to the default branch.

### 206 — Scheduled template exposes Dependency-Check — PASS
`sentinel-shield-scheduled.yml` has a dedicated `dependency-check:` job (line 57) — foreground,
`timeout-minutes: 45`, monthly NVD `actions/cache`, `SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE: enabled`,
report-only, `if: always()` upload. This is the RECOMMENDED home for the slow NVD scan.

### 207 — DAST template dispatch-only — PASS
```
sentinel-shield-dast.yml  on => { workflow_dispatch: { inputs: target_url(required), allowed_host(required), scan } }
```
Only `workflow_dispatch`. No `pull_request`/`push`/`schedule`. Fails closed without an allowlisted
host; `self-test workflow-sanity` asserts "DAST template is workflow_dispatch-only (no pull_request:)".

### 208 — AI review non-gating — PASS
`sentinel-shield-ai-review.yml` header: "ASSISTIVE, NON-DETERMINISTIC, NON-GATING by default …
NOT a release gate unless the project profile explicitly sets `fail_on.ai_review_findings: true`."
The job only emits an advisory artifact and a `::notice::` ("AI review is ASSISTIVE and NON-GATING by
default"); it never sets a failing exit. `self-test workflow-sanity` asserts the template is marked
NON-GATING and does **not** force-enable the ai gate.

### 209 — Nuclei manual-only — PASS
```
$ grep -rn 'nuclei' templates/workflows/*.yml
sentinel-shield-dast.yml:3   ... nuclei-target-allowlist.md.
sentinel-shield-dast.yml:15  description: "zap-baseline | zap-full | nuclei"
sentinel-shield-dast.yml:46  nuclei) sh .../scripts/runners/nuclei.sh reports/raw/nuclei.json ;;
```
Nuclei appears **only** inside the DAST workflow, which is `workflow_dispatch`-only and host-allowlisted.
No auto-triggered (PR/push/schedule) template references Nuclei.

### 210 — Workflow `name:` matches filename — PASS
```
PASS  sentinel-shield-ai-review.yml         (name: sentinel-shield-ai-review)
PASS  sentinel-shield-dast.yml              (name: sentinel-shield-dast)
PASS  sentinel-shield-dependency-check.yml  (name: sentinel-shield-dependency-check)
PASS  sentinel-shield-main.yml              (name: sentinel-shield-main)
PASS  sentinel-shield-pr-fast.yml           (name: sentinel-shield-pr-fast)
PASS  sentinel-shield-scheduled.yml         (name: sentinel-shield-scheduled)
PASS  sentinel-shield.yml                   (name: sentinel-shield)
```

### 211 — Self-test expectations (for the captain to wire into `workflow-sanity`)
The existing `scripts/self-test.sh` `run_workflow_sanity()` (subcommand `workflow-sanity`) already
asserts the following over `$WF_GH` + `$WF_TPL`. Captain: these are the per-rule expectations; no
new check is strictly required for this lane, but check #6 could be tightened from "≥1 `if: always()`
per template" to "every upload step guarded" to match the rule's intent exactly.

| # | Check (ws_check label) | Expectation |
|---|------------------------|-------------|
| 1 | `no pull_request_target trigger` | count of `^\s+pull_request_target:` == 0 |
| 2 | `all workflows declare permissions` | every wf has a `permissions:` block |
| 3 | `DAST template references ALLOWED_HOST` | == 1 |
| 4 | `DAST template uses guarded runners` | yes |
| 5 | `AI review template marked NON-GATING` | yes |
| 6 | `AI review template does not force-enable ai gate` | == 0 |
| 7 | `DAST template is workflow_dispatch-only (no pull_request:)` | == 0 |
| 8 | `all artifact uploads use if: always()` | 0 templates with an upload but no `if: always()` |
| 9 | `workflow name matches filename` | 0 mismatches |
| 10 | `templates expose SEMGREP image override` | yes |
| 11 | `templates expose GRYPE image override` | yes |
| 12 | `templates expose DOCKLE image override` | yes |
| 13 | `dep-check evidence workflow exists` | yes |
| 14 | `dep-check evidence has workflow_dispatch` | == 1 |
| 15 | `dep-check evidence uses actions/cache` | yes |
| 16 | `dep-check evidence uploads if: always()` | yes |
| 17 | `dep-check evidence has no pull_request_target` | == 0 |

`workflow-sanity` run after this lane's fix:
```
$ sh scripts/self-test.sh workflow-sanity
... all 17 checks PASS ...
[sentinel-shield] self-test 'workflow-sanity': PASS
```

## Inventory delta (220 — captain folds into `docs/workflow-template-inventory.md`)

`docs/workflow-template-inventory.md` is captain-owned (off-limits this lane). The only delta to fold in:

- **`templates/workflows/sentinel-shield.yml` — Known limitations / hardening:** as of v0.1.24, **all
  10 artifact-upload steps now carry `if: always()`** (previously only the two `release-gate` uploads
  did). Raw reports, gate resolution, SBOM, security summary, and merged artifacts are now preserved
  even if a job step fails. No other inventory field changes; maturity labels, pinning status, and
  trigger scope are unchanged for every template.
- No new template was added or removed; the inventory still lists 7 templates.

## Honesty notes
- No gate weakened; no `continue-on-error` added to any enforcement step; enforce-gates exit codes
  (0 pass / 1 fail / 2 config) unchanged.
- DAST and Nuclei remain `workflow_dispatch`-only and host-allowlisted; AI review remains non-gating.
- Templates still ship readable tags / `YOUR_ORG`/`TODO` placeholders by default — consumers must
  pin actions/images to SHAs/digests before production (see `docs/pinned-tool-references.md`).
