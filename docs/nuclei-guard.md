# Nuclei Controlled Template-Path Guard (v0.1.25)

> Status: **CONTROLLED / MANUAL-ONLY.** Nuclei is never part of the default PR or main
> gates. This document records the v0.1.25 (Lane I, items 161-180) work that turns the
> previously process-only "controlled template path" expectation into a **code-enforced**
> guard, complementing the host/target safety guard documented in
> [`nuclei-readiness.md`](./nuclei-readiness.md).

## What changed vs. v0.1.24 readiness

In v0.1.24 (`nuclei-readiness.md`, items 127-128) the template-path control was flagged as
a **future** hardening — process/approval-governed, not code-enforced. v0.1.25 closes that
gap: `scripts/runners/dast-guard.sh` now ships a new POSIX-sh function
`ss_nuclei_template_check`, and `scripts/runners/nuclei.sh` calls it (in addition to the
existing `ss_dast_check`) before any scan, forwarding the allowlisted templates via
`-t "$SENTINEL_SHIELD_NUCLEI_TEMPLATES"`.

`ss_dast_check` is unchanged; the ZAP runners that depend on it are unaffected. The
template guard is a **separate** function by design.

## 172 — Controlled template policy

A controlled Nuclei run MUST point at a **curated, version-controlled template set** —
never the full upstream template registry and never an operator-supplied arbitrary path.
The curated set is selected via the required env var:

```
SENTINEL_SHIELD_NUCLEI_TEMPLATES=<path to curated template dir or file>
```

`ss_nuclei_template_check` enforces, in order (fail closed → `return 3`):

1. **Missing path** — `SENTINEL_SHIELD_NUCLEI_TEMPLATES` unset/empty → `3`.
2. **Path traversal** — any `..` in the path → `3`.
3. **Remote source** — `http://`, `https://`, or `git@` prefix → `3`, **unless**
   `SENTINEL_SHIELD_NUCLEI_ALLOW_REMOTE=1` is explicitly set (then it is allowed).
4. **Absent on disk** — a local path that does not exist (`! -e`) → `3`.

Only a local, non-traversing, existing path (or an explicitly-allowed remote URL) returns
`0`. Host/target safety (no-target → skip/`10`; non-http(s) / no-allowlist / host-mismatch
→ `3`) is still enforced first by `ss_dast_check` in `nuclei.sh` — items 166/167.

## 173 — Allowlist documentation

Two independent allowlists govern a controlled run; both must pass:

| Allowlist | Env var | Enforced by | Failure |
|---|---|---|---|
| Target **host** | `SENTINEL_SHIELD_DAST_ALLOWED_HOST` | `ss_dast_check` | `3` (mismatch / unset) |
| **Template** path | `SENTINEL_SHIELD_NUCLEI_TEMPLATES` | `ss_nuclei_template_check` | `3` (missing/traversal/remote/absent) |

Curated templates SHOULD live in a reviewed, version-controlled directory (e.g. a vetted
subset checked into the security repo). Remote template sources are denied by default;
fetching from a remote registry requires the explicit
`SENTINEL_SHIELD_NUCLEI_ALLOW_REMOTE=1` opt-in plus the same signed approval as any other
controlled run. See `templates/nuclei-target-allowlist.md` for the host allowlist rows.

## 174 — Severity mapping

Unchanged from the collector contract (`scripts/collectors/nuclei.sh`):

| Nuclei `info.severity` | Counted as `dast_findings`? |
|---|---|
| critical | yes |
| high | yes |
| medium | yes |
| low | no |
| info | no |
| unknown / missing | treated as `info` → no |

The runner scopes live scans to `-severity medium,high,critical`; the collector counts the
same three. The fixture `tests/fixtures/dast-v025/nuclei.json`
(`[{"info":{"severity":"high"}},{"info":{"severity":"info"}}]`) yields `dast_findings: 1`
(the `high` entry counts; `info` does not).

## 175 — False-positive triage

1. Inspect `reports/raw/nuclei.json`; identify the template id/matcher behind each counted
   finding.
2. Reproduce manually against the allowlisted staging host with the **same curated
   template path**.
3. Confirmed false positive → record it in the DAST exception/approval notes with the
   template id and an expiry; do not silently drop. Re-run to confirm the count drops.
4. Confirmed true positive → file a remediation ticket; the gate stays red until fixed or a
   time-boxed, approved exception is recorded.
5. If a finding traces to a template **outside** the curated set, that is a process error —
   tighten `SENTINEL_SHIELD_NUCLEI_TEMPLATES`, do not broaden the allowlist to match.

## 176 — Runtime budget

Nuclei runs are out-of-band (manual), so they do not count against PR/main gate latency.
A curated template set materially bounds runtime versus the full registry; combined with a
single allowlisted host and the `medium,high,critical` severity scope, the scan stays
modest. Abort and re-scope if it overruns the approved window.

## 177 — Approval template note

Every controlled run still requires a completed, signed, unexpired
`templates/dast-scan-approval.md` (requester, scan type `nuclei`, target URL, exact allowed
host, staging confirmation, auth boundary, window, approver sign-off, expiry). v0.1.25 adds
one field to capture in the approval: the **curated template path / set** passed via
`SENTINEL_SHIELD_NUCLEI_TEMPLATES` (and, if `SENTINEL_SHIELD_NUCLEI_ALLOW_REMOTE=1` is
used, the remote source and the reason it was permitted).

## 178 — Manual-only

Nuclei is **manual-only**. It is never wired into `sentinel-shield-pr-fast.yml` or
`sentinel-shield-main.yml`. It runs solely through the `workflow_dispatch`-only
`sentinel-shield-dast.yml` (and, opt-in, the scheduled workflow only when a DAST target,
host allowlist, **and** curated template path are explicitly configured for staging). No
automatic, push-triggered, or PR-triggered Nuclei runs exist.

## 179 — Not in default gates

The default PR-fast and main gates do not reference Nuclei. A workflow-sanity check should
assert `grep -i nuclei templates/workflows/sentinel-shield-pr-fast.yml
templates/workflows/sentinel-shield-main.yml` returns no matches. The template-path guard
does not change this: it constrains *how* a controlled run scopes templates, not *whether*
Nuclei is gated (it is not).

## Self-tests the captain should wire

The runner and guard are deterministic and unit-testable **without a live Nuclei run**
(Nuclei is never executed live — item 180). Suggested cases:

| Case | Setup | Expected |
|---|---|---|
| Missing template | `SENTINEL_SHIELD_NUCLEI_TEMPLATES` unset | `ss_nuclei_template_check` → `3` |
| Path traversal | `SENTINEL_SHIELD_NUCLEI_TEMPLATES=../etc` | `ss_nuclei_template_check` → `3` |
| Remote (denied) | `SENTINEL_SHIELD_NUCLEI_TEMPLATES=https://x` | `ss_nuclei_template_check` → `3` |
| Remote (allowed) | same + `SENTINEL_SHIELD_NUCLEI_ALLOW_REMOTE=1` | `ss_nuclei_template_check` → `0` |
| Real dir | `SENTINEL_SHIELD_NUCLEI_TEMPLATES=<existing dir>` | `ss_nuclei_template_check` → `0` |
| Host mismatch | target host != `SENTINEL_SHIELD_DAST_ALLOWED_HOST` | `ss_dast_check` → `3` (unchanged) |
| Non-http target | `SENTINEL_SHIELD_DAST_TARGET_URL=ftp://x` | `ss_dast_check` → `3` (unchanged) |
| No target | `SENTINEL_SHIELD_DAST_TARGET_URL` unset | `ss_dast_check` → `10` → runner `exit 0` (unchanged) |

The collector on `tests/fixtures/dast-v025/nuclei.json` must emit `dast_findings: 1`.
