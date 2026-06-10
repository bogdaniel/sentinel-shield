# Nuclei Controlled-Scan Readiness

> Status: **CONTROLLED / MANUAL-ONLY.** Nuclei is never part of the default PR or main
> gates. It runs only via the manual, `workflow_dispatch`-triggered
> `templates/workflows/sentinel-shield-dast.yml`, against an explicitly allowlisted
> staging host, after a signed approval. This document records the v0.1.24 readiness
> review (Lane G, items 121-140).

## 121-124 — Runner safety review (controlled run required)

`scripts/runners/nuclei.sh` sources `scripts/runners/dast-guard.sh` and calls
`ss_dast_check` **before** any scan. The guard enforces, in order:

1. **No target URL → SKIP.** If `SENTINEL_SHIELD_DAST_TARGET_URL` is unset, the guard
   returns `10`; the runner treats that as a clean skip (`exit 0`) and runs nothing.
2. **Non-http(s) target → REJECT.** A target not matching `http://*` or `https://*`
   returns `3` (fail closed). The runner propagates that non-zero exit.
3. **Missing allowlist → FAIL CLOSED.** If `SENTINEL_SHIELD_DAST_ALLOWED_HOST` is unset,
   the guard returns `3` — it refuses to scan an un-allowlisted target.
4. **Host mismatch → FAIL CLOSED.** The host parsed from the target URL must equal the
   allowlisted host exactly, or the guard returns `3`.

Only after the guard passes does the runner check for the `nuclei` binary. If `nuclei`
is not installed locally it logs and exits `0` (no fake scan). When it does run, it
invokes:

```
nuclei -u "$SENTINEL_SHIELD_DAST_TARGET_URL" -jle "$OUT" -severity medium,high,critical
```

**Honest note on the "controlled template path" expectation.** The runner today scopes
the scan by a **fixed severity filter** (`medium,high,critical`) — it does **not** accept
or constrain an arbitrary `-t/-templates` path, and it does not pin a curated template
directory. So the *intended* control — "run Nuclei only against allowlisted hosts with a
curated template/severity scope" — is partially met:

- **Enforced today:** host allowlist (fail closed), http(s)-only target, and a fixed
  severity scope (`medium,high,critical`).
- **NOT enforced today:** there is no template-path guard. The runner neither requires a
  curated template set nor rejects an operator-supplied arbitrary template path (it
  simply never passes one). Template curation is currently a **process/manual control**,
  not a code-enforced one.

**Future hardening (flagged):** add a template-path guard to `nuclei.sh` so that, if a
template path is supplied, it must resolve under an approved curated directory
(reject otherwise, fail closed), mirroring the host allowlist model. Until then, template
scope is governed by the approval + allowlist process, not by the runner.

## 125 — Fixture

`tests/fixtures/dast/nuclei.json` is a valid Nuclei JSON array shaped to match
`scripts/collectors/nuclei.sh`:

```json
[{"info":{"severity":"high"}},{"info":{"severity":"info"}}]
```

## 126 — Collector test expectation

`scripts/collectors/nuclei.sh` counts array entries whose
`(.info.severity // .severity // "info")` is `critical`, `high`, or `medium`. `info`
(and `low`) are intentionally **not** counted. For the fixture above the collector emits
`dast_findings: 1` and `status: "fail"` (the `high` entry counts; the `info` entry does
not). Verified output:

```json
{"status":"fail","dast_findings":1}
```

## 127-129 — Guard/runner test expectations (enforced today vs future)

| # | Scenario | Input | Expectation | Status |
|---|---|---|---|---|
| 127 | Missing template path | (no template arg) | Runner uses fixed severity scope; **no** template-path guard exists, so this is not rejected. Documented as a future hardening, not a current failure mode. | **Future** (process-controlled) |
| 128 | Disallowed template path | arbitrary `-t` path | Should fail closed once a template-path guard is added. Today the runner never forwards an operator template path, so there is nothing to reject. | **Future** (not code-enforced) |
| 129 | Host mismatch | target host != `SENTINEL_SHIELD_DAST_ALLOWED_HOST` | `ss_dast_check` returns `3`; runner exits non-zero, no scan. | **Enforced today** |

Additional guard cases enforced today (regression-worthy): no-target → skip (`exit 0`);
non-http(s) target → `exit 3`; missing allowlist → `exit 3`.

## 130 — Approval template reference

Every controlled run requires a completed
[`templates/dast-scan-approval.md`](../templates/dast-scan-approval.md): requester, scan
type (`nuclei`), target URL, exact allowed host, staging confirmation, auth boundary,
window, approver sign-off, and approval expiry. Nuclei scans require explicit approver
sign-off.

## 131 — Target allowlist example

See [`templates/nuclei-target-allowlist.md`](../templates/nuclei-target-allowlist.md).
The host listed there is what you pass as `SENTINEL_SHIELD_DAST_ALLOWED_HOST`; the runner
fails closed if the target host is not exactly one of those rows. Example row:

| Host | Environment | Owner | Approved until | Notes |
|---|---|---|---|---|
| staging.example.com | staging | sec-team | 2026-12-31 | scoped templates: medium,high,critical only |

Never list production or third-party hosts you do not own.

## 132 — Severity mapping

| Nuclei `info.severity` | Counted as `dast_findings`? |
|---|---|
| critical | yes |
| high | yes |
| medium | yes |
| low | no |
| info | no |
| unknown / missing | treated as `info` → no |

The collector also tolerates `{"findings":[...]}` and a top-level `.severity` fallback.
Any non-counted finding still appears in the raw report for triage but does not fail the
gate.

## 133 — False-positive triage

1. Inspect `reports/raw/nuclei.json` and identify the template id/matcher behind each
   counted finding.
2. Reproduce manually against the allowlisted staging host.
3. If confirmed false positive: record it in the DAST exception/approval notes with a
   template id and expiry; do not silently drop. Re-run to confirm the count drops.
4. If confirmed true positive: file a remediation ticket; the gate stays red until fixed
   or a time-boxed, approved exception is recorded.

## 134 — Manual-only policy

Nuclei is **manual-only**. It is never wired into `sentinel-shield-pr-fast.yml` or
`sentinel-shield-main.yml`. It runs solely through the `workflow_dispatch`-only
`sentinel-shield-dast.yml` (and, opt-in, the scheduled workflow only when a DAST target +
allowlist are explicitly configured for staging). No automatic, push-triggered, or
PR-triggered Nuclei runs exist.

## 135 — Regulated-mode criteria

In regulated mode a Nuclei run is permitted only when **all** hold: (a) a signed,
unexpired `dast-scan-approval.md`; (b) the target host is in
`nuclei-target-allowlist.md` and matches `SENTINEL_SHIELD_DAST_ALLOWED_HOST` exactly;
(c) target is staging/pre-prod that the org owns (not production); (d) scoped to
`medium,high,critical` severities; (e) within the approved window; (f) artifacts retained
for audit (see 136). Any missing criterion → do not run.

## 136 — Artifact expectations

- `reports/raw/nuclei.json` — raw Nuclei JSONL/JSON output.
- Collector summary JSON with `dast_findings` (consumed by the aggregator).
- The completed approval record and the relevant allowlist row at scan time.
- Retain per the audit/retention policy in regulated mode.

## 137 — Runtime budget

Nuclei runs are out-of-band (manual), so they do not count against PR/main gate latency.
Budget the scan itself to a bounded window (scoped severity + single allowlisted host
keeps it modest); abort and re-scope if it materially overruns the approved window.

## 138 — Rollback guidance

Nuclei is read-only/observational against the target and adds no merge gate, so "rollback"
is operational: cancel the `workflow_dispatch` run, remove or expire the allowlist row to
prevent re-runs, and void the approval. No code rollback is required to disable Nuclei
because it is opt-in by construction.

## 139 — Workflow-sanity expectation

A workflow-sanity check should assert that **no default gate workflow references
nuclei**: `grep -i nuclei templates/workflows/sentinel-shield-pr-fast.yml
templates/workflows/sentinel-shield-main.yml` must return **no matches** (exit 1).

## 140 — Confirmation: Nuclei absent from default gates

Verified on this branch:

- `grep -ni nuclei templates/workflows/sentinel-shield-pr-fast.yml` → no matches.
- `grep -ni nuclei templates/workflows/sentinel-shield-main.yml` → no matches.
- Nuclei appears only in `sentinel-shield-dast.yml` (`workflow_dispatch` only) and as an
  opt-in branch of `sentinel-shield-scheduled.yml`.

Nuclei is confirmed **absent from the default PR-fast and main gates.**
