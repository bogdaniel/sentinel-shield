# Dependency-Check Consumer Evidence (v0.1.27)

> **Scope.** First **dependency-rich consumer** run of OWASP Dependency-Check (closing the v0.1.26
> thin-self-scan caveat), plus **local consumer** baseline-vs-strict enforcement evidence. Maturity
> claims defer to [`product-status.md`](product-status.md); the canonical registry is
> [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
>
> **Privacy.** The consumer (`zenchron-tools`) is a **private** repo; this repo (`sentinel-shield`) is
> **public**. The raw 7.3 MB `dependency-check.json` is therefore **kept local (gitignored)** — only
> aggregate counts and the collector summary are recorded here. No per-package CVE list, no consumer
> source, no internal dependency inventory is committed.

## 1. Dependency-Check on a dependency-rich consumer (Lane A)

| Field | Value |
|---|---|
| Consumer | **`bogdaniel/zenchron-tools`** (private), commit `271e5b7` — PHP (Laravel) + JS |
| Direct deps | **218 Composer** + **610 npm** (lockfiles); DC expanded to **9,289 analyzed dependencies** (transitive + `vendor/` + `node_modules/`) |
| Run | local, 2026-06-14, container `owasp/dependency-check@sha256:ad169904…cc77b9`, **warm NVD cache** (incremental update only: 1,034 records) |
| Runtime | **89 s** (warm cache; vs 153 s cold in v0.1.26) |
| Exit | tool exited **14** (findings + npm Node-Audit API HTTP 429) **but produced valid JSON** → wrapper **preserved** the report (preserve-on-nonzero, proven on a real run) |
| Artifact | `reports/raw/dependency-check-consumer.json` — **7.3 MB, valid JSON**, kept **local/gitignored** |
| Findings | **7 vulnerable dependencies, 11 vulnerabilities** |
| Severity (raw) | `HIGH`=3 (NVD) + `high`=3 (npm) = **6 high**; `moderate`=3 (npm) → **medium**; `low`=2 |
| Sources | NVD=3, NPM=7, RetireJS=1 |
| Collector mapping | **status `fail`, 0 critical / 6 high / 3 medium** |
| Key handling | `SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY` via `0600 --propertyfile`; **never logged / committed / in-artifact** (verified) |

**Non-zero CVE severity buckets are now exercised on real consumer evidence** (v0.1.26's open caveat),
with one correctness fix below.

### Severity-mapping fix (surfaced by real data)

Dependency-Check mixes **NVD/CVSS** labels (`CRITICAL/HIGH/MEDIUM/LOW`) with **npm Node-Audit /
RetireJS** labels (`critical/high/moderate/low`). The collector matched `MEDIUM` but **not** npm's
`MODERATE`, so **3 real moderate CVEs were dropped** (`medium=0` instead of `3`). Since `medium`
gates in **strict**, those CVEs were invisible to the strict gate. Fixed in
`scripts/collectors/dependency-check.sh`: `MODERATE → medium`. This **strengthens** the gate (more
findings counted) — it does not weaken it, suppress, or fake anything. Regression-guarded by
`tests/fixtures/dependency-check/npm-vocab.json` (synthetic, no consumer data) and `self-test v027-live`.

### Caveat — npm Node-Audit rate limit

DC's online npm Node-Audit analyzer returned **HTTP 429** (npmjs registry rate limit) during the run,
so npm-source findings may be **undercounted**. NVD and RetireJS sources are complete; this is an
external rate limit, **not** a Sentinel Shield failure (the wrapper kept the valid NVD/RetireJS
results and flagged the partial npm source). A later re-run with npm-audit backoff would broaden npm
coverage.

## 2. Local consumer strict-vs-baseline evidence (Lane B)

Real enforcement engine over a real summary built from the consumer's Dependency-Check artifact
(`build-security-summary.sh` → `resolve-gates.sh` → `enforce-gates.sh`). **Local** consumer
evidence — NOT a live CI run (see §4).

| Mode | Enforce exit | Result | Failed gates |
|---|---|---|---|
| `baseline` | 1 | **fail** | `high_vulnerabilities` (6) |
| `strict` | 1 | **fail** | `high_vulnerabilities` (6), `medium_vulnerabilities` (3), `missing_sbom` |

- **Baseline correctly fails** on **6 real HIGH CVEs** — correct gate behavior, not noise. Because
  baseline already fails, the clean *baseline-pass / strict-fail* contrast is **not** demonstrable on
  the raw consumer data; the **strict-only delta is still visible**: strict additionally counts the 3
  `moderate→medium` CVEs and flags `missing_sbom` (no SBOM in this minimal raw set).
- **Nothing suppressed** (`accepted_risks.loaded = 0`). To adopt strict, the consumer must first
  triage or accept-risk the 6 high + 3 medium CVEs (consumer remediation — **out of scope here**).

## 3. NVD API key handling

`SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY`, passed through a `0600 --propertyfile` (never on the
command line / process list). Verified: **0 occurrences** in the run log, the artifact, and every
tracked/committed file. Key stored outside the repo.

## 4. What this is NOT

- **Not a live CI run.** This is local consumer evidence. A live `strict` CI run on a real consumer
  (run ID + uploaded artifacts) is still **outstanding** — see [`v1-readiness.md`](v1-readiness.md) §(7).
- **Strict mode is NOT marked production-ready.**
- **No consumer findings were remediated** (mission rule).

## 5. Reproduce (local)

```sh
# 1. Dependency-Check on the consumer (warm cache, NVD key from a 0600 keyfile)
cd <consumer>
SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY="$(cat ~/.sentinel-shield-nvd.key)" \
SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled \
SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE=owasp/dependency-check:latest \
SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE=<sentinel>/.sentinel-shield/cache/dependency-check \
  sh <sentinel>/scripts/audits/dependency-check.sh /tmp/dc.json
# 2. Build summary + enforce baseline/strict
mkdir -p /tmp/raw && cp /tmp/dc.json /tmp/raw/dependency-check.json
sh scripts/build-security-summary.sh --raw-dir /tmp/raw --output /tmp/s.json --project-name consumer --commit c --workflow local
for m in baseline strict; do d=$(mktemp -d); sh scripts/resolve-gates.sh --mode $m --output-dir $d --format env;
  sh scripts/enforce-gates.sh --gates-env $d/sentinel-shield-gates.env --summary /tmp/s.json --output-dir $d --format json; echo "$m -> $?"; done
```
