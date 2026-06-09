# DAST Controlled-Pilot Readiness (v0.1.23)

> **Status: PREPARATION ONLY.** Per [`docs/product-status.md`](product-status.md), DAST
> (OWASP ZAP baseline/full, Nuclei) is `manual` and has **never been live-run** against a
> target. This document prepares a *controlled pilot* — it does **not** enable DAST, weaken
> any gate, or authorize a scan. No scan may run until the checklist below is satisfied and an
> approval ([`templates/dast-scan-approval.md`](../templates/dast-scan-approval.md)) is
> recorded.

See also: [`docs/dast-policy.md`](dast-policy.md),
[`templates/workflows/sentinel-shield-dast.yml`](../templates/workflows/sentinel-shield-dast.yml),
[`templates/nuclei-target-allowlist.md`](../templates/nuclei-target-allowlist.md),
[`docs/regulated-mode-readiness.md`](regulated-mode-readiness.md).

---

## 1. DAST is NEVER run by default

DAST is not a PR check and not part of any default gate. It runs **only** when an operator
explicitly triggers it, and it **fails closed** without an allowlist:

- **`workflow_dispatch` only.** `sentinel-shield-dast.yml` has no `push`/`pull_request`/
  `schedule` trigger — it can only be started manually with explicit `target_url` +
  `allowed_host` inputs.
- **No target → no scan.** Without `SENTINEL_SHIELD_DAST_TARGET_URL`, the guard
  (`scripts/runners/dast-guard.sh`) returns 10 and the runner exits 0 — a clean **SKIP**,
  no scan.
- **No allowlist → fail closed.** Without `SENTINEL_SHIELD_DAST_ALLOWED_HOST`, or if the
  target host ≠ the allowlisted host, the guard returns 3 and the runner exits 3 — **fail
  closed**, no scan.
- **http/https only.** Any other scheme fails closed (exit 3).
- **Never scans an arbitrary target.** There is no code path that scans a host that is not
  exactly the operator-supplied, allowlisted host.

This pilot does **not** change any of the above. It documents how to exercise these controls
safely, once.

---

## 2. DAST pilot readiness CHECKLIST

All boxes must be checked **before** any scan is dispatched. Record the evidence (links,
ticket IDs, signatures) alongside the approval form.

- [ ] **Approval recorded.** A completed [`templates/dast-scan-approval.md`](../templates/dast-scan-approval.md)
      exists, with requester, target, allowed host, approver, and expiry.
- [ ] **Staging-only target.** The target is a staging / pre-prod environment you own and
      control — **never production** (see §4, §5).
- [ ] **Allowlist host set.** `SENTINEL_SHIELD_DAST_ALLOWED_HOST` is set to the exact host
      of the target URL, and (for Nuclei) the host is listed in
      [`templates/nuclei-target-allowlist.md`](../templates/nuclei-target-allowlist.md).
- [ ] **Auth boundary defined.** Credentials are scoped staging-only test accounts; no
      production credentials; blast radius documented (see §4).
- [ ] **Evidence retention.** You know where the raw report lands (`reports/raw/…`), that the
      workflow uploads it as the `sentinel-shield-dast` artifact (retention 30 days), and
      where the pilot evidence will be archived for the maturity citation (§7).
- [ ] **Scope confirmed for active scans.** For `zap-full` (active) or Nuclei, explicit owner
      sign-off is on the approval form (active/intrusive — see §4, §8).

---

## 3. Target ALLOWLIST example

The runner derives the host from `SENTINEL_SHIELD_DAST_TARGET_URL` (strips scheme, path,
query, and port) and compares it for **exact equality** against
`SENTINEL_SHIELD_DAST_ALLOWED_HOST`. Anything but an exact match fails closed.

**Matching pair — proceeds:**

```sh
SENTINEL_SHIELD_DAST_TARGET_URL="https://staging.example.com/app"
SENTINEL_SHIELD_DAST_ALLOWED_HOST="staging.example.com"
# host-of(target) = "staging.example.com" == allowed host  -> guard returns 0, scan proceeds
```

**Mismatching pair — FAILS CLOSED (no scan, exit 3):**

```sh
SENTINEL_SHIELD_DAST_TARGET_URL="https://prod.example.com/app"
SENTINEL_SHIELD_DAST_ALLOWED_HOST="staging.example.com"
# host-of(target) = "prod.example.com" != "staging.example.com"  -> guard returns 3, FAIL CLOSED
```

Other fail-closed cases: a subdomain that is not exactly the allowed host
(`api.staging.example.com` vs `staging.example.com`), an empty `SENTINEL_SHIELD_DAST_ALLOWED_HOST`,
or a non-http(s) scheme.

---

## 4. AUTH boundary documentation

- **Never scan production.** The target host must be a staging / pre-prod system you own.
  Production is out of scope for the pilot; a production target requires the explicit
  written sign-off described in [`docs/dast-policy.md`](dast-policy.md) and is **not** part
  of this readiness exercise.
- **Never use production credentials.** Use a **scoped staging test account** provisioned
  only for the scan, with least privilege and no access to real customer data. Rotate or
  disable the account after the pilot.
- **Scoped staging account.** Document which account is used, what it can reach, and its
  blast radius on the approval form.
- **No destructive payloads on ZAP full without sign-off.** `zap-full` is an **active**
  scan (it sends attack payloads); Nuclei templates can be intrusive. Active scans require
  explicit owner sign-off on the approval form before dispatch, and must run only against a
  staging target where data loss / state mutation is acceptable and recoverable.

---

## 5. STAGING-ONLY policy

The pilot runs against staging / pre-prod **only**. Concretely:

- The allowlisted host (`SENTINEL_SHIELD_DAST_ALLOWED_HOST`) must be a staging host you own.
- The `Environment` field on the approval form must read `staging` (or `pre-prod` with
  sign-off) — never `production`.
- Third-party hosts and hosts you do not own are never valid targets, regardless of
  allowlist.

This is the operating constraint for the entire pilot; production DAST remains out of scope
until a separate, future decision with its own approval.

---

## 6–8. Evidence artifact EXPECTATIONS

All three runners write JSON to `reports/raw/`. The `sentinel-shield-dast.yml` workflow
uploads `reports/**` as the `sentinel-shield-dast` artifact (`retention-days: 30`,
`if-no-files-found: warn`). If the tool is **absent**, the runner emits nothing and exits 0
(no faked scan); the collector then reports the tool as unavailable. The collectors map every
finding count to the single `dast_findings` summary key.

### 6. ZAP baseline (passive) → `reports/raw/zap.json`

- **Runner:** `scripts/runners/zap-baseline.sh` (`zap-baseline.py -t <target> -J zap.json`).
- **Shape:** the ZAP JSON report — `{ "site": [ { "alerts": [ { "riskcode": "…", … } ] } ] }`.
- **What counts as a finding:** the `zap` collector (`scripts/collectors/zap.sh`) counts
  alerts with **`riskcode >= 2`** (i.e. Medium/High). `dast_findings` is that count; `> 0`
  marks the collector `fail`, `0` marks `pass`.
- **Lands in:** `reports/raw/zap.json` → collector → `dast_findings`.

### 7. ZAP full (active) → `reports/raw/zap-full.json`

- **Runner:** `scripts/runners/zap-full.sh` (active scan; `zap-full-scan.py -t <target> -J
  zap-full.json`).
- **Shape:** identical ZAP report shape to the baseline.
- **What counts as a finding:** same rule — alerts with **`riskcode >= 2`**. Collect it by
  pointing the same `zap` collector at the full report:
  `scripts/collectors/zap.sh --input reports/raw/zap-full.json` (the collector defaults to
  `reports/raw/zap.json`, so the full report must be passed via `--input`).
- **Lands in:** `reports/raw/zap-full.json` → collector → `dast_findings`.

### 8. Nuclei → `reports/raw/nuclei.json`

- **Runner:** `scripts/runners/nuclei.sh` (`nuclei -u <target> -jle nuclei.json -severity
  medium,high,critical`).
- **Shape:** Nuclei JSON — either a top-level array or `{ "findings": [ … ] }`; each entry
  carries `info.severity` (or `severity`).
- **What counts as a finding:** the `nuclei` collector (`scripts/collectors/nuclei.sh`) counts
  entries whose severity is **`critical`, `high`, or `medium`** (case-insensitive). That count
  is `dast_findings`; `> 0` → `fail`, `0` → `pass`.
- **Lands in:** `reports/raw/nuclei.json` → collector → `dast_findings`.

In all three cases the collector emits an overlay `{ "dast_findings": <n> }` that the summary
builder folds into the security summary's `dast_findings` key.

---

## 9 (Task 73). When DAST CAN become a regulated-mode gate

`dast_findings` is gated **only in `regulated` mode**, and **only if** a target + allowlist +
approval are configured (see [`docs/regulated-mode-readiness.md`](regulated-mode-readiness.md)
and `templates/profile.yaml`, where `dast_findings: false` by default). DAST may be promoted
to a regulated-mode gate **only after**:

1. A controlled pilot (this document's checklist) has been completed against a staging target.
2. The pilot produced **cited, real evidence** — an actual `reports/raw/{zap,zap-full,nuclei}.json`
   from a live run, with the `dast_findings` count it yielded — not a synthetic or assumed
   result.
3. The guard's fail-closed and skip behaviors were observed in practice (matching pair runs;
   mismatching pair fails closed).
4. The maturity promotion is recorded with that citation, consistent with how other tools are
   promoted only on cited live evidence.

Until then DAST stays `manual` / non-gating. Promoting it without a cited pilot would violate
the honesty rule: today the only honest claim is "manual, fail-closed guard verified, never
live-run."

---

## 10 (Task 74). When Nuclei MUST remain manual

Nuclei templates are powerful and can be **intrusive/active** (exploit checks, fuzzing). It
must remain **manual / operator-triggered** and never default-on because:

- Templates can mutate state or trigger denial-of-service against a fragile target.
- It requires the same fail-closed allowlist guard as ZAP, **plus** a host entry in
  [`templates/nuclei-target-allowlist.md`](../templates/nuclei-target-allowlist.md).
- The runner restricts severity to `medium,high,critical` and a **controlled template path**;
  broadening templates requires re-approval.

Nuclei therefore runs only via `workflow_dispatch` with a recorded approval and an allowlisted
staging host — never as a gate, never by default.

---

## 11 (Task 75). Risk-approval template

Every dispatch must be backed by a completed
[`templates/dast-scan-approval.md`](../templates/dast-scan-approval.md). It captures:
requester, target URL, allowed host, staging confirmation, auth boundary, approver, and
expiry. For Nuclei, also complete
[`templates/nuclei-target-allowlist.md`](../templates/nuclei-target-allowlist.md). The
approval form is the gate that authorizes a pilot scan; without it, do not dispatch.
