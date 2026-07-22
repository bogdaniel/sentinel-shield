# Changelog

All notable changes to Sentinel Shield are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). History began at `v0.1.0`
and reached the **stable v1.x line** (`v1.9.2`, still supported). **`v2.0.1` is the latest
published release** — an engine-only maintenance release (2026-07-09, marked latest, tag
target `32812ed`) that refreshes the `v2.0.0` engine-only production release (tag target
`13be630`, still an intact release) with no executable engine change. Engine-only scope:
**not** framework-validated and **not** a full-platform GA claim (Laravel/Symfony are
engine- and fixture-tested only, not live-validated in real consumer
repositories). See [`docs/product-status.md`](docs/product-status.md)
for canonical status and [`docs/v2-release-scope.md`](docs/v2-release-scope.md) for the
engine-only v2 scope.

## [Unreleased]

### Fixed — full-repo review batch 4: collector fail-closed hardening + honest tooling claims (14 findings)

Coherent fail-closed + honest-claim batch from the 475-finding census. `ss_collector_guard`
already rejects missing/empty and invalid-JSON input; the gap closed here is **valid JSON of
an unrecognized shape** (a scanner that emits an error object) being coerced to 0 findings and
silently clearing a security gate.

- **11 collectors now fail closed on an unrecognized report shape** (they previously coerced
  malformed/error output to a clean pass): `actionlint`, `hadolint`, `psalm`, `phpstan`,
  `dockle`, `conftest`, `nuclei`, `zap`, `terrascan`, `third-party-semgrep`,
  `dependency-policy`. Each asserts its expected container (array / `.totals` / `.results` /
  `.details` / …) is present and exits 2 otherwise; `phpstan` also gained the integer guard
  its siblings have. A new prod test — `tests/prod/273-collector-shape-failclosed.sh` —
  proves both directions for all 11 (malformed → exit 2, well-typed clean/empty → pass;
  22/22 assertions green), so the hardening cannot silently over- or under-fire.
  *(The quality collectors — complexity/coverage/dead-code/… — already fail closed on an
  unknown `.status`; their narrower residual hole is deferred to a fixtured batch.)*
- **`scripts/run-hadolint.sh` default image pinned to a digest** —
  `hadolint/hadolint:v2.12.0@sha256:30a8fd2e…`. A gate engine that enforces image-digest
  pinning on consumers was pulling its own gate tool from a floating `hadolint/hadolint`
  tag by default.
- **`scripts/support-bundle.sh` now has a redaction test** —
  `tests/prod/290-support-bundle.sh` seeds secret-shaped tokens and asserts the shareable
  bundle redacts included config, excludes raw artifacts by default, redacts raw copies under
  `--include-raw`, and leaks no seeded secret anywhere. It aggregates diagnostics (253's exact
  threat surface) but had zero test coverage — a redaction regression would have shipped silently.
- **Honest workflow-template tool claims** — `sentinel-shield-pr-fast.yml` and
  `sentinel-shield-main.yml` headers advertised tools they do not run: pr-fast listed
  Gitleaks (the secrets control), Psalm, ESLint, tsc, zizmor, actionlint, composer audit —
  none has a step (Gitleaks/actionlint/zizmor run in the separate `ci-security.yml`); main
  listed CodeQL, Trivy fs, Deptrac and architecture tests, none wired, with Dependency-Check
  disabled by default. Both headers corrected to the tools actually executed, with the
  pr-fast note that it is **not** the secrets gate.

### Fixed — full-repo review batch 3: critical DAST/type-gate bypasses + fail-open collectors (20 findings)

From the 475-finding full-repo census (7 parallel sweeps). This batch takes the 2 CRITICAL
and 18 HIGH findings not owned by open PRs. Every fix verified against code; security fixes
proven behaviorally.

**Critical**

- **DAST allowlist bypass (`scripts/runners/dast-guard.sh`).** The host parser stripped the
  port before the userinfo, so `http://allowed.host:x@evil.com/` matched the allowed host
  while ZAP/nuclei actually scanned `evil.com`. Userinfo (`*@`) is now stripped before the
  port. *Proven: the bypass URL now fails closed (exit 3).*
- **TypeScript gate fake clean pass (`scripts/runners/typescript.sh`).** When tsc could not
  run, `grep -c "error TS"` counted 0 and the runner wrote `{errors:0}` — a fake pass on the
  type gate. It now captures tsc's exit code and reports unavailable (writes nothing) when
  tsc fails without emitting diagnostics; a stale report is cleared up front. *Proven both
  paths.*

**High — fake-clean / stale-evidence / fail-open**

- `runners/knip.sh` — a ts-prune crash in the fallback path yielded `dead_code_count:0`
  (fake pass); now reports unavailable on non-zero ts-prune exit.
- `runners/laravel-phpstan.sh` — missing the stale-report `rm -f` the sibling PHPStan
  runners have; a stale `phpstan.json` could be read as current evidence. Added.
- `runners/zap-full.sh` — probed `zap-baseline.py`/`zap.sh` but executed
  `zap-full-scan.py`; the active scan silently no-op'd. Now probes the binary it runs.
- `runners/nuclei.sh` — wrote JSONL (`-jle`); the collector reads one JSON document and
  exits 2 on multi-doc input, hard-erroring the DAST gate exactly when ≥2 findings exist.
  Switched to `-je` (JSON array).
- `runners/codeql-export.sh` — searched the whole repo for `*.sarif`, so a stray/fixture
  SARIF (PR-influenceable) could be exported as the CodeQL evidence. Restricted to the
  codeql-action output dir.
- `runners/php-syntax.sh` — `for f in $(find …)` word-split filenames; paths with spaces
  fragmented and inflated `php_syntax_errors` with false positives that block releases. Now
  uses `find … -exec` per file.
- `collectors/docker-base-digest.sh` + `collectors/github-actions-pins.sh` — a non-array
  (malformed) audit report coerced to count 0 → clean pass, silently clearing the
  `unsafe_docker` / `unsafe_github_actions` gates. Now fail closed (exit 2) on non-array
  input. *Proven: malformed → exit 2, empty array → exit 0.*

**High — durability / bounded execution**

- `lib/transaction.sh` — the journal appended without healing a torn prior tail, so a
  crash-truncated line got concatenated into by the next append, turning a tolerated
  trailing artifact into prefix corruption that blocks recovery. A trailing newline is now
  ensured before each append.
- `audits/grype.sh` + `audits/osv-scanner.sh` — headers claimed hangs "can no longer stall
  the scan"; only the version probe was bounded, the actual scan ran unbounded. The scan is
  now wrapped in `bp_run` with a `*_SCAN_TIMEOUT_SECONDS` cap.

**High — fail-open workflow templates**

- `templates/workflows/sentinel-shield.yml` (and the `examples/` copy) — the prepare step's
  `resolve-gates.sh … || true` and the main-gate `run-tool-plan.sh … || true` swallowed
  resolver/runner failures (exit 3/4), letting the release gate enforce on partial evidence
  or the wrong gate set. Both `|| true` removed.

**High — false/ broken documentation**

- `prompts/install-sentinel-shield.md` + `prompts/update-sentinel-shield.md` — the
  authoritative-gate step ran `run-local-pipeline.sh --target .`, which exits 2 (missing
  required `--profile`/`--stage`). Corrected to the full invocation.
- False "`0600 --propertyfile`" NVD-key security claim corrected across six docs
  (troubleshooting, faq, product-readiness-checklist, enterprise-scanner-matrix,
  production-readiness-audit, dependency-check-consumer-evidence) — the wrapper deliberately
  uses 644/755 (0600 was the container-unreadable bug); troubleshooting.md contradicted its
  own correct statement.
- `policies/opa/docker.rego` + `terraform.rego` — headers advertised `--parser dockerfile`
  / hcl2 modes the rules do not support (they read Compose / plan-JSON only; other shapes
  pass vacuously — fail-open for a documented mode). Scoped the headers to what the rules
  actually consume.

### Fixed — full-repo review batch 2: stale template pins, unpinned example actions, config hygiene (7 findings)

- **All shipped workflow templates now pin `SENTINEL_SHIELD_REF: v2.0.1`** (the latest
  published release). The template set a consumer installs together carried four different
  stale refs (v0.1.0 / v0.1.12 / v0.1.21 / v1.1.0) — consumers fetched an engine two major
  versions old with none of the v2 gate fixes. The "pin to a full SHA before production"
  guidance is retained.
- **`templates/workflows/sentinel-shield-main.yml` grype sbom mode now has an SBOM.** The
  template set `SENTINEL_SHIELD_GRYPE_MODE: sbom` pointing at `reports/sbom.spdx.json`, but
  no step produced it (only a comment suggested Syft) — grype scanned nothing. A
  `scripts/audits/syft.sh` step now writes the SBOM first.
- **`examples/laravel-react-docker` workflow actions pinned to full commit SHAs** —
  33 `uses:` references (checkout, upload/download-artifact, setup-node, setup-php,
  trivy-action, sbom-action) now use the same verified SHAs as the canonical templates
  (download-artifact v4 resolved via the GitHub API); the example previously shipped
  floating version tags in the exact file consumers copy. The hardcoded `branches: [master]`
  push trigger now carries a warning that a wrong default-branch name silently skips the
  gate on merges.
- **`.trivyignore` ceiling documented**: the plain format suppresses the three fixture CVEs
  repo-wide (it cannot path-scope). Acceptable only while the engine has no production
  dependency manifests; the migration path (path-scoped `.trivyignore.yaml`) is now recorded
  in the file.
- **`config/release-required-workflows.json`** dropped a dangling `$schema` URL pointing at
  a schema file that does not exist (the config is validated structurally by
  `scripts/lib/release-authz.sh`; prod test 262 still passes).
- **CONTRIBUTING.md** semgrep layout corrected: rules live under `semgrep/app/<lang>/` and
  `semgrep/supply-chain/`, not the documented `semgrep/<lang>/`.
- Reviewed and **dismissed as false positive**: reported dead links in
  `docs/maturity-audit-v024.md` are quoted defect examples inside an audit-findings table,
  and the defects they describe were already fixed in the target docs.

### Fixed — full-repo review batch 1: fail-open policies, broken doc commands, portability (20 findings)

Fixes from a systematic four-dimension review (scripts/lib, policies/schemas/config,
Makefile/templates/workflows, docs-vs-code), scoped to exclude everything already
addressed by open PRs #49–#63. Every finding was verified against the code before the
fix, and every policy fix was proven with positive/negative OPA eval fixtures.

- **`policies/opa/production-env.rego` failed OPEN on boolean cookie flags.** The deny
  bodies guarded on `input.SESSION_SECURE_COOKIE` / `input.COOKIE_SECURE` truthiness, so a
  JSON/YAML boolean `false` — the exact insecure state — made the guard itself fail and the
  deny never fired. The rules now bind the value first, then check truthiness (proven:
  boolean `false` now denies).
- **`policies/opa/github-actions.rego` missed fully-unpinned actions.** `is_third_party`
  required `contains(uses, "@")`, so a ref-less `uses: foo/bar` (resolves to the default
  branch — the most dangerous form) escaped the pin-to-SHA deny. The `@` requirement is
  removed (`docker://` images excluded); ref-less third-party actions are now denied.
- **`policies/opa/terraform.rego`** now actually checks RDP 3389 (header claimed "SSH/RDP",
  only 22 was checked) and catches full-range openers (`from_port 0, to_port 65535`,
  `protocol "-1"`) that the `== 0/== 0` unrestricted-ingress rule missed.
- **`policies/opa/docker.rego`** untagged-image deny now evaluates the tag on the image's
  last path segment, so untagged `registry:5000/app` no longer slips through on the
  registry-port colon.
- **`scripts/support-bundle.sh` could leak secrets on macOS.** The redaction `sed` used the
  GNU-only `/gi` flag; BSD sed errors and the fallback copied the file **unredacted** into
  the bundle. Case now folded into the pattern (portable), and the fallback fails closed
  (omits content instead of copying raw).
- **`scripts/health.sh` network probe always failed.** The default probe URL
  (`github.com/anthropics/.git`) is not a repository, so `git ls-remote` returned 128 and
  `--check-network` reported `network_unreachable` even fully online. Now probes a real
  public repo.
- **`Makefile` `validate` masked syntax errors** — the `sh -n` loop returned only the last
  iteration's status; a broken non-last script still exited 0. Now exits 1 on the first
  failure (regression-tested).
- **README/`docs/compatibility.md` compatibility-gate examples were broken**: `health.sh`
  shown without `--policy` runs the operational report (different exit codes), and
  `--docker`/`--require-network` without `--policy` exit 64 "unknown argument". All
  examples now pass `--policy config/compatibility-policy.json`.
- **`.gitleaks.toml` allowlist anchored** (`^tests/`, `^examples/`) — unanchored regexes
  also suppressed secrets in any path containing `tests/`/`examples/`.
- **Semgrep rules**: `ss-tp-js-dynamic-require` had a top-level `pattern-not` beside
  `pattern-either` (schema-invalid — the exclusion was silently dropped); now nested under
  `patterns:`, with literal `import("...")` also excluded. `\bsh \b` in the js-install-scripts
  high-confidence regex missed `sh -c`/`sh ./x`; now `\bsh\b`. The docker `:latest` rule
  message no longer claims to catch untagged `FROM` (it cannot, without multi-stage
  alias false positives).
- **Example workflow images pinned** — `examples/laravel-react-docker` ran
  `semgrep/semgrep:latest` and `zricethezav/gitleaks:latest`, contradicting the canonical
  template's own "never `:latest`" rule; now pinned to the template's versions.
- **`scripts/normalize-security-summary.sh`** built JSON scalars by hand-quoting
  (`"\"$_ver\""`); a `"`/`\` in a version/timestamp/digest produced invalid JSON and
  aborted under `set -e`. Scalars now pass through `jq --arg`.
- **`scripts/generate-report.sh`** generated reports pointing users at the deprecated
  `run-local-security.sh` shim; now references `run-local-scanner-sweep.sh`.
- Stale README tool count ("Fourteen tools") corrected to the actual 30+ collector table;
  wrong `scripts/audits/` path to `audit-github-actions-pins.sh` fixed in two docs.

### Fixed — false claims and a non-operative profile (documentation accuracy)

Docs asserting **more validation than the engine performs**, in the file set whose entire
purpose is honest status reporting. Every claim below was verified against the code before
being changed, and `tests/prod/268-documentation-accuracy.sh` now guards the class
mechanically — nothing checked these before.

- **`product-status.md` claimed three consumer rows were `yes (live)`** — "real lockfile,
  `npm ci`, mutations caught, byte-for-byte rollback". The live tier is gated on
  `SS_CONSUMER_LIVE=1` and **nothing in the repository sets it**, so the CI job labelled
  "Consumer validation (BLOCKING)" runs the structural tier and emits `skip/LIVE_UNAVAILABLE`.
  The same file already downgraded the php-library row for exactly this condition — the
  standard was applied unevenly, in favour of the flattering rows. Downgraded to
  `structural only`.
- **The `docker` profile resolved ZERO tools — now 13.** It declared no `tools` map and no
  `extends`, so `hadolint`, `docker-base-digest`, `trivy-fs`, `dockle`, `checkov`, `syft` and
  `grype` were never required, never run and never gated, and `required_tool_failures` could not
  fire. Worse than the docs suggested: `hardened-enterprise` **extends** `docker`, so the
  maximum-hardening profile had no container or IaC coverage either (52 tools -> 59 now).
  A real `tools` map is wired, with policies assigned by **validated maturity**
  (`docs/scanner-maturity-policy.md`) rather than aspiration:
  `required` for the nine that run from Sentinel Shield itself or are live-validated
  (hadolint, docker-base-digest, gitleaks, actionlint, zizmor, github-actions-pins, trivy-fs,
  syft, grype); `recommended` for Checkov/Terrascan/Conftest, which are **ci-validated against
  evidence fixtures only** — requiring them would assert live IaC validation this project has
  not performed; `optional` for Dockle, which needs a built image (`$SENTINEL_SHIELD_IMAGE`).
  Nine tools are gate-enforced, verified end-to-end: `required_tool_failures` is 9 with no
  reports and 0 with them.
- **`install-sync-consumer-safety.md` was built on a false premise** — ~400 lines asserting the
  scripts take "no backup" and have "no script-side backup or transaction". All three use
  `lib/transaction.sh` (12/12/9 call sites): operation lock, per-file snapshot before write,
  rollback. Worse, its documented recovery step ("re-run dry-run, then re-apply") **fails**:
  `tx_detect_stale` exits 4 while a prior lock exists. Correction inserted at the top.
- **Both SHA inventories were stale and unenforced.** Several documented SHAs appeared in no
  workflow and several real pins were undocumented, under a header claiming the list was
  "asserted by two fail-closed gates" — neither audit script ever reads those docs. Both are
  regenerated from the tree, and the dead `zaproxy/*` rows are removed (no workflow has used
  them since `ci-zap.yml` was deleted).
- **Two docs understated the security posture**, claiming only `ci-self-test.yml` was SHA-pinned
  and that other templates "must be pinned before production". **126 of 126** `uses:` lines
  across all workflows and templates are pinned.
- **`profile-compatibility.md` said Laravel deliberately omits style analysis**; the manifest
  declares `pint` as `required` with `missing_behavior: fail` on PR and main. An adopter
  trusting the doc and skipping Pint would hit a required-tool failure.
- **`support-policy.md` still presented `v2.0.0` as latest** — zero mentions of `v2.0.1`. The
  document governing customer entitlements was a release behind.
- **`install-sync-status.md` listed two "known gaps (not fixed)" that are fixed** — the
  `node-react` combination and `symfony` manifests both exist.
- **"DAST is never a default gate"** appeared in several docs; `regulated` resolves
  `FAIL_ON_DAST_FINDINGS=true`.
- **Three different gate counts were each called "canonical"** (12 / 24 / the resolver's actual
  41). `resolve-gates.sh` is now named as the only authority.

New: `tests/prod/268-documentation-accuracy.sh` asserts that no doc claims a live tier that
cannot run, that a zero-tool profile is marked non-operative, that the SHA-pinning claims match
the workflows, that no doc pins actions for a deleted workflow, that the support policy tracks
the current release, and that no stale literal gate count is asserted.

### Fixed — documentation reference integrity

- **Documented release commands failed outright.** `docs/release-provenance.md` and
  `docs/production-release-runbook.md` passed `evidence/releases/2.0.0-beta.2.json`; the real
  file is `v2.0.0-beta.2.json`, and `generate-release-manifest.sh` **exits 2** on a missing
  evidence file. Copy-pasting the documented procedure did not work.
- **`RELEASE-GATES.md` contradicted itself** on `missing_sbom` in strict — one table blocking,
  the other report-only, under a line asserting the two are kept consistent. Verified against
  the resolver (`FAIL_ON_MISSING_SBOM=true` in strict); the second table was wrong.
- **"Eight manifests ship"** in three docs; nine do (seven single-stack + two combinations).
- **`strict-regulated-execution.md` arithmetic never reconciled** — "baseline blocks 13" while
  its own list enumerated 9 additions. Replaced with counts verified against the resolver:
  report-only 3, baseline 16, strict 32, regulated 40.
- **`profile-compatibility.md` said php-library has no deptrac/psalm**; the manifest declares
  both. This matters — skipping `deptrac.yaml` raises `missing_architecture_evidence`, which
  blocks in strict/regulated.
- **`severity-normalization.md` described parsing that does not happen**: Dependency-Check was
  documented as CVSS-bucketing when the collector does an exact `.severity` **string** match
  (so a non-standard label is not bucketed), and `dast_findings` was described as a raw finding
  count when ZAP filters `riskcode >= 2` and Nuclei keeps critical/high/medium — so
  `dast_findings: 0` means "no Medium+ finding", not "no findings".
- **`v2-merge-commit-ci-evidence.md` asserted in the present tense** that v1.9.2 is the latest
  supported tag, inside a frozen evidence record cited by `product-status.md` as current.

New: `tests/prod/271-doc-reference-integrity.sh` — every documented evidence **input** path
exists, documented manifest counts match the filesystem, the gate tables agree with the
resolver, and no doc describes parsing the collectors do not perform. Verified falsifiable.

**No tag, release, manifest, or evidence bundle is produced by this change.**

### Fixed — profile tool keys now resolve to real evidence contracts

Profiles recommended and required tools that nothing could execute, and — worse — gated the
*presence* of reports whose *contents* nothing ever read.

- **Silent fail-open closed.** `pint`, `larastan`, `php-cs-fixer`, `phpstan-symfony`,
  `phpstan-doctrine`, `rector` and `syft` ran and wrote raw reports whose filenames had no
  `TOOL_TABLE` row, so `build-security-summary.sh` never read them. Five were
  `missing_behavior: fail`: the gate demanded the file exist, then ignored what was in it.
  A `larastan.json` reporting 47 type errors together with a `pint.json` listing style
  violations produced an **all-zero summary**. Each now has a `TOOL_TABLE` row reusing the
  existing parser for its format (`phpstan.sh`, `php-style.sh`), matching the established
  `trivy-fs|trivy-fs.json|trivy.sh|trivy_fs` convention. The same inputs now yield
  `type_errors=94`, `style_violations=3`.
- **New collectors** `rector.sh` and `syft.sh`. Both are deliberately **advisory**:
  they enforce that the report exists and parses but contribute 0 to every gated counter.
  Rector proposes upgrades (a large count is normal mid-upgrade, not a defect); Syft
  inventories packages and does not judge them. Gating either needs its own counter —
  channel separation is deliberate.
- **Dead keys removed.** `grype-fs` (8 profiles) and `trivy-image` (2) resolved to nothing:
  no `TOOL_TABLE` row, no `.tools` entry, no runner, no collector, no workflow step.
  `grype-fs` → canonical `grype`; `trivy-image` removed (image scanning needs a built image
  these profiles do not assume).
- **New audit** `scripts/audits/profile-tool-integrity.sh` + suite
  `tests/prod/272-profile-tool-integrity.sh` enforce that every recommended, required or
  declared key resolves — via a `TOOL_TABLE` row, a collected `report`, or execution by an
  installed workflow template. Reverting the `TOOL_TABLE` rows reproduces all 17 original
  holes; the audit fails closed with exit 1.

Verified NOT dead, and left alone: `scorecard`, `trufflehog`, `dependency-check` and
`tests` are executed by the installed workflow templates rather than `.tools`, and
`php-tests` is a legitimate `one-of` group whose members write the collected `tests.json`.

### Added — Engineering Quality Gates (v2.1)

First-class **engineering-quality** gate family, extending Sentinel Shield from a security/
release-gate baseline into a broader engineering-governance baseline. Fully additive and
backward-compatible; **no release, tag, or runtime release evidence is produced by this change.**

- **New gates** (resolver + enforcer): `coverage_threshold_violations`, `coverage_regression`,
  `mutation_score_violations`, `complexity_violations`, `duplication_violations`,
  `dead_code_violations`, and the boolean `missing_coverage_evidence`. Emitted as
  `SENTINEL_SHIELD_FAIL_ON_*` and overridable via `gates.fail_on`. Mode defaults: strict blocks
  coverage threshold/regression + complexity + duplication + missing-coverage-evidence; regulated
  additionally blocks mutation + dead-code; report-only/baseline keep all new gates non-blocking.
  Existing mode defaults are unchanged. `missing_coverage_evidence` (set by the builder when a
  profile declares an APPLICABLE coverage tool that produced no report) makes strict/regulated fail
  on ABSENT coverage, not only on bad coverage.
- **Fail-closed hardening**: the coverage adapters reject out-of-range/non-boolean options and
  malformed metric objects (exit 2) and fail closed when an explicitly configured regression
  baseline is missing/malformed; the quality-policy loader validates thresholds as finite,
  in-range numbers (percentages 0..100, complexity integer ≥ 1) and rejects `1.2.3`/`...`/`101`/
  `-1`/`NaN`; the PHPMD/knip runners require a recognized report shape (no fake-clean 0 from `{}`).
- **Schema** (`schemas/security-summary.schema.json`): additive optional summary keys — the six
  gate counters above plus informational `coverage_line_percent`, `coverage_branch_percent`,
  `coverage_method_percent`, `coverage_class_percent`, `mutation_score_percent`, `complexity_max`,
  `complexity_average`, `duplication_percent`, `dead_code_count`. Existing required keys, key
  names, and exit-code semantics are unchanged; old summaries still validate.
- **Collectors** (`scripts/collectors/`): `coverage`, `mutation`, `complexity`, `duplication`,
  `dead-code` — same missing→`unavailable`/invalid→exit-2 contract as every other collector.
- **Builder** (`scripts/build-security-summary.sh`): quality counters merge as a separate channel
  (never mixed with vulnerability counters). Combined-profile coverage aggregation — violations
  SUM across stacks, coverage percentages take the MINIMUM (weakest stack drives the gate),
  `coverage_regression` is 1 if any stack regressed. Per-stack `php-*`/`js-*` report aliases keep
  distinct tool visibility; a missing quality report is `unavailable`, never fake-clean.
- **Coverage support**: PHP Clover (`scripts/adapters/clover-to-coverage-json.php` +
  `scripts/runners/php-coverage.sh`) and JS Istanbul
  (`scripts/adapters/istanbul-summary-to-coverage-json.mjs` + `scripts/runners/js-coverage.sh`),
  with threshold + baseline-regression evaluation from the quality policy.
- **Additional runners** (optional/recommended by policy): `infection.sh`, `phpmd-complexity.sh`,
  `phpcpd.sh` (PHP); `stryker.sh`, `jscpd.sh`, `knip.sh` (JS/TS). All leave the report absent when
  their tool is unavailable.
- **Quality policy**: `.sentinel-shield/quality-policy.yaml` (loader `scripts/lib/quality-policy.sh`,
  schema `schemas/quality-policy.schema.json`, template `templates/quality-policy.example.yaml`) —
  thresholds/baselines for the runners. Fails closed (exit 2) when present-but-malformed; an absent
  policy uses documented defaults.
- **Profiles**: coverage/complexity/duplication (recommended) and mutation/dead-code (optional)
  wired into `laravel`, `symfony`, `php-library`, `node`, `react`; combined profiles
  (`node-react`, `laravel-react-docker`, `hardened-enterprise`) compose both stacks via `extends`
  without one stack satisfying the other's coverage.
- **Docs**: new `docs/engineering-quality-gates.md`; updated raw-report and schema references.
- **Tests**: `tests/prod/270-quality-gates.sh` covers resolver defaults/overrides, all
  collectors, builder aggregation, enforcer enable/disable/strict/regulated, quality-policy
  fail-closed, and the Istanbul/Clover adapters.
- **Evidence-backed gating (round 2)**: additional best-practice gates so strict/regulated cannot
  pass because reports are absent or new code is untested —
  - `changed_lines_coverage_violations` / `changed_lines_coverage_percent` — diff (changed-lines)
    coverage vs `quality.coverage.changed_lines_min` (baseline+). Collector `diff-coverage`;
    deterministic PHP runner `php-diff-coverage.sh` (git diff + Clover per-line via
    `clover-diff-to-coverage-json.php`); JS is external-normalized.
  - `missing_test_evidence` / `empty_test_suite` (boolean, baseline+) + `test_count` /
    `skipped_tests` (`skipped_tests` gates in regulated) — the test adapters (PHPUnit/Pest/Jest/
    Vitest) now emit `tests`/`skipped`; the builder flags an applicable test stack with no report
    or zero tests. PHP and JS test evidence are independent.
  - `focused_test_violations` (all modes) / `skipped_test_marker_violations` (strict+) — grep
    scanner `focused-tests.sh` for `describe.only`/`->only()`/`markTestSkipped`/`it.skip`/…
  - `debug_code_violations` (baseline+) — grep scanner `debug-code.sh` for
    `dd`/`dump`/`var_dump`/`console.log`/`debugger`/… (production source only).
  - `large_file_violations` / `large_function_violations` (strict+) + `max_file_lines` /
    `max_function_lines` — `source-size.sh` (file-size deterministic; function-size best-effort/
    external), thresholds `quality.maintainability.max_file_lines` / `max_function_lines`.
  - Quality-policy validation tightened: percentages finite 0..100, integer thresholds ≥ 1,
    present-but-empty rejected (exit 2); new `quality.coverage.changed_lines_min` +
    `quality.maintainability.*`.
  - Profiles: the fast quality tools (coverage/complexity/duplication + diff-coverage + the
    focused/debug/size scanners) now run on PRs (`execution.pr=true`); mutation and dead-code stay
    off-PR. New tool keys wired into all five base profiles (combined profiles compose via
    `extends`).
  - `270-quality-gates.sh` extended (67 checks): every new gate's failure path, combined-profile
    PHP/JS coverage + test-evidence independence, quality-policy malformed cases, adapter option/
    baseline fail-closed, the `js-coverage.sh` no-dir fix, and all runners; Node **and** PHP are
    now mandatory for this suite (no skip-pass), provisioned in the CI `self-tests` job.

### Added — Architecture Governance v2 (v2.1.0)

Architecture validation becomes a first-class, evidence-backed, **multi-language** governance
layer instead of a single PHP tool wrapper. Fully additive and backward-compatible; **no release,
tag, release manifest, or evidence bundle is produced by this change** — the latest published
release remains `v2.0.1`.

Sentinel Shield enforces architecture governance through normalized architecture evidence.
Deptrac is the PHP structural-boundary producer. dependency-cruiser and ESLint boundaries are
JS/TS producers. Custom architecture tests can also emit the same contract. Architecture tools
detect dependency-boundary violations, not the quality of domain modeling itself.

- **New gate + summary keys**: boolean `missing_architecture_evidence` (emitted as
  `SENTINEL_SHIELD_FAIL_ON_MISSING_ARCHITECTURE_EVIDENCE`, overridable via `gates.fail_on`) plus
  informational `architecture_rule_count`, `architecture_tool_count`, `architecture_context_count`.
  The existing `architecture_violations` gate is unchanged in name and meaning but is now the SUM
  across every architecture producer. Mode defaults: `architecture_violations`
  false/true/true/true and `missing_architecture_evidence` false/false/true/true across
  report-only/baseline/strict/regulated — baseline blocks on violations found by evidence that
  exists; strict/regulated also block when expected evidence is missing, unavailable or errored.
  All keys are optional/additive: older summaries stay valid and an absent key reads as 0/false.
- **Normalized architecture raw contract** (`{tool, status, violations, rule_count, context_count,
  failures[]}`) implemented once in `scripts/collectors/architecture.sh`. Statuses `pass`,
  `findings`, `unavailable`, `not-configured`, `execution-error`, `disabled`, `not-applicable` are
  preserved verbatim; only `pass`/`findings` count as evidence. Fail-closed throughout: unknown
  status → `execution-error`, unrecognized native shape → `execution-error` (never a clean 0),
  a malformed/negative/fractional violation count → `execution-error` (never coerced to a clean 0,
  and never credited as an evidence-producing tool), missing/empty report → `unavailable`, invalid
  JSON → exit 2. The COLLECTOR status vocabulary is unchanged (`pass`/`fail`/…): the new statuses
  apply to the raw-report surface, so `deptrac` still emits `fail` exactly as it has since v0.1.14.
- **Deptrac hardened** (`scripts/runners/deptrac.sh`, `scripts/collectors/deptrac.sh`):
  `--output`/`--config`/`--policy` flags, config detection (`deptrac.yaml`/`.yml`/`.php`), vendor
  and global binary support, version metadata, native output preserved verbatim, and honest
  `unavailable` / `not-configured` / `execution-error` statuses. The collector accepts the known
  native shapes and the normalized contract; an unrecognized shape is `execution-error`, never
  `pass`.
- **New producers**: PHPArkitect (`php-arkitect`), custom PHP architecture tests
  (`php-architecture-tests`), dependency-cruiser, ESLint boundaries (`eslint-boundaries`), and
  custom JS/TS architecture tests (`js-architecture-tests`) — each with a runner, a collector and a
  `templates/raw/*.example.json`. JS runners detect the package manager from the lockfile
  (`package-lock.json` → npm, `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn) instead of forcing
  `npx`. `eslint-boundaries` counts ONLY boundary rules (`boundaries/*`,
  `import/no-restricted-paths`, `no-restricted-imports`), so general ESLint findings are never
  double-counted as architecture violations.
- **Architecture policy** (`scripts/lib/architecture-policy.sh` +
  `templates/architecture-policy.example.yaml`): POSIX sh loader in the spirit of
  `quality-policy.sh` — mikefarah `yq` v4 when available, canonical-YAML awk fallback otherwise,
  never required. Fails closed on malformed YAML, non-boolean known booleans and present-but-empty
  known fields; an absent policy means defaults. `architecture.enabled: false` /
  `architecture.evidence_required: false` are the honest opt-outs.
- **Builder** (`scripts/build-security-summary.sh`): architecture evidence is profile-aware like
  coverage/test evidence. Violations, rule counts and tool counts SUM across producers;
  `architecture_context_count` takes the MAXIMUM (producers describe the same codebase, so summing
  would double-count). Architecture findings are never folded into security counters. Optional
  (opt-in) producers never set `missing_architecture_evidence`.
- **Profiles**: `laravel`, `symfony`, `php-library` gain `php-arkitect` and
  `php-architecture-tests` (both optional) alongside the existing recommended `deptrac`; `node` and
  `react` gain recommended `dependency-cruiser` + `eslint-boundaries` and optional
  `js-architecture-tests`. The fast JS producers run on PRs; Deptrac/PHPArkitect/custom suites run
  on the main gate. Combination profiles compose via `extends`, keeping PHP and JS evidence
  independent.
- **Style templates** under `templates/architecture/` (clean-architecture, hexagonal,
  ddd-bounded-contexts, modular-monolith, node-clean-architecture, node-ddd-bounded-contexts,
  react-feature-boundaries), each marked "Template only. Adapt to your namespaces/folders. Do not
  enable as blocking until observed clean." Project-owned architecture files are never overwritten.
- **Docs**: new `docs/architecture-governance.md`; `docs/architecture-policy.md` rewritten for
  v2.1.0; updates across raw-report-contract, security-summary-schema, gate-resolution,
  profile-tool-policy, product-status/contract, strict/regulated readiness, consumer-onboarding,
  production-rollout, the Deptrac guides and the README.
- **Tests**: new `tests/prod/280-architecture-governance.sh` covers resolver mode defaults, every
  collector (native + normalized + fail-closed paths), runner honesty without the tools installed,
  builder aggregation and non-mixing with security counters, profile-aware missing evidence,
  combined PHP+JS independence, and the policy loader's fail-closed parsing. Picked up
  automatically by `scripts/self-test.sh production-readiness`.

**Behavior changes to note.** The generic architecture-test runner no longer maps a failing
command to `violations: 1`: a command that fails without emitting the JSON contract is now an
honest `execution-error` (a failure of unknown size is not a violation count). It also deletes any
stale report before running, so a leftover report from a previous run can never be mistaken for the
current run's evidence.

Architecture governance is supported by engine tests and fixtures. Do not claim real consumer proof
until a real Laravel/Symfony/Node consumer validation exists.

## [2.0.1] — Engine-Only Maintenance Release — 2026-07-09

Maintenance release candidate refreshing post-`v2.0.0` release evidence. **No executable
engine change** over `v2.0.0`: the only differences from the v2.0.0 evidence merge (`c9013b5`)
are documentation reconciliation (PR #37) and SHA-pinned workflow-action upgrades
(`actions/upload-artifact` 4→7 #6, `actions/checkout` 4→7 #7, `actions/setup-node` 4→6 #8,
`github/codeql-action/autobuild` 3→4 #34, `actions/download-artifact` 4→8 #35) — CI
infrastructure only. Evidence re-derived against source commit `32812ed` (7 required
workflows green, event=push); `verify-candidate` for `stage=ga scope=engine-only` → **READY**,
`framework-validated` / `full-platform` → **BLOCKED**. **Excluded:** Laravel/Symfony
live-consumer validation (framework-validated / full-platform GA is not claimed). Published
2026-07-09 as an SSH-signed tag at `32812ed`, marked latest. Published under a documented
**sole-maintainer authorization** deviation: the enforced two-person `requested_by ≠
approved_by` control cannot be satisfied by a single admin, so it was waived by the release
owner (see [`docs/release-authorization-policy.md`](docs/release-authorization-policy.md)).
See [`docs/v2.0.1-release-notes.md`](docs/v2.0.1-release-notes.md) and
[`docs/v2.0.1-known-limitations.md`](docs/v2.0.1-known-limitations.md).

## [2.0.0] — Engine-Only Production Release — 2026-07-09

Published GitHub release (marked latest), engine commit `13be630`, evidence merged by PR #36.
Engine, installer, recovery, security controls, release-governance tooling, standalone
PHP-library and Node/React consumer harnesses, and black-box adopter validation passed the
engine-only production gates. **Excluded:** Laravel/Symfony live-consumer validation and
independent external-adopter validation (framework-validated / full-platform GA is not
claimed). RC→GA source is unchanged executable code (evidence/docs metadata only); the RC
soak was explicitly waived by the release owner (`evidence/releases/v2.0.0-soak-waiver.json`).
See [`docs/v2.0.0-release-notes.md`](docs/v2.0.0-release-notes.md) and
[`docs/v2.0.0-known-limitations.md`](docs/v2.0.0-known-limitations.md).

## [Unreleased]

### v2.0.0-beta.2 (DRAFT — engine-only, not published) — production-readiness hardening

Additive hardening increment on top of the published `v2.0.0-beta.1` engine-only
pre-release. **No STABLE CLI, exit code, env var, or schema was renamed or removed.**
Framework live-validation remains **excluded**: Laravel/Symfony are engine- and
fixture-tested only, and the standalone PHP-library consumer is **structural only**
(live composer/phpunit/phpstan/pint gates are CI-deferred SKIPs). Final commit / CI-run /
artifact / tag identifiers are pending the release commit. See
[`docs/v2.0.0-beta.2-release-notes.md`](docs/v2.0.0-beta.2-release-notes.md) and
[`docs/migration-beta1-to-beta2.md`](docs/migration-beta1-to-beta2.md).

- **CI / actions.** New `scripts/audits/workflow-runtime-audit.sh` gate (SHA-pins,
  least-privilege `permissions`, `timeout-minutes`, `concurrency`, `if-no-files-found`)
  wired into `ci-workflow-lint`; action inventory recorded.
- **Scanners.** OSV-Scanner action `v1.9.0` → `v2.3.8`; Grype (`anchore/scan-action`)
  `v4` → `v7.4.0` (re-pinned by SHA). Collectors carry scanner-version + db-timestamp
  metadata and tool-provenance checksums. New scanner-health vocabulary
  (`ok|findings|no-targets|scanner-error|parser-error`) with **fail-closed exit 2 on
  `parser-error`** (unparseable output is never treated as clean).
- **Consumer validation.** One unified consumer-validation record schema
  (`schemas/consumer-validation.schema.json`) via `scripts/report-consumer-validation.sh`.
  Node service + React app **LIVE-TESTED** (real npm/pnpm/yarn lockfiles;
  `npm ci` / `pnpm --frozen-lockfile` / `yarn --immutable`; mutations caught;
  byte-for-byte rollback). Standalone PHP-library consumer **STRUCTURAL only**.
- **Installer / recovery.** `scripts/lib/transaction.sh` extracted verbatim from three
  inline copies; append-only transaction journal + `scripts/recover-operation.sh`
  (fail-closed, exit 4 on tampered/partial journal); optional
  `scripts/lib/source-verification.sh` (tree checksum / signed-tag); deterministic
  installation-plan JSON.
- **Automation interface.** Opt-in `--output json` command-result envelope on `doctor`,
  `install-baseline`, `sync-baseline`, `plan-upgrade`, `bootstrap-profile-tools`,
  `run-local-pipeline`, `check-release-readiness` (human output + exit codes unchanged;
  secrets masked, absolute paths stripped; `schemas/command-result.schema.json`).
  Black-box adopter harness (`tests/adopter/black-box-install.sh`).
- **Governance.** `config/required-checks.json` registry +
  `scripts/audits/required-checks-audit.sh` + `scripts/audits/merge-safety-audit.sh`
  wired into `ci-workflow-lint`.
- **Evidence / provenance.** `scripts/collect-release-evidence.sh` (engine_ci[]
  generator from the GitHub API), `scripts/verify-release-artifacts.sh` + archive-safety
  guards, reproducible release manifest (`scripts/generate-release-manifest.sh` +
  `scripts/verify-release-manifest.sh`), finite two-commit finalization
  (`scripts/finalize-release-evidence.sh`). Signing/attestation deferred.
- **Production-readiness candidate + independent evidence review.**
  `scripts/run-production-readiness.sh` orchestrates every local engine-only gate (shell
  syntax, shellcheck, actionlint, schema validation, self-tests, all prod tests, adopter
  scenarios, consumer validation, security acceptance, release-authorization negative+positive,
  archive/artifact adversarial, evidence+manifest reproducibility) into one bounded,
  fail-closed report (`schemas/production-readiness-report.schema.json`) — a hung gate yields a
  DISTINCT exit code 4. Its `review` mode treats the generated report as **UNTRUSTED** evidence
  and independently re-derives source commit, changed-file inventory, test applicability,
  skipped/failed required jobs, workflow identity, default branch, event type, artifact
  ownership + content, report freshness, scanner health, compatibility coverage, adopter score,
  release limitations, and tag-target policy (profiles `ci-gate` / `release`). A
  `version-decision` helper recommends `v2.0.0-beta.3` (material blockers), `v2.0.0-rc.1`
  (behavior complete, soak/evidence remains), or `v2.0.0` (all engine-only GA criteria pass) —
  titled engine-only until the framework tracks are independently validated. Wired into the new
  `ci-production-readiness` workflow (SHA-pinned) and covered by
  `tests/prod/263-production-readiness.sh` (positive / negative / failure-injection). The
  new workflow's jobs are registered in `config/required-checks.json`.

### Hardening (production readiness)
- **Safe acquisition (destructive-cleanup guard).** `acquire-sentinel-shield.sh` validates
  `--destination` before any destructive step; `--cleanup` / re-acquire **refuse** (exit 2,
  nothing deleted) an unsafe path (`.`, `..`, `/`, `$HOME`, repo root, an ancestor, or a
  symlink that escapes the tools dir). Only a dedicated tools directory is permitted.
- **No path leak in the acquisition record.** `.sentinel-shield-ref` is normalized and never
  stores a local/home path: GitHub shorthand → `repository_kind:"github"`; explicit URL →
  `repository_kind:"url"` (credentials/query/fragment stripped); local path →
  `repository_kind:"local"`, `repository:null`.
- **Recovery fails closed.** A transactional install/sync/migration whose rollback cannot
  complete now **exits 4**, retains its operation lock + snapshots
  (`state:"rollback-incomplete"`), and prints a manual recovery procedure — never claims
  success, never deletes recovery data.
- **Full-suite release readiness.** `check-release-readiness.sh` runs the self-test *syntax*,
  *production-readiness*, *e2e*, and *all* suites plus schema/workflow/pinning/hygiene/evidence
  gates; fixture existence is no longer treated as proof.
- **Structural vs GitHub-verified evidence.** `validate-release-evidence.sh` adds `--offline`
  (structural only) and `--verify-github` (confirms run IDs/commit/conclusion); `beta`+
  promotion requires GitHub-verified evidence (or a documented equivalent).
- **Stage-differentiated overrides.** Override policy now differs by stage — alpha CLI
  `--override-reason` (loud, recorded); beta a version-controlled, unexpired
  `.sentinel-shield/release-override.json` waiver with no self-approval; rc/ga prohibited or
  strict signed waiver. Secrets, malformed evidence, failed rollback, and path-safety can
  never be waived.
- **Pipeline evidence layout + retention.** `run-local-pipeline.sh` keeps a run's evidence
  under a single root (or the explicit `--output-dir-partial` mode behind a concurrency lock),
  and `--purpose developer|release` controls raw-evidence retention — `release` hashes each raw
  report into the stage execution manifest.
- **Docs/prompts aligned.** Install/update prompts and the install, update, tool-provisioning,
  upgrading, v2-migration, workflow-execution-model, and consumer-validation docs document the
  above and use the real post-remediation flags.

## [2.0.0-beta.1] — Engine-Only Beta Pre-Release — 2026-07-02

**MAJOR (beta pre-release).** `v2.0.0-beta.1` is **published as a GitHub
[pre-release](https://github.com/bogdaniel/sentinel-shield/releases/tag/v2.0.0-beta.1)**
under **engine-only** scope: the engine is validated by its own GitHub-verified default-branch
CI (engine commit `becec20`), and Laravel/Symfony profiles are engine- and fixture-tested but
**not** live-validated in real consumer repositories. It is a pre-release — **not** stable,
**not** the latest release, and **not** framework-validated. It supersedes the earlier
`v2.0.0-alpha.1` candidate and carries the same profile tool-policy work recorded below. The
**latest stable, supported line remains v1.x (latest published tag `v1.9.2`)**. Not a drop-in
upgrade — read `docs/v2-migration-guide.md` first.

## [2.0.0-alpha.1] — Profile Tool Provisioning & Required-Tool Enforcement (candidate — superseded by v2.0.0-beta.1)

**MAJOR (alpha candidate).** This entry documents the `v2.0.0-alpha.1` candidate, which was
**superseded by the published `v2.0.0-beta.1` pre-release**. Changes the meaning of a profile: a profile now declares a machine-readable
**tool policy** (required/recommended/optional/one-of/disabled/external) and the toolchain is
explicit, verifiable and upgradeable. The v2 line is scoped **engine-only**: it is backed by the
engine's own green default-branch CI, **not** by real Laravel/Symfony consumer runs. **Laravel and
Symfony are supported by profiles, fixtures and engine tests but are not independently
live-validated in real consumer repositories**; that validation is deferred (see
`docs/consumer-validation-runbook.md` and `docs/v2-tracking-issues.md`). Not yet a drop-in upgrade —
read `docs/v2-migration-guide.md` first.

### Added
- **Tool-policy schema** (`schemas/tool-policy.schema.json`) — per-tool `policy`, `category`,
  `packages`, `executable`, `runner`, `report`, `missing_behavior`, `requires`, `alternatives`,
  `execution`, `config`. Profile manifests extended additively with `tools`, `extends`,
  `tool_policy_version`. Per-tool status enum gains `findings`, `not-configured`, `not-applicable`,
  `execution-error`, `disabled`. Contract: `docs/profile-tool-policy.md`.
- **Profile tool policies** for laravel, symfony, php-library, node, react, and composed
  combinations (laravel-react-docker, node-react, hardened-enterprise) via `extends` with
  `required>one-of>recommended>optional>external>disabled` precedence, composed by the
  canonical resolver (`scripts/resolve-effective-profile.sh`, `scripts/lib/effective-profile.sh`).
- **Compatibility resolver** (`scripts/lib/compat-resolver.sh`, `scripts/resolve-tool-plan.sh`) —
  inspects PHP/framework/lock state, emits an install plan, never downgrades app/framework deps;
  conflicts → isolated-tool recommendation.
- **Provisioning** — `install-baseline.sh`/`sync-baseline.sh` gain `--tool-mode`
  `config-only|require-existing|bootstrap-tools`, `--emit-plan`, `--non-interactive`;
  `scripts/bootstrap-profile-tools.sh` (dry-run default, explicit `--apply`, rollback on failure);
  isolated-tool manager (`scripts/lib/isolated-tools.sh`).
- **Runners** — new deterministic PHP/Node runners: larastan, pint, php-cs-fixer, rector, pest,
  phpunit, composer-audit, npm-audit (honest `unavailable`, never fake-clean).
- **Doctor + maturity** report activation state (installed/configured/executed/gate-enforced);
  `doctor.sh` exits 3 when required tools are absent under `require-existing`/`bootstrap-tools`.
- **Upgrade UX** — `scripts/plan-upgrade.sh` (text/markdown/json, mutates nothing),
  installation metadata (`schemas/installation.schema.json`, `scripts/lib/installation-metadata.sh`),
  project override (`schemas/tool-policy-override.schema.json`, `scripts/lib/tool-policy-override.sh`),
  v1 migration (`scripts/migrate-v1.sh`).
- **Prompts/docs** — `prompts/update-sentinel-shield.md` (17 safety clauses), updated
  `prompts/install-sentinel-shield.md`; `docs/upgrading.md`, `v2-migration-guide.md`,
  `tool-provisioning.md`, `workflow-execution-model.md`, `ai-assisted-update.md`.
- **Self-tests** — `self-test.sh v2-toolpolicy` covers the 30 required v2 cases (policy semantics,
  one-of, composition precedence, SHA-pin verification, every-required-tool-in-workflow, override
  validation, migration preservation, no-leak).

### Hardening (review round 3)
- **Portable waiver validation.** `control-waivers.sh` date checks are POSIX `/bin/sh` safe
  (no `$((10#..))`; `dash`-correct for `08`/`09`); reject year `0000`.
- **Waiver schema v1 + safe keys.** `version` must be the string `"1"`; tool keys must match
  `^[A-Za-z0-9_.-]+$` (a single shell-safe token — can never split into multiple controls);
  `created_at <= expires_at`; UTC expiry. Schema `control-waiver.schema.json` updated.
- **Fail-closed everywhere.** `doctor.sh` and `maturity-report.sh` validate the waiver file
  **unconditionally** (a malformed file is rejected even when `jq` is absent) — same verdict
  across doctor/maturity/gate/bootstrap/resolver.
- **Numeric gate count.** `enforce-gates.sh` no longer mis-parses the detailed required-failure
  count (`grep -c` no-match) — summary-only `required_tool_failures>0` still fails closed.
- **Honest direct runners.** PHPStan/Jest/Vitest (and the other PR-added runners) clear any stale
  report up-front, so a direct invocation can't inherit a previous run's valid report.
- **Quoting/globbing safety.** `resolve-workflow-plan.sh` no longer flattens `--target` into an
  unquoted scalar (paths with spaces/glob chars work); `maturity-report.sh` parses activation
  records with tab-aware `read` (no word-splitting/pathname expansion).
- **Independent test groups.** The shared `tests` one-of is split into `php-tests`
  (`pest`|`phpunit`) and `js-tests` (`vitest`|`jest`); combined profiles require **both**
  independently — a JS runner never satisfies a PHP test requirement or vice versa. Both reports
  feed the `test_failures` gate.
- Self-test: new `v2-review-round3` group; the validator-hidden case now runs against a temp copy
  (never renames a repo file).

### Enforcement (remediation)
- **Required-tool gate is the single decision point.** `enforce-gates.sh` derives required-tool
  status from report presence/validity and returns only `0/1/2`: a required tool that is
  `unavailable`/`not-configured` (contract code 3) or produced no valid report / `execution-error`
  (contract code 4) surfaces **here as a gate failure (exit 1)**, not 3/4 — those belong to the
  runners/orchestrator upstream. Legacy runners keep the honest-absent pattern (report absent,
  exit 0); `unavailable` is never converted to a clean `0`.
- **Control-waiver, not `disabled_tools`, waives a required control.** A required tool recorded as
  disabled (`installation.json` `disabled_tools`) still fails the gate unless covered by an
  unexpired, owner-bound, expiring waiver in `.sentinel-shield/control-waivers.json`
  (`schemas/control-waiver.schema.json`). A waiver only re-words the failure as a prominently-
  reported, time-boxed waiver; it never suppresses findings (use accepted-risks) and is never
  auto-applied.
- **Non-suppressible secrets scanners fail closed.** `tool-policy.yaml` cannot set `gitleaks` or
  `trufflehog` to `disabled`; the effective-profile resolver rejects it (exit 2). Overrides may not
  convert an `execution-error` into `pass`.
- **Node package-manager ambiguity is fatal.** `bootstrap-profile-tools.sh` exits 2 when multiple
  distinct Node lockfiles are present (resolve via `package.json` `packageManager`); pnpm/yarn/npm
  are selected by lockfile (`pnpm-lock.yaml`/`yarn.lock`/`package-lock.json`).
- **Rollback limitations documented honestly.** `bootstrap-profile-tools.sh` rolls back
  dependency manifests/lockfiles on install/test failure; engine + managed-file rollback is
  re-pinning `SENTINEL_SHIELD_REF` to the prior tag and re-running `sync-baseline.sh --apply
  --force`. Doc over-claims from the prior pass (e.g. "accepted-risk record" to disable a control)
  were removed.

### Deferred
- Live Laravel/Symfony consumer CI run IDs (beta/RC/GA gate); `--apply` bootstrap exercised against
  real composer/npm.

## [1.9.1] — Pin managed workflow actions

**Additive patch — supply-chain hardening only.** No engine/STABLE change, no flag change, no
scanner/maturity change. Drop-in from v1.9.0.

### Changed
- `templates/workflows/sentinel-shield.yml`: pin all third-party GitHub Actions to full 40-char
  commit SHAs (version retained as a trailing comment). Satisfies the `unsafe_github_actions` gate
  for consumers and removes moving-tag supply-chain risk. Consumers pick this up via
  `sync-baseline.sh --apply --force`.

## [1.9.0] — AI-Assisted Install Guide

**Additive minor — docs/tooling only.** No engine/STABLE change, no install/sync flag change, no new
scanners, **no maturity change**, no IaC/AWS/Kubernetes work. Drop-in from v1.8.0.

### Added
- **`docs/ai-assisted-install.md`** — what AI-assisted install is/when/what it does + must NOT do,
  audit-before-install, profile selection, upgradeability, accepted-risks, CI, local validation, honest
  failure reporting. Explicit: **not blind auto-install; inspect first; never suppress findings; never
  commit secrets/private artifacts.**
- **`prompts/install-sentinel-shield.md`** — copy-paste AI-agent prompt with 14 phases (audit → git
  hygiene → PHP/Node baselines → profile → install → non-IaC gate → Deptrac → accepted-risks → local →
  CI → docs → upgradeability → final report), hard non-negotiables, and upgradeability rules.
- **`scripts/print-ai-install-prompt.sh`** — additive, read-only helper that prints the prompt
  (exit 0; exit 2 if missing). No network, no mutation.
- Links from README, `docs/index.md`, and the quickstart (as an **optional** path — manual install
  remains the supported baseline).
- **Self-test `v190-ai-install`** — guards the guide/prompt exist, are linked, contain the key safety
  clauses (no secrets, no suppression, dry-run, final report), helper works, hygiene. Self-test
  **644 → 658 PASS / 0 FAIL**.

## [1.8.0] — Non-IaC Completion Sprint

**Additive minor.** No STABLE contract change, no new scanners, no gates weakened, **no maturity
promotions.** Closes the repeatedly-identified **non-IaC** post-GA scope; AWS/k8s/IaC live validation
stays **deferred** and IaC stays `ci-validated (evidence-fixture)`. Drop-in from v1.7.0.

### Added — tooling (additive scripts)
- `scripts/doctor.sh` — preflight/diagnostics (tooling, profile, accepted-risks, reports, workflows,
  NVD key **by name only**); exit 0 info / 2 invalid. Does not run scanners or change gates.
- `scripts/support-bundle.sh` — redacted diagnostics tarball; **excludes `reports/raw`, `.env`,
  secrets** by default; `--include-raw` adds redacted copies with a warning.
- `scripts/maturity-report.sh` — offline scanner maturity matrix as markdown or JSON.
- **Hardened enterprise profile** `profiles/hardened-enterprise/` — first-class **opt-in**
  (`--profile hardened-enterprise`); ships the digest/SHA-pinned hardened reference; defaults unchanged.

### Added — docs
- `severity-normalization.md`, `external-adoption-test.md`, `dast-staging-runbook.md`,
  `ai-security-review.md`, `consumer-cleanup.md`, `install-sync-ux.md`; buyer pack support/RACI model;
  roadmap **closure** (closed / intentionally-deferred / future-optional + the "100% non-IaC" definition);
  troubleshooting v3; Dependency-Check operational finalization. All linked from `docs/index.md`.

### Guarded
- **Self-test `v180-completion`** — hardened profile opt-in + round-trip, doctor/support-bundle/maturity
  scripts present + valid output, severity (npm MODERATE→medium), DAST not-PR-fast, AI non-gating,
  roadmap closure sections, no IaC `live-validated` claim, hygiene. Self-test **613 → 644 PASS / 0 FAIL**.

### Deferred (explicit, not in scope)
- AWS / Kubernetes / IaC **live** validation; IaC maturity promotion; DAST default gating; AI gating;
  STABLE (v2.0.0) changes (`profile list` flag, `sync-managed-block` in-place updater).

## [1.7.0] — Evidence Platform and Public Adoption Kit

**Additive minor — documentation/platform only.** No engine/STABLE change, no new scanners, no gates
touched, **no maturity promotions** (IaC stays `ci-validated (evidence-fixture)`; Deptrac stays
`live-validated`). Drop-in from v1.6.0.

### Added
- **Evidence platform** [`evidence-platform.md`](docs/evidence-platform.md) — engine↔evidence-repo
  model, repo categories (evidence-fixture / real-consumer / private-aggregate), required metadata,
  artifact/run-ID/version/sanitization conventions.
- **Evidence contribution rules** [`evidence-contribution-guide.md`](docs/evidence-contribution-guide.md)
  — what qualifies/disqualifies, no-fake-output & no-deploy policy, reviewer checklist.
- **Scanner maturity policy v2** [`scanner-maturity-policy.md`](docs/scanner-maturity-policy.md) —
  label definitions + promotion/demotion/caveat rules; `ci-validated` kept **distinct** from `live-validated`.
- **Live-validation playbook** [`live-validation-playbook.md`](docs/live-validation-playbook.md) —
  how to promote `ci-validated` → `live-validated` on a real consumer.
- **Public adoption kit** [`public-adoption-kit.md`](docs/public-adoption-kit.md) and **enterprise
  buyer pack** [`enterprise-buyer-pack.md`](docs/enterprise-buyer-pack.md).
- **Self-test `v170-platform`** — guards the new docs exist + are linked, the maturity vocabulary,
  and that `ci-validated` is never called `live-validated`. Self-test **593 → 613 PASS / 0 FAIL**.

### Honest scope
- No tool changed maturity. IaC remains `ci-validated (evidence-fixture)` (CI run 27636439883),
  **not** `live-validated`. Platform/docs only.

## [1.6.0] — Supported IaC Evidence Consumer; IaC scanners ci-validated

**Additive minor.** No STABLE contract change, no new scanners, no gates weakened. Introduces the
**`ci-validated (evidence-fixture)`** maturity tier (distinct from `live-validated`). Drop-in from v1.5.0.

### Added — dedicated IaC evidence consumer + first IaC maturity change
- **`bogdaniel/sentinel-shield-iac-evidence`** (public, evidence-only, no credentials, no deploy):
  intentionally-insecure AWS Terraform + Kubernetes YAML + real Rego. Static scanners only.
  Design doc [`iac-evidence-consumer-design.md`](docs/iac-evidence-consumer-design.md).
- **Checkov / Terrascan / Conftest `experimental` → `ci-validated (evidence-fixture)`.** Real CI:
  workflow `iac-evidence`, **run 27636439883** (all jobs success) — Checkov 3.3.1 → `iac_violations=27`,
  Terrascan 1.19.9 → `8`, Conftest 0.56.0/OPA 0.69.0 (real `policy/kubernetes.rego`) → `5`; collectors
  verified on the real artifacts. Sanitized fixtures `tests/fixtures/iac-v160/`.
- **Self-test `v160-iac`** — guards the CI fixtures map (27/8/5), the run ID is cited, the new tier is
  honest, and IaC is still NOT claimed `live-validated`. Self-test **583 → 593 PASS / 0 FAIL**.
- **Enterprise adoption** [`enterprise-iac-adoption.md`](docs/enterprise-iac-adoption.md): supported vs
  unsupported provider table, evidence-consumer pattern, bring-your-own-IaC, multi-team + maturity
  checklists, regulated rollout. Defaults unchanged.

### Honest scope
- **NOT `live-validated`.** Findings are engineered on a dedicated fixture; `live-validated` still
  requires a real third-party-production consumer with a supported AWS/Azure/GCP/Kubernetes surface.
- Conftest CI fix: output file must not be named `conftest.{json,toml,yaml}` (auto-loaded as config).

## [1.5.0] — Deptrac CI Evidence; IaC consumer-CI promotion blocked

**Additive minor.** No STABLE contract change, no new scanners, no gates weakened, **no maturity
promotions** (labels unchanged). Drop-in from v1.4.x.

### Added (real consumer-CI evidence)
- **Deptrac consumer-CI run ID** — the v1.3.0 gap (local-only) is closed. Evidence-only GitHub Actions
  workflow on the **public** consumer **bogdaniel/silver-potato** (genuine `deptrac.yaml`): run
  **27633798174** (success), `deptrac.json` → `scripts/collectors/deptrac.sh` → `architecture_violations=4`
  (**fail**), deptrac 1.0.2. Report-only fixture `tests/fixtures/deptrac-v150/silver-potato-ci.json`
  (counts only — no class/path data). Deptrac stays `live-validated`; caveat upgraded (local + CI);
  severity still binary.
- **Self-test `v150-evidence`** — guards the Deptrac CI run ID citation, the v150 fixture mapping, and
  that IaC is still NOT claimed live-validated. Self-test **574 → 583 PASS / 0 FAIL**.

### Not promoted (honest — consumer-CI surface does not exist)
- **IaC (Checkov/Conftest/Terrascan) stays `experimental`.** A promotion-grade consumer-CI run requires a
  supported AWS/Azure/GCP/Kubernetes surface; the only real IaC consumer (`zenchron-infra`) is 100%
  Hetzner `hcloud` (unsupported). No run ID invented, no IaC fabricated. v1.4.0 local evidence stands.

## [1.4.1] — Sprint Report Clarity Patch

**Documentation-only.** No engine/STABLE change, no maturity change, no new scanners, no gates
touched. Drop-in from v1.4.0.

### Changed
- **`docs/sprint-v140-report.md` re-framed.** Now leads with an executive summary, a **Real diff
  summary** (21 files, +766/−8, 3 commits), and **10 substantive deliverables**; adds a **"What the
  800 tasks mean"** section clarifying the count is brief-mandated atomic-check accounting, **not**
  800 feature-level deliverables. The full 20-lane × 40-item ledger is preserved verbatim under
  **Appendix A — Brief-Mandated Atomic Task Ledger**. All v1.4.0 facts (574/0 self-test, STABLE
  diff = 0, no promotions, honest limitations) are preserved.

## [1.4.0] — Enterprise IaC Evidence, Adoption Scale, and Supportability

**Additive minor.** No STABLE contract change, no new scanners, no gates weakened, **no maturity
promotions.** Drop-in from v1.3.0.

### Added (real local evidence — NOT a promotion)
- **IaC local tool-execution evidence.** Ran the three IaC scanners via their *supported* paths
  against the committed insecure fixture and verified the collectors on real artifacts:
  **Checkov 3.3.1** (`pip`) → 3 resources / **16** violations / 0 parse errors → `iac_violations=16`;
  **Terrascan 1.19.9** → **4** high violations → `4`; **Conftest 0.56.0/OPA 0.69.0** (real repo Rego,
  `--namespace sentinel.terraform`, plan-JSON) → **2** failures → `2`. Derived sanitized fixtures at
  `tests/fixtures/iac-v140/`; docs [`iac-local-evidence-v140.md`](docs/iac-local-evidence-v140.md),
  [`iac-evidence-candidate-matrix.md`](docs/iac-evidence-candidate-matrix.md).
- **Self-test `v140-iac`** (12 guards): IaC fixtures parse through the collectors; the new docs are
  honest (experimental/NOT consumer-CI); the no-overclaim guard now covers the v1.4.0 docs; hygiene
  (no absolute paths/consumer names in fixtures, no scratch tracked). Self-test **562 → 574 PASS / 0 FAIL**.

### Diagnosed (v1.3.0 IaC blocker root causes — still NOT promoted)
- **Checkov** "resource_count:0" → the **Docker image**, not the wrapper/TF (`pip`/Action parse fine).
- **Terrascan** "0 policies" → **`hcloud`-only** (Hetzner unsupported); AWS/Azure/GCP/k8s work.
- **Conftest** "no output" → **namespace + HCL-vs-plan-JSON** usage of the repo Rego.

### Not promoted / not done (honest)
- **IaC stays `experimental`.** A local run is not a consumer-CI live-validation; no run ID exists.
- **Deptrac CI evidence not pursued** this sprint (local-only scope); Deptrac maturity unchanged.
- **Deptrac local re-run blocked** here (no PHP/Composer on the bench); v1.3.0 evidence stands.

## [1.3.0] — Evidence-Based Deptrac and IaC Promotion

**Additive minor.** No STABLE contract change, no new scanners, no gates weakened. **One
evidence-backed maturity promotion (Deptrac); IaC honestly NOT promoted** (no usable evidence).
Drop-in from v1.2.0.

### Promoted (with real cited evidence)
- **Deptrac `experimental` → `live-validated`.** Real **deptrac 1.0.2** runs on real consumer projects
  with genuine `deptrac.yaml` (Controller/Service/Repository layers + ruleset): `commerce-bridge` → 0
  violations (pass), `octo-cms`/`silver-potato` → 4 violations (fail). The SS collector
  (`scripts/collectors/deptrac.sh`) maps `.Report.Violations` → `architecture_violations` — both the
  clean and violation paths exercised on real data. Raw artifacts kept **local** (private consumers);
  fixtures derived from the real `Report` block only (no private class/path data) committed at
  `tests/fixtures/deptrac-v130/`. [`main-gate-live-evidence.md`](docs/main-gate-live-evidence.md).

### NOT promoted (honest blockers — no fake evidence)
- **IaC (Checkov / Conftest / Terrascan) stays `experimental`.** v1.3.0 attempted real Terraform
  (`zenchron-infra`, Hetzner `hcloud`): **Checkov 3.3.0** parsed 0 resources (image not analyzing
  Terraform — confirmed on a trivial known-bad TF); **Terrascan** has no `hcloud` policies (0/0);
  **Conftest** produced no output. No usable `iac_violations` evidence → no promotion. Wrappers
  reported `unavailable`/0, never fake-clean. Exact blockers in the registry.

### Added
- Self-test `v130-evidence` (+12): Deptrac fixtures parse (clean→0/pass, violations→4/fail), Deptrac
  promotion is evidence-backed (registry cites tool version + reproducible command + collector result),
  IaC is NOT claimed live-validated, fixtures carry no private data, no raw artifacts tracked.
- Adoption smoke test confirmed the v1.2.0 quickstart works end-to-end (detect→install→enforce) for a
  fresh fixture — no doc changes needed.

## [1.2.0] — Documentation, Adoption, Enterprise Hardening, and Evidence Readiness

**Additive minor — docs/adoption only.** No STABLE contract change (engine scripts, exit codes, env
vars, schemas, modes byte-for-byte unchanged), no new scanners, no gates weakened, **no maturity
promotions** (Deptrac/IaC stay `experimental` — the new guides are evidence-readiness *planning*, not
promotions). Drop-in from v1.0.0/v1.1.0.

### Added — adoption & support documentation
- **Documentation hub** [`docs/index.md`](docs/index.md): Start Here, "which guide should I read?" by
  role (new adopter / production adopter / security engineer / platform engineer / maintainer /
  auditor), and a canonical doc map tagged stable/advanced/reference/experimental/evidence. README now
  leads with the hub + fast paths.
- **Quickstart** [`docs/quickstart.md`](docs/quickstart.md) — install & run in <30 min, reading
  `security-summary.json`/enforcement output, common first-run failures, rollback.
- **Production rollout** [`docs/production-rollout.md`](docs/production-rollout.md) — pilot → staged →
  default, mode selection, accepted-risk governance, ownership model (SS owns engine/templates/gates;
  consumer owns profile/accepted-risks/findings/remediation), rollout + readiness checklists.
- **Enterprise hardening** [`docs/enterprise-hardening.md`](docs/enterprise-hardening.md) — readable
  tags vs digest-pinned production overrides, SHA-pinned Actions, minimal permissions, branch
  protection, secret/NVD-key handling, strict-vs-regulated, DAST/AI posture (opt-in; not forced).
- **Dependency-Check runbook** [`docs/dependency-check-runbook.md`](docs/dependency-check-runbook.md) —
  committed vs transitive surfaces, NVD key + cold/warm cache, the H2/permission fixes, non-zero-exit
  semantics, troubleshooting table, recommended production settings.
- **Deptrac / IaC evidence-readiness guides** ([`docs/deptrac-evidence-guide.md`](docs/deptrac-evidence-guide.md),
  [`docs/iac-evidence-guide.md`](docs/iac-evidence-guide.md)) — prerequisites, raw paths, collector
  mappings, promotion criteria. **PLANNING ONLY — no maturity change.**
- **Troubleshooting + FAQ** ([`docs/troubleshooting.md`](docs/troubleshooting.md),
  [`docs/faq.md`](docs/faq.md)) — symptom→cause→fix and frequent questions.
- Self-test `v120-docs` (+20): required docs exist, hub links **mechanically resolve** (no broken
  links), README navigable, Deptrac/IaC not promoted (planning-only), no key/`.claude` leakage.

## [1.1.0] — Post-GA Adoption and Hardening

**Additive minor release (semver minor).** No STABLE contract change — engine CLIs, exit codes,
`SENTINEL_SHIELD_*` env vars, schemas, adoption modes, and profile file modes are unchanged. Upgrading
from `v1.0.0` is **drop-in** (bump `SENTINEL_SHIELD_REF`). No new scanners, no maturity promotions
(none had new cited evidence), no gates weakened.

### Added (all opt-in / default-off)
- **Transitive Dependency-Check CI knobs** on `templates/workflows/sentinel-shield-dependency-check.yml`:
  `SENTINEL_SHIELD_DEPENDENCY_CHECK_INSTALL_PHP` / `INSTALL_NODE` (+ `PHP_COMMAND` / `NODE_COMMAND`, and
  `workflow_dispatch` inputs), **default `false`**. When enabled, `composer install` + `npm ci` populate
  the transitive surface before DC (credential-free for public deps; `continue-on-error` → honest
  fallback to the committed surface). **Default off preserves the v1.0.0 committed-surface behavior.**
  Validated on a real consumer (9,179 deps, rc.2 soak run `27576003051`).
  Docs: [`dependency-check-ci-cache.md`](docs/dependency-check-ci-cache.md).
- **Hardened digest-pinned example** extended with the transitive knobs
  ([`examples/hardened/sentinel-shield-hardened.snippet.yml`](examples/hardened/sentinel-shield-hardened.snippet.yml)) —
  digest-pinned scanners + SHA-pinned actions; default templates stay tag-based.
- **Deptrac / IaC promotion plan** ([`docs/deptrac-iac-promotion-plan.md`](docs/deptrac-iac-promotion-plan.md)) —
  evidence checklists, expected raw paths, collector mappings, promotion criteria. **Planning only —
  no maturity change** (Deptrac/IaC stay `experimental` until a real cited consumer run exists).
- **Onboarding/migration doc** ([`docs/v1.1-onboarding-and-migration.md`](docs/v1.1-onboarding-and-migration.md)):
  drop-in upgrade, production onboarding checklist, rollout/rollback, strict opt-in, regulated-not-default,
  and a "what v1.0.0/v1.1.0 does NOT mean" section.
- **Security-hygiene doc** ([`docs/security-hygiene.md`](docs/security-hygiene.md)): NVD key rotation,
  `gh secret set`, verify-no-committed-key, consumer evidence-branch cleanup, artifact retention,
  `.gitignore` coverage.
- Self-test `v110-postga` (+19 checks): transitive knobs additive & default-off, NVD secret-only,
  upload `if: always()`, hardened pins (no floating tag), planning-only promotion docs, no STABLE
  exit-code drift, hygiene.

## [1.0.0] — General Availability

**Sentinel Shield `v1.0.0` is released.** All seven hard v1.0 blockers are closed with cited evidence
(v0.1.27–v0.1.30), and the `v1.0.0-rc.2` candidate **soaked clean on a real consumer** with no STABLE
regression. No new scanners, no scope change from rc.2 — this promotes rc.2 to GA.

### Final-release verification (rc.2 re-soak — run `27576003051`, success)
- **Consumer baseline + strict-EVIDENCE on the `v1.0.0-rc.2` tag** (`bogdaniel/zenchron-tools`):
  transitive Dependency-Check via `composer install` + `npm ci` → **9,179 deps**, collector `fail`
  1 critical / 8 high / 6 medium; baseline FAIL `[critical, high]`, strict-EVIDENCE FAIL
  `[critical, high, medium]` (strict-only delta visible). Nothing suppressed.
- **STABLE exit-code contract verified IN CI** on the rc.2 tag: `resolve-gates` invalid config → exit
  **2**, valid run → exit **0** (`contract_ok: true`). The rc.1→rc.2 fix is confirmed end-to-end.
- self-test **512 PASS / 0 FAIL**; sh-n / JSON / YAML / node all clean; no secrets, no private
  artifacts; prior tags untouched.

### Compatibility promise (from `v1.0.0`)
The STABLE surfaces ([`product-contract.md`](docs/product-contract.md) §1–§3) now follow **semver**:
additive changes in **minor** releases; any rename/removal/exit-code or summary-key semantic change is
a **major** bump with a CHANGELOG callout. EXPERIMENTAL/INTERNAL surfaces and coarse scanner severity
stay outside the semver promise until individually promoted in `product-status.md`.

### Upgrade path
- **From `v1.0.0-rc.2`:** drop-in — bump `SENTINEL_SHIELD_REF` to `v1.0.0`. No STABLE change vs rc.2.
- **From `v0.1.x`:** bump the ref; the STABLE surfaces are unchanged except the documented
  `resolve-gates` config-error exit code (`1`→`2`, fixed in rc.2) — consumers checking only
  non-zero/zero are unaffected.

### Soft limitations carried into `v1.0.0` (documented; `v1.0.0` ≠ "every optional scanner production-default")
Strict mode opt-in/non-required (correctly fails on real findings); regulated opt-in; DAST/Nuclei
manual/fail-closed; AI review non-gating; Dependency-Check transitive CI coverage requires the
consumer to add `composer install`/`npm ci`; digest pinning opt-in (dev tags / prod pinned);
install/sync covers the shipped profiles; `sync-managed-block` reserved; **the NVD API key must be
consumer-provided and rotated** (it was chat-exposed) — never committed or logged.

## [1.0.0-rc.2] — RC Soak Hardening (release candidate; superseded by v1.0.0)

The 3-hour, multi-lane rc.1 soak validated rc.1 on a real consumer and fixed real issues found before
final. **A STABLE-surface bug (resolve-gates exit code) was fixed**, so this is a new candidate
(`rc.2`) for re-soak — not final `v1.0.0`. No new scanners, no scope change, no gates weakened.

#### rc.1 soak — hardening (bugfix/coherence only; no scope change)
- **Fixed (contract coherence):** `scripts/resolve-gates.sh` now exits **2** on config/input errors
  (invalid `--mode`/`--format`, unparseable/missing-required profile), matching the STABLE engine
  exit-code convention (`0`/`1`/`2`) already used by enforce/build/select. It previously exited `1`,
  contradicting `product-contract.md` §1. Guarded by `self-test rc1-soak`.
- **Dependency-Check TRANSITIVE CI coverage proven** on the rc.1 tag (soak run `27573703800`,
  success): `composer install` + `npm ci` before DC → **9,179 deps** scanned in CI (vs 69
  committed-surface), collector `fail` 1 critical / 8 high / 6 medium; strict-EVIDENCE delta visible.
  Closes the v0.1.30 "committed-surface" caveat. [`main-gate-live-evidence.md`](docs/main-gate-live-evidence.md).
- **Docs coherence (soak audit):** removed stale "Dependency-Check experimental / NOT live-validated"
  labels from canonical sections of `product-status.md` (§3/§6/§7) and `strict-mode-readiness.md` (DC
  is live-validated since v0.1.27/v0.1.30). Added rc.1 soak transitive evidence to the registry.
- **Example workflow hardening:** every `upload-artifact` step in
  `examples/laravel-react-docker/.github/workflows/sentinel-shield.yml` now has `if: always()` (raw
  reports survive scanner failure/findings), matching the shipped templates.
- **Self-test `rc1-soak`** (+12 checks): resolve-gates exit-2 contract, no-final-v1.0-claim, contract
  freeze + migration + README links, DC-not-experimental, example-upload `if: always()`.

## [1.0.0-rc.1] — Release Candidate Contract Freeze

**Release candidate — NOT final `v1.0.0`.** No new scanners, no scope expansion, no gates weakened,
no findings suppressed. This tag **freezes the product contract** for soak/validation; final `v1.0.0`
follows the RC soak. All seven hard v1.0 blockers are closed with cited evidence (v0.1.27–v0.1.30).

### Frozen (the v1.0.0 STABLE surface — see [`docs/product-contract.md`](docs/product-contract.md) §1–§3, §6)
- Engine CLIs (`resolve-gates`, `enforce-gates`, `build-security-summary`, `select-security-summary`,
  `install-baseline`, `sync-baseline`) — flags, exit codes (`0`/`1`/`2`), `SENTINEL_SHIELD_*` env vars.
- Schemas (additive): `security-summary.json`, profile manifest, accepted-risks.
- Adoption modes (`report-only`/`baseline`/`strict`/`regulated`), profile file modes, raw-report contract.

### Changed (RC-coherence fixes only — no behavior change)
- **`docs/product-contract.md`**: retitled to the `v1.0.0-rc.1` freeze; resolved a contradiction —
  **OWASP Dependency-Check is now live-validated** (local v0.1.27 + CI v0.1.30), removed from the
  "not yet live-validated" rows in §1/§4; added **§6 RC freeze + v0.1.x→v1.0.0 migration policy** and
  the carried RC known-limitations.
- **`templates/workflows/sentinel-shield-dependency-check.yml`**: plumbs the NVD secret
  `SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY` (contract coherence — DC is live-validated with the
  key); digest-pin note updated. Guarded by `self-test v030-live`.

### Known limitations carried into rc.1 (documented, not blockers)
Strict opt-in/non-required; regulated opt-in; DAST/Nuclei manual/fail-closed; AI review non-gating;
DC CI evidence scans the committed surface (DC also locally validated on 9,289 deps); digest pinning
opt-in (dev tags / prod pinned); install/sync covers shipped profiles only; NVD key must be
consumer-provided and **rotated** (it was chat-exposed). **Final `v1.0.0` is NOT claimed.**

## [0.1.30] — Dependency-Check CI Cache Reliability

No new scanners; no gates weakened; no findings suppressed; no consumer remediation; no fake reports.
**Closes the final hard v1.0 CI blocker → `v1.0.0-rc.1` recommended next.**

### Fixed
- **Dependency-Check now completes in CI.** Root cause of the v0.1.29/30 H2 failure (`Unable to obtain
  an exclusive lock on the H2 database` / `No documents exist`, even on a fresh cache): the OWASP
  Dependency-Check container runs as a **non-root** user but the bind-mounted NVD data + report dirs
  are owned by the host UID, so the container could not create/lock the H2 database. The wrapper now
  `chmod a+rwX` the mounted data/report dirs before `docker run` (NVD data/reports are not secret; the
  key stays only in the propertyfile). Same UID class as the v0.1.29 propertyfile fix.
- **Stale H2/update lock cleanup.** The wrapper removes stale `*.lock` / `odc.update.lock` (never the
  NVD data) before running, so a run killed mid-update doesn't block the next.

### Added
- **Dependency-Check CI evidence** ([`docs/dependency-check-ci-evidence-v030.md`](docs/dependency-check-ci-evidence-v030.md)):
  run `27530386965` (zenchron-tools, success) — full NVD download (357,832 records), valid 67 KB
  `dependency-check.json`, collector `fail` 1 critical/1 high/0 medium; strict-EVIDENCE FAIL
  `[critical, high, medium]` (delta visible). **Cold + warm cache both proven** (conditional save →
  cache hit on rerun).
- **CI cache reliability** ([`docs/dependency-check-ci-cache.md`](docs/dependency-check-ci-cache.md)):
  fresh `nvd-v030-*` cache namespace (never restores the poisoned `nvd-Linux-*`), conditional save
  (only on a produced report → never poison), `reset_dependency_check_cache` dispatch input.
- Self-test `v030-live`: stale-lock cleanup (data preserved), cache-reset docs, propertyfile
  container-readable + deleted-after-run, key-off-argv, valid-JSON-preserved, no-fake-clean.

### Decided
- **`v1.0.0-rc.1` is RECOMMENDED next.** The RC bar set in v0.1.28 ("(7) strict delta visible AND DC
  completes in CI") is now fully met. **All 7 hard v1.0 blockers are closed.** Remaining items are
  soft/known-limitations (strict opt-in; DC CI committed-surface; digest opt-in; NVD key rotation),
  not engine defects. **Final `v1.0.0` is not yet claimed — `v1.0.0-rc.1` is.**

## [0.1.29] — Clean Strict CI Evidence

No new scanners; no gates weakened; no findings suppressed; no consumer remediation; no fake reports;
**no v1.0 RC claim**.

### Fixed
- **Dependency-Check NVD propertyfile is now container-readable.** The v0.1.26 leak-safe propertyfile
  used `0600`/`0700` owned by the host UID — unreadable by the Dependency-Check container's different
  UID on Linux Docker (`FileNotFoundException ... Permission denied`), which is exactly why DC failed
  at 14 s in the v0.1.28 CI run. Now world-readable in a traversable ephemeral mktemp dir (removed on
  exit). The key still never touches the command line, logs, report, or commits.

### Added
- **Clean strict-mode CI evidence** ([`docs/clean-strict-ci-evidence-v029.md`](docs/clean-strict-ci-evidence-v029.md)):
  live consumer run `27513388096` (zenchron-tools, success) with **3 attributable views** — baseline
  FAIL `[high]`; **strict-EVIDENCE FAIL `[high, medium]`** (pure mode default → strict delta visible);
  strict-CONSUMER FAIL `[high]` (medium skipped by the consumer's own override, shown transparently).
  Nothing suppressed. DC ran the full cold NVD download (perms fix) but then hit OWASP's **H2
  database-lock** (stale cache) → no fake-clean report; exact blocker documented, local DC evidence
  (v0.1.27) stands.
- Self-test `v029-live`: consumer override precedence, evidence-profile isolation (pure vs
  consumer-effective strict), DC container-readable propertyfile, DC no-fake-clean, key-never-logged,
  evidence-doc sections.

### Decided
- **v1.0 RC: NOT yet — next is `v0.1.30`.** Holds the v0.1.28 RC bar ("(7) strict delta visible AND DC
  completes in CI"): the delta-visible condition is now met cleanly; DC-in-CI is not (H2-lock). v0.1.30
  closes DC-in-CI with a clean cache seed, then `v1.0.0-rc.1`. Remaining items are operational/
  consumer-side, not engine defects. v1.0 NOT reached.

## [0.1.28] — Strict CI Evidence and Install/Sync Breadth

No new scanners; no gates weakened; no findings suppressed; no consumer remediation; no fake reports;
**no v1.0 claim**.

### Added
- **Live strict-mode CI evidence** on a consumer: real GitHub Actions run on `bogdaniel/zenchron-tools`
  (run `27512789768`, success) running the gate in baseline AND strict, artifacts uploaded
  (`if: always()`). baseline FAIL `[high]` / strict FAIL `[high]` on real OSV/Trivy findings (6 high,
  4 medium; SBOM present). Evidence-only, non-required, push-triggered off `main` (the consumer's
  `deploy.yml` triggers on push to `main`). [`docs/strict-ci-and-install-sync-evidence-v028.md`](docs/strict-ci-and-install-sync-evidence-v028.md).
- **Install/sync breadth**: 8 profiles round-tripped (laravel-react-docker, laravel, react, node,
  node-react, symfony, php-library, docker) — dry-run no-op, apply, accepted-risks never touched,
  full drift detect→resolve cycle, unmanaged files untouched.
- **Digest-pinning policy**: dev/onboarding = readable tags, production/hardened = digest-pinned
  overrides; hardened example `examples/hardened/sentinel-shield-hardened.snippet.yml`; digests
  re-verified (all MATCH).
- Self-test `v028-live`: strict-CI evidence doc fields, install/sync breadth matrix, accepted-risks &
  project-local not overwritten, hardened digest-pinned example, no production `:latest` recommendation,
  no `.claude/` tracked, no secret literal committed.

### Decided
- **v1.0 RC: NOT recommended.** Blockers (4) DC rich-consumer, (5) install/sync breadth, (6) digest
  policy are closed; (7) strict CI has a live run but with honest residuals (strict not green; delta
  masked by the consumer's explicit `medium_vulnerabilities:false`; DC didn't complete in CI). Next is
  **`v0.1.29`** (a clean strict CI run), then evaluate `v1.0.0-rc.1`. v1.0 NOT reached.

## [0.1.27] — Dependency-Check Consumer CVE Coverage and Strict CI Evidence

No new scanners; no gates weakened; no findings suppressed; no fake reports; **no v1.0 claim**.
No consumer findings remediated.

### Added
- **Dependency-Check on a dependency-rich consumer** (`zenchron-tools`, private; 218 Composer + 610
  npm → 9,289 analyzed deps): **7 vulnerable deps / 11 vulns**, collector → **6 high / 3 medium**
  (`fail`), 89 s warm cache. Closes the v0.1.26 thin-self-scan caveat — **non-zero CVE buckets now
  exercised**. Raw 7.3 MB artifact kept **local/gitignored** (consumer private, this repo public);
  aggregate counts only. [`docs/dependency-check-consumer-evidence-v027.md`](docs/dependency-check-consumer-evidence-v027.md).
- **Local consumer strict evidence**: real engine on the consumer summary — baseline FAIL (6 high),
  strict FAIL (6 high + 3 medium + missing_sbom); nothing suppressed. Live strict CI run still
  outstanding; **strict NOT production-ready**.
- Self-test `v027-live`: npm-vocab severity mapping, consumer-shaped strict/baseline, secret-not-committed,
  digest-override docs, evidence-doc sections.
- `tests/fixtures/dependency-check/npm-vocab.json` (synthetic, no consumer data).

### Fixed
- **Collector severity-mapping gap (surfaced by real consumer data):** Dependency-Check mixes NVD
  labels (`MEDIUM`) with npm Node-Audit/RetireJS labels (`moderate`); the collector dropped
  `MODERATE`, hiding **3 real moderate CVEs** from the strict `medium` gate. Now mapped
  `MODERATE → medium` in `scripts/collectors/dependency-check.sh` — **strengthens** the gate.

### Changed
- Digest pins for DC/Semgrep/Grype/Dockle **re-verified** (2026-06-15) — all MATCH prior records.
- `docs/v1-readiness.md`: blocker (4) **fully closed** (consumer non-zero CVE coverage); (7) advanced
  to **local consumer evidence**. **v1.0 RC NOT recommended** — next is `v0.1.28`. v1.0 NOT reached.

## [0.1.26] — Dependency-Check Live Validation and Strict Consumer Evidence

Closes the chief `v1.0` blocker's execution path. No new scanners; no gates weakened; no findings
suppressed; no fake reports; **no v1.0 claim**.

### Added
- **First real `dependency-check.json` artifact** — produced by a real OWASP Dependency-Check run
  authenticated with an NVD API key. Valid 4.2 KB native-schema JSON (5 deps, 0 vulns), collector
  parsed to `pass` 0/0/0, runtime 153 s, NVD full dataset downloaded with the key (no HTTP 429).
  Committed evidence: `tests/fixtures/live-evidence/dependency-check-real.json`. OWASP
  Dependency-Check promoted `experimental → live-validated` (execution path; thin self-scan caveat).
- **NVD API-key plumbing** in `scripts/audits/dependency-check.sh` via
  `SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY`, passed through a `0600 --propertyfile` (never on the
  command line, never logged, never in the report, never committed).
- **Strict-mode consumer evidence** ([`docs/strict-mode-consumer-evidence-v026.md`](docs/strict-mode-consumer-evidence-v026.md)):
  real engine baseline-PASS / strict-FAIL dry-run on a controlled fixture. Strict NOT marked
  production-ready.
- Self-test `v026-live` (+22 checks): real NVD-backed artifact parse, leak-safe key
  (off-argv / off-logs / propertyfile), preserve-on-nonzero, no-fake-clean on missing key, strict flip.

### Changed
- `.gitignore` now excludes local agent metadata (`.claude/`, `graphify-out/`) and scan caches
  (`.sentinel-shield/`).
- `docs/v1-readiness.md`, `docs/product-status.md`, `docs/main-gate-live-evidence.md`,
  `docs/roadmap.md`: Dependency-Check chief-blocker execution path marked CLOSED (with thin-surface
  caveat); strict blocker now PARTIAL (controlled-fixture dry-run). v1.0 still NOT reached.

## [0.1.25] — Live Evidence Closure Sprint

15-lane sprint prioritizing **real evidence over task count**. No new scanners; no gates weakened;
no findings suppressed; no fake reports; **no v1.0 claim**. This sprint ran **real scanners** (not
just fixtures) and produced **real artifacts**.

### Real evidence produced (this sprint actually ran scanners)
- **Checkov 3.3.0** ran via Docker against the Terraform fixture → **16 real `iac_violations`**;
  collector parsed the real artifact (`tests/fixtures/live-evidence/checkov-real.json`).
- **Grype 0.114.0** (digest-pinned) ran → **1 real medium**; collector parsed
  (`tests/fixtures/live-evidence/grype-real.json`).
- **Deptrac 4.6.1** ran via Docker+Composer against a layered fixture → **real `deptrac.json`**
  (violations→2, clean→0); collector parsed.
- **Strict-mode engine** ran for real: baseline PASS / strict FAIL on `medium_vulnerabilities`,
  `style_violations`, `iac_violations`.
- See [`live-evidence-v025.md`](docs/live-evidence-v025.md). These are **local tool-execution
  validations**, not consumer-CI promotions.

### Dependency-Check — real attempt, BLOCKED by external constraint (honest)
The real cold run **failed with NVD HTTP 429** (NVD now requires an API key; keyless bulk pulls are
refused). The wrapper behaved correctly: reported `unavailable`, wrote **no fake-clean report** — the
v0.1.24 anti-fake hardening **confirmed under a real failure**. **Attempted, NOT live-validated —
proven blocked by an external constraint** (evidence: `dependency-check-429-excerpt.log`).
Consumer-default-branch dispatch also remains blocked (v0.1.24). Nothing fabricated.

### Code fixes (real)
- **zap-full input gap CLOSED** — `scripts/collectors/zap.sh` now supports full reports
  (`--report-kind`/auto-detect `*zap-full*` → tool label `zap-full`); baseline behavior unchanged.
- **Code-enforced Nuclei template-path guard** — new `ss_nuclei_template_check` rejects
  missing/traversal/remote(unless opted-in)/absent template paths; `ss_dast_check` left unchanged so ZAP is unaffected.

### Added
- Real-artifact + new fixtures (dep-check medium/mixed, dast-v025, deptrac-v025, architecture-v025,
  regulated-v025); docs (zap-collector-fix, nuclei-guard, deptrac/architecture validation,
  regulated-dry-run, install-sync consumer-safety + managed-file-inventory, consumer-onboarding,
  multi-project-rollout, workflow-release-hardening, supply-chain-reproducibility-v025,
  dependency-check-evidence-checklist, v1-blocker-burndown-v025, live-evidence-v025).
- Self-test suite **`v025-live`** (26 checks: real artifacts, zap-full, nuclei guard, deptrac/arch,
  regulated, 3 new workflow rules). `self-test all` = **375 PASS**.

### Not validated (honest)
- Dependency-Check: NOT live-validated (NVD-429 external block). DAST/Nuclei manual/fail-closed.
  Deptrac/Checkov/Grype locally tool-validated, NOT consumer-CI promoted. v1.0 **NOT reached** (5/7 hard gates).

## [0.1.24] — Enterprise Production Closure Sprint

Fifteen-agent parallel sprint (14 worktree-isolated lanes A–N + release captain) merged via
`release/v024-integration`. No new scanners; no gates weakened; no findings suppressed; no fake
reports. **OWASP Dependency-Check remains attempted, NOT live-validated.** **v1.0 NOT reached.** No
consuming-project application code modified.

### Dependency-Check live-evidence attempt (real, honest)
A real attempt was made: an evidence-only workflow (SS v0.1.23 full-SHA pin, monthly NVD cache,
foreground, `if: always()` upload) was pushed to a **non-default branch** of consumer
`bogdaniel/zenchron-tools` (workflow-only, no app code, not merged to main). Dispatch was blocked
because GitHub only registers `workflow_dispatch` on the default branch — **no artifact produced,
nothing promoted, nothing fabricated** (see `docs/dependency-check-live-evidence-v024.md`).

### Added (14 lanes)
- Dep-check hardening fixtures (high/critical/empty/malformed) + `docs/dependency-check-hardening.md`.
- `docs/install-sync-productization.md` + `docs/install-sync-quickstart.md` (per-profile matrix, rollback, troubleshooting).
- `docs/profile-adoption-guide.md` + 8 `docs/examples/profiles/*.yaml` override examples; profile support matrix.
- `tests/fixtures/modes-v024/*` (multi/clean/dast/repo-health) + `docs/strict-regulated-execution.md`.
- `tests/fixtures/dast/{zap-baseline,zap-full,nuclei}.json` + `docs/dast-zap-readiness.md` + `docs/nuclei-readiness.md` + `templates/nuclei-target-allowlist.md`.
- `tests/fixtures/iac-v024/*` + `docs/iac-scanner-realism.md`; `tests/fixtures/{deptrac-v024,architecture-v024}/*` + `docs/architecture-deptrac-realism.md`.
- `docs/supply-chain-reproducibility-v024.md` (all 3 scanner digests re-verified live = MATCH; dep-check `latest` resolved but NOT pinned).
- `docs/workflow-hardening-v024.md` + `docs/workflow-template-adoption.md`; `if: always()` added to all 8 combined-template uploads.
- `docs/v1-closure-v024.md` (v1.0 NOT reached; thresholds + graduation ladder); `docs/maturity-audit-v024.md` (0 maturity contradictions; broken-link + cruft findings).
- **Complete 34-collector fixture library** `tests/fixtures/collectors-v024/*` + INDEX.
- Self-test suites **`v024-collectors`**, **`v024-coverage`**, **`v024-docs`**; `self-test all` PASS.

### Changed / fixed
- Removed stray `</content>`/`</invoke>` cruft from product-status/roadmap/v1-readiness; fixed 6 broken doc links (audit-driven).
- Captain docs: CHANGELOG, product-status, roadmap, product-readiness-checklist, v1-readiness (closure link).

### Not validated (honest)
- Dependency-Check: attempted, NOT live-validated (no artifact). DAST/Nuclei manual/fail-closed (never enabled; Nuclei template-path guard noted as future). IaC/Deptrac/architecture remain experimental/only-if-configured. No v1.0 claim.

## [0.1.23] — Enterprise Readiness Burn-Down Sprint

Ten-lane parallel sprint (9 worktree-isolated agent lanes + release captain) merged via
`release/v023-integration`. No new scanners; no gates weakened; no findings suppressed; no fake
reports. **OWASP Dependency-Check remains attempted, NOT live-validated** — a real consumer run was
attempted (gh auth + network confirmed) but the evidence workflow is not yet deployed on the
consumer and no `dependency-check.json` artifact exists. No v1.0 claim. No consuming-project
application code modified.

### Added
- **`docs/dependency-check-evidence-plan.md`** + fixtures `tests/fixtures/dependency-check/clean.json`
  and `warm-cache/.nvd-cache-marker` (clean-scan parse path; real-run attempt documented as negative).
- **`docs/install-sync-reliability.md`** — write-path audit, rollback, troubleshooting, release checklist.
- **Symfony install fixture** (`tests/fixtures/projects/symfony/`) + **`docs/profile-compatibility.md`**
  (compatibility table across all 8 profiles); symfony manifest tool-list fix.
- **`docs/gate-promotion-policy.md`** + mode fixtures (`tests/fixtures/modes/*`) with a 24-gate
  readiness matrix verified against `resolve-gates.sh`.
- **`docs/dast-pilot-readiness.md`** + updated `templates/dast-scan-approval.md` (controlled-pilot prep; DAST never enabled).
- **`docs/iac-architecture-readiness.md`** + IaC/deptrac/architecture fixtures (`tests/fixtures/{iac,deptrac,architecture}/*`).
- **`docs/supply-chain-reproducibility.md`** — digest verify/rollback, version-update process (all 3 digests re-verified live against Docker).
- **`docs/v1-readiness.md`** — v1.0 minimum capabilities (DONE/OUTSTANDING), non-goals, stable/experimental surfaces, migration/deprecation/graduation policy. v1.0 explicitly NOT reached.
- Self-test suites **`v023-coverage`** (dep-check clean, strict/regulated mode enforcement, IaC/deptrac/architecture mappings, DAST fail-closed incl. non-http rejection, no-`:latest` check) and **`v023-regression`** (all fail_on flags, secrets non-suppressible, invalid→exit2/missing→unavailable, manifest validity, README links, changelog presence, no `.claude` tracked); `install-matrix` extended to symfony. `self-test all` PASS.

### Changed
- Docs refreshed by the captain: CHANGELOG, product-status, roadmap, product-readiness-checklist.

### Not validated (honest)
- **Dependency-Check: still attempted, NOT live-validated** — real run attempted, blocked by
  workflow-not-deployed-on-consumer; nothing fabricated.
- DAST/Nuclei remain manual/fail-closed (pilot prepared, not enabled). IaC/Deptrac/architecture
  remain experimental/only-if-configured. No v1.0 readiness asserted.

## [0.1.22] — Acceleration Sprint: Adoption, Evidence, Hardening, Product Closure

Parallel multi-lane sprint (worktree-isolated branches merged via `release/v022-integration`). No
new scanners; no gates weakened; no findings suppressed; no fake reports; **OWASP Dependency-Check
remains attempted, NOT live-validated** (no real `dependency-check.json` artifact exists). No v1.0
claim. No zenchron-tools application code modified.

### Added
- **`templates/workflows/sentinel-shield-dependency-check.yml`** — dedicated dispatch-only EVIDENCE
  workflow (monthly NVD `actions/cache`, foreground, `timeout-minutes`, `if: always()` upload) to
  produce the first real `dependency-check.json` artifact.
- **`tests/fixtures/dependency-check/with-findings.json`** — findings fixture; self-test proves a
  non-zero-exit valid-JSON report parses (critical/high counts).
- **`profiles/symfony/profile.manifest.json`** + **`profiles/combinations/node-react.manifest.json`**;
  all 8 manifests enriched with `recommended_pr_fast_tools` / `recommended_main_gate_tools` /
  `recommended_scheduled_tools` + `recommended_raw_reports`. `profiles/docker` clarified as docker-only.
- **`docs/strict-mode-readiness.md`**, **`docs/regulated-mode-readiness.md`** — pre-flight checklists
  and honest "too-immature-to-gate-by-default" lists.
- **`docs/product-contract.md`** — pre-1.0 stability contract (stable vs experimental surfaces, raw
  report + profile-manifest compatibility promises, migration policy). README links core docs.
- **`docs/install-sync-guide.md`** — managed-file marker strategy, protected files, manual post-install steps.
- Self-test suites: **`install-matrix`** (docker/php-library/node-react round-trips), **`mode-readiness`**
  (strict gates fire; report-only/baseline don't inherit strict-only gates), **`v022-fixtures`**
  (IaC-no-binary, deptrac-absent, dependency-policy lockfiles, dep-check findings, grype SBOM-first,
  dockle image-required, summary-key coverage, raw-JSON validity). `self-test all` = 271 checks PASS.

### Changed
- **Workflow hardening:** `if: always()` on every consumer-template artifact upload (pr-fast, main,
  scheduled, dast, ai-review, combined); scanner-image digest-override env vars exposed across
  templates; `workflow-sanity` self-test extended to enforce if:always uploads, name==filename,
  digest-override presence, and the dependency-check evidence workflow shape.
- Docs refreshed: workflow-template-inventory, main-gate-live-evidence (v0.1.22 placeholder),
  dependency-check-nightly-strategy (cold vs warm run expectations), README, product-status, roadmap.

### Not validated (honest)
- **OWASP Dependency-Check: still attempted, NOT live-validated** — the evidence workflow is the
  *path* to the first artifact; until one exists it is not promoted and not faked.
- No new live consumer run in this release; Grype/Dockle stay live-validated and Semgrep
  consumer-verified on the v0.1.20 run. No v1.0 readiness asserted.

## [0.1.21] — Dependency-Check nightly & scanner digest pinning

Product hardening (no consumer remediation). No new scanners; no gates weakened; no findings
suppressed; no zenchron-tools application code touched. **OWASP Dependency-Check is NOT claimed
live-validated** — no real `dependency-check.json` artifact was produced this release.

### Added
- **`docs/dependency-check-nightly-strategy.md`** — why Dependency-Check is not PR-fast, why the cold
  NVD download fails CI budgets, `actions/cache` usage, monthly cache rotation, `workflow_dispatch`,
  artifact preservation on findings, honest-unavailable + no-fake-clean rules, promotion path.
- **`docs/scanner-image-digest-pinning.md`** — resolved digests (Docker, not invented; 2026-06-10)
  for Semgrep 1.165.0 / Grype v0.114.0 / Dockle v0.4.15, resolution/verify/update/rollback procedure.
- **`templates/raw/dependency-check.example.json`** — clean raw fixture for the contract.
- Scheduled template `dependency-check` job: monthly NVD `actions/cache` (key `nvd-<os>-YYYY-MM`,
  partial-reuse restore-keys), foreground execution, `timeout-minutes`, `if: always()` artifact upload.
- Self-tests (`main-gate-exec`): dep-check disabled→no-fake, enabled-missing-tool→unavailable, fake
  tool valid JSON→collector parses, valid-JSON-with-non-zero-exit→preserved, exit-without-JSON→no
  fake report; scheduled `actions/cache` + `if: always()`; digest-pinning doc image names; template
  digest-override env vars.

### Changed
- **`scripts/audits/dependency-check.sh`** hardened: foreground only (no detached container), optional
  `SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT` via `timeout`, keeps valid JSON even on non-zero exit,
  discards partial/empty/invalid output and reports `unavailable` (never fake-clean).
- Digest-override examples added to `sentinel-shield-{pr-fast,main,scheduled}.yml`
  (`SENTINEL_SHIELD_SEMGREP_IMAGE` / `_GRYPE_IMAGE` / `_DOCKLE_IMAGE`); templates keep readable tags.
- Docs refreshed: pinned-tool-references, workflow-template-inventory, profile-driven-adoption,
  raw-report-contract, main-gate-live-evidence, product-status, production-readiness-audit,
  enterprise-scanner-matrix, tooling/main-gate-tool-installation.

### Not validated (honest)
- **OWASP Dependency-Check: attempted, NOT live-validated** — no artifact. Next path: the cached
  nightly job. Dependency-Check is deliberately **not** digest-pinned (no validated image).
- Digest resolution is supply-chain hardening, **not** a new live-validation: Grype/Dockle stay
  live-validated and Semgrep consumer-verified on the v0.1.20 evidence run (27239206382); consumers
  must still pin by digest before production.

## [0.1.20] — main-gate live evidence run

Real-consumer evidence (bogdaniel/zenchron-tools, `sentinel-shield-main-gate-evidence`,
**run 27239206382**). No new scanners; no gates weakened; no findings suppressed; npm critical
NOT touched (consuming-project issue).

### Changed — promotions (with downloaded artifacts + verified collector mappings)
- **Semgrep 1.165.0: fixture-verified → CONSUMER-VERIFIED** — **0 PartialParsing errors on real
  `Modules/**/app`** (vs **118** on 1.90.0); 25 INFO→medium findings, visible for triage (not suppressed).
- **Grype → live-validated** — SBOM-first (`grype sbom:` off the Syft SBOM); `grype.json` valid,
  collector maps severities to `*_vulnerabilities` (0 matches this run).
- **Dockle → live-validated** — scanned a real built `base` image stage; `dockle.json` valid,
  collector → `container_image_violations`=1 (1 WARN + 3 INFO).

### Not promoted (honest)
- **OWASP Dependency-Check: attempted, NOT live-validated** — cold NVD download exceeds the CI
  budget and the detached scanner container ignored a step `timeout-minutes` (would burn the job +
  lose artifacts). Recommended on a **nightly** job with a warm NVD cache. NOT faked.
- Deptrac / Checkov/Conftest/Terrascan remain not-configured (no consumer config/IaC).

### Notes
No Sentinel Shield code bug surfaced — every v0.1.19 wrapper/collector behaved correctly on real
artifacts. Docs updated: main-gate-live-evidence, product-status, production-readiness-audit,
enterprise-scanner-matrix, pilot-consumers, tooling/main-gate-tool-installation,
remediation/semgrep-parser-errors. Scanner image tags used in the evidence run (anchore/grype
v0.114.0, goodwithtech/dockle v0.4.15, semgrep 1.165.0) — pin by digest before production.


## [0.1.19] — main-gate execution hardening

### Added
- **`scripts/verify-semgrep-image.sh`** + `tests/fixtures/semgrep/php-modern/` — verify the
  configured `SENTINEL_SHIELD_SEMGREP_IMAGE` parses modern PHP 8.1+ syntax. **`semgrep/semgrep:1.165.0`
  fixture-verified: 0 parser errors** (1.90.0 produced 118 on the pilot). Missing tool → unavailable
  (exit 0); parser errors → exit 1; clean → exit 0. **Fixture verification ≠ live consumer validation.**
- **`docs/main-gate-execution-hardening-v0.1.19.md`** + evidence-registry + tool-installation env-var
  tables.
- **Self-test `main-gate-exec`** (fake binaries, no network): grype sbom missing→unavailable / sbom+
  fake→report; dep-check disabled→unavailable, enabled-no-binary→unavailable; dockle no-image→
  unavailable, image+fake→report; semgrep-verify no-tool→unavailable / parser-error→exit 1 / clean→
  exit 0; main-gate tools JSON v1.1 fields.

### Changed
- **Grype** (`audits/grype.sh`): SBOM-first (default) / fs modes; local binary **or** container;
  `SENTINEL_SHIELD_GRYPE_MODE/IMAGE/SBOM_PATH`. Harness exports the Syft SBOM path so SBOM-first works.
- **OWASP Dependency-Check** (`audits/dependency-check.sh`): **disabled by default**; `enabled` mode;
  cache dir; container image; nightly-recommended. Documented slow + duplicates OSV/Trivy/Grype.
- **Dockle** (`audits/dockle.sh`): built-image-gated (`SENTINEL_SHIELD_IMAGE`), local or container
  (`SENTINEL_SHIELD_DOCKLE_IMAGE`, `_EXIT_CODE`); never builds/scans-arbitrary.
- **`run-main-gate-validation.sh`**: tools JSON **v1.1** — adds `duration_seconds`, `executor`,
  `valid_json` (additive; v1.0 consumers unaffected). main/scheduled templates wire the new env vars.
- All honest: missing binary/precondition → unavailable, no file, never fake-clean.

### Honest status
No new scanners. No gates weakened. No findings suppressed. **Grype/Dependency-Check/Dockle are
NOT live-validated** (no consumer artifact). Semgrep 1.165.0 is **fixture-verified, not
consumer-verified** — the 118 errors were on the consumer's real code, not the fixture.


## [0.1.18] — main-gate live-validation hardening

> v0.1.17 (already tagged) is the *branch-safe main-gate harness*. This release (v0.1.18) is the
> evidence-based **promotion + Semgrep strategy** pass that builds on it. Earlier tags unchanged.

### Added
- **`docs/main-gate-live-evidence.md`** — canonical live-validation evidence registry (tool,
  consumer, run ID, artifact, mapping, maturity, limitations, next target). Source of truth for
  promotions; other maturity docs defer to it.
- **`docs/remediation/semgrep-parser-errors.md`** — findings-vs-parser-errors triage, when to
  upgrade the Semgrep image, why NOT to `.semgrepignore` application code.
- **`docs/tooling/main-gate-tool-installation.md`** — how to run Grype / OWASP Dependency-Check /
  Dockle via action/container (main gate / nightly, never PR-fast), with honest-unavailable contract.
- **Self-test `main-gate-evidence`** (wired into `all`): Semgrep image variable present in
  templates; no `--config=auto` for app scan; main-gate template has no DAST/Nuclei/AI; evidence
  registry contains CodeQL/OSV/Trivy/Syft.

### Changed
- **Promoted with cited evidence (zenchron run 27214865086): CodeQL, OSV-Scanner, Trivy-fs, Syft
  SBOM → live-validated.** Updated product-status, production-readiness-audit, enterprise-scanner-matrix,
  pilot-consumers, raw-report-contract, roadmap. Grype/Dep-Check/Dockle/Deptrac/IaC stay
  experimental/not-configured (no evidence).
- **Documented baseline run 27214863297 FAIL as correct gate behavior** (real npm critical:
  shell-quote via concurrently). NOT suppressed/accepted/downgraded — consuming-project fix.
- **Semgrep image strategy**: default `semgrep/semgrep:1.90.0` → **`1.165.0`** (PHP parser fix),
  overridable via **`SENTINEL_SHIELD_SEMGREP_IMAGE`** across pr-fast/combined templates +
  ci-security/ci-pipeline; never `:latest` silently. Pin by digest before prod.
- Deptrac/IaC status clarified (not-validated-unless-configured; skip honestly).

### Honest status
No new scanners. No gates weakened. No findings suppressed. npm critical NOT fixed here (consumer's
job). Grype/Dependency-Check/Dockle NOT live-validated. Semgrep 1.165.0 default is documented but
**not live-tested in this pass** (no Docker/Semgrep locally).


## [0.1.17] — main-gate validation harness

Solves the dispatchability blocker that kept main-gate scanners `experimental`. **No new scanners.
No weakened gates. No faked reports. No live-validation claims without artifact evidence.**

### Added
- **`scripts/run-main-gate-validation.sh`** — branch-safe main-gate validation harness (POSIX sh).
  Runs the deterministic main-gate wrappers/audits (codeql-export, osv-scanner, trivy-fs, syft,
  grype, dependency-check, deptrac, architecture-tests, checkov, conftest, terrascan, dockle) from
  **any branch/PR** — no `workflow_dispatch`, no merge-first. Produces the same `reports/raw/*`
  contracts the summary builder consumes. `--target`, `--output-dir`, `--profile`, `--all`,
  repeatable `--tool`. Missing binary / unmet precondition → `unavailable`, **no file written**
  (never fake-clean); an unexpected wrapper crash → `fail` (exit 1). **No DAST/Nuclei/AI.**
- **`reports/raw/main-gate-validation-tools.json`** — per-tool `{status,reason,report}` descriptor
  (status ∈ `pass|fail|unavailable|skipped`), version 1.0.
- **`docs/main-gate-validation-strategy.md`** — the dispatchability analysis (why `workflow_dispatch`
  needs the workflow on the default branch first), Options A–E compared, and the recommended
  strategy (D for first validation, A for steady-state).
- **Self-test suite `main-gate-harness`** (wired into `all`): unknown-tool/no-selection → exit 2;
  DAST/AI tool names rejected; `--tool` selection vs `skipped`; `--all` → 12 tools; unavailable
  writes no fake report; fake-binary proves the `pass` branch; builder consumes harness output.

### Changed
- `templates/workflows/sentinel-shield-main.yml`, `docs/workflow-template-inventory.md`,
  `docs/profile-driven-adoption.md`: document validating main-gate scanners **branch-safely first**
  with the harness, then merge the workflow (never merge unvalidated).
- Docs updated for the harness + promotion path: product-status, product-readiness-checklist,
  roadmap (Phase 3 now in-progress), raw-report-contract, enterprise-scanner-matrix,
  production-readiness-audit, docs/README.

### Honest status (unchanged)
The harness makes branch-safe validation **possible**; it does **not** make any main-gate scanner
`live-validated`. No main-gate tool has a cited consumer run yet — promotion still requires a real
report + reviewed severity (roadmap Phase 3). Engine + PR-fast gate remain `proven`; main-gate
scanners remain `experimental`/`template-only`. DAST stays `manual`; AI stays `non-gating`.


## [0.1.16] — product completion & stabilization

A documentation + stabilization release. **No new scanners. No weakened gates. No new maturity
claims without cited evidence.** Goal: round Sentinel Shield up as a reusable product —
understandable, installable, maintainable, ready for repeated adoption.

### Added
- **Product docs:** `docs/product-status.md` (canonical maturity — single source of truth),
  `docs/product-boundaries.md` (product owns vs project owns + the upstream/keep-local rule),
  `docs/pilot-consumers.md` (zenchron-tools recentered as pilot **evidence**, not a product target;
  what it did and did not prove), `docs/roadmap.md` (maturity-phased, not tool-accumulation),
  `docs/product-readiness-checklist.md` (done/partial/not-started/blocked, evidence-gated).
- **Install/sync audit:** `docs/install-sync-status.md` — coverage for laravel-react-docker,
  node-react, docker-only, php-library; gaps + manual steps + safe next improvements.
- **Workflow inventory:** `docs/workflow-template-inventory.md` — all six templates with gate
  category, inputs/secrets, default-enabled, PR-safety, maturity, limitations, pinning.
- **Documentation index:** `docs/README.md` — categorized entry point for new teams.
- **`profiles/php-library/profile.manifest.json`** — framework-free PHP install profile (generic
  PHPStan, composer audit, PHPUnit adapter; no Larastan/Docker assumptions). Closes the
  "no php-library manifest" gap. Validated: valid JSON + clean dry-run on the php-library fixture.

### Changed
- **Maturity canonicalized:** `enterprise-scanner-matrix.md`, `production-readiness-audit.md`,
  `tooling/scanner-enablement.md`, and `README.md` now defer to `product-status.md` as the single
  maturity source (A–F → label mapping documented). No tool carries conflicting labels.
- **Release process** (`sentinel-shield-release-process.md`) made explicit: shell syntax, self-test
  all (incl. workflow-sanity, fixture install/sync, raw-report-contract), JSON/YAML validity,
  adapter syntax, changelog update, tag immutability. No unstable scanner run in the engine's gate.

### Honest status (unchanged)
Engine (resolver/enforcer/builder/install/sync/self-test) and the PR-fast gate remain `proven`
(zenchron run 27170148123). **Main-gate scanners remain `experimental`/`template-only` — not
live-validated; `sentinel-shield-main.yml` is still not dispatchable from a feature branch
(roadmap Phase 3).** DAST stays `manual`+fail-closed; AI review stays `non-gating`. Severity
parsing for OSV/CodeQL remains coarse. Sentinel Shield is **not** complete.


## [0.1.15] — live-validation hardening

### Changed
- **Semgrep default hardened**: the PR-fast workflow template now runs **curated
  `semgrep/app` rules** (honoring the project `.semgrepignore`), explicitly **never
  `--config=auto`**. Validated on zenchron-tools (run 27170148123): curated rules produced
  **0 critical / 0 high** and 118 scan errors vs `--config=auto`'s 7/16 + 341 errors.
- **Maturity promotions (evidence-based, cited)** in production-readiness-audit.md from the
  zenchron-tools pilot (run 27170148123): Pint/PHP-CS-Fixer (php-style → live-validated,
  style_violations=88), TypeScript --noEmit (live-validated, type_errors=0), dependency-policy
  lockfile detector (live-validated, dependency_policy_violations=0). Core PR-fast tools remain
  proven; baseline gate PASS with no regression on v0.1.14.
- pr-fast template also runs the dependency-policy audit by default.
- Docs updated: production-readiness-audit, tooling/scanner-enablement (curated Semgrep
  guidance), pinned-tool-references (validated action SHAs), README.

### Not promoted (honest)
Psalm/Deptrac/ESLint were `not-configured` on the pilot (runner correctly reported unavailable —
no fake). CodeQL/OSV/Trivy/Syft/Grype/Dependency-Check/IaC remain template/fixture-only
(main-validation not yet dispatchable). DAST/Nuclei/AI stay manual/non-gating. No new scanners;
no gates weakened.


## [0.1.14] — enterprise feature completion

### Added
- **dependency-policy emitter** (`scripts/audits/dependency-policy.sh` + collector) — first
  concrete `dependency_policy_violations` source: flags ecosystem manifests missing a lockfile
  (composer/npm/python/go/ruby/rust). License/version policy deferred (documented future).
- **9 runners**: psalm, php-style (Pint/PHP-CS-Fixer), eslint, typescript, actionlint, zizmor,
  deptrac, codeql-export (SARIF→raw), architecture-tests. **3 audits**: syft, trivy-fs,
  trivy-image. **1 collector**: architecture-tests. All honest: missing binary → unavailable,
  never fake-clean.
- Policy docs: iac-security-policy, static-analysis-policy, style-policy, architecture-policy;
  dependency-policy emitter section. Remediation: dependency-advisory-triage, iac-finding-triage,
  phpstan-psalm-triage, deptrac-architecture-triage. Templates: dependency-risk-review,
  iac-exception-request. Gap audit: `docs/feature-completion-v0.1.14.md`.
- Self-test `feature-completion` (dependency-policy detector, arch-tests collector, runner/audit
  presence, IaC clean-skip, missing→unavailable, invalid→exit 2). `architecture-tests` +
  `dependency-policy` wired into the summary TOOL_TABLE.

### Notes
This is a FEATURE-COMPLETION release, NOT hardening/live-validation. Scanner binaries are
external; most integrations remain supported/experimental (fixture-validated, not live). DAST
stays manual+allowlisted+fail-closed; AI review stays assistive+non-gating. No gates weakened.


## [0.1.13] — production readiness hardening

### Added
- **Production readiness audit** (`docs/production-readiness-audit.md`) — per-tool A–F status
  (proven-live / fixture-only / collector-only / template-only / documented-only / not-ready).
- **Fixture consumer projects** (`tests/fixtures/projects/{laravel-react-docker,node-react,docker-only,php-library}`)
  — minimal, offline.
- **Self-test suites** `fixtures` (detect-stack + install/sync round-trip + profile resolution +
  enforcement) and `workflow-sanity` (no pull_request_target trigger, permissions present, DAST
  allowlist required, AI review non-gating). Both BLOCKING in ci-self-test.yml.
- Docs: `workflow-template-validation.md`, `pinned-tool-references.md` (real upstream SHAs
  resolved 2026-06-09), `raw-report-contract.md`, `sentinel-shield-release-process.md`,
  `ci-runtime-budget.md`.
- Maturity labels (proven/supported/experimental/template-only/manual/non-gating) across README,
  enterprise-scanner-matrix, profile-driven-adoption.

### Changed
- `ci-self-test.yml`: actions **SHA-pinned** (checkout v4.2.2, upload-artifact v4.6.2) + new
  BLOCKING `full-self-test` job (sh -n all scripts, self-test all, workflow-sanity, fixtures).
- `scripts/self-test.sh`: +`fixtures`, +`workflow-sanity`; all suites wired into `all`.

### v0.1.12 correction (honesty)
v0.1.12 expanded scanner BREADTH but the integrations are **not equally mature**. The new
collectors are deterministic-fixture-validated, **not live-validated**; severity parsing for
OSV/CodeQL is coarse; DAST/Nuclei are manual+allowlisted; AI review is non-gating. Sentinel
Shield is production-ready as a **release-gate engine**, not as a turnkey "all scanners proven"
product. See production-readiness-audit.md.


## [0.1.12] — enterprise scanner expansion

### Added
- **Enterprise scanner matrix** (`docs/enterprise-scanner-matrix.md`) classifying every tool by
  gate category (PR fast / main / nightly / manual) with honest before/after status.
- **16 new collectors** (normalize tool output → summary keys; self-tested): codeql, php-syntax,
  php-style, osv-scanner, grype, dependency-check, scorecard, trufflehog, checkov, conftest,
  terrascan, dockle, zap, nuclei, ai-security-review, kuzushi.
- **8 new summary keys**: style_violations, php_syntax_errors, dependency_policy_violations,
  iac_violations, dast_findings, container_image_violations, repository_health_warnings,
  ai_review_findings (+ gate flags, mode defaults, enforcement).
- **DAST safety runners** (`scripts/runners/{dast-guard,zap-baseline,zap-full,nuclei}.sh`):
  no target → skip; host not allowlisted → **fail closed**; never scans arbitrary targets.
- **Audit wrappers** (`scripts/audits/*`) + `scripts/runners/php-syntax.sh` — run tool if present,
  else report unavailable (never fake clean).
- **Workflow templates**: sentinel-shield-{pr-fast,main,scheduled,dast,ai-review}.yml.
- **Report templates**: ai-security-review-report, kuzushi-investigation-report,
  dast-scan-approval, nuclei-target-allowlist, scheduled-scan-report, tool-exception-request.
- **Docs**: dast-policy, ai-review-policy, scheduled-scans, dependency-policy,
  tooling/scanner-enablement.
- **Self-test suite** `scanner-matrix` (collectors, resolver/enforcer gates by mode, DAST
  fail-closed, AI non-gating).

### Changed
- `resolve-gates.sh`: 8 new fail_on flags with conservative mode defaults (baseline blocks
  php_syntax + dependency_policy; strict adds style/iac/container; regulated adds
  dast/repo-health; **AI review never gating by default**).
- `enforce-gates.sh`: evaluates the new count gates (optional, null-safe; finding-scoped
  accepted-risk still ONLY for unsafe_docker; secrets never suppressible).
- `build-security-summary.sh`, schema, example, `ss_emit_collector`: carry the 8 new keys.
- profile manifest + `templates/profile.yaml`: new gates + manual workflow templates.

### Notes
- Collectors normalize/gate; scanner binaries run via workflow templates / audit wrappers
  (not bundled). DAST/Nuclei are manual + allowlisted; AI review is assistive + non-gating.
  Severity parsing (OSV/CodeQL) is best-effort. See enterprise-scanner-matrix.md.


## [0.1.11] — profile-driven adoption & sync

### Added

- **Profile manifests** (`profiles/<name>/profile.manifest.json`,
  `profiles/combinations/laravel-react-docker.manifest.json`) + schema
  (`profiles/profile.manifest.schema.json`). A manifest declares `files`/`workflows`/`docs`
  entries (`source`, `target`, `mode`), `never_touch`, `required_scripts`,
  `recommended_raw_reports`. File modes: `create-if-missing`, `overwrite-if-force`,
  `sync-managed-block` (reserved), `manual`.
- **Thin-consumer workflow template** `templates/workflows/sentinel-shield.yml` — uses the
  upstream runner/adapters/audits (`runners/laravel-phpstan.sh`,
  `adapters/{phpunit,vitest}-to-tests-json.*`, `run-hadolint.sh`,
  `audit-{github-actions-pins,docker-base-digest}.sh`, `build-security-summary.sh`,
  `enforce-gates.sh`); minimal permissions; uploads raw reports + downloads them in
  release-gate for finding-scoped accepted-risk matching; never fakes reports.
- `templates/.semgrepignore`, `docs/profile-driven-adoption.md`.
- Self-test `install-sync` suite (temp dirs, no network): dry-run writes nothing; `--apply`
  creates expected files + stamps profile mode; never creates/overwrites
  `accepted-risks.json`; `--force` overwrites managed files only (not project-owned);
  sync reports drift, updates managed files, preserves project-local; detect-stack
  identifies Laravel/React/Docker.

### Changed

- **`install-baseline.sh`** is now profile-manifest-driven: `--profile` (default
  `laravel-react-docker`), `--mode` (default `report-only`, stamped into `profile.yaml`),
  dry-run by default, `--apply`, `--force` (managed files only), `--target`. Installs
  profile.yaml + accepted-risks.example + workflow + .semgrepignore + security doc
  templates. **Never** creates/overwrites `accepted-risks.json` / `phpstan-baseline.neon`.
- **`sync-baseline.sh`** now updates a consumer from a newer release without destroying
  local decisions: `--dry-run` default, `--apply`, `--force` (managed only), `--target`,
  `--profile`. Reports created/updated/up-to-date/manual-review-needed/project-local-preserved.
  Never overwrites `accepted-risks.json`, `phpstan-baseline.neon`, project-owned files, or code.
- **Example** `examples/laravel-react-docker/` now represents installer output: workflow ==
  the managed template (upstream scripts), README explains generation + sync + the migration;
  removed the superseded local normalizers (`scripts/sentinel/*`).

### Notes

- Profiles cover **Laravel, React, Node, Docker** (and the combination) only — full
  multi-stack project onboarding is **not** solved yet. Project-local risk decisions stay
  local and are never overwritten.


## [0.1.10] — Larastan PHPStan runner robustness; multi-source unsafe_docker enforcement

### Changed

- **Laravel PHPStan runner** (`scripts/runners/laravel-phpstan.sh`) hardened for Larastan
  apps: captures stdout/stderr **separately**, **extracts/validates** the JSON object
  before writing `reports/raw/phpstan.json` (so deprecation/boot noise on stdout no longer
  forces `unavailable`), keeps debug artifacts (`phpstan.stdout.raw`, `phpstan.stderr.log`)
  on trouble, and exits 0 so artifact upload is not skipped. Still **never writes a fake
  clean report** — PHPStan missing or no valid JSON → report absent (`unavailable`). New
  env: `SENTINEL_SHIELD_LARAVEL_PACKAGE_DISCOVER`, `SENTINEL_SHIELD_LARAVEL_PREPARE`
  (plus the existing `…_MEMORY_LIMIT/_CONFIG/_PATHS/_BIN`).
- **Multi-source `unsafe_docker` finding-scope enforcement** (`scripts/enforce-gates.sh`):
  matching now normalizes **all** unsafe_docker raw sources into one shape and matches
  `rule_id` + `files` — `reports/raw/hadolint.json` (DL*) **and**
  `reports/raw/docker-base-digest.json` (`SS_DOCKER_BASE_DIGEST`). A `DL3018` accepted-risk
  no longer (silently) covers base-digest findings; each source needs its own record. A
  source whose raw report is missing while the summary accounts for it is treated as
  **unaccepted** (fail-closed). New flag `--docker-base-digest-raw`.
- The base-digest detector emits `rule_id: SS_DOCKER_BASE_DIGEST` (underscored).
- **Release-gate** in `ci-release-gate.yml`, `ci-pipeline.yml`, and the example workflow
  now downloads the raw reports (`sentinel-shield-raw-security*`, merge-multiple) so
  finding-scope matching has `hadolint.json` + `docker-base-digest.json`. The reusable
  docker job now also runs the base-digest audit.

### Added

- Self-test `phpstan-runner` (missing/clean/errors/stdout-noise/fatal — never fakes) and
  `ud-multisource` (hadolint+base-digest matching; DL3018 never suppresses base-digest;
  unaccounted source fails closed). Schema/template/docs document the two unsafe_docker
  sources and an `SS_DOCKER_BASE_DIGEST` finding-scoped example.

### Notes

- The runner improvements are **not yet verified against zenchron-tools** (no real
  Larastan app in this repo) — tested via fake php/phpstan fixtures only.


## [0.1.9] — consolidation: promote pilot lessons upstream

Reusable pieces discovered during the `zenchron-tools` pilot are now owned by Sentinel
Shield so consuming projects stop duplicating scanner/tooling logic. See
[`docs/consolidation-v0.1.9.md`](docs/consolidation-v0.1.9.md) for the full classification.

### Added

- **Test adapters** → canonical `reports/raw/tests.json` (`{failures, errors}`), fail
  clearly on missing/invalid input (never fake success):
  `scripts/adapters/phpunit-to-tests-json.php` (JUnit XML),
  `scripts/adapters/vitest-to-tests-json.mjs`, `scripts/adapters/jest-to-tests-json.mjs`.
- **Laravel PHPStan runner** `scripts/runners/laravel-phpstan.sh` — handles the Laravel CI
  pitfalls (APP_ENV/APP_KEY, writable dirs, `package:discover`, memory limit), always
  writes the raw report on non-zero exit, and marks the tool **unavailable** (not a fake
  clean report) when PHPStan is absent. Env: `SENTINEL_SHIELD_PHPSTAN_{MEMORY_LIMIT,CONFIG,PATHS,BIN}`.
- **GitHub Actions pin audit** `scripts/audit-github-actions-pins.sh` +
  collector `scripts/collectors/github-actions-pins.sh` → `unsafe_github_actions`. Flags
  tag/branch/no-ref `uses:` and un-digested `container:`/`image:`/`docker://`; allows full
  40-char SHAs, `@sha256:` digests, and local (`./`) actions. Complementary to
  actionlint/zizmor (the builder SUMS the gate).
- **Docker base-image digest detector** `scripts/audit-docker-base-digest.sh` +
  collector `scripts/collectors/docker-base-digest.sh` → `unsafe_docker`. Flags
  `FROM image:tag` (and implicit `:latest`); allows `@sha256:` and multi-stage aliases.
  Distinct from Hadolint DL3018/DL3008 (package pinning).
- **Remediation guides** under `docs/remediation/`: react-dangerously-set-inner-html,
  phpstan-baseline-strategy, docker-dl3018-decision-tree, browser-stack-isolation,
  third-party-install-script-review, github-actions-sha-pinning, docker-base-digest-pinning.
- **Governance templates**: `templates/security-debt-register.md`,
  `sentinel-shield-rollout-status.md`, `security-triage-report.md`,
  `third-party-install-script-review.md`, `pinned-ci-references.md` (generic, not
  project-specific).
- Self-test `adapters` subcommand (in `all`): adapter parsing + fail-closed, runner
  unavailable-not-fake, pin audit flag/pass, base-digest flag/pass, template existence.

### Notes

- Promoting these capabilities does **not** move a project's debt or accepted-risk
  decisions upstream — those stay in the consuming project (`profile.yaml`,
  `accepted-risks.json`, baselines, code fixes). Class **D** in the consolidation doc.
- The PHP adapter is validated by `php -l` + fixture parse (run via local PHP or Docker);
  CI/self-test skip it cleanly when PHP is absent.

## [0.1.8] — finding-scoped accepted-risk suppression

### Added

- **Finding-scoped accepted-risk suppression.** Accepted-risk records are now
  FINDING-SCOPED by default: a record suppresses only the findings it matches, not the
  whole gate. Implemented for `unsafe_docker` (matched against `reports/raw/hadolint.json`
  by `rule_id` + `files`). New record fields: `scope` (`finding`|`gate`, default
  `finding`), `rule_id`, `rule_ids`, `files`; `components`/`fingerprints` are reserved
  (declared in the schema, not yet enforced).
- `enforce-gates.sh --hadolint-raw <path>` (default `<summary-dir>/raw/hadolint.json`)
  for unsafe_docker finding matching.
- Enforcement reports (`sentinel-shield-enforcement.json`/`.md`) now show: accepted-risks
  loaded; applied **broad** (`scope:gate`) vs **finding-scoped**; pending/expired/invalid/
  legacy-unscoped ignored; and a per-finding `unsafe_docker` table (rule_id, file, line,
  accepted, matched risk id) with total/accepted/unaccepted. Unaccepted findings are not
  hidden — they fail the gate.
- Self-test `finding-scope` subcommand (9 cases): per-file/per-rule matching, mixed
  accepted/unaccepted, legacy-unscoped (no suppress), `scope:gate` (broad), pending/
  expired (no suppress), and secrets-never-suppressed.

### Changed

- **Prevents one `unsafe_docker` accepted-risk from suppressing unrelated Docker
  findings** (the v0.1.7 multi-Dockerfile-discovery governance bug): a DL3018 record for
  `Dockerfile`/`Dockerfile.prod` no longer hides DL3008/DL3016/DL4006 in other Dockerfiles.
- **Backward compatibility / migration:** a record with no `scope` and no
  `rule_id`/`files` is ambiguous and **no longer suppresses** (it warns). Broad gate-wide
  suppression now requires explicit `"scope": "gate"` and is reported as broad and
  discouraged. Raw counts are still never reduced; `secrets`/`expired_exceptions`/
  `missing_release_evidence` are still never suppressible.

### Notes

- Finding-scoped suppression is implemented for **`unsafe_docker` only** in v0.1.8. Other
  suppressible gates (`medium_vulnerabilities`) support only broad `scope:gate`
  suppression; finding-scope records targeting them warn and do not suppress.
- If the raw Hadolint report is missing, finding-scope records cannot match and the
  `unsafe_docker` gate fails on any count > 0 (declare `scope:gate` for broad).

## [0.1.7] — global multi-Dockerfile Hadolint discovery

### Added

- `scripts/run-hadolint.sh` (POSIX sh): discovers all Dockerfile-like files
  (`Dockerfile`, `Dockerfile.*`, `docker/**/Dockerfile[.*]`, `.docker/**/Dockerfile[.*]`),
  runs Hadolint on each (local binary or `hadolint/hadolint` Docker image), and **merges
  the JSON arrays into one `reports/raw/hadolint.json`** (per-finding `.file` path
  preserved) that the existing `hadolint` collector parses unchanged. Prunes generated/
  cache dirs (`node_modules`, `vendor`, `dist`, `build`, `coverage`, `.git`). `--list`
  mode prints discovered files. Skips cleanly (writes nothing, exit 0) when no
  Dockerfiles exist → collector marks hadolint `unavailable`. Never fakes an empty `[]`
  on unexpected Hadolint failure (exit 1, no file written).

### Changed

- `ci-docker.yml`, `ci-pipeline.yml`, and the Laravel+React+Docker example workflow now
  call `run-hadolint.sh` instead of the single-`Dockerfile` `hadolint-action`. The
  example's docker-security job checks out Sentinel Shield to use the script.
- **Removes the need for project-local Hadolint multi-file workarounds** — multi-file
  discovery is now a global Sentinel Shield behavior. Project-specific accepted-risk
  decisions stay in the consuming project (not moved into Sentinel Shield).
- `unsafe_docker` normalization is unchanged (collector still counts error+warning).
- Self-test `hadolint` subcommand (in `all`): discovery includes Dockerfile +
  Dockerfile.prod + `docker/**`, excludes vendor/node_modules, handles "no Dockerfiles",
  merged JSON stays valid, and the collector still maps `unsafe_docker`.

### Notes

- DL3018 is **not** hidden — findings from every discovered Dockerfile flow into
  `unsafe_docker` (more files scanned can raise the count). Accepted-risk governance is
  unchanged and remains the consuming project's responsibility.

## [0.1.6] — separate app vs third-party rule trees; high-confidence supply-chain rules

### Changed (rule layout — see migration note)

- **Physically separated Semgrep rule trees.** Application rules moved to
  `semgrep/app/{php,javascript,docker}`; supply-chain rules to
  `semgrep/supply-chain/third-party/`. Broad/noisy heuristics moved to a **sibling**
  `semgrep/supply-chain/third-party-experimental/` (opt-in; NOT loaded by the default
  third-party config). The old `semgrep/{php,javascript,docker,third-party}` paths are
  gone.
- **App scans can no longer load third-party rules.** All workflows
  (`ci-security.yml`, `ci-pipeline.yml`, example, `run-local-security.sh`) config the
  app scan from `semgrep/app` (never the bare `semgrep/` catch-all) and the
  third-party scan from `semgrep/supply-chain/third-party`.

### Changed (third-party JS rules)

- **Tightened to high-confidence by default.** Default third-party set = npm
  install-script risk (`js-install-scripts.yml`, with a higher-severity variant for
  `curl`/`wget`/`bash`/`node -e`/`child_process`/URL), decode→eval + remote-fetch→eval
  (`js-high-confidence.yml`), and PHP decode→eval / `preg_replace /e`
  (`php-suspicious.yml`). The broad rules that flooded `node_modules` with false
  positives (`ss-tp-js-dynamic-require`, generic `eval`/`new Function`,
  `child_process`, generic outbound, `.env` read, long-base64) are now **experimental
  / opt-in**.

### Changed (third-party target discovery)

- Workflows mount each dependency dir under a **neutral name** (`/scan/depN`) so
  Semgrep's built-in `node_modules`/`vendor` ignore + git-only discovery no longer skip
  them, and exclude `*.min.js`/`dist`/`build`/`coverage`. Still skips cleanly when no
  dependency dirs exist.

### Fixed

- Three pre-existing Semgrep rules that never compiled now parse and run:
  `ss-react-dangerously-set-inner-html`, `ss-react-unsanitized-html-render` (JSX
  bare-attribute patterns), and `ss-symfony-missing-csrf-note` (attribute+method
  pattern → regex).

### Notes

- Summary keys and the collector (`third-party-semgrep.sh`, maps by
  `metadata.sentinel_shield_category`) are unchanged — `security-summary.json` stays
  backward compatible.
- **Migration:** consuming projects that copied a workflow must repoint app scans to
  `…/semgrep/app` and third-party scans to `…/semgrep/supply-chain/third-party`.

## [0.1.5] — third-party supply-chain suspicious-code scan

### Added

- **Separate third-party suspicious-code scan channel.** A dedicated Semgrep run over
  dependency/vendored code (`vendor/`, `node_modules/`, `public/vendor/`,
  `public/js/filament/`) using **only** `semgrep/third-party/*.yml` — distinct from
  the application SAST scan, written to a **separate** artifact
  (`reports/raw/third-party-semgrep.json`).
- New summary keys: `third_party_suspicious_code`, `third_party_install_script_risk`,
  `third_party_obfuscation`, `third_party_network_behavior` (schema + example +
  builder seed). New gate flags + resolver defaults (report-only/baseline: all false;
  strict: install_script_risk + network_behavior true; regulated: all true).
- New files: `semgrep/third-party/{suspicious-code,php-suspicious,js-suspicious}.yml`,
  `scripts/collectors/third-party-semgrep.sh`,
  `templates/raw/third-party-semgrep.example.json`,
  `docs/third-party-supply-chain-scan.md`. Profile gains a `supply_chain.third_party_sast`
  block (modes: disabled | report-only | scheduled | strict | regulated).
- Workflow steps (ci-security, ci-pipeline, example) run the third-party scan from
  `-w /tmp` with explicit dependency-dir targets (so the app `.semgrepignore` does
  not exclude them); they skip cleanly when no dependency dirs exist.
- Self-test `third-party` subcommand: missing raw → unavailable/0; fixture → category
  counts; report-only non-blocking; regulated blocks all four.

### Scope (explicit)

- This is **behavioral** supply-chain triage, **not** a replacement for Trivy /
  composer audit / npm audit (dependency CVEs), Syft (SBOM), or Gitleaks (secrets) —
  those remain the source of truth and are unchanged.
- Application SAST still excludes `vendor/`/`node_modules/` (v0.1.4 `.semgrepignore`);
  third-party findings stay in their own keys/artifact and never mix into app
  `*_vulnerabilities`. Non-blocking by default in v1; secrets are never suppressible.

## [0.1.4] — default Semgrep/SAST scoping for Laravel/React

### Added

- Default **Semgrep/SAST path exclusions** via project-local `.semgrepignore`
  templates: `profiles/laravel/.semgrepignore`, `profiles/react/.semgrepignore`, and
  `examples/laravel-react-docker/.semgrepignore`. They exclude vendored/generated/
  cache paths (`vendor/`, `node_modules/`, `storage/`, `bootstrap/cache/`,
  `public/js/filament/`, `public/vendor/`, `public/build/`, `dist/`, `build/`,
  `coverage/`, …) while keeping application source scanned.
- `docs/semgrep-scoping.md` explaining the scope and the scanner-specific behavior.
- Self-test check that the `.semgrepignore` templates exist and carry the key
  exclusions (incl. `public/js/filament/` in the example).

### Changed

- Semgrep workflow steps run with `-w /src` so a project-local `.semgrepignore` (at
  the repo root) is honored: `ci-security.yml`, `ci-pipeline.yml`, and the
  Laravel+React+Docker example workflow.
- Fixed a Semgrepignore-v2 anchoring deprecation in the JS rule excludes
  (`*/__tests__/*` → `**/__tests__/*`, `*/tests/*` → `**/tests/*`).

### Scope (explicit)

- These exclusions apply to **Semgrep / SAST only**. `composer audit`, `npm audit`,
  Trivy, Syft (SBOM), Gitleaks, and Hadolint are **not** narrowed — dependency
  scanning, SBOM, and secret scanning remain broad.

## [0.1.3] — Semgrep image fix, rule-noise tuning, accepted-risk suppression

### Fixed

- **Invalid Semgrep image reference.** `semgrep/semgrep:1` does not exist
  (`manifest unknown`), so Semgrep never ran (`unavailable`). Changed to
  `semgrep/semgrep:latest` in `ci-security.yml`, `ci-pipeline.yml`, and the
  Laravel+React+Docker example workflow (pin to a digest before production).

### Changed

- **Semgrep starter-rule scoping** to cut false positives on real projects:
  - `ss-laravel-app-debug-true` now excludes `*.example`/`.env.testing`/`.env.local`/
    `.env.ci` (APP_DEBUG=true is normal in non-production env templates).
  - `ss-php-insecure-random` → WARNING (was ERROR) and excludes
    `tests/`/`database/factories/`/`database/seeders/`/`fixtures/`/`examples/`.
  - `ss-js-insecure-random-security` → INFO (was WARNING) and excludes test/story
    paths (UI `Math.random()` is benign).
  - `ss-php-hardcoded-credentials` excludes test/factory/fixture paths (Gitleaks
    remains the authoritative secret scanner).
  - React XSS heuristics (`ss-react-dangerously-set-inner-html`,
    `ss-react-unsafe-dom-write`, `ss-react-javascript-url`) → WARNING (high), not
    ERROR (critical).
  - `ss-laravel-missing-authorization-review` moved out of the default set into
    opt-in `semgrep/php/laravel-review-prompts.yml` at INFO (it is a review prompt,
    not a confirmed bug).

### Added

- **Accepted-risk suppression** in `scripts/enforce-gates.sh` (`--accepted-risks`,
  default `.sentinel-shield/accepted-risks.json`). An APPROVED, unexpired,
  owner-bound record may mark a **suppressible** gate (`unsafe_docker`,
  `medium_vulnerabilities`) as `accepted-risk` — raw count preserved (not zeroed),
  reported, does not fail. `pending`/expired/invalid never suppress; `secrets`,
  `expired_exceptions`, `missing_release_evidence` are never suppressible.
- `schemas/accepted-risks.schema.json`, `templates/accepted-risks.example.json`,
  `docs/accepted-risk-suppression.md`, and the example
  `.sentinel-shield/accepted-risks.example.json`.
- Self-test `suppression` subcommand (in `all`): approved→pass(accepted-risk),
  pending/expired/missing→fail, secrets+approved→still fail.

## [0.1.2] — trivy-action transitive-pin fix

### Fixed

- **`aquasecurity/trivy-action` bumped to `v0.36.0`.** `v0.30.0` resolved as a tag
  but transitively pinned `aquasecurity/setup-trivy@v0.2.2`, a tag that no longer
  exists, so job setup still failed with "Unable to resolve action
  …setup-trivy@v0.2.2". `v0.36.0` pins `setup-trivy` by commit SHA, so it always
  resolves. Applied across `ci-security.yml`, `ci-pipeline.yml`, `ci-docker.yml`,
  and the example workflow. (Supersedes the partial `v0.1.1` trivy fix.)

## [0.1.1] — workflow fixes from first GitHub-runner validation

### Fixed

- **`aquasecurity/trivy-action` version pin** corrected from the non-existent
  `0.30.0` to `v0.30.0` (the action's tags are `v`-prefixed); later found
  insufficient (see 0.1.2). Affected
  `ci-security.yml`, `ci-pipeline.yml`, `ci-docker.yml`, and the Laravel+React+Docker
  example workflow. The bad pin failed job setup with
  "Unable to resolve action …@0.30.0".
- **`actions/setup-node` cache** (`cache: npm`) removed from the fixture-capable
  workflows (`ci-pipeline.yml`, example `sentinel-shield.yml`) because it fails when
  no lockfile is present (minimal/report-only repos without `package.json`).
  `ci-node.yml` (a Node-project-only workflow) keeps the cache.

Both were found by the first real GitHub Actions fixture run; the Sentinel Shield
scripts (resolver/builder/enforcer) were unaffected.

## [0.1.0]

### Added

- **Baseline & governance.** Top-level standards (`README.md`,
  `SECURITY-STANDARD.md`, `RELEASE-GATES.md`) and the `docs/` governance set:
  adoption guide, severity policy, exception policy, secure-coding standard,
  Docker and GitHub Actions security, dependency policy, architecture
  boundaries, and the project-readiness checklist. Defines the four adoption
  modes (`report-only`, `baseline`, `strict`, `regulated`) and the security
  doctrine.
- **Per-stack profiles.** Laravel and Symfony (PHPStan/Larastan, Psalm + taint,
  Pint/PHP-CS-Fixer, Deptrac, Rector), Node and React (ESLint flat configs,
  strict `tsconfig`, Knip, audit-ci, Vite security guide), and Docker (hardened
  Dockerfile/Compose references, Hadolint, Trivy).
- **Reusable CI workflows.** PHP, Node, Docker, security (SAST/secrets/deps/SBOM),
  CodeQL, ZAP (staging-only), and the release-gate aggregator, plus Dependabot
  and CodeQL config. Minimal permissions and `master`-branch examples.
- **Semgrep rules** for generic PHP, Laravel, Symfony, generic JS, Node, React,
  and Docker.
- **OPA/Rego policies** for Docker/Compose, GitHub Actions, Terraform, and
  production env config, plus the accepted-risk exception template.
- **Templates.** Pull request, security review, STRIDE-lite threat model,
  one-page ADR, and production-readiness report.
- **Local automation scripts** (POSIX `sh`): stack detection, PHP/Node quality
  runners, local security sweep, report generator, safe `install-baseline`
  (dry-run by default), and a non-destructive `sync-baseline` stub.
- **Gate resolver** (`scripts/resolve-gates.sh`): reads
  `.sentinel-shield/profile.yaml` and resolves the adoption mode into
  machine-readable `SENTINEL_SHIELD_FAIL_ON_*` flags
  (`sentinel-shield-gates.{env,json,md}`). Prefers `yq` v4, with a
  canonical-format awk/sed fallback. Shared shell library in
  `scripts/lib/sentinel-shield-common.sh`; canonical `templates/profile.yaml`;
  documented in `docs/gate-resolution.md`.
- **Gate enforcer** (`scripts/enforce-gates.sh`): consumes the resolved flags
  plus a normalized `reports/security-summary.json` and decides pass/fail
  (exit `0`/`1`/`2`). The gates `.env` is validated line-by-line and never
  blind-sourced; JSON is parsed only with `jq`; a missing required summary key
  is an error, never a silent zero. Ships the `security-summary.json` contract:
  JSON Schema (`schemas/security-summary.schema.json`), canonical example, and
  `docs/security-summary-schema.md`.
- **Repository hygiene.** `CHANGELOG.md`, `LICENSE`, `CONTRIBUTING.md`, and a
  `Makefile` wrapper over the scripts.

### Security

- Audit-hardened the baseline: fixed malformed XML (double-hyphen in comments),
  removed fabricated/invalid GitHub Action SHA pins (converted to version tags
  with a pin-to-SHA note), fixed `set -e` foot-guns in shell, corrected a Node
  quality-runner binary bug, and made report generation portable.
- Enforcer rejects suspicious `.env` lines (command substitution, backticks,
  shell metacharacters) instead of sourcing them.

### Notes

- Sentinel Shield does **not** yet ship per-scanner adapters that emit
  `security-summary.json`; producing it is currently the consuming project's
  responsibility. The enforcement layer defines and enforces the target contract.
- GitHub Action references use version tags for readability; pin them to commit
  SHAs in sensitive workflows before production use
  (`docs/github-actions-security.md`).

[Unreleased]: https://example.com/sentinel-shield/compare/HEAD
