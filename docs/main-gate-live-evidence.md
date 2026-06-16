# Main-Gate Live Evidence Registry

Canonical record of main-gate scanner integrations validated against a **real consumer** with
**downloaded artifact evidence**. A tool is promoted only when a real `reports/raw/*` artifact
exists, is valid, and its collector parsed it. No entry here is added from fixtures alone.

| Tool | Consumer | Workflow / Run ID | Artifact (size, validity) | Summary mapping | Promoted maturity | Known limitations | Next validation target |
|---|---|---|---|---|---|---|---|
| CodeQL (js/ts) | bogdaniel/zenchron-tools | sentinel-shield-main-validation / **27214865086** | `reports/raw/codeql.json` (669 KB SARIF, valid) | 0 critical / 0 high / **11 medium** (SARIF `level→severity`) | **live-validated** | severity from SARIF `level`, not CVSS (coarse); JS/TS only (no PHP CodeQL in this run) | add PHP/`php` language; triage the 11 medium |
| OSV-Scanner | bogdaniel/zenchron-tools | sentinel-shield-main-validation / **27214865086** | `reports/raw/osv-scanner.json` (7.5 KB, valid) | **1 high** | **live-validated** | severity coarse (all→high unless normalized) | refine severity mapping; triage the 1 high |
| Trivy (filesystem) | bogdaniel/zenchron-tools | sentinel-shield-main-validation / **27214865086** | `reports/raw/trivy.json` (308 KB, valid) | 0/0/0 (clean) | **live-validated** | fs-mode only; image-mode still unproven | run a Trivy image scan with a built image |
| Syft (SBOM) | bogdaniel/zenchron-tools | sentinel-shield-main-validation / **27214865086** | `reports/sbom.spdx.json` (964 KB SPDX, valid) | evidence: `missing_sbom=false` | **live-validated** | presence/validity only (not a vuln gate) | feed SBOM to Grype (SBOM-scan mode) |
| Grype | — | — | — | critical/high/medium_vulnerabilities | **NOT promoted** (experimental) | binary absent on runner; wrapper reported `unavailable` (no fake) | install via action/container; see main-gate-tool-installation.md |
| OWASP Dependency-Check | — | — | — | critical/high/medium_vulnerabilities | **NOT promoted** (experimental) | binary absent; slow | container-backed run on a consumer |
| Dockle | — | — | — | container_image_violations | **NOT promoted** (experimental) | needs a built image | run after an image build |
| Deptrac | — | — | — | architecture_violations | **NOT promoted** (not-configured) | no `deptrac.yaml` in the pilot | validate on a project with defined layers |
| Checkov / Conftest / Terrascan | — | — | — | iac_violations | **NOT promoted** (not-applicable) | no IaC files in the pilot | validate on a repo with `*.tf`/k8s |
| ZAP / Nuclei / Claude Code / Kuzushi | — | — | — | dast_findings / ai_review_findings | **NOT promoted** (manual / non-gating) | not enabled (target allowlist + approval / non-deterministic) | dedicated approval-gated pass |

## Baseline evidence (release gate working)
| Consumer | Workflow / Run ID | Result | Interpretation |
|---|---|---|---|
| bogdaniel/zenchron-tools | sentinel-shield (baseline) / **27214863297** | **FAIL** on `critical_vulnerabilities=2` (npm: `shell-quote` via `concurrently@9.2.1`) | **Correct gate behavior** — a real npm critical blocked the gate. Consuming-project dependency fix (separate PR). NOT a Sentinel Shield bug; NOT suppressed; NOT accepted-risk. |

This registry is the source of truth for "what is live-validated." `product-status.md`,
`production-readiness-audit.md`, and `enterprise-scanner-matrix.md` defer to it.

## Semgrep image verification (v0.1.19 — FIXTURE, not live)
| Image | Method | Fixture | Parser errors | Findings | Status |
|---|---|---|---|---|---|
| **semgrep/semgrep:1.165.0** (output `.version`=1.165.0, via Docker) | `scripts/verify-semgrep-image.sh` | `tests/fixtures/semgrep/php-modern` (readonly/enum/attributes/match/promotion/typed) | **0** (`errors: []`) | 0 (15 rules) | **fixture-verified** |

This is a **fixture** result — it proves 1.165.0 parses modern PHP syntax that 1.90.0 failed on
(118 errors on the pilot). It is **NOT** a live consumer validation: re-run on zenchron-tools'
real `Modules/**/app` to confirm the 118 errors actually drop, then cite that run here. The
prior 1.90.0 evidence (118 parser errors) stands as the contrast.

## v0.1.20 — main-gate execution-path live evidence (zenchron run 27239206382)
Consumer **bogdaniel/zenchron-tools**, workflow `sentinel-shield-main-gate-evidence`, **run 27239206382** (success). All artifacts downloaded + collectors verified.

| Tool | Artifact (valid) | Collector → summary key | Promotion | Limitations |
|---|---|---|---|---|
| **Semgrep 1.165.0** (real app code) | `semgrep.json` 108 KB, `.version`=1.165.0 | semgrep.sh → 0 crit / 0 high / **25 medium** | **fixture-verified → CONSUMER-VERIFIED**: **0 parser errors** on real `Modules/**/app` (vs **118** on 1.90.0). 25 INFO findings → medium, **visible for triage (not suppressed)**. | curated SS rules only; medium findings need project triage |
| **Grype (SBOM-first)** | `grype.json` 5.3 KB, valid | grype.sh → 0/0/0 (0 matches) | **supported/experimental → LIVE-VALIDATED**: ran `grype sbom:` off the Syft SBOM (969 KB), collector parses severities to `*_vulnerabilities` | 0 matches this run (SBOM scope); container executor (anchore/grype:v0.114.0, tag — pin by digest) |
| **Dockle** (built `base` image stage) | `dockle.json` 955 B, valid | dockle.sh → `container_image_violations`=1 | **supported/experimental → LIVE-VALIDATED**: scanned a real built image stage; 4 details (1 WARN + 3 INFO) → 1 violation | scanned the `base` stage only (fast), not the full prod image; goodwithtech/dockle:v0.4.15 (tag — pin by digest) |
| **OWASP Dependency-Check** | — (no artifact) | — | **ATTEMPTED, NOT live-validated** | cold NVD download exceeds CI budget; the detached container ignored a step timeout. Run on a dedicated **nightly** job with a warm cache (see [`tooling/main-gate-tool-installation.md`](tooling/main-gate-tool-installation.md)). NOT faked, NOT promoted. |

**Headline:** the v0.1.18 Semgrep 1.165.0 fixture verification is now **confirmed on real consumer code** — the 118 PartialParsing errors are **gone (0)**. No Sentinel Shield bug surfaced; every wrapper/collector behaved correctly on real artifacts.

## v0.1.21 — Dependency-Check nightly path + scanner digest pins (no new live validation)
No new consumer run in v0.1.21. Truth restated and hardened:

| Tool | Status (v0.1.21) | Evidence / next step |
|---|---|---|
| **Semgrep 1.165.0** | **consumer-verified** (run 27239206382) | digest resolved `sha256:f4791a54…bfed1b` — pin in consumer |
| **Grype** (SBOM-first) | **live-validated** (run 27239206382) | digest resolved `sha256:7a9fc7f8…01dd28` — pin in consumer |
| **Dockle** (built image) | **live-validated** (run 27239206382) | digest resolved `sha256:eade932f…7abe6b9` — pin in consumer |
| **OWASP Dependency-Check** | **attempted, NOT live-validated** | **no real `dependency-check.json` artifact exists.** Next validation path: the cached **nightly** job (`sentinel-shield-scheduled.yml`, monthly NVD `actions/cache`, foreground) — see [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md). NOT promoted, NOT faked. |

Digest pins were **resolved with Docker (not invented)** on 2026-06-10 — full table + verify/rollback
in [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md). Resolving a digest is a
supply-chain hardening step, **not** a new live-validation; the promotions above stand on run
27239206382. Dependency-Check stays unpromoted until a nightly run produces a real artifact recorded here.

## v0.1.22 — Dependency-Check evidence placeholder (no artifact yet)

Placeholder registry entry. **No new consumer run, no artifact, no run ID** — this records the
*pending* state and the path to close it, nothing more.

| Tool | Status (v0.1.22) | Workflow / Run ID | Artifact | Evidence / next step |
|---|---|---|---|---|
| **OWASP Dependency-Check** | **attempted, NOT live-validated** | `sentinel-shield-dependency-check.yml` / **PENDING** (no run yet) | **none — no real `dependency-check.json` exists** | A maintainer must run the dedicated evidence workflow [`templates/workflows/sentinel-shield-dependency-check.yml`](../templates/workflows/sentinel-shield-dependency-check.yml) on a real consumer (foreground, monthly NVD `actions/cache`), download the resulting `dependency-check.json`, and confirm `scripts/collectors/dependency-check.sh` parses it. Promotion requires that **real, cited artifact** recorded here. NOT promoted, NOT faked. |

Until that artifact exists and is cited, Dependency-Check remains **attempted, NOT live-validated**.
No run ID or artifact is invented to fill this row — the PENDING state is the honest record.

## v0.1.26 — Dependency-Check FIRST REAL ARTIFACT (NVD-key live run) + strict consumer evidence

**The chief v1.0 blocker is closed.** A real `dependency-check.json` now exists, produced by a real
OWASP Dependency-Check run authenticated with an NVD API key. The v0.1.25 blocker was an external
**NVD HTTP 429** (open rate limit on the first full-dataset pull); supplying
`SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY` raised the rate limit and the pull **completed**.

| Field | Value |
|---|---|
| Tool | OWASP Dependency-Check (container `owasp/dependency-check`, digest `sha256:ad169904106250816059f113d374d63a49a7cb0fd2c5e476d05c4fb814cc77b9`) |
| Consumer | **sentinel-shield self-scan** (repo root) — thin dependency surface (security-tooling repo) |
| Run | local, **2026-06-10**, foreground container, NVD-key authenticated |
| Artifact | `reports/raw/dependency-check.json` (gitignored) → committed evidence copy **`tests/fixtures/live-evidence/dependency-check-real.json`** — **4.2 KB, valid JSON**, native schema (`dependencies`/`projectInfo`/`reportSchema`/`scanInfo`) |
| Findings | **5 dependencies analyzed, 0 vulnerabilities** |
| Collector mapping | `scripts/collectors/dependency-check.sh` → **status `pass`, 0 critical / 0 high / 0 medium** |
| Runtime | **153 s** (NVD full dataset of **357,201 records** downloaded once with the key; cache now warm, **241 MB**) |
| NVD behavior | **authenticated rate limit — no HTTP 429** (the v0.1.25 failure mode is gone); subsequent runs reuse the warm cache |
| Key handling | passed via a **`0600 --propertyfile`** (NOT a CLI arg → not in the process list); **never logged, never written to the report, never committed** (verified: 0 occurrences in script, run log, and artifact) |
| Promotion | **experimental → LIVE-VALIDATED** (execution path proven on a real NVD-backed artifact, collector-parsed) |
| Caveat | clean result on a **thin self-scan** surface; the wrapper/collector/NVD path is proven, but non-zero severity mapping is **not** yet exercised on a dependency-rich consumer |
| Next target | run the same path on a dependency-rich consumer (e.g. zenchron-tools) to exercise non-zero CVE buckets |

**Redacted command shape** (key lives only in the mounted `0600` propertyfile):

```sh
docker run --rm \
  -v "<repo>:/src" \
  -v "<cache>:/usr/share/dependency-check/data" \
  -v "<out>:/report" \
  -v "<propdir>:/ss-secret:ro" \
  owasp/dependency-check:latest \
  --scan /src --format JSON --out /report/dependency-check.json \
  --data /usr/share/dependency-check/data \
  --propertyfile /ss-secret/dependency-check.properties   # contains: nvd.api.key=<redacted>
```

### Strict-mode consumer evidence (controlled-fixture dry-run)

Real enforcement engine (`resolve-gates.sh` → `enforce-gates.sh`) over a controlled consumer fixture
(`laravel-react-docker`-derived summary: baseline-clean, but carrying **3 `medium_vulnerabilities` +
2 `style_violations`**). Full detail: [`strict-mode-consumer-evidence-v026.md`](strict-mode-consumer-evidence-v026.md).

| Mode | Enforce exit | Result | Failed gates |
|---|---|---|---|
| `baseline` | 0 | **pass** | — |
| `strict` | 1 | **fail** | `medium_vulnerabilities` (3), `style_violations` (2) |

The strict failure is **expected and attributable** to the two documented strict-only blockers — not
noise. Verified via the resolved gate-env diff: strict additionally turns on `medium_vulnerabilities`,
`missing_sbom`, `style_violations`, `iac_violations`, `container_image_violations`,
`third_party_install_script_risk`, `third_party_network_behavior`. **Nothing suppressed**
(`accepted_risks.loaded = 0`). This is a **controlled-fixture dry-run**, NOT a live full-CI consumer
run — strict mode is **adoptable once a consumer has triaged medium vulns and configured style**, and
remains **NOT claimed production-ready** until a live strict CI run on a real consumer is cited here.

## v0.1.27 — Dependency-Check on a DEPENDENCY-RICH consumer (non-zero CVE buckets) + npm-vocab fix

Closes the v0.1.26 thin-self-scan caveat. Full record (with privacy/CI caveats):
[`dependency-check-consumer-evidence-v027.md`](dependency-check-consumer-evidence-v027.md).

| Field | Value |
|---|---|
| Tool / Consumer | OWASP Dependency-Check (`owasp/dependency-check@sha256:ad169904…cc77b9`) on **`bogdaniel/zenchron-tools`** (private), commit `271e5b7` |
| Surface | 218 Composer + 610 npm direct → **9,289 analyzed dependencies** |
| Artifact | `dependency-check.json` **7.3 MB, valid** — kept **local/gitignored** (consumer private, this repo public); aggregate counts only |
| Findings | **7 vulnerable deps, 11 vulns** — raw `HIGH`=3 + npm `high`=3 = **6 high**; npm `moderate`=3 → **medium**; `low`=2 (NVD=3 / NPM=7 / RetireJS=1) |
| Collector mapping | **status `fail`, 0 critical / 6 high / 3 medium** |
| Runtime | **89 s** (warm NVD cache) |
| Severity fix | npm `MODERATE → medium` in `dependency-check.sh` collector — **3 real CVEs were being dropped**; fix **strengthens** the gate. Guarded by `npm-vocab.json` + `self-test v027-live` |
| npm caveat | Node-Audit online analyzer hit **HTTP 429** (npmjs rate limit) → npm-source findings may be undercounted; NVD/RetireJS complete |
| Promotion | **live-validated (execution path) → live-validated on a dependency-rich consumer with non-zero CVE buckets.** Severity fidelity still best-effort (coarse npm/NVD vocab) |

### Strict-mode — LOCAL consumer evidence (Lane B)

Real engine over a summary built from the consumer's DC artifact:

| Mode | Exit | Result | Failed gates |
|---|---|---|---|
| `baseline` | 1 | **fail** | `high_vulnerabilities` (6) |
| `strict` | 1 | **fail** | `high_vulnerabilities` (6), `medium_vulnerabilities` (3), `missing_sbom` |

**Baseline correctly fails on 6 real HIGH CVEs** (not noise); the strict-only delta (3 `moderate→medium`
CVEs + `missing_sbom`) is visible. Nothing suppressed. This is **LOCAL** consumer evidence — a **live
strict CI run on a real consumer is still OUTSTANDING**; strict mode remains **NOT production-ready**.

## v0.1.29 — CLEAN strict CI run (delta visible) + DC propertyfile fix

Live consumer CI run `27512789768`'s successor: **run `27513388096`** (zenchron-tools, **success**,
~41 min). Full record: [`clean-strict-ci-evidence-v029.md`](clean-strict-ci-evidence-v029.md). Three
attributable views on the real CI summary (6 high, 4 medium; SBOM present):

| View | Result | Failed gates | medium gate |
|---|---|---|---|
| baseline (pure default) | fail | `high_vulnerabilities` | — |
| **strict (EVIDENCE)** | fail | `high_vulnerabilities`, **`medium_vulnerabilities`** | `enabled:true, value:4, fail` |
| strict (CONSUMER) | fail | `high_vulnerabilities` | `enabled:false, value:4, skipped` |

**Strict-only delta visible** (4 medium, EVIDENCE view); the CONSUMER skip is the consumer's own
explicit `fail_on.medium_vulnerabilities:false` (shown transparently — SS suppressed nothing).

**Dependency-Check CI:** the v0.1.28 **propertyfile permission blocker is FIXED** (container-readable;
DC ran the full cold NVD download). DC then hit the OWASP **H2 database lock / "No documents exist"**
error (stale/empty cache from the failed v0.1.28 run under `restore-keys: nvd-Linux-`) → exit 13, **no
fake-clean report**. Exact blocker documented; **local DC evidence (v0.1.27, 6 high/3 medium) stands**.
Strict is demonstrated cleanly in live CI but **not green** (real highs) and **not production-ready**.

## v0.1.30 — Dependency-Check COMPLETES in CI (final CI blocker closed)

Full record: [`dependency-check-ci-evidence-v030.md`](dependency-check-ci-evidence-v030.md). The
v0.1.29 H2 failure was a container-UID write issue (the non-root DC container could not write the
host-owned bind-mounted NVD data dir → could not build/lock the H2 DB). **Fixed** by `chmod a+rwX` on
the mounted data + report dirs (same UID class as the v0.1.29 propertyfile fix).

| Field | Value |
|---|---|
| Consumer / Run | `bogdaniel/zenchron-tools` — **run `27530386965`, success** |
| NVD | **357,832 / 357,832 records (100%)** via the API key — no 429, **no H2 lock** |
| Artifact | `dependency-check.json` **valid, 67 KB** — DC **completes in CI** |
| Findings | 69 deps (committed surface), 3 vulns → collector **`fail`, 1 critical / 1 high / 0 medium** |
| Strict (EVIDENCE) | baseline FAIL `[critical, high]`; strict FAIL `[critical, high, **medium**]` — delta visible |
| Key | full NVD download with the key; 0 key occurrences in artifact/log/commits |

**Promotion:** OWASP Dependency-Check is now **live-validated in CI** (in addition to the v0.1.27
dependency-rich local scan). Limitation: the CI scan covers the committed manifests (69 deps); add
`composer install`/`npm ci` before DC for full transitive CI coverage (enhancement, not a blocker).
**This closes the last hard v1.0 CI blocker** — see [`v1-readiness.md`](v1-readiness.md) for the RC call.

## v1.0.0-rc.1 soak — Dependency-Check TRANSITIVE CI coverage (committed-surface caveat CLOSED)

The RC soak ran the strict-evidence workflow pinned to **`v1.0.0-rc.1`** with `composer install` +
`npm ci` BEFORE Dependency-Check, so DC scans the full transitive surface (vendor/ + node_modules/).

| Field | Value |
|---|---|
| Consumer / Run | `bogdaniel/zenchron-tools` — **run `27573703800`, success** (~9 min, warm NVD cache) |
| SS version | pinned **`v1.0.0-rc.1`** (commit `f1b2644`) |
| **DC analyzed deps** | **9,179** (vs 69 committed-surface in v0.1.30) — transitive surface restored by credential-free installs |
| DC findings | 1 critical / 8 high / 6 medium (npm `moderate`→medium) / 4 low → collector **`fail` 1 critical / 8 high / 6 medium** |
| Strict views | baseline FAIL `[critical, high]`; **strict-EVIDENCE FAIL `[critical, high, medium]`** (delta visible) |
| Key | NVD download with the secret key; 0 key occurrences in artifact/log/commits |

**Outcome:** the v0.1.30 "CI scans the committed surface" limitation is **closed** — DC scans **9,179
transitive deps in CI** on the rc.1 tag, collector-parsed, strict delta visible, nothing suppressed.
The rc.1 STABLE contract held (no regression). Strict still correctly fails on real findings (opt-in,
not production-ready by default).

## v1.0.0 final — rc.2 re-soak (clean → GA)

The `v1.0.0-rc.2` candidate was re-soaked on a real consumer pinned to the **`v1.0.0-rc.2`** tag, then
promoted to **`v1.0.0` (GA)**.

| Field | Value |
|---|---|
| Consumer / Run | `bogdaniel/zenchron-tools` — **run `27576003051`, success** (~11 min) |
| SS version | pinned **`v1.0.0-rc.2`** (commit `77fab17`) |
| Exit-code contract (in CI) | `resolve-gates` invalid config → **exit 2**, valid → **exit 0** — `contract_ok: true` (the rc.1→rc.2 STABLE fix verified end-to-end) |
| DC analyzed deps | **9,179** (transitive via `composer install` + `npm ci`) |
| DC collector | **`fail`, 1 critical / 8 high / 6 medium** |
| Strict views | baseline FAIL `[critical, high]`; **strict-EVIDENCE FAIL `[critical, high, medium]`** (delta visible) |
| Key | NVD download with the secret key; 0 key occurrences in artifact/log/commits |

**Outcome:** rc.2 soaked **clean** — exit-code contract verified in CI, transitive DC complete,
strict delta visible, nothing suppressed, no STABLE regression. All 10 final-release criteria pass →
**`v1.0.0` released.** Strict remains opt-in/non-required (correctly red on real findings).

## v1.3.0 — Deptrac PROMOTED (real consumer evidence); IaC stays experimental (blockers documented)

### Deptrac — `experimental` → `live-validated`

Real **Deptrac 1.0.2** runs on **real consumer projects** with **genuine `deptrac.yaml`** files
(layers `Controller`/`Service`/`Repository` + ruleset `Controller→Service`, `Service→Repository`). The
SS collector (`scripts/collectors/deptrac.sh`) parsed each artifact → `architecture_violations`. Raw
artifacts kept **local** (private consumers); only counts cited. Both the clean and violation paths are
exercised on real data:

| Consumer (private) | Deptrac | `Report.Violations` | Collector → `architecture_violations` | Result |
|---|---|---|---|---|
| `commerce-bridge` | 1.0.2 | 0 | 0 | **pass** (clean architecture) |
| `octo-cms` | 1.0.2 | 4 | 4 | **fail** (real layer-rule violations) |
| `silver-potato` | 1.0.2 | 4 | 4 | **fail** |

**Reproducible command** (local; private consumer, raw kept local):
```sh
docker run --rm -v <consumer>:/app -v /tmp/out:/out -w /app php:8.3-cli \
  php vendor/bin/deptrac analyse --formatter=json --output=/out/deptrac.json --no-progress
sh scripts/collectors/deptrac.sh --input /tmp/out/deptrac.json   # -> architecture_violations
```

Committed evidence (synthetic, derived from the real `Report` block only — no private class/path
data): `tests/fixtures/deptrac-v130/{clean,violations}.json`, guarded by `self-test v130-evidence`.
**Promotion:** Deptrac → **live-validated** (`architecture_violations`). Caveat: validated on the
local CLI path with genuine consumer configs; severity is binary (violation count), not graded.

### IaC (Checkov / Conftest / Terrascan) — NOT promoted (exact blockers)

Attempted on **real Terraform** (`zenchron-infra/terraform`, Hetzner `hcloud` provider, ~561 lines +
modules). **No usable evidence was produced** — so, per the rules, **no IaC promotion**:

| Tool | Version | Attempt | Blocker → status |
|---|---|---|---|
| **Checkov** | 3.3.0 | `-d /tf --framework terraform` | `resource_count: 0` **even on a trivial known-bad AWS TF** → the Checkov image is not parsing Terraform in this environment. **No evidence.** |
| **Terrascan** | latest | `scan -i terraform` | scanned but **0 applicable policies for the `hcloud`/Hetzner provider** (Terrascan ships AWS/Azure/GCP/K8s policies) → 0 passed / 0 violated. **No real findings on this surface.** |
| **Conftest** | latest | `test --parser hcl2 -p policies/opa/terraform.rego` | no output (parser/policy/image mismatch). **No evidence.** |

**Decision:** Checkov/Conftest/Terrascan remain **`experimental`** — promotion still requires a real
cited run that parses real IaC into a non-trivial `iac_violations` count. Next attempt: an AWS/Azure/GCP
or Kubernetes IaC surface (which the tools have policies for) and a working scanner image. The wrappers
correctly report `unavailable`/0 — they never fake a clean IaC report.

## v1.4.0 — IaC LOCAL tool-execution evidence (diagnostic closure; NO promotion)

> **Not a consumer-CI promotion.** This is a **local** validation (same class as
> [`live-evidence-v025.md`](live-evidence-v025.md)): real scanner binaries, real artifacts, real
> collectors — but **no consumer, no run ID**. Checkov/Conftest/Terrascan **stay `experimental`.**
> The registry table above is unchanged. Full record: [`iac-local-evidence-v140.md`](iac-local-evidence-v140.md).

v1.4.0 ran the three IaC scanners via their **supported** execution paths against the committed
insecure fixture (`tests/fixtures/iac-v024/terraform/insecure.tf`) and pinned every v1.3.0 blocker
to a root cause:

| Tool | Version | Command | Raw | Collector → `iac_violations` | v1.3.0 blocker → root cause |
|---|---|---|---|---|---|
| **Checkov** | 3.3.1 (`pip`) | `checkov -d <tf> -o json` | 3 resources, 16 failed, 0 parse errs | `fail` / **16** | "resource_count:0" was the **Docker image**, not TF/wrapper |
| **Terrascan** | 1.19.9 | `terrascan scan -d <tf> -i terraform -o json` | 4 violations (4 high) | `fail` / **4** | "0 policies" was **`hcloud`-only**; AWS works |
| **Conftest** | 0.56.0 / OPA 0.69.0 | `conftest test --policy policies/opa/terraform.rego --namespace sentinel.terraform <plan.json>` | 2 failures | `fail` / **2** | "no output" was **namespace + HCL-vs-plan-JSON** |

Derived, sanitized fixtures committed at `tests/fixtures/iac-v140/`; guarded by `self-test v140-iac`.
**Still NOT promoted** — no consumer-CI run ID exists. The known-good commands above are the recipe
for the next promotion attempt.
