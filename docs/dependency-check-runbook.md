# Dependency-Check Operator Runbook

> Reference/runbook doc (v1.2.0).

The canonical operator runbook for OWASP Dependency-Check in Sentinel Shield: how it runs,
what the knobs do, how to keep it fast and reliable, and how to diagnose the failures we have
actually seen in CI. This doc is **additive and docs-only** — it changes no script, template,
or schema. For the deeper dives it references (and does not duplicate), see:

- [`dependency-check-ci-cache.md`](dependency-check-ci-cache.md) — NVD cache reliability, poisoned-cache / stale-lock internals.
- [`security-hygiene.md`](security-hygiene.md) — NVD API key rotation and `gh secret set`.
- [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) — pinning the DC image by digest.
- [`main-gate-live-evidence.md`](main-gate-live-evidence.md) — live consumer evidence (committed vs transitive counts).

Source of truth: `scripts/audits/dependency-check.sh` (wrapper),
`templates/workflows/sentinel-shield-dependency-check.yml` (evidence workflow),
`scripts/collectors/dependency-check.sh` (severity mapping).

---

## 1. What Dependency-Check does here

Dependency-Check (DC) is a **slow** SCA scanner: it matches your dependencies against the NVD
(National Vulnerability Database). It is **disabled by default**
(`SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=disabled`) and is intended for scheduled / nightly runs
or an **optional** main-gate — **never** on the PR-fast path. Findings may duplicate OSV / Trivy /
Grype because they share CVE sources; that overlap is expected.

The DC contract is **honest**: a run either produces a valid report, or it reports `unavailable`
and writes **no** report. It never fakes a clean result.

---

## 2. Two scan surfaces (committed vs transitive)

DC only sees what is on disk. There are two surfaces:

| Surface | What DC sees | How to enable | Default |
|---|---|---|---|
| **Committed** | committed manifests / locks (`composer.json`, `package-lock.json`, …) | nothing — this is the default | **ON** |
| **Transitive** | the full installed tree (`vendor/` + `node_modules/`) after `composer install` / `npm ci` | the workflow knobs below (v1.1.0) | OFF |

**Transitive knobs (additive, v1.1.0; default OFF so v1.0.0 behavior is preserved):**

```yaml
# workflow env (or use the workflow_dispatch inputs install_php / install_node):
SENTINEL_SHIELD_DEPENDENCY_CHECK_INSTALL_PHP:  "true"   # composer install before DC
SENTINEL_SHIELD_DEPENDENCY_CHECK_INSTALL_NODE: "true"   # npm ci before DC
SENTINEL_SHIELD_DEPENDENCY_CHECK_PHP_COMMAND:  "composer install --no-interaction --no-progress --no-scripts --ignore-platform-reqs --prefer-dist"
SENTINEL_SHIELD_DEPENDENCY_CHECK_NODE_COMMAND: "npm ci --no-audit --no-fund --ignore-scripts"
```

The install steps are **credential-free** (public packages) and `continue-on-error`: if an install
fails, DC **falls back to the committed surface** rather than faking transitive coverage. A private
registry needs consumer-provided auth (composer `auth.json` / npm `.npmrc` from the consumer's own
secrets) — it is **not** wired into the template.

**Why it matters:** on a real consumer the transitive surface saw **9,179 deps** vs **69** on the
committed surface — a ~130x coverage difference. See `main-gate-live-evidence.md`. Transitive scan
is **opt-in**, never required by default.

---

## 3. The NVD API key

The NVD throttles unauthenticated clients. Without a key, the **first full-dataset pull** typically
hits **HTTP 429** and the download never completes. The GitHub secret
`SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY` raises the rate limit so that pull completes.

**Provisioning / rotation** is documented in `security-hygiene.md` (`gh secret set`). Set the secret
with the **same name** in the consumer repo.

**Key handling (never leaks):** the wrapper writes the key into an **ephemeral** propertyfile
(`mktemp -d`, removed on exit via a `trap`) and passes it with `--propertyfile`, never on the command
line. The file is **container-readable** (dir `chmod 755`, file `chmod 644`) because the DC container
runs as a **non-root UID** that could not read a `0600` file in a `0700` dir. The key is **never** on
the command line, never in the process list, never in logs, never in the report, never committed. The
only relaxation is short-lived local readability inside the throwaway temp dir.

> **NEVER** print or commit the key value. Treat its presence as the only observable fact.

---

## 4. Cold vs warm cache

DC stores the NVD dataset in an H2 database (`odc.mv.db`) under its data dir. In CI that dir is an
`actions/cache`.

- **Cold run (first):** downloads the **full** NVD dataset (~357k records, hundreds of MB). Slow.
- **Warm run:** restores the **monthly** cache (key `nvd-v030-<os>-<month>`, with partial-reuse
  `restore-keys: nvd-v030-<os>-`) and fetches only the **delta**. Fast.

The cache is saved **conditionally** — only when a `dependency-check.json` report was actually
produced — so a failed run can **never poison** the cache for the next run. The fresh `nvd-v030-*`
namespace also cannot restore the poisoned `nvd-Linux-*` caches from earlier failed runs. To force a
cold rebuild, dispatch with the input `reset_dependency_check_cache=true`. Full internals:
`dependency-check-ci-cache.md`.

---

## 5. Honest exit semantics

DC exits **non-zero when it finds vulnerabilities**. That is normal. The wrapper therefore:

1. Runs DC in the **foreground** (so `timeout-minutes` and `SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT`
   actually apply — a detached `docker run -d` would ignore them).
2. **Keeps valid JSON even on a non-zero exit** — the collector / gate decides pass/fail, not the
   scanner's exit code.
3. If there is **no valid JSON** (timeout, incomplete NVD download, crash), it **discards** any
   partial file and reports `unavailable` — it never writes a fake-clean report.

Artifact upload uses `if: always()`, so a scanner failure or findings can **never erase** the raw
report from the run artifacts.

**Severity mapping (collector):** `scripts/collectors/dependency-check.sh` maps CVSS labels to the
`critical` / `high` / `medium_vulnerabilities` buckets. npm's **`moderate`** maps to **medium**
(v0.1.27 fix) so real moderate npm CVEs are counted and gated, not dropped.

---

## 6. The H2 / permission failures we fixed (context for triage)

Two classes of failure broke DC in early CI runs; both are fixed in the shipped wrapper but you may
still see their symptoms if a cache or mount is in a bad state:

1. **`FileNotFoundException … Permission denied` on the propertyfile** — the non-root DC container
   could not read a `0600` key file in a `0700` dir. **Fixed** by making the propertyfile
   container-readable (dir `755`, file `644`) in a traversable temp dir.
2. **`Unable to obtain an exclusive lock on the H2 database` / `No documents exist`** — the non-root
   container could not write/lock the H2 DB in the host-owned data and report dirs. **Fixed** by
   `chmod -R a+rwX` on the mounted NVD data dir and report dir, plus clearing stale `*.lock` /
   `odc.update.lock` before the run. The lock cleanup removes **only** lock files, never the NVD data.

---

## 7. Troubleshooting table

| Symptom | Cause | Fix |
|---|---|---|
| **HTTP 429** during the NVD download | unauthenticated NVD rate limit on the first full-dataset pull | set the `SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY` secret (see `security-hygiene.md`); re-run |
| **`Unable to obtain an exclusive lock on the H2 database`** / **`No documents exist`** | stale `*.lock` / `odc.update.lock`, or an empty/poisoned cache restored | wrapper auto-deletes stale locks; if it persists dispatch with `reset_dependency_check_cache=true`; the fresh `nvd-v030-*` namespace + conditional save prevent re-poisoning |
| **`FileNotFoundException … Permission denied`** on the propertyfile | non-root container could not read the key file | already fixed (dir `755` / file `644`); if seen, confirm the temp dir is not on a `noexec`/restrictive mount |
| **No `dependency-check.json` artifact at all** | DC timed out, NVD download incomplete, or crashed → no valid JSON | this is **unavailable, not fake-clean**; fix the root cause, re-run (often with `reset_dependency_check_cache=true`). `if: always()` already preserves any report that *was* produced |
| **DC exited non-zero but a report exists** | **findings** (expected behavior) | nothing to fix — the wrapper **keeps** the valid JSON; the collector/gate decides pass/fail |
| **Private-registry install failure (transitive)** | `composer install` / `npm ci` needs registry auth not provided to the template | provide consumer auth (`auth.json` / `.npmrc`) via the consumer's own secrets; until then DC `continue-on-error`s and **falls back to the committed surface** (honest, never fakes coverage) |
| **Cold run too slow** | first run downloads the full NVD dataset (~357k records) | warm the cache (monthly `nvd-v030-*` key); raise `timeout-minutes` / `SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT` for the cold run; provide the NVD key so the pull is not throttled |

---

## 8. Recommended production settings

1. **Pin the DC image by digest**, not a moving tag:
   `owasp/dependency-check@sha256:ad169904…` (validated v0.1.30). Templates ship the readable
   `:latest` tag for onboarding — override with the digest before production. See
   `scanner-image-digest-pinning.md`.
2. **Keep the cache warm.** Use the monthly `nvd-v030-<os>-<month>` cache with conditional save so a
   failed run never poisons it; only the first run per month is cold.
3. **Provide the NVD API key secret** (`SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY`) so the
   dataset pull is not rate-limited. Rotate per `security-hygiene.md`.
4. **Opt into the transitive surface** (`INSTALL_PHP` / `INSTALL_NODE = "true"`) when you want full
   coverage (vendor/ + node_modules/) rather than committed manifests only.
5. **Keep `if: always()` artifact uploads** so findings or a scanner failure can never erase the raw
   report.
6. **Run DC scheduled/nightly or as an optional main-gate — never on the PR-fast path.** Pin
   `SENTINEL_SHIELD_REF` to a full SHA and apply a foreground timeout
   (`SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT`, e.g. `40m`, under the step `timeout-minutes`).
