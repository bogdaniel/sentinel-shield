# ZAP collector fix — full-report input gap (v0.1.25)

## The fix (141–143)

Before v0.1.25 the `zap` collector hardcoded its default input as
`reports/raw/zap.json`. A ZAP **FULL** (active) report written by
`scripts/runners/zap-full.sh` lands at `reports/raw/zap-full.json`, so it was
**never collected** unless `--input` was passed explicitly, and even then it was
labelled under the generic `zap` tool — indistinguishable from a baseline scan.

`scripts/collectors/zap.sh` now:

- keeps `--input` working, with the **unchanged** default
  `reports/raw/zap.json` (baseline behavior preserved);
- adds an optional `--report-kind baseline|full` flag;
- **auto-detects** the report kind from the input basename: if the basename
  contains `zap-full`, the kind resolves to `full`;
- derives a **distinct tool label** from the kind — a full report maps to
  `dast_findings` under the tool name **`zap-full`** (baseline stays `zap`);
- still honours an explicit `--tool-name` (it wins over the derived label).

`scripts/runners/zap-full.sh` already writes `reports/raw/zap-full.json` (its
default `OUT`); its header now documents the exact matching collector
invocation. No counting logic changed: the collector still counts ZAP alerts
with `riskcode >= 2` (High/Medium), so existing baseline self-tests stay green.

### Resolution precedence

1. `--tool-name <name>` — explicit, always wins for the label.
2. `--report-kind baseline|full` — explicit kind; derives `zap`/`zap-full`.
3. Auto-detect from input basename (`*zap-full*` → full).
4. Default → baseline (`zap`).

## Collector invocations (147–148)

Baseline (passive) — default input, no flags needed:

```sh
scripts/collectors/zap.sh                                   # reads reports/raw/zap.json, tool=zap
scripts/collectors/zap.sh --input reports/raw/zap.json      # explicit, identical
```

Full (active) — point `--input` at the full report; label auto-promotes to
`zap-full`:

```sh
scripts/collectors/zap.sh --input reports/raw/zap-full.json          # auto-detected -> tool=zap-full
scripts/collectors/zap.sh --input reports/raw/zap-full.json --report-kind full   # explicit, identical
```

The runner `scripts/runners/zap-full.sh` writes `reports/raw/zap-full.json`, so
the canonical pipeline is: run `zap-full.sh`, then collect with
`scripts/collectors/zap.sh --input reports/raw/zap-full.json`.

## Missing report → unavailable (149)

If the input file is missing or empty, `ss_collector_guard` emits a canonical
collector object with `status: "unavailable"` and **exits 0** (the scan simply
did not run; this is not a failure). This holds for both baseline and full
inputs — a ZAP that is not installed locally produces no report, and the
collector reports `unavailable` rather than failing the build.

## Invalid JSON → exit 2 (150)

If the input file exists but is not valid JSON, the collector logs an error and
**exits 2** (fail-closed). A malformed `zap-full.json` is treated identically to
a malformed `zap.json`. A bad `--report-kind` value (anything other than
`baseline`/`full`) also exits 2.

## DAST guard behavior (151)

The runners source `scripts/runners/dast-guard.sh` (owned by Lane I — not
modified here). The guard enforces, before any scan:

- `SENTINEL_SHIELD_DAST_TARGET_URL` unset → **SKIP** (exit 10 in the guard;
  runner exits 0, nothing scanned).
- target URL not `http(s)://` → **FAIL CLOSED** (exit 3).
- `SENTINEL_SHIELD_DAST_ALLOWED_HOST` unset → **FAIL CLOSED** (exit 3).
- target host ≠ allowed host → **FAIL CLOSED** (exit 3).

ZAP never scans an arbitrary or un-allowlisted target.

## ZAP baseline docs (152)

`scripts/runners/zap-baseline.sh` runs the OWASP ZAP **baseline (passive)** scan
(`zap-baseline.py`) against the allowlisted staging target, writing
`reports/raw/zap.json`. Passive scanning only observes traffic; it does not send
attack payloads. Collected as tool `zap`.

## ZAP full docs (153)

`scripts/runners/zap-full.sh` runs the OWASP ZAP **FULL (active)** scan
(`zap-full-scan.py`) against the allowlisted staging target, writing
`reports/raw/zap-full.json`. Active scanning sends attack payloads and is
CONTROLLED/MANUAL only. Collected as tool `zap-full`.

## Artifact contract (154)

- Baseline runner → `reports/raw/zap.json` → collector tool `zap`.
- Full runner → `reports/raw/zap-full.json` → collector tool `zap-full`.
- Collector output: canonical object with all summary count keys zeroed and
  `dast_findings` set to the count of alerts with `riskcode >= 2`.
- `status`: `pass` (0 findings), `fail` (>0 findings), or `unavailable`
  (missing/empty input).
- If neither tool is installed, no report is written; the collector reports
  `unavailable`. Output is **never** faked.

## Staging-target policy (155)

DAST runs **only** against a deliberately provisioned staging target. The target
is supplied via `SENTINEL_SHIELD_DAST_TARGET_URL` and must match
`SENTINEL_SHIELD_DAST_ALLOWED_HOST`. Production and arbitrary hosts are out of
scope and fail closed.

## Auth-boundary policy (156)

The staging target must be isolated behind its own auth boundary (no shared
prod credentials, no shared data store). Active scanning can mutate state, so it
runs only where that state is disposable and the blast radius is contained to
staging.

## False-positive triage (157)

ZAP alerts (especially active-scan findings) require human triage before they
gate a release. The collector counts `riskcode >= 2` alerts mechanically;
confirmed false positives should be suppressed via ZAP's context/alert-filter
configuration (not by editing the collector). Triaged-away alerts then drop out
of the report and out of `dast_findings`.

## Regulated future-gate (158)

DAST `dast_findings` is **manual / advisory** today. In a future regulated
profile it may become a hard gate (release-blocking on confirmed findings). That
promotion is out of scope for v0.1.25 and must be wired deliberately, not
inferred — DAST stays fail-closed and manual until then.

## ZAP stays manual / never arbitrary target (159–160)

ZAP (baseline and full) is **manual / controlled** by design. It is never
invoked automatically against an arbitrary target. The DAST guard refuses to
scan anything that is not an explicitly allowlisted staging host, and the
runners fake nothing when ZAP is absent. This fix changes only how the *full
report is collected and labelled* — it does not relax the manual / allowlist
posture in any way.

## Self-tests for the captain to wire

The captain should wire these collector self-tests against
`tests/fixtures/dast-v025/`:

- `zap-baseline.json` via default-style input → `dast_findings == 1` (tool `zap`).
- `zap-full.json` via `--input` (auto-detected) → `dast_findings == 2`
  (tool `zap-full`).
- `zap-mixed.json` (riskcodes 3,2,1,0) → `dast_findings == 2`.

Example:

```sh
sh scripts/collectors/zap.sh --input tests/fixtures/dast-v025/zap-baseline.json | jq '.summary.dast_findings'  # 1
sh scripts/collectors/zap.sh --input tests/fixtures/dast-v025/zap-full.json     | jq '.summary.dast_findings'  # 2
sh scripts/collectors/zap.sh --input tests/fixtures/dast-v025/zap-mixed.json    | jq '.summary.dast_findings'  # 2
```
