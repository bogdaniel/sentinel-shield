# Dependency-Check Hardening (v0.1.24)

OWASP Dependency-Check is Sentinel Shield's deep, NVD-backed Software Composition
Analysis (SCA) tool. This document records the hardening contract for the audit
wrapper (`scripts/audits/dependency-check.sh`) and the collector
(`scripts/collectors/dependency-check.sh`), the severity mapping, why the tool is
scheduled-only, and operational troubleshooting.

All claims below were verified against the actual scripts and by running the
collector over the fixtures in `tests/fixtures/dependency-check/`. No gates were
weakened and no fake-clean behavior exists.

---

## 1. Audit-wrapper contract review (tasks 21-24)

The audit wrapper (`scripts/audits/dependency-check.sh`) was reviewed line-by-line.
The three required honesty properties hold. No bug was found.

### 21/22. Foreground execution only

The tool runs in the foreground so step-level timeouts and the optional
`timeout(1)` cap actually apply — there is no `docker run -d`, no `&`, no
backgrounding. From the wrapper header (lines 7-9):

```
#   SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT  optional wall-clock cap (e.g. 30m); applied FOREGROUND
#                                             via `timeout` if that binary is present. No detached
#                                             containers — a `docker run -d` would ignore step timeouts.
```

And the run block comment (lines 61-62):

```
# Run FOREGROUND so the step timeout/`timeout` actually applies. `|| true` keeps a valid JSON report
# even when the tool exits non-zero (findings). We validate the output afterward.
```

Both execution paths invoke the tool directly and capture its exit code rather
than detaching:

```
$TO dependency-check --scan . --format JSON --out "$OUT" --data "$CACHE" || rc=$?
```
```
$TO docker run --rm -v "$PWD:/src" ... "$IMAGE" \
    --scan /src --format JSON --out /report/"$(basename "$OUT")" --data /usr/share/dependency-check/data || rc=$?
```

The `docker run` uses `--rm` (no `-d`), so the container is foreground and bound to
the step's lifetime. CONFIRMED: foreground only.

### 23. Valid JSON preserved on non-zero exit

A non-zero exit from Dependency-Check is normal when vulnerabilities are found.
The wrapper captures the exit code into `rc` with `|| rc=$?` and then decides based
on JSON validity, not on `rc`. From lines 78-83:

```
# Decide: keep valid JSON (even on non-zero exit), else discard partial and report unavailable.
if valid_json "$OUT"; then
	[ "$rc" -eq 0 ] || echo "[sentinel-shield] dependency-check exited $rc but produced valid JSON — kept for the collector/gate to decide." >&2
	echo "[sentinel-shield] dependency-check: report written -> $OUT" >&2
	exit 0
fi
```

So a valid report is kept and the wrapper exits 0 even when `rc != 0`; the
collector/gate then decides pass/fail. CONFIRMED.

### 24. Invalid / no JSON never fake-clean

If the output is missing, empty, or unparseable, the wrapper deletes any partial
file and reports `unavailable` rather than emitting a clean report. From lines
30-44 and 84-85:

```
unavailable() { echo "[sentinel-shield] dependency-check unavailable: $1 (no report written)." >&2; exit 0; }

# remove a partial/empty/invalid output so a half-written file can never look clean.
discard_partial() { [ -f "$OUT" ] && rm -f "$OUT" 2>/dev/null || true; }
```
```
discard_partial
unavailable "tool exited ${rc} without valid JSON (timed out, NVD download incomplete, or crashed) — no fake-clean report"
```

`valid_json()` (lines 36-44) requires a non-empty file that parses with `jq -e .`
(or, when jq is absent, a minimal structural first-byte check). The disabled path
and the missing-binary path also call `unavailable` and write no file (lines 56,
75). CONFIRMED: there is no path that writes a clean report when the scan did not
produce valid JSON.

> Downstream the collector treats "no file" as `unavailable` (exit 0), never as a
> pass. See the contract table below.

---

## 2. Collector contract cases (tasks 29-33)

The collector reads severities from `.dependencies[].vulnerabilities[].severity`,
upper-cases them (`ascii_upcase`), and counts CRITICAL / HIGH / MEDIUM into
`critical_vulnerabilities` / `high_vulnerabilities` / `medium_vulnerabilities`. Any
non-zero total → `fail`; zero → `pass`. Missing/empty input → `unavailable`
(exit 0); invalid JSON → exit 2 (via `ss_collector_guard`).

The captain's self-test asserts the following cases. Each row was verified by
running `scripts/collectors/dependency-check.sh --input <fixture>`:

| # | Fixture | Input shape | Expected mapping | Status | Exit |
|---|---------|-------------|------------------|--------|------|
| 29 | `critical.json` | one dep, one `"Critical"` vuln | `critical=1, high=0, medium=0` | `fail` | 0 |
| 30 | `high.json` | one dep, one `"High"` vuln | `critical=0, high=1, medium=0` | `fail` | 0 |
| 31 | (inline `medium`) | one dep, one `"medium"` vuln | `critical=0, high=0, medium=1` | `fail` | 0 |
| 32 | missing file | input path does not exist / empty | `status=unavailable` | `unavailable` | 0 |
| 33 | `malformed.json` | `{"dependencies":[` (truncated) | n/a — invalid JSON | error | **2** |
| — | `empty-deps.json` | `{"dependencies":[]}` | all counts 0 | `pass` | 0 |

Notes on the table:
- Severity matching is case-insensitive: the fixtures use mixed case (`"Critical"`,
  `"High"`) precisely to exercise the collector's `ascii_upcase`.
- `empty-deps.json` is the minimal valid clean shape and proves the `has("dependencies")`
  native branch with zero findings yields `pass`, not `unavailable`.
- There is no standalone `medium.json` fixture; the medium mapping is asserted with
  an inline document in the self-test. (Lane B was scoped to high/critical/empty/
  malformed fixtures.)

---

## 3. Severity mapping (task 34)

| Native DC severity (any case) | Sentinel Shield bucket |
|-------------------------------|------------------------|
| `CRITICAL` | `critical_vulnerabilities` |
| `HIGH` | `high_vulnerabilities` |
| `MEDIUM` | `medium_vulnerabilities` |
| `LOW` / `INFO` / unknown / missing | not counted (ignored) |

The collector (`scripts/collectors/dependency-check.sh`, line 18) builds the count
object directly from the native report:

```
.dependencies[]?.vulnerabilities[]?.severity // empty | ascii_upcase
```

then selects `=="CRITICAL"`, `=="HIGH"`, `=="MEDIUM"`. The collector also accepts a
pre-normalized `{critical, high, medium}` object via the `else` branch (used when an
upstream step already reduced the report). LOW/INFO severities are intentionally not
mapped to a gate bucket: Dependency-Check gating focuses on medium-and-above to
match the dependency policy and to avoid drowning the gate in informational CVEs.

---

## 4. Overlap with OSV / Trivy / Grype (task 35)

Dependency-Check, OSV-Scanner, Trivy, and Grype all consume overlapping CVE feeds
(NVD, GitHub Security Advisories, ecosystem advisories). The same CVE on the same
artifact can therefore appear in more than one tool's report. This is **expected and
not a bug** — the audit header states it explicitly (lines 11-12):

```
# Findings
# may DUPLICATE OSV/Trivy/Grype (overlapping CVE sources) — that is expected.
```

How they differ in practice:

| Tool | Primary strength | Speed | Typical lane |
|------|------------------|-------|--------------|
| OSV-Scanner | Lockfile-precise, ecosystem advisories | Fast | PR-fast |
| Trivy | Broad (OS packages + language deps + images) | Fast | PR-fast |
| Grype | SBOM/image-oriented matching | Fast | PR-fast / main |
| Dependency-Check | Deep evidence-based file inspection + full NVD | Slow | Scheduled / nightly |

Dependency-Check's value is depth: it inspects binary artifacts (e.g. bundled JARs)
by evidence rather than relying solely on declared manifests, so it can flag
transitively-bundled vulnerable components the lockfile scanners miss. The cost is
the full NVD dataset download and slow analysis, which is why it is not on the
PR-fast lane. Each collector emits into the same severity buckets, so the gate
naturally deduplicates by treating any failing source as a failure; duplicate CVEs
across tools do not double-count against a single gate decision because the gate
keys on the aggregate status, not a CVE union.

---

## 5. Why Dependency-Check is scheduled-only / never PR-fast (task 36)

From the audit header (lines 2-3):

```
# Sentinel Shield audit wrapper — OWASP Dependency-Check (v0.1.21). SLOW — scheduled/nightly
# (recommended) / main-gate (optional); NEVER PR-fast. Disabled by default.
```

Reasons:
1. **First-run NVD download is hundreds of MB and slow** (lines 10-11). A cold cache
   on a PR would add many minutes of latency to every push.
2. **Analysis itself is slow** — evidence-based inspection of every artifact is far
   heavier than lockfile parsing.
3. **It is disabled by default** (`SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=disabled`,
   wrapper line 24/56). It must be explicitly enabled, reinforcing that it is an
   opt-in deep lane, not a default fast check.
4. **Overlap** — fast lanes (OSV/Trivy/Grype) already cover the common CVE surface on
   PRs, so Dependency-Check's marginal coverage is best spent on a nightly/scheduled
   run with a warm cache rather than blocking developer iteration.

Recommended placement: scheduled/nightly with a persisted cache
(`actions/cache`, monthly key). See `docs/dependency-check-nightly-strategy.md`.

---

## 6. Troubleshooting

### 6.1 NVD API / timeout (task 37)

Symptoms: the audit logs `tool exited <rc> without valid JSON (timed out, NVD
download incomplete, or crashed)` and reports `unavailable`.

- **First-run download is slow.** The initial NVD pull is hundreds of MB. If the
  step times out before it completes, the cache is left incomplete and no report is
  written (correctly `unavailable`, never fake-clean). Re-run with a warm cache, or
  raise the step / `timeout` budget.
- **`SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT`** applies a foreground `timeout` cap
  only if the `timeout` binary is present; otherwise the wrapper logs that it is
  running without a cap (lines 47-54). On macOS install `coreutils` (`gtimeout`) or
  rely on the CI step timeout.
- **NVD rate limiting.** Without an NVD API key, the dataset fetch is throttled and
  can be very slow or fail. Provision an NVD API key for the scheduled job and pass
  it through to Dependency-Check's own NVD configuration to reduce timeouts. A
  throttled/failed download yields `unavailable`, not a clean pass.
- **Air-gapped / restricted egress.** If NVD endpoints are unreachable, pre-seed the
  cache out-of-band and mount it (see 6.2).

### 6.2 Cache (task 38)

The cache dir defaults to `.sentinel-shield/cache/dependency-check`
(`SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE`, wrapper lines 5/25). It is created with
`mkdir -p "$CACHE"` (line 57) and, in container mode, mounted to
`/usr/share/dependency-check/data` (line 72).

- **Cold cache every run.** If findings flip between runs or runs are unexpectedly
  slow, confirm the cache is actually persisted (e.g. `actions/cache` with a
  monthly key). A non-persisted cache means a full NVD re-download each time.
- **Corrupt / partial cache.** An interrupted first download can leave a partial
  dataset that makes later runs fail. Delete the cache dir and let it re-seed:
  `rm -rf .sentinel-shield/cache/dependency-check`.
- **Container mode permissions.** The cache is bind-mounted; ensure the host dir is
  writable by the container user, or the dataset cannot be written/updated.
- **Cache key.** Use a monthly rotation key so the NVD data refreshes regularly
  without re-downloading on every run. See `docs/dependency-check-nightly-strategy.md`.

### 6.3 Artifact preservation (task 39)

The wrapper's whole purpose is to preserve the raw report honestly:

- **Valid report kept on findings.** Even when Dependency-Check exits non-zero
  because it found vulnerabilities, the JSON at `reports/raw/dependency-check.json`
  is kept (wrapper lines 78-83). Upload it as a CI artifact so the collector and
  humans can inspect it.
- **No partial/empty artifact.** A partial/empty/invalid output is deleted
  (`discard_partial`, line 32/84) so a half-written file can never look clean. If
  you expected a report and got `unavailable`, the artifact was correctly
  discarded — check the NVD/timeout/cache items above for the root cause.
- **Collector input path.** The collector reads `reports/raw/dependency-check.json`
  by default (collector line 10) or `--input <path>`. Preserve that exact path
  between the audit and collector steps; if the artifact is missing/empty the
  collector reports `unavailable` (exit 0), and if it is present-but-invalid the
  collector exits 2 — so an upload/download that truncates the file will surface as
  a hard exit-2 error, not a silent pass.

---

## 7. Verification log

Commands run from the worktree root against the committed fixtures:

```
$ python3 -c "import json,glob;[json.load(open(f)) for f in glob.glob('tests/fixtures/dependency-check/*.json') if 'malformed' not in f];print('valid ok')"
valid ok

$ python3 -c "import json;json.load(open('tests/fixtures/dependency-check/malformed.json'))"
json.decoder.JSONDecodeError: Expecting value: line 2 column 1 (char 18)   # does NOT parse

$ sh scripts/collectors/dependency-check.sh --input tests/fixtures/dependency-check/critical.json
status=fail  critical=1 high=0 medium=0   (exit 0)

$ sh scripts/collectors/dependency-check.sh --input tests/fixtures/dependency-check/high.json
status=fail  critical=0 high=1 medium=0   (exit 0)

$ sh scripts/collectors/dependency-check.sh --input tests/fixtures/dependency-check/empty-deps.json
status=pass  critical=0 high=0 medium=0   (exit 0)

$ sh scripts/collectors/dependency-check.sh --input tests/fixtures/dependency-check/malformed.json
[sentinel-shield][error] dependency-check: invalid JSON in '...malformed.json'   (exit 2)
```
