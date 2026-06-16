> Stable adoption doc (v1.2.0).

# Sentinel Shield — 30-Minute Quickstart

Get a new team from zero to a running, gated CI pipeline by copy-paste. This is the
**fastest on-ramp**; it does not duplicate the depth of the references it links. Once you
are running, follow the cross-links for tuning, migration, and policy.

- Install / sync behavior, file modes, rollback table: [`install-sync-quickstart.md`](install-sync-quickstart.md)
- Full consumer onboarding (roles, PR flow, triage): [`consumer-onboarding.md`](consumer-onboarding.md)
- How modes resolve into gate flags: [`gate-resolution.md`](gate-resolution.md)
- Accepting/suppressing a finding correctly: [`accepted-risk-suppression.md`](accepted-risk-suppression.md)
- Upgrading an existing adopter: [`v1.1-onboarding-and-migration.md`](v1.1-onboarding-and-migration.md)
- **Optional AI-assisted path:** drive this install with an AI agent — [`ai-assisted-install.md`](ai-assisted-install.md) + the copy-paste prompt [`../prompts/install-sentinel-shield.md`](../prompts/install-sentinel-shield.md). This manual quickstart remains the supported baseline.

---

## 1. Prerequisites

| Tool | Needed for | Install |
|---|---|---|
| `sh` (POSIX) | every engine script | preinstalled on Linux/macOS |
| `jq` | building + enforcing the summary (hard requirement) | `brew install jq` / `apt-get install jq` |
| `git` | checkout, rollback | preinstalled |
| `docker` | *some* scanners only (Semgrep app scan, container/IaC scanners) | optional; CI runners have it |

`jq` is mandatory: `build-security-summary.sh` and `enforce-gates.sh` exit `2` without it.
Sentinel Shield intentionally does **not** parse JSON with shell hacks.

**Engine exit-code contract (STABLE)** — every engine CLI follows it:
`0` = success / gates pass · `1` = gate failure · `2` = config-or-input error.

---

## 2. Supported project types (profiles)

Run `detect-stack.sh` against your project, then pick the matching `--profile`:

```sh
sh scripts/detect-stack.sh /path/to/your/project
```

| Detected stack | `--profile` |
|---|---|
| Laravel + React + Docker | `laravel-react-docker` *(default)* |
| Node + React | `node-react` |
| Laravel | `laravel` |
| Symfony | `symfony` |
| React | `react` |
| Node | `node` |
| PHP, no framework | `php-library` |
| Docker only | `docker` |

---

## 3. Minimal install (dry-run, then apply in report-only)

Run from inside your Sentinel Shield checkout. **Install is dry-run by default** — it
writes nothing until `--apply`.

```sh
# 1. DRY-RUN — preview every file install would write; writes NOTHING
sh scripts/install-baseline.sh --target /path/to/project --profile laravel-react-docker

# 2. APPLY — start in the safest mode (report-only); only secrets + expired exceptions block
sh scripts/install-baseline.sh --target /path/to/project --profile laravel-react-docker \
   --apply --mode report-only
```

Start at `report-only` to get visibility without breaking anyone's build, then move to
`baseline` once the team has seen real output (see §9 and `gate-resolution.md`).

### What gets created (apply)

| Path | Mode | Notes |
|---|---|---|
| `.sentinel-shield/profile.yaml` | create-if-missing | mode stamped from `--mode`; **you own it after first write** |
| `.sentinel-shield/accepted-risks.example.json` | create-if-missing | template only |
| `.semgrepignore` | create-if-missing | you own it |
| `.github/workflows/sentinel-shield.yml` | overwrite-if-force | the **managed** workflow (sync updates this) |
| `docs/security/*.md` | create-if-missing | debt register, triage, rollout status, pinned refs |

**Never created or overwritten** (your risk decisions): `.sentinel-shield/accepted-risks.json`
and `phpstan-baseline.neon` — even with `--force`. Copy `accepted-risks.example.json` →
`accepted-risks.json` yourself, only when accepting an owner-approved risk.

The per-job workflow templates (`sentinel-shield-pr-fast.yml`, `-main.yml`,
`-scheduled.yml`, …) are **manual** mode — install prints a notice but does not write them.
Copy the ones you want from `templates/workflows/` (next sections).

### Post-install manual steps (the script prints these)

1. Edit `.sentinel-shield/profile.yaml` — set `project.{name,type,criticality,owner}`.
2. In each workflow you adopt, set `SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/sentinel-shield`
   and pin `SENTINEL_SHIELD_REF` to a tag (pin to a full SHA before production).

---

## 4. First PR-fast run

The PR gate is fast and deterministic (no external target scanning). Copy the template:

```sh
cp templates/workflows/sentinel-shield-pr-fast.yml \
   /path/to/project/.github/workflows/sentinel-shield-pr-fast.yml
```

Set `SENTINEL_SHIELD_REPOSITORY` + `SENTINEL_SHIELD_REF`, commit, open a PR. It wires the
lifecycle for you: **resolve-gates → (run scanners) → build-security-summary → enforce-gates**.
See [`templates/workflows/sentinel-shield-pr-fast.yml`](../templates/workflows/sentinel-shield-pr-fast.yml).

---

## 5. First main-gate run

The main gate is heavier (CodeQL, OSV-Scanner, Trivy, Grype, SBOM, IaC). It only triggers
on `push`/`workflow_dispatch`, so it can't be dispatched from a feature branch until it
already exists on the default branch. **Do not merge it unvalidated** — validate the same
scanners from a branch first:

```sh
sh scripts/run-main-gate-validation.sh --target . --output-dir reports/raw --all
```

Then copy [`templates/workflows/sentinel-shield-main.yml`](../templates/workflows/sentinel-shield-main.yml)
and merge only after the real reports are green. Note: OWASP Dependency-Check is **disabled
by default** in the main gate (slow NVD download) — enable it on the scheduled/nightly job.

---

## 6. Reading `security-summary.json`

The producer writes normalized, mode-agnostic counts to `reports/security-summary.json`
(schema in [`security-summary-schema.md`](security-summary-schema.md)). Two quick reads:

```sh
# All finding counts + evidence flags
jq '.summary' reports/security-summary.json

# Just the gates that usually block (secrets / criticals / highs)
jq '{secrets: .summary.secrets,
     critical: .summary.critical_vulnerabilities,
     high: .summary.high_vulnerabilities}' reports/security-summary.json
```

---

## 7. Reading the enforcement output

`enforce-gates.sh` writes `reports/sentinel-shield-enforcement.{json,md}`. The two fields
that matter: `result` (`pass`/`fail`) and `failed_gates`.

```sh
jq '{result, failed_gates}' reports/sentinel-shield-enforcement.json
```

- **Pass** (`result: "pass"`, exit `0`): no enabled gate exceeded its threshold.
- **Fail** (`result: "fail"`, exit `1`): at least one enabled gate has findings.
  `failed_gates` lists exactly which.

In `report-only`, expect **pass** unless you have leaked secrets or expired exceptions
(only those two gates are enabled). In `baseline`, new high-risk findings (criticals/highs,
syntax errors, dependency-policy violations, …) will flip it to **fail** — that is correct.

---

## 8. Artifact locations

Everything lands under `reports/` (gitignored — these are CI artifacts, not committed):

| File | Produced by |
|---|---|
| `reports/sentinel-shield-gates.{env,json,md}` | `resolve-gates.sh` |
| `reports/raw/*.json` | scanner steps (one raw file per tool) |
| `reports/security-summary.json` | `build-security-summary.sh` |
| `reports/sentinel-shield-enforcement.{json,md}` | `enforce-gates.sh` |

The shipped workflows upload `reports/**` with `if: always()`, so raw reports are preserved
even when the gate fails.

---

## 9. Common first-run failures

| Symptom | Cause | Fix |
|---|---|---|
| `error: jq is required` (exit 2) | `jq` not on `PATH` | `brew install jq` / `apt-get install jq` |
| `error: no manifest for profile '<x>'` (exit 2) | profile typo | use a profile from §2 |
| Dry-run "did nothing" | by design — dry-run writes nothing | re-run with `--apply` |
| `security summary not found` (exit 2) | enforce ran before a scanner produced the summary | run `build-security-summary.sh` first |
| `gates env not found` (exit 2) | enforce ran before `resolve-gates.sh` | run `resolve-gates.sh` first |
| Dependency-Check slow / empty | no NVD API key; disabled by default | leave disabled for PRs; add an NVD key on the nightly job |
| `profile.yaml` mode not what you expected | `--mode` defaults to `report-only`; file is project-owned after first write | pass `--mode` on first apply, or edit `profile.yaml` directly |
| `sync` errors "`.sentinel-shield` not found" | ran sync before install | run `install-baseline.sh --apply` first |

---

## 10. When the gate fails

**A failing gate is correct behavior, not a bug.** It means a real finding crossed a
threshold you enabled. Do not suppress it to make CI green:

1. Read `failed_gates` in `reports/sentinel-shield-enforcement.json`.
2. Open `reports/security-summary.json` (and the matching `reports/raw/<tool>.json`) to see
   the actual finding.
3. **Fix it** if you can.
4. If you genuinely must defer, record an **owner-approved, expiring** accepted-risk — never
   a blanket suppression. Only `unsafe_docker` and `medium_vulnerabilities` are suppressible,
   and records are finding-scoped by default. `secrets`, `expired_exceptions`, and
   `missing_release_evidence` are **never** suppressible. See
   [`accepted-risk-suppression.md`](accepted-risk-suppression.md).

---

## 11. Rollback

Adoption is reversible without losing your risk decisions.

```sh
# Lower the mode — edit .sentinel-shield/profile.yaml:  gates.mode: report-only
# (resolve-gates re-reads it on the next run; report-only blocks only secrets + expired exceptions)

# Roll back the managed workflow to a known-good commit
git -C /path/to/project checkout <good-commit> -- .github/workflows/sentinel-shield.yml

# Pin Sentinel Shield back to a previous version, then re-sync managed files
#   set SENTINEL_SHIELD_REF: <previous-tag> in your workflows, then:
sh scripts/sync-baseline.sh --target /path/to/project --apply --force
```

`sync-baseline.sh` (dry-run by default; `--apply --force` to update) never touches
`accepted-risks.json`, `phpstan-baseline.neon`, or your project-owned `profile.yaml` /
`.semgrepignore`, so rollback is narrowly scoped to the managed workflow. Full rollback
procedure: [`install-sync-quickstart.md`](install-sync-quickstart.md#rollback-task-57).

---

## Next steps

- Tune gates and understand mode defaults → [`gate-resolution.md`](gate-resolution.md)
- Full onboarding + PR/triage flow → [`consumer-onboarding.md`](consumer-onboarding.md)
- Already on an older version → [`v1.1-onboarding-and-migration.md`](v1.1-onboarding-and-migration.md)
