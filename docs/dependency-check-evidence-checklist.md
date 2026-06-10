# Dependency-Check Evidence Checklist & Operational Triage (v0.1.25)

This document is the operator-facing companion to `dependency-check-hardening.md` and
`dependency-check-evidence-plan.md`. It covers Lane B tasks **32-39**: false-positive
triage, CPE noise, NVD API/key limitations, cache-corruption recovery, first-run vs
warm-run expectations, the evidence checklist itself, and a registry template stub for
the day a real artifact finally exists.

**Honesty note (carried from prior sprints):** OWASP Dependency-Check remains
**ATTEMPTED, NOT live-validated**. No real `dependency-check.json` artifact from a
consumer CI run exists yet. The captain runs the real attempt; this doc does **not**
claim a live run, and the registry entry in §39 is an explicitly-empty *template stub*.
All collector counts cited here come from the local fixtures in
`tests/fixtures/dependency-check/`, which are synthetic by design.

---

## 32. False-positive triage

Dependency-Check matches your dependencies against the NVD by deriving CPEs (Common
Platform Enumeration identifiers) and Maven/package coordinates. Because matching is
heuristic, false positives are normal and expected — they do **not** indicate a broken
scan.

Triage procedure when a flagged vulnerability looks wrong:

1. **Open the dependency in the report.** Each `dependencies[].vulnerabilities[]` entry
   carries a `name` (CVE id) and `severity`. Cross-reference the CVE on
   <https://nvd.nist.gov/> and confirm the affected `cpe`/version range.
2. **Confirm the matched evidence.** Native DC reports include
   `dependencies[].evidenceCollected` and `dependencies[].identifiers`/`vulnerabilityIds`.
   If the matched CPE vendor/product does not correspond to your library, it is a CPE
   mismatch (see §33), not a real exposure.
3. **Confirm the version is actually in range.** A common FP class is a CVE whose fixed
   version predates the bundled version, or a CVE filed against an unrelated product line
   that shares a name.
4. **Suppress, do not silence globally.** Record a *scoped* suppression in a
   `dependency-check-suppression.xml` keyed on the specific `<cve>` + `<packageUrl>`/
   `<cpe>` regex. Never suppress by severity or wildcard the whole dependency.
5. **Log the rationale.** Every suppression must carry a `<notes>` line with who triaged
   it and why, so the suppression is auditable and revisited when the dependency upgrades.

The collector itself does **no** triage — it faithfully counts every
`severity` present (see `scripts/collectors/dependency-check.sh`). Suppressions belong
at scan time in the wrapper input, before the collector ever sees the JSON.

## 33. CPE noise

CPE-based matching is the dominant source of noise:

- **Over-matching:** generic product names (`commons`, `core`, `client`, `server`) match
  unrelated NVD vendor/product pairs, producing vulnerabilities for code you never ship.
- **Under-matching:** a dependency with no derivable CPE (e.g. a shaded/relocated jar or a
  vendored binary) silently contributes **zero** vulnerabilities — absence of findings is
  not proof of safety.
- **Version-format drift:** snapshot/`-SNAPSHOT`, build-metadata (`+build`), and
  date-stamped versions confuse NVD range comparisons and can both over- and under-match.

Mitigations: prefer `packageUrl` (PURL) identifiers over raw CPE when available; keep a
reviewed suppression file (§32); and treat a *clean* DC report as "no CPE matches found",
not "no vulnerabilities exist". Fixtures `clean.json` and `empty-deps.json` exercise the
zero-finding path; the collector correctly reports `pass` with all buckets `0` for them.

## 34. NVD API / API-key limitations

Dependency-Check populates and updates its local vulnerability database from the NVD
data feeds / NVD API.

- **An NVD API key is now effectively required for usable rates.** Without a key, the NVD
  API throttles anonymous clients to a very low request ceiling (a handful of requests per
  rolling 30-second window). A **cold** run with no key is heavily throttled and can take
  *tens of minutes to multiple hours* — or fail outright on transient 403/503 responses —
  while it walks the full CVE history.
- **With a key** (`--nvdApiKey` / `NVD_API_KEY`), the allowed rate is substantially higher,
  turning a cold warm-up into a bounded operation and making warm incremental updates fast.
- **Key handling:** the key is a secret. In CI it must come from an encrypted secret
  (e.g. `${{ secrets.NVD_API_KEY }}`), never be committed, and never be echoed into logs.
- **Honest consequence for this project:** because cold, keyless runs are throttled to the
  point of being impractical inside a sprint, the real live-validation attempt is owned by
  the captain in an environment that has the key and the cache. This doc does not and
  cannot stand in for that run.

## 35. Cache / database corruption recovery

Dependency-Check stores its NVD database under the `--data` directory (the `CACHE` path in
the wrapper). A partial write — typically from a run killed at the timeout cap mid-update —
can leave the H2 database (`odc.mv.db`) corrupt. Symptoms: the scan aborts early with an
H2/`MVStore` error, or every subsequent run re-warms from scratch.

Recovery, in order of least to most destructive:

1. **Retry once.** A transient lock can clear on its own; a clean re-run may succeed.
2. **Purge and rebuild the DB.** Run with `--purge` (or delete `odc.mv.db` under the data
   dir) and let the next run rebuild. With an NVD key this is bounded; keyless it is the
   slow cold path (§34).
3. **Restore from a known-good cache artifact.** If CI persists the data dir via
   `actions/cache`, a corrupt cache key should be invalidated (bump the key) so the
   OS-prefixed `restore-keys` seed a partial-warm rebuild rather than reusing the corruption.
4. **Never ship a fake-clean on corruption.** If the DB cannot be rebuilt in budget, the
   wrapper must report `unavailable`, not `pass`. A corrupt-cache scan that produces no
   findings is *not* evidence of safety.

## 36. First-run (cold) expectations

A first run on a fresh `--data` directory must download and build the entire local NVD DB.

- **Duration:** dominated by NVD throttling (§34). With a key: bounded (minutes). Without a
  key: long and unreliable — plan for it to exceed a normal step timeout.
- **Network:** required. An air-gapped first run will fail unless seeded with a prebuilt DB.
- **Result shape:** once the DB is built, the scan itself over a normal repo is fast; the
  cost is almost entirely the one-time warm-up.
- **CI guard:** the wrapper's foreground execution plus `SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT`
  (set below the step `timeout-minutes`) lets a cold run that blows its budget stop and report
  `unavailable` *honestly*, while a separate `if: always()` upload step still preserves any
  raw output. A cold run is the expected reason for an honest `unavailable`.

## 37. Warm-run expectations

A warm run reuses an existing, recent `--data` cache.

- **Duration:** fast — only the incremental NVD delta since the last update is fetched,
  then the scan runs locally.
- **Network:** still touched for the incremental update; with a key this is quick and
  reliable.
- **Result shape:** stable, reproducible finding counts for the same input — this is the
  run that produces a trustworthy artifact worth registering (§38, §39).
- **Cache freshness:** a warm cache that is too stale will fetch a larger delta (slower) but
  is still correct. A cache older than the NVD's modified-feed window may force a fuller
  refresh.

## 38. Evidence checklist

Before any Dependency-Check result is treated as **live-validated** and registered (§39),
ALL of the following must be true and recorded:

- [ ] Run executed on a real consumer repo (not a fixture), in CI or an equivalent
      reproducible environment.
- [ ] NVD API key was present (§34); run was a **warm** run (§37) over a non-corrupt cache (§35).
- [ ] The scan completed (not timed out / not `unavailable`); exit handled per the wrapper
      contract (valid JSON preserved even on non-zero exit due to findings).
- [ ] Raw `dependency-check.json` was uploaded as a CI artifact via `if: always()`.
- [ ] A real, verifiable **run ID** and **artifact ID/URL** exist and are recorded — never
      invented.
- [ ] The collector (`scripts/collectors/dependency-check.sh`) was run over the **real**
      artifact and its `critical/high/medium` counts were captured.
- [ ] False positives triaged (§32) and any suppressions are scoped and noted (§33).
- [ ] The registry entry (§39) is filled in with the above and the global PENDING row in
      `main-gate-live-evidence.md` is updated to reflect promotion.

Until every box is checked, the honest status is **ATTEMPTED, NOT live-validated**.

### Local fixture evidence (synthetic — NOT a substitute for the above)

For collector-behavior verification only, the local fixtures produce deterministic counts.
Verified on 2026-06-10 in this worktree:

| Fixture | Command | critical | high | medium | status |
|---|---|---|---|---|---|
| `medium.json` | `sh scripts/collectors/dependency-check.sh --input tests/fixtures/dependency-check/medium.json` | 0 | 0 | 1 | fail |
| `mixed.json`  | `sh scripts/collectors/dependency-check.sh --input tests/fixtures/dependency-check/mixed.json`  | 1 | 1 | 1 | fail |

These confirm severity bucketing only. They are **synthetic** and do **not** count as
live evidence.

## 39. Registry template entry (STUB — no real artifact exists yet)

When a warm, keyed consumer run finally satisfies the §38 checklist, copy the block below
into the live-evidence registry and fill every `<...>` placeholder from the **real** run.
Do not commit this stub as if it were filled.

```
- tool: dependency-check
  status: PENDING            # → set to LIVE-VALIDATED only when every §38 box is checked
  consumer_repo: <owner/repo>
  workflow: <workflow name / file>
  run_id: <real GitHub Actions run id>          # NEVER fabricated
  run_url: <https://github.com/<owner/repo>/actions/runs/<id>>
  artifact: <artifact name>
  artifact_id: <real artifact id>
  artifact_url: <real download url>
  run_type: warm            # must be warm per §37
  nvd_api_key_used: true    # must be true per §34
  cache_state: healthy      # per §35
  collector_counts:         # from running the collector over the REAL artifact
    critical: <n>
    high: <n>
    medium: <n>
  date: <YYYY-MM-DD>
  triaged_by: <name>        # false positives reviewed per §32/§33
  notes: <suppressions applied, anomalies, follow-ups>
```

**Current state of this stub:** empty. No real consumer artifact, run ID, or artifact ID
exists. The captain owns producing the real run; this template only describes the shape of
the eventual evidence so it can be dropped in without fabrication.
