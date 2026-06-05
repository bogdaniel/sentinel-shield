# GitHub Fixture Run

How to execute this reference integration in a throwaway GitHub repository to
validate the Sentinel Shield plumbing end-to-end on a real runner: external
checkout, pinned ref, artifact upload/download, raw scanner output,
build → select → enforce, and `report-only` behavior.

> This proves the **wiring**, not your application's security. Findings on a near-empty
> fixture repo are expected to be near-zero.

---

## 0. Prerequisites

Complete [`github-preflight-checklist.md`](github-preflight-checklist.md) first. In
short: Sentinel Shield is published as a GitHub repo, tagged `v0.1.0`, and reachable
from the fixture repo's Actions.

---

## 1. Create a throwaway fixture repo

```sh
# A new, empty repo on GitHub (private is fine), default branch master.
gh repo create YOUR_ORG/sentinel-shield-fixture --private --confirm
git clone https://github.com/YOUR_ORG/sentinel-shield-fixture
cd sentinel-shield-fixture
git checkout -b master 2>/dev/null || git branch -M master
```

Ensure **Actions are enabled** for the repo (Settings → Actions → General).

---

## 2. Copy the example files into the repo root

Copy the contents of `examples/laravel-react-docker/` to the fixture repo root so the
workflow lands at `.github/workflows/sentinel-shield.yml`:

```sh
SS=/path/to/sentinel-shield/examples/laravel-react-docker
# Minimal fixture (recommended first run): copy everything EXCEPT the illustrative
# app manifests, so the PHP/Node stack jobs cleanly skip and you test the plumbing.
rsync -a --exclude composer.json --exclude package.json "$SS"/ ./
# (Copy composer.json / package.json / a Dockerfile later, when wiring a real app.)
```

What this gives the fixture:

```txt
.sentinel-shield/profile.yaml          # report-only
.github/workflows/sentinel-shield.yml
docs/security/...
scripts/sentinel/...                   # normalizers (not run without an app)
reports/.gitkeep, reports/raw/.gitkeep
.gitignore
```

> Minimal fixture mode is supported by the workflow itself: `php-quality` skips when
> there is no `composer.json`, `node-quality` skips without `package.json`, and
> `docker-security` skips without a `Dockerfile`/compose file — each emits a
> `::warning::` and exits 0. `security-scan` always runs. Nothing is faked.

---

## 3. Point the workflow at Sentinel Shield

Edit `.github/workflows/sentinel-shield.yml` `env:`:

```yaml
env:
  SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/sentinel-shield   # the published Sentinel Shield repo
  SENTINEL_SHIELD_REF: v0.1.0                            # a TAG for first adoption
  SENTINEL_SHIELD_PATH: tools/sentinel-shield
```

- **First run:** use the **tag** `v0.1.0` (readable, easy to update).
- **Before production:** replace with a **full commit SHA**, e.g.
  `SENTINEL_SHIELD_REF: 1a2b3c4d…` (40 hex chars), so the ref cannot move under you.
- **Private Sentinel Shield repo:** add a read token to each
  `Checkout Sentinel Shield` step:
  `token: ${{ secrets.SENTINEL_SHIELD_RO_TOKEN }}` (a fine-grained PAT or deploy key
  with read access), and store it as a repo secret.

Also set `project.name` in `.sentinel-shield/profile.yaml` (replace
`PROJECT_NAME_HERE`).

Commit and push:

```sh
git add -A && git commit -m "fixture: Sentinel Shield report-only run" && git push -u origin master
```

---

## 4. Run the workflow

The workflow triggers on push to `master` and on pull requests. To run it on demand:

```sh
gh workflow run sentinel-shield.yml --ref master
gh run watch        # or: gh run list --workflow sentinel-shield.yml
```

Or in the UI: Actions → `sentinel-shield` → Run workflow → branch `master`.

---

## 5. Artifacts to inspect

After the run, download artifacts (Actions → the run → Artifacts, or
`gh run download <run-id>`):

| Artifact | Contains | What to check |
| --- | --- | --- |
| `sentinel-shield-raw-security` | `gitleaks.json`, `semgrep.json`, `trivy.json` | scanners produced JSON |
| `sentinel-shield-raw-security-{php,node,docker}` | per-stack raw (present only if that stack ran) | skipped stacks have no artifact |
| `sentinel-shield-sbom` | `sbom.spdx.json` | SBOM produced (or absent → `missing_sbom`) |
| `sentinel-shield-security-summary` | `security-summary.json` | the merged, normalized findings |
| `sentinel-shield-gate-resolution` | `sentinel-shield-gates.{env,json,md}` | resolved mode = `report-only` |
| `sentinel-shield-enforcement` | `sentinel-shield-enforcement.{json,md}` | overall result |
| `sentinel-shield-release-evidence` | `release-evidence.md` | rollup assembled |

---

## 6. Expected outcome in report-only

- **Overall result: PASS.** In `report-only` only `secrets` and `expired_exceptions`
  block. With a near-empty fixture and no committed secrets, the gate passes.
- **Warnings are expected**, not failures: "no composer.json", "no package.json",
  "no Docker files", and any scanner container that could not run.
- Stacks with no files produce **no** per-stack raw artifact; the builder records
  those tools as `unavailable` (counts 0) — this is correct, not an error.

If the gate **fails** in report-only, it almost certainly found a real secret
(Gitleaks) — inspect `security-summary.json` `.summary.secrets` and the
`sentinel-shield-raw-security/gitleaks.json` artifact, and remove the secret.

---

## 7. Interpreting the reports

```sh
gh run download <run-id> -n sentinel-shield-security-summary
gh run download <run-id> -n sentinel-shield-enforcement

jq '.summary' security-summary.json          # the 12 normalized counts/flags
jq '.tools'   security-summary.json           # per-tool status (pass/unavailable/...)
jq '{mode,result,failed_gates}' sentinel-shield-enforcement.json
cat sentinel-shield-enforcement.md            # human rollup: which gates blocked
```

- `security-summary.json` — what was found, normalized. `unavailable` tools mean no
  raw artifact was produced (stack skipped or tool absent).
- `sentinel-shield-enforcement.md` — which gates were active and whether each passed.
  In `report-only`, only `secrets`/`expired_exceptions` are active.

---

## 8. Promote to baseline (after review)

Once the report-only run is green and you have reviewed real findings on an actual
app (not just the fixture):

1. Wire any missing adapters (e.g. Node test JSON → `reports/raw/tests.json`).
2. Edit `.sentinel-shield/profile.yaml`: `gates.mode: baseline`.
3. Re-run. Now new critical/high vulns, type errors, test failures, architecture
   violations, and unsafe Docker/Actions block. Track pre-existing critical/high as
   owned, time-boxed exceptions.

See [`sentinel-shield-adoption.md`](sentinel-shield-adoption.md) for the full
migration plan and the per-mode gate table.
