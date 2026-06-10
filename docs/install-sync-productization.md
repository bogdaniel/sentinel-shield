# Install / Sync Productization — Per-Profile Behavior Audit + Test Matrix Specification (v0.1.24)

Productization companion to [`install-sync-guide.md`](install-sync-guide.md) (behavior reference),
[`install-sync-reliability.md`](install-sync-reliability.md) (write-path audit, rollback,
troubleshooting, release checklist), and [`install-sync-status.md`](install-sync-status.md)
(per-stack coverage). This document does **not** repeat those. It adds two things v0.1.24 needs:

1. A **per-profile behavior audit** (§1–§2) that enumerates, for every shipped manifest, exactly
   what `install-baseline.sh` creates and what `sync-baseline.sh` manages — verified by running each
   profile's dry-run against this checkout.
2. A **test-matrix specification** (§3–§6) that states precisely what assertions the captain must
   wire into `scripts/self-test.sh` for the executable install tests (sprint tasks 43–56). Each row
   gives the assertion, the expected value, and the existing `is_check` / `im_check` precedent it
   extends. This doc is the contract; the captain writes the code.

The existing executable proof lives in `scripts/self-test.sh` suites `install-sync` (lines 658–715,
laravel-react-docker round-trip) and `install-matrix` (lines 1212–1234, docker / php-library /
node-react round-trip). The matrix below extends those to cover **all** shipped profiles.

> **Scope guard:** this is a specification doc. It defines what the tests must assert; it does not
> modify `self-test.sh`, `scripts/`, or any manifest. Verification commands quoted here were run
> read-only against temp dirs (`mktemp -d`) during authoring — see §1.3 for the captured output.

---

## 1. Per-profile install audit (tasks 41–42)

### 1.1 Manifest inventory

Six single-stack profiles plus two combinations ship today. Profile name → manifest path:

| Profile | Manifest |
|---|---|
| `laravel` | `profiles/laravel/profile.manifest.json` |
| `react` | `profiles/react/profile.manifest.json` |
| `node` | `profiles/node/profile.manifest.json` |
| `php-library` | `profiles/php-library/profile.manifest.json` |
| `docker` | `profiles/docker/profile.manifest.json` |
| `symfony` | `profiles/symfony/profile.manifest.json` |
| `laravel-react-docker` (default) | `profiles/combinations/laravel-react-docker.manifest.json` |
| `node-react` | `profiles/combinations/node-react.manifest.json` |

`install-baseline.sh` resolves the profile by checking `profiles/<name>/profile.manifest.json` first,
then `profiles/combinations/<name>.manifest.json` (install lines 56–59).

### 1.2 What install creates / sync manages, per profile

Legend for **mode** (manifest `mode`, enforced by both scripts):
- **create-if-missing** — written once on first install if absent; project owns it thereafter.
  Install skips if it exists; sync reports `project-local-preserved` on drift. **Never overwritten.**
- **overwrite-if-force** — *managed*. Created on first install; on a re-install or sync, only
  overwritten with `--force`. This is the only category sync will overwrite.
- **manual** — listed for awareness; install/sync print a `MANUAL` notice and write nothing. The
  consumer copies it by hand if wanted.
- **protected** — hard gate (`never_touch` + the literal `accepted-risks.json` basename). Never
  created, never overwritten, `--force` has no effect. A `manual`-mode file that is also in
  `never_touch` (e.g. laravel/symfony `phpstan.neon`) is reported PROTECTED, not MANUAL — the
  protected gate runs first (install line 81 / sync line 69).

#### `laravel` — created/would-create=5, manual=0, protected=1

| Target | Source | Mode | Install | Sync |
|---|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create once (mode stamped) | preserved on drift |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create once | preserved on drift |
| `.semgrepignore` | `profiles/laravel/.semgrepignore` | create-if-missing | create once | preserved on drift |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | **overwrite-if-force** | create; `--force` to update | **managed** — `--apply --force` updates |
| `docs/security/security-debt-register.md` | `templates/security-debt-register.md` | create-if-missing | create once | preserved on drift |
| `phpstan.neon` | (project) | **protected** (`never_touch`) | never written | never written |
| `.sentinel-shield/accepted-risks.json` | — | **protected** | never created | never overwritten |
| `phpstan-baseline.neon` | — | **protected** (hard default) | never created | never overwritten |

#### `react` — created/would-create=4, manual=0, protected=0

| Target | Source | Mode | Install | Sync |
|---|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create once | preserved |
| `.semgrepignore` | `profiles/react/.semgrepignore` | create-if-missing | create once | preserved |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | **overwrite-if-force** | create; `--force` | **managed** |
| `.sentinel-shield/accepted-risks.json` | — | **protected** | never created | never overwritten |

(`react` declares only `accepted-risks.json` in `never_touch`; `phpstan-baseline.neon` is still a
hard default but irrelevant to a JS stack.)

#### `node` — created/would-create=3, manual=0, protected=0

| Target | Source | Mode | Install | Sync |
|---|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create once | preserved |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | **overwrite-if-force** | create; `--force` | **managed** |
| `.sentinel-shield/accepted-risks.json` | — | **protected** | never created | never overwritten |

(No `.semgrepignore` in the `node` manifest — that is intentional; it is the leanest profile.)

#### `php-library` — created/would-create=5, manual=0, protected=0

| Target | Source | Mode | Install | Sync |
|---|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create once | preserved |
| `.semgrepignore` | `profiles/laravel/.semgrepignore` | create-if-missing | create once | preserved |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | **overwrite-if-force** | create; `--force` | **managed** |
| `docs/security/security-debt-register.md` | `templates/security-debt-register.md` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.json` | — | **protected** | never created | never overwritten |
| `phpstan-baseline.neon`, `phpstan.neon` | — | **protected** (`never_touch`) | never written | never written |

#### `docker` — created/would-create=5, manual=0, protected=0

| Target | Source | Mode | Install | Sync |
|---|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create once | preserved |
| `hadolint.yaml` | `profiles/docker/hadolint.yaml` | create-if-missing | create once | preserved |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | **overwrite-if-force** | create; `--force` | **managed** |
| `docs/security/pinned-ci-references.md` | `templates/pinned-ci-references.md` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.json` | — | **protected** | never created | never overwritten |

#### `symfony` — created/would-create=5, manual=4, protected=1

| Target | Source | Mode | Install | Sync |
|---|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create once | preserved |
| `.semgrepignore` | `profiles/laravel/.semgrepignore` | create-if-missing | create once | preserved |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | **overwrite-if-force** | create; `--force` | **managed** |
| `docs/security/security-debt-register.md` | `templates/security-debt-register.md` | create-if-missing | create once | preserved |
| `psalm.xml` | `profiles/symfony/psalm.xml` | **manual** | MANUAL notice; not written | manual-review-needed |
| `deptrac.yaml` | `profiles/symfony/deptrac.yaml` | **manual** | MANUAL notice; not written | manual-review-needed |
| `.php-cs-fixer.dist.php` | `profiles/symfony/php-cs-fixer.php` | **manual** | MANUAL notice; not written | manual-review-needed |
| `rector.php` | `profiles/symfony/rector.php` | **manual** | MANUAL notice; not written | manual-review-needed |
| `phpstan.neon` | `profiles/symfony/phpstan.neon` | manual + **protected** (`never_touch`) | PROTECTED (gate wins) | never written |
| `.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon` | — | **protected** | never created | never overwritten |

#### `laravel-react-docker` (default) — created/would-create=9, manual=5, protected=0

| Target | Source | Mode | Install | Sync |
|---|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create once | preserved |
| `.semgrepignore` | `templates/.semgrepignore` | create-if-missing | create once | preserved |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | **overwrite-if-force** | create; `--force` | **managed** |
| `.github/workflows/sentinel-shield-{pr-fast,main,scheduled,dast,ai-review}.yml` | `templates/workflows/*` | **manual** (×5) | MANUAL notice; not written | manual-review-needed |
| `docs/security/security-debt-register.md` | `templates/security-debt-register.md` | create-if-missing | create once | preserved |
| `docs/security/sentinel-shield-rollout-status.md` | `templates/sentinel-shield-rollout-status.md` | create-if-missing | create once | preserved |
| `docs/security/sentinel-shield-triage.md` | `templates/security-triage-report.md` | create-if-missing | create once | preserved |
| `docs/security/pinned-ci-references.md` | `templates/pinned-ci-references.md` | create-if-missing | create once | preserved |
| `docs/security/third-party-install-script-review.md` | `templates/third-party-install-script-review.md` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`, `phpstan.neon` | — | **protected** | never created | never overwritten |

> Note: this is the only profile whose `never_touch` lists `phpstan.neon`, but it does not ship a
> `phpstan.neon` manifest entry — so its dry-run shows protected=0 (nothing in the entry list hits
> the gate). The hard defaults still block `accepted-risks.json` / `phpstan-baseline.neon`.

#### `node-react` — created/would-create=5, manual=0, protected=0

| Target | Source | Mode | Install | Sync |
|---|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create once | preserved |
| `.semgrepignore` | `profiles/react/.semgrepignore` | create-if-missing | create once | preserved |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | **overwrite-if-force** | create; `--force` | **managed** |
| `docs/security/security-debt-register.md` | `templates/security-debt-register.md` | create-if-missing | create once | preserved |
| `.sentinel-shield/accepted-risks.json` | — | **protected** | never created | never overwritten |

### 1.3 Audit verification (captured dry-run output)

Every "created/would-create / manual / protected" count above was produced by running the real
dry-run against this checkout. Reproduce with:

```sh
for p in laravel react node php-library docker symfony laravel-react-docker node-react; do
  t=$(mktemp -d)
  echo "[$p]"; sh scripts/install-baseline.sh --target "$t" --profile "$p" | grep -E 'would write|MANUAL|PROTECTED|^SUMMARY'
  rm -rf "$t"
done
```

Captured SUMMARY counts (authoring run, this checkout):

| Profile | created/would-create | managed-skipped | manual | protected | files actually written (dry-run) |
|---|---|---|---|---|---|
| `laravel` | 5 | 0 | 0 | 1 | **0** |
| `react` | 4 | 0 | 0 | 0 | **0** |
| `node` | 3 | 0 | 0 | 0 | **0** |
| `php-library` | 5 | 0 | 0 | 0 | **0** |
| `docker` | 5 | 0 | 0 | 0 | **0** |
| `symfony` | 5 | 0 | 4 | 1 | **0** |
| `laravel-react-docker` | 9 | 0 | 5 | 0 | **0** |
| `node-react` | 5 | 0 | 0 | 0 | **0** |

The "files actually written = 0" column is the dry-run safety invariant (§3) and is the first thing
the per-profile tests must assert.

---

## 2. `detect-stack.sh` audit (supports profile selection)

`detect-stack.sh <dir>` is how a consumer picks a profile before install. Verified against the
committed fixtures (`tests/fixtures/projects/`):

| Fixture | `detect-stack.sh` output | Recommended profile |
|---|---|---|
| `laravel-react-docker` | `laravel node react docker` | `laravel-react-docker` |
| `node-react` | `node react` | `node-react` |
| `docker-only` | `docker` | `docker` |
| `symfony` | `symfony` | `symfony` |
| `php-library` | `php` | `php-library` |

Reproduce: `sh scripts/detect-stack.sh tests/fixtures/projects/<fixture>`.

---

## 3. Test-matrix SPEC: per-profile install/sync round-trip (tasks 43–51)

The captain wires these into `self-test.sh`. The existing `install-matrix` suite (lines 1212–1234)
already runs this shape for `docker / php-library / node-react`. **Task 43–51 = extend the loop to
cover ALL eight profiles** (add `laravel`, `react`, `node`, `symfony`, `laravel-react-docker`). The
per-profile loop must assert, for each profile `$P`:

| # | Assertion (label) | Command shape | Expected | Precedent |
|---|---|---|---|---|
| T1 | `$P: dry-run writes no files` | install dry-run into fresh `mktemp -d`; `find "$_t" -type f \| wc -l` | `0` | self-test.sh:1218 / 675 |
| T2 | `$P: apply creates profile.yaml` | `install --apply`; `[ -f "$_t/.sentinel-shield/profile.yaml" ]` | `yes` | self-test.sh:1221 / 679 |
| T3 | `$P: apply creates workflow` | `[ -f "$_t/.github/workflows/sentinel-shield.yml" ]` | `yes` | self-test.sh:1222 / 680 |
| T4 | `$P: apply creates accepted-risks EXAMPLE` | `[ -f "$_t/.sentinel-shield/accepted-risks.example.json" ]` | `yes` | self-test.sh:681 |
| T5 | `$P: sync reports no managed drift after clean install` | `sync` dry-run; count `manual-review-needed` lines | `0` | self-test.sh:1230 |
| T6 | `$P: sync reports managed drift after workflow edit` | append a marker to the installed workflow; `sync` dry-run; count `manual-review-needed` | `1` | self-test.sh:702 |
| T7 | `$P: sync --apply --force resolves drift` | `sync --apply --force`; re-grep the marker in the workflow | `0` (marker gone) | self-test.sh:707 |

**Per-profile expectations that differ** (the loop must parameterize, not hardcode):

- **`.semgrepignore` presence after apply** (T-extra): assert `yes` for every profile **except
  `node`** (the `node` manifest ships no `.semgrepignore`). Label: `$P: apply creates .semgrepignore`.
  For `node`, assert the file is **absent** (`no`) — proving the installer only writes what the
  manifest declares.
- **mode stamping** (T-extra, reuse self-test.sh:683): assert the installed `profile.yaml` carries
  `mode: report-only` by default, and `mode: <X>` when `--mode <X>` is passed. Label:
  `$P: profile mode written = report-only`.
- **manual entries** (symfony, laravel-react-docker only): assert the `manual`-mode targets
  (e.g. `psalm.xml`, `sentinel-shield-pr-fast.yml`) are **NOT** created by `--apply` (they print a
  MANUAL notice but write nothing). Label: `$P: apply does NOT create manual <file>`, expected `no`.

The four-step happy path each profile test exercises is exactly the quickstart in
[`install-sync-quickstart.md`](install-sync-quickstart.md) §4: **dry-run → apply → sync drift report
→ sync resolve**. T1 = dry-run; T2–T4 = apply; T5/T6 = sync-drift; T7 = sync-apply.

> **Why this is safe in CI:** every step uses a throwaway `mktemp -d` target and `--target` only;
> no network, no writes outside the temp dir. This matches how `install-matrix` already runs.

---

## 4. Test-matrix SPEC: protected-file invariants (tasks 52–54)

These are the highest-value assertions — they prove Sentinel Shield never destroys a consumer's risk
decisions. For each profile `$P`, after a clean `--apply`:

### 4.1 Task 52 — `accepted-risks.json` never overwritten

| # | Assertion (label) | Setup | Command | Expected | Precedent |
|---|---|---|---|---|---|
| P1 | `$P: install NEVER created accepted-risks.json` | clean apply | `[ -f "$_t/.sentinel-shield/accepted-risks.json" ]` | `no` | self-test.sh:684 / 1223 |
| P2 | `$P: install --force preserves real accepted-risks.json` | write a file containing a unique marker (`KEEP_$P`) to `.sentinel-shield/accepted-risks.json`; re-run `install --apply --force` | `grep -c "KEEP_$P" .../accepted-risks.json` | `1` | self-test.sh:689 / 1227 |
| P3 | `$P: sync --apply --force preserves accepted-risks.json` | same marker file present; run `sync --apply --force` | `grep -c "KEEP_$P" .../accepted-risks.json` | `1` | self-test.sh:711 |

The invariant: the marker count stays `1` through both a forced install **and** a forced sync —
proving `--force` has no reach over the hard-protected gate (install line 81 / sync line 69).

### 4.2 Task 53 — `phpstan-baseline.neon` never overwritten

Applies to PHP-stack profiles (`laravel`, `php-library`, `symfony`) and the combination
`laravel-react-docker` whose `never_touch` lists it. The test must run on at least `laravel` and
`symfony`:

| # | Assertion (label) | Setup | Command | Expected |
|---|---|---|---|---|
| P4 | `$P: phpstan-baseline.neon never created` | clean apply | `[ -f "$_t/phpstan-baseline.neon" ]` | `no` |
| P5 | `$P: install/sync --force preserves phpstan-baseline.neon` | write marker `BASELINE_$P` to `phpstan-baseline.neon`; run `install --apply --force` then `sync --apply --force` | `grep -c "BASELINE_$P" phpstan-baseline.neon` | `1` |

For `laravel` / `symfony`, the same P4/P5 pair must also cover **`phpstan.neon`** (it is in their
`never_touch`; the dry-run reports it PROTECTED — see §1.2). Label: `$P: phpstan.neon never overwritten`.

### 4.3 Task 54 — `.semgrepignore` (create-if-missing) never overwritten

`.semgrepignore` is **not** hard-protected; it is `create-if-missing`. The invariant is therefore
"create if absent, never overwrite if present" — a distinct gate (install line 88 / sync line 82),
verified separately from the protected gate. Run on a profile that ships it (e.g. `laravel`,
`react`, `node-react`):

| # | Assertion (label) | Setup | Command | Expected |
|---|---|---|---|---|
| P6 | `$P: install creates .semgrepignore when absent` | clean apply | `[ -f "$_t/.semgrepignore" ]` | `yes` |
| P7 | `$P: install --force does NOT overwrite existing .semgrepignore` | overwrite installed `.semgrepignore` with marker `MINE_$P`; re-run `install --apply --force` | `grep -c "MINE_$P" .semgrepignore` | `1` |
| P8 | `$P: sync preserves edited .semgrepignore (project-local-preserved)` | marker present; `sync` dry-run | output contains `project-local-preserved` for `.semgrepignore` | `1` match |
| P9 | `$P: sync --apply --force preserves edited .semgrepignore` | marker present; `sync --apply --force` | `grep -c "MINE_$P" .semgrepignore` | `1` |

P7/P9 are the key distinction from the managed workflow (§5): `--force` updates the managed workflow
but does **not** touch a `create-if-missing` file the project has edited — because the
`create-if-missing` branch never consults `FORCE` (install line 87–88; sync line 81–82).

---

## 5. Test-matrix SPEC: managed-workflow invariants (tasks 55–56)

The managed workflow (`.github/workflows/sentinel-shield.yml`, mode `overwrite-if-force`) is the
**only** file `--force` overwrites. For each profile `$P`, after clean apply:

### 5.1 Task 55 — managed workflow IS updated with `--force`

| # | Assertion (label) | Setup | Command | Expected | Precedent |
|---|---|---|---|---|---|
| M1 | `$P: install --force overwrites managed workflow` | overwrite installed workflow with marker `PROJECT_EDIT_$P`; re-run `install --apply --force`; the marker is gone (canonical content restored) | `grep -c "PROJECT_EDIT_$P" .../sentinel-shield.yml` | `0` | self-test.sh:696 |
| M2 | `$P: sync dry-run reports managed drift` | append marker `DRIFT_$P` to workflow; `sync` dry-run; count `manual-review-needed` for the workflow | `1` | self-test.sh:702 |
| M3 | `$P: sync dry-run does NOT modify (drift still present)` | after M2 dry-run | `grep -c "DRIFT_$P" .../sentinel-shield.yml` | `1` (untouched) | self-test.sh:703 |
| M4 | `$P: sync --apply --force updates managed workflow` | `sync --apply --force` | `grep -c "DRIFT_$P" .../sentinel-shield.yml` | `0` (refreshed) | self-test.sh:707 |

### 5.2 Task 56 — unmanaged / project-owned workflow NOT overwritten without `--force`

Two facets the tests must assert:

- **Managed workflow without `--force` is NOT overwritten:** edit the installed workflow with marker
  `KEEPWF_$P`; run `install --apply` **without** `--force`; the marker survives.
  Label: `$P: install without --force does NOT overwrite managed workflow`,
  command `grep -c "KEEPWF_$P" .../sentinel-shield.yml`, expected `1`. (Install line 90–91: an
  existing managed file is skipped when `FORCE=0`.)
- **`manual`-mode workflows are never auto-written:** for `laravel-react-docker`, assert the
  `manual` workflows (`sentinel-shield-pr-fast.yml`, `-main.yml`, `-scheduled.yml`, `-dast.yml`,
  `-ai-review.yml`) are **absent** after `--apply --force`.
  Label: `lrd: apply --force does NOT create manual workflow <name>`, expected `no` for each.
  (These are the only "unmanaged-by-the-installer" workflow templates we ship; the installer treats
  `manual` mode as write-nothing — install line 86.)

> A truly hand-authored project workflow (one not in any manifest) is never even visited by the
> installer — it only iterates manifest entries (install line 106). So "unmanaged file untouched" is
> structurally guaranteed; the explicit assertions above cover the in-manifest `manual` case and the
> no-`--force` managed case, which are the ones a test can meaningfully exercise.

---

## 6. Suite wiring guidance (for the captain)

- **Extend `install-matrix`**, do not create a parallel suite. Its profile loop variable
  (`_prof`) already parameterizes the four matrix profiles; widen the list to all eight and add the
  protected/managed assertion blocks (§4, §5) inside the loop, parameterizing markers by `$_prof`
  to keep them unique across the loop.
- **Keep `install-sync` as the deep laravel-react-docker case** — it already exercises mode stamping
  (683), `create-if-missing` preserve (697), and the accepted-risks round-trip (684/689/711). Do not
  duplicate those into the matrix loop for laravel-react-docker; reference them.
- **Marker discipline:** suffix every injected marker with the profile name (`KEEP_$P`,
  `DRIFT_$P`, `MINE_$P`, `PROJECT_EDIT_$P`, `KEEPWF_$P`) so a failure message points at the profile.
- **Each profile gets its own `mktemp -d`** and is cleaned up — no shared state, matching the
  existing suites.
- **No network, no `--target` outside temp** — every assertion above is satisfiable offline.

When wired, the §3–§5 matrix is the executable proof for the §1 audit and for every protected /
managed claim in [`install-sync-reliability.md`](install-sync-reliability.md) §1–§4 — extended from
three profiles to all eight.

---

## Cross-references

- [`install-sync-quickstart.md`](install-sync-quickstart.md) — quickstart, rollback, troubleshooting (tasks 57–60).
- [`install-sync-reliability.md`](install-sync-reliability.md) — line-by-line write-path audit, rollback, release checklist.
- [`install-sync-guide.md`](install-sync-guide.md) — behavior, file modes, manual post-install steps.
- [`install-sync-status.md`](install-sync-status.md) — per-stack coverage, known gaps.
- `scripts/self-test.sh` (`install-sync` lines 658–715, `install-matrix` lines 1212–1234) — the suites this spec extends.
- `profiles/profile.manifest.schema.json` — manifest schema and `mode` enum.
