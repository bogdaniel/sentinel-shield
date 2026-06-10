# DAST ZAP Controlled-Pilot Readiness (v0.1.24)

> **Status: PREPARATION ONLY.** OWASP ZAP (baseline / passive and full / active) is `manual`
> and has **never been live-run** against a target. This document is the ZAP-specific
> readiness companion to [`docs/dast-pilot-readiness.md`](dast-pilot-readiness.md). It does
> **not** enable DAST, weaken any gate, or authorize a scan. DAST is **never enabled by
> default and never scans arbitrary targets.** No scan may run until the checklist (§13) is
> satisfied and an approval is recorded.

This lane (Agent F, tasks 101–120) supplies the ZAP fixtures
([`tests/fixtures/dast/zap-baseline.json`](../tests/fixtures/dast/zap-baseline.json),
[`tests/fixtures/dast/zap-full.json`](../tests/fixtures/dast/zap-full.json)) and this doc.
Nuclei is out of scope here (Lane G).

Source of truth referenced below:

- Guard: [`scripts/runners/dast-guard.sh`](../scripts/runners/dast-guard.sh)
- Runners: [`scripts/runners/zap-baseline.sh`](../scripts/runners/zap-baseline.sh),
  [`scripts/runners/zap-full.sh`](../scripts/runners/zap-full.sh)
- Collector: [`scripts/collectors/zap.sh`](../scripts/collectors/zap.sh)

---

## §1 (Tasks 101–105). Guard review — the guard rejects unsafe targets, fail-closed

The runners source `dast-guard.sh` and call `ss_dast_check`; baseline/full both treat the
return code as: `10` → clean SKIP (exit 0, no scan); any other non-zero → propagate (fail
closed, no scan). The guard's environment variables are exactly:

- `SENTINEL_SHIELD_DAST_TARGET_URL` — the target URL; **absent → skip**.
- `SENTINEL_SHIELD_DAST_ALLOWED_HOST` — the required allowlist; the target host must equal it.

The guard's four return codes, quoted from `dast-guard.sh`:

| # | Condition | Guard behavior | Runner result |
|---|-----------|----------------|---------------|
| 101 | **No target** (`SENTINEL_SHIELD_DAST_TARGET_URL` unset/empty) | `"...TARGET_URL not set; SKIPPING DAST (no scan run)." ... return 10` | runner exits `0` — clean SKIP |
| 102 | **Non-http(s) scheme** | `case "$_url" in http://*|https://*) : ;; *) ... "target URL must start with http:// or https:// — refusing." ... return 3 ;;` | runner exits `3` — fail closed |
| 103 | **No allowlist** (`SENTINEL_SHIELD_DAST_ALLOWED_HOST` unset/empty) | `"...ALLOWED_HOST not set; FAIL CLOSED (refusing to scan an un-allowlisted target)." ... return 3` | runner exits `3` — fail closed |
| 104 | **Host mismatch** (target host ≠ allowed host) | `"...target host '$_host' is not the allowed host '$_allow'; FAIL CLOSED (no scan)." ... return 3` | runner exits `3` — fail closed |
| 105 | **Matching pair** (target host == allowed host, http/https) | `"...target host '$_host' allowlisted; proceeding." ... return 0` | runner proceeds (scan only if ZAP present) |

`ss_dast_host_of` strips scheme, path, query, and port before comparison, and the comparison
is **exact equality** — a subdomain of the allowed host (e.g. `api.staging.example.test` vs
`staging.example.test`) is a mismatch and fails closed. **There is no code path that scans a
host that is not exactly the operator-supplied, allowlisted host.**

Runner dispatch logic (both `zap-baseline.sh` and `zap-full.sh`):

```sh
rc=0; ss_dast_check || rc=$?
[ "$rc" -eq 10 ] && exit 0      # no target -> skip cleanly
[ "$rc" -ne 0 ] && exit "$rc"   # allowlist violation -> fail closed
```

**Conclusion (101–105): confirmed.** Missing-target → SKIP (rc 10 / exit 0). Non-http,
no-allowlist, and host-mismatch → fail closed (rc 3 / exit 3). The matching pair is the only
path that proceeds.

---

## §2 (Tasks 106–107). ZAP raw report paths

| Scan | Type | Runner | Raw report path |
|------|------|--------|-----------------|
| 106 ZAP baseline | passive | `scripts/runners/zap-baseline.sh` (`zap-baseline.py -t <target> -J <out>`) | `reports/raw/zap.json` |
| 107 ZAP full | active | `scripts/runners/zap-full.sh` (`zap-full-scan.py -t <target> -J <out>`) | `reports/raw/zap-full.json` |

If ZAP is not installed locally, the runner emits nothing and exits `0` (no faked scan); the
collector then reports the tool as `unavailable`. Live scans run via the
`sentinel-shield-dast.yml` workflow (zaproxy container), `workflow_dispatch` only.

---

## §3 (Task 108). ZAP-full EXPLICIT-INPUT GAP

The `zap` collector (`scripts/collectors/zap.sh`) has a single hardcoded default input:

```sh
INPUT="reports/raw/zap.json"
```

So invoking the collector **with no `--input`** collects only the **baseline** report. The
**full** scan writes to `reports/raw/zap-full.json`, which the default never reads. To collect
the full report you **must** pass it explicitly:

```sh
# baseline (default — collects reports/raw/zap.json)
scripts/collectors/zap.sh

# full (active) — MUST override the input, or the full report is silently ignored
scripts/collectors/zap.sh --input reports/raw/zap-full.json
```

**Why this matters:** without the explicit `--input`, a full-scan pipeline would either
re-collect a stale/absent `zap.json` (reporting `unavailable` or the wrong count) and the
`zap-full.json` findings would never reach the `dast_findings` summary key. This is a
*pipeline-wiring* gap, not a guard/safety gap.

**Recommendation for the captain:** wire a self-test that asserts the full report is collected
via the explicit input — e.g. run
`scripts/collectors/zap.sh --input tests/fixtures/dast/zap-full.json` and assert
`dast_findings == 2`. A baseline self-test should run
`scripts/collectors/zap.sh --input tests/fixtures/dast/zap-baseline.json` and assert
`dast_findings == 1`. The full-scan self-test specifically guards against the default-input
trap: it must use `--input reports/raw/zap-full.json` (or the fixture), never the bare default.

---

## §4 (Tasks 111–112). Collector test expectations

The `zap` collector counts ZAP alerts with **`riskcode >= 2`** (Medium/High; Low=1 and
Informational=0 are excluded), maps the count to `dast_findings`, and sets `status=fail` when
`dast_findings > 0`, else `pass`.

### 111 — baseline fixture (`tests/fixtures/dast/zap-baseline.json`)

- Contents: one alert `riskcode: "3"` (counted) + one alert `riskcode: "1"` (excluded).
- Expectation: **`dast_findings == 1`**, `status == fail`.
- Invocation: `scripts/collectors/zap.sh --input tests/fixtures/dast/zap-baseline.json`

### 112 — full fixture (`tests/fixtures/dast/zap-full.json`)

- Contents: two high-risk alerts `riskcode: "3"` and `riskcode: "2"` (both counted) + one
  `riskcode: "1"` and one `riskcode: "0"` (both excluded).
- Expectation: **`dast_findings == 2`**, `status == fail`.
- Invocation: `scripts/collectors/zap.sh --input tests/fixtures/dast/zap-full.json`
  (note the explicit `--input` per §3).

Both fixtures are valid ZAP JSON of shape
`{ "site": [ { "alerts": [ { "riskcode": "…" }, … ] } ] }`. Validated counts: baseline = 1,
full = 2 (see §14).

---

## §5 (Task 113). ZAP pilot CHECKLIST

All boxes must be checked **before** any ZAP scan is dispatched. Record evidence (links,
ticket IDs, signatures) alongside the approval form.

- [ ] **Approval recorded.** A completed DAST scan approval exists, with requester, target,
      allowed host, approver, and expiry.
- [ ] **Staging-only target.** The target is a staging / pre-prod environment you own — never
      production (§6).
- [ ] **Allowlist host set.** `SENTINEL_SHIELD_DAST_ALLOWED_HOST` equals the exact host of
      `SENTINEL_SHIELD_DAST_TARGET_URL`.
- [ ] **Scheme is http/https.** The target URL begins with `http://` or `https://`.
- [ ] **Auth boundary defined.** Scoped staging-only test account; no production credentials;
      blast radius documented (§7).
- [ ] **Active-scan sign-off.** For `zap-full` (active, sends attack payloads), explicit owner
      sign-off is on the approval form.
- [ ] **Output paths confirmed.** Baseline → `reports/raw/zap.json`; full →
      `reports/raw/zap-full.json`; collector invoked with the correct `--input` (§3).
- [ ] **Guard behavior observed.** Matching pair proceeds; missing-target SKIPs (exit 0);
      non-http / no-allowlist / mismatch fail closed (exit 3).
- [ ] **Evidence retention.** Raw report archived; workflow artifact `sentinel-shield-dast`
      (retention 30 days) retained for the maturity citation.

---

## §6 (Task 114). Staging target policy

- The allowlisted host (`SENTINEL_SHIELD_DAST_ALLOWED_HOST`) **must** be a staging / pre-prod
  host you own and control. Production is out of scope for the pilot.
- The `Environment` field on the approval form must read `staging` (or `pre-prod` with
  sign-off) — **never** `production`.
- Third-party hosts and hosts you do not own are never valid targets, regardless of allowlist.
- Active (`zap-full`) scans run only where data loss / state mutation is acceptable and
  recoverable — i.e. a disposable staging environment, never a shared or production-like one
  carrying real data.

---

## §7 (Task 115). Auth boundary policy

- **Never scan production.** The target host must be a staging / pre-prod system you own.
- **Never use production credentials.** Use a **scoped staging test account** provisioned only
  for the scan, with least privilege and no access to real customer data. Rotate or disable the
  account after the pilot.
- **Document the account.** Record which account is used, what it can reach, and its blast
  radius on the approval form.
- **No destructive payloads without sign-off.** `zap-full` is an **active** scan (it sends
  attack payloads). Active scans require explicit owner sign-off before dispatch and run only
  against a staging target where state mutation is acceptable and recoverable. The passive
  `zap-baseline` does not send attack payloads but still requires an allowlisted staging target.

---

## §8 (Task 116). Target allowlist examples

The guard derives the host from `SENTINEL_SHIELD_DAST_TARGET_URL` (strips scheme, path, query,
port) and compares it for **exact equality** against `SENTINEL_SHIELD_DAST_ALLOWED_HOST`.

**Matching pair — proceeds (guard returns 0):**

```sh
SENTINEL_SHIELD_DAST_TARGET_URL="https://staging.example.test/app?x=1"
SENTINEL_SHIELD_DAST_ALLOWED_HOST="staging.example.test"
# host-of(target) = "staging.example.test" == allowed host  -> return 0, scan proceeds
```

**Mismatching pair — FAILS CLOSED (guard returns 3, exit 3, no scan):**

```sh
SENTINEL_SHIELD_DAST_TARGET_URL="https://prod.example.test/app"
SENTINEL_SHIELD_DAST_ALLOWED_HOST="staging.example.test"
# host-of(target) = "prod.example.test" != "staging.example.test"  -> return 3, FAIL CLOSED
```

Other fail-closed cases: a subdomain that is not exactly the allowed host
(`api.staging.example.test` vs `staging.example.test`), an empty
`SENTINEL_SHIELD_DAST_ALLOWED_HOST`, or a non-http(s) scheme.

---

## §9 (Task 117). Artifact expectations

- Both runners write JSON to `reports/raw/` (baseline → `zap.json`, full → `zap-full.json`).
- The `sentinel-shield-dast.yml` workflow uploads `reports/**` as the `sentinel-shield-dast`
  artifact (`retention-days: 30`, `if-no-files-found: warn`).
- If ZAP is **absent**, the runner emits nothing and exits 0 (no faked scan); the collector
  reports `status=unavailable` and emits `{"status":"unavailable"}` with no `dast_findings`
  overlay.
- The collector maps the alert count to the single `dast_findings` summary key and emits an
  overlay `{ "dast_findings": <n> }` that the summary builder folds into the security summary.

---

## §10 (Task 118). Failure interpretation guide

| Observed | Meaning | Action |
|----------|---------|--------|
| Runner exits `0`, log `SKIPPING DAST` | No target set — guard returned 10 | Expected when DAST is off; set target + allowlist to run |
| Runner exits `3`, log `must start with http://` | Non-http(s) scheme | Fix the target URL scheme |
| Runner exits `3`, log `ALLOWED_HOST not set` | No allowlist | Set `SENTINEL_SHIELD_DAST_ALLOWED_HOST` to the exact target host |
| Runner exits `3`, log `not the allowed host` | Host mismatch | Target host ≠ allowlist; this is fail-closed by design, not a bug |
| Runner exits `0`, log `ZAP not installed locally` | ZAP binary absent | Run via the `sentinel-shield-dast.yml` workflow (zaproxy container) |
| Collector `status=unavailable` | Input report missing/empty | Confirm the scan ran and wrote to the expected path; check `--input` (§3) |
| Collector exits `2`, `invalid JSON` | Report is not valid JSON | Re-run the scan; do not hand-edit the report |
| Collector `dast_findings == 0`, `status=pass` | No alerts with `riskcode >= 2` | Pass (no Medium/High findings); Low/Info are excluded by design |
| Collector `dast_findings > 0`, `status=fail` | Medium/High alerts found | Triage the ZAP report; findings are gating only in regulated mode (§12) |

A fail-closed exit 3 is a **safety success**, not an error — it means the guard refused an
un-allowlisted or malformed target.

---

## §11 (Task 119). "Never PR-fast" rule

ZAP DAST is **never** wired into the PR-fast path (or any default PR check). It is not a
`push` / `pull_request` / `schedule` trigger — `sentinel-shield-dast.yml` is
`workflow_dispatch` only, started manually with explicit `target_url` + `allowed_host` inputs.
PR-fast must stay fast and side-effect-free; ZAP (especially the active full scan) sends
network traffic / attack payloads to a live target and can take many minutes, so it is
operator-triggered only and never on the PR critical path. Nothing in this pilot changes that.

---

## §12 (Task 120). Regulated-mode future-gate criteria

`dast_findings` is gated **only in `regulated` mode**, and **only if** a target + allowlist +
approval are configured (`dast_findings: false` by default in the profile). ZAP DAST may be
promoted to a regulated-mode gate **only after**:

1. A controlled pilot (the §5 checklist) has been completed against a staging target.
2. The pilot produced **cited, real evidence** — an actual `reports/raw/zap.json` and/or
   `reports/raw/zap-full.json` from a live run, with the `dast_findings` count it yielded — not
   a synthetic or assumed result. (The fixtures here are for self-tests only; they are **not**
   pilot evidence.)
3. The guard's fail-closed and skip behaviors were observed in practice (matching pair runs;
   missing-target SKIPs; mismatch / non-http / no-allowlist fail closed).
4. The collector's `--input` wiring for the full report (§3) was exercised and asserted.
5. The maturity promotion is recorded with that citation, consistent with how other tools are
   promoted only on cited live evidence.

Until then ZAP DAST stays `manual` / non-gating. The only honest claim today is: "manual,
fail-closed guard verified, never live-run."

---

## §13 Summary of guardrails (honesty)

- DAST is **never enabled by default** and **never scans arbitrary targets**.
- Missing target → SKIP (exit 0). Non-http / no-allowlist / host-mismatch → fail closed
  (exit 3). Matching allowlisted staging host → proceed (scan only if ZAP present).
- ZAP full is an **active** scan and requires explicit sign-off.
- ZAP DAST is `workflow_dispatch`-only and never on the PR-fast path.

---

## §14 Validation evidence

Collector run in this worktree against the two fixtures:

```
$ scripts/collectors/zap.sh --input tests/fixtures/dast/zap-baseline.json
  -> "dast_findings": 1, "status": "fail"

$ scripts/collectors/zap.sh --input tests/fixtures/dast/zap-full.json
  -> "dast_findings": 2, "status": "fail"
```

Both fixtures are valid JSON (verified with `jq -e .`).
