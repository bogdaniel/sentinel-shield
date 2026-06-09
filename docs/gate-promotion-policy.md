# Gate Promotion Policy

> **Purpose.** This document defines the **policy** for promoting a project's adoption
> mode up the ladder `report-only → baseline → strict → regulated`: what must be clean,
> configured, and governed **before** you turn a tier on, and how to override an
> individual gate with justification. It is the decision procedure that sits on top of the
> per-tier *readiness checklists*.
>
> **It does not duplicate the checklists.** The concrete pre-flight checklists live in
> [`strict-mode-readiness.md`](strict-mode-readiness.md) and
> [`regulated-mode-readiness.md`](regulated-mode-readiness.md). Read those for the item
> lists; read this for the promotion *policy*, the boundary rules, and the readiness
> matrix.
>
> **Source of truth for what each tier gates** is `default_for()` in
> [`scripts/resolve-gates.sh`](../scripts/resolve-gates.sh). The
> [readiness matrix](#readiness-matrix) below is derived from that function's resolved
> output, not hand-authored. Maturity claims follow
> [`product-status.md`](product-status.md) (canonical — it wins on any disagreement).
>
> **Not a v1.0 claim.** Sentinel Shield is production-ready as a release-gate **engine**
> (resolver, enforcer, summary-builder, install, sync, self-test are self-gated). It is
> **not** a turnkey "all scanners proven" product. Several scanner integrations are
> `supported`/`experimental`/`manual` and should run advisory before you let them block —
> even in higher tiers. Promotion is per-project and reversible.

---

## 1. The promotion ladder

| Tier | Role | What it adds vs the tier below |
| --- | --- | --- |
| `report-only` | Visibility only | Only leaked **secrets** and **expired exceptions** block. Everything else is advisory. |
| `baseline` | Migration | New high-risk issues do not enter: critical/high vulns, architecture, types, tests, unsafe Docker/Actions, php-syntax, dependency-policy. Existing debt may remain. |
| `strict` | Production | Quality + remaining security: medium vulns, SBOM presence, style, IaC, container-image, plus higher-confidence third-party install-script / network-behavior signals. |
| `regulated` | Compliance | Mandatory release evidence, DAST, repo-health, and the full third-party supply-chain set become hard blockers. |

Promotion is **monotonic by intent**: each tier is a superset of the gates below it (the
matrix shows no gate that is `true` at a lower tier and `false` at a higher one). The only
gate that is never on by default at any tier is `ai_review_findings` (advisory-only; opt in
per project — see [`ai-review-policy.md`](ai-review-policy.md)).

---

## 2. Readiness matrix

Each row is a `fail_on.*` gate. Each column is an adoption mode. **✓ = gated** (the gate is
`true` by default in that mode and will block a release), **✗ = not gated** (advisory only).
This table is the resolved output of `scripts/resolve-gates.sh --mode <m>` for each mode;
regenerate it with the [verification snippet](#regenerating-the-matrix) and confirm it
matches before editing.

| `fail_on` gate | report-only | baseline | strict | regulated |
| --- | :---: | :---: | :---: | :---: |
| `secrets` | ✓ | ✓ | ✓ | ✓ |
| `critical_vulnerabilities` | ✗ | ✓ | ✓ | ✓ |
| `high_vulnerabilities` | ✗ | ✓ | ✓ | ✓ |
| `medium_vulnerabilities` | ✗ | ✗ | ✓ | ✓ |
| `architecture_violations` | ✗ | ✓ | ✓ | ✓ |
| `type_errors` | ✗ | ✓ | ✓ | ✓ |
| `test_failures` | ✗ | ✓ | ✓ | ✓ |
| `unsafe_docker` | ✗ | ✓ | ✓ | ✓ |
| `unsafe_github_actions` | ✗ | ✓ | ✓ | ✓ |
| `missing_sbom` | ✗ | ✗ | ✓ | ✓ |
| `missing_release_evidence` | ✗ | ✗ | ✗ | ✓ |
| `expired_exceptions` | ✓ | ✓ | ✓ | ✓ |
| `third_party_suspicious_code` | ✗ | ✗ | ✗ | ✓ |
| `third_party_install_script_risk` | ✗ | ✗ | ✓ | ✓ |
| `third_party_obfuscation` | ✗ | ✗ | ✗ | ✓ |
| `third_party_network_behavior` | ✗ | ✗ | ✓ | ✓ |
| `php_syntax_errors` | ✗ | ✓ | ✓ | ✓ |
| `style_violations` | ✗ | ✗ | ✓ | ✓ |
| `dependency_policy_violations` | ✗ | ✓ | ✓ | ✓ |
| `iac_violations` | ✗ | ✗ | ✓ | ✓ |
| `container_image_violations` | ✗ | ✗ | ✓ | ✓ |
| `dast_findings` | ✗ | ✗ | ✗ | ✓ |
| `repository_health_warnings` | ✗ | ✗ | ✗ | ✓ |
| `ai_review_findings` | ✗ | ✗ | ✗ | ✗ |

**Promotion boundaries the matrix encodes:**

- **baseline → strict newly gates:** `medium_vulnerabilities`, `missing_sbom`,
  `style_violations`, `iac_violations`, `container_image_violations`,
  `third_party_install_script_risk`, `third_party_network_behavior`.
- **strict → regulated newly gates:** `missing_release_evidence`, `dast_findings`,
  `repository_health_warnings`, `third_party_suspicious_code`,
  `third_party_obfuscation`.
- **Never gated by default (any tier):** `ai_review_findings`.

The mode fixtures in [`tests/fixtures/modes/`](../tests/fixtures/modes/README.md) pin these
boundaries: a style/IaC fixture must pass at baseline and fail at strict; a DAST /
missing-release-evidence fixture must pass at strict and fail at regulated; a medium-vuln
fixture must pass at baseline and fail at strict.

---

## 3. Promotion policy: baseline → strict

Strict turns Sentinel Shield from a migration aid into a production release requirement.
**Before flipping `gates.mode: strict`, the gates that strict newly turns on must already
run clean (or be explicitly accepted)** — promoting a tier should never mean "discover a
backlog the next push." Work the full checklist in
[`strict-mode-readiness.md`](strict-mode-readiness.md); the policy gates are:

1. **The newly-gated checks are green or accepted.** For each gate that flips `✗→✓` at
   strict (`medium_vulnerabilities`, `missing_sbom`, `style_violations`, `iac_violations`,
   `container_image_violations`, `third_party_install_script_risk`,
   `third_party_network_behavior`): the collector has run on the real codebase and either
   reports `0`, or every residual finding is covered by an active, unexpired exception
   (see [`exception-policy.md`](exception-policy.md) and
   [`accepted-risk-suppression.md`](accepted-risk-suppression.md)).
2. **Style / type / IaC tooling is configured, not defaulted.** A style or IaC gate that
   blocks on an unconfigured tool is noise. Pin the formatter ruleset (Pint / PHP-CS-Fixer),
   the type config (PHPStan/Psalm level or `tsc` strictness), and the IaC policy
   (Checkov/Conftest) in-repo and commit them before turning the gate on.
3. **SBOM generation is wired.** `missing_sbom` is gated at strict, so the pipeline must
   emit `reports/sbom.spdx.json` on every run (Syft/Trivy). A strict promotion with no SBOM
   step is a guaranteed red build.
4. **Scanner maturity is acceptable for blocking.** Any integration still
   `experimental`/`manual` in [`product-status.md`](product-status.md) should run advisory
   (override to `false` with a justification, §6) until it is `supported`, rather than
   silently failing releases on a flaky tool.
5. **Third-party triage is tuned.** Strict starts blocking `install_script_risk` and
   `network_behavior`; confirm the curated allowlists / suppressions are in place so known
   dependencies do not trip the gate.

Do **not** weaken a gate to make the promotion pass — record an exception or an explicit,
justified override instead (§6).

---

## 4. Promotion policy: strict → regulated

Regulated is the compliance-heavy tier: release evidence and SBOM are mandatory, and DAST,
repo-health, and the full third-party set become hard blockers. **Regulated requires
everything strict requires, PLUS the items below.** Work the full checklist in
[`regulated-mode-readiness.md`](regulated-mode-readiness.md); the policy gates are:

1. **DAST allowlist + approval.** `dast_findings` becomes gating. Before promotion the DAST
   target scope, authenticated-scan config, and a documented **allowlist of accepted
   alerts** must exist and be **approved by the security owner** — see
   [`dast-policy.md`](dast-policy.md). An un-allowlisted DAST gate against a real app will
   block on baseline noise.
2. **Scorecard / repository-health acceptable.** `repository_health_warnings` becomes
   gating. The repo must pass the OpenSSF Scorecard / repo-health thresholds, or each
   residual warning must be an accepted, justified exception. Do not promote with unreviewed
   repo-health debt.
3. **Audit-evidence retention.** `missing_release_evidence` becomes gating: the pipeline
   must produce and **retain** `reports/release-evidence.md` (and the SBOM) as durable audit
   artifacts per the project's retention requirement. Confirm artifact retention is long
   enough to satisfy the compliance regime before flipping the gate.
4. **Accepted-risk expiry is enforced.** `expired_exceptions` already blocks at every tier,
   but regulated raises the stakes: every accepted risk / suppression must carry an
   **expiry date and an owner**, and there must be no expired entries at promotion time. Run
   the exception audit and clear or renew expiries first
   ([`accepted-risk-suppression.md`](accepted-risk-suppression.md),
   [`exception-policy.md`](exception-policy.md)).
5. **Full third-party set is triaged.** Regulated additionally blocks
   `third_party_suspicious_code` and `third_party_obfuscation`; confirm these run clean or
   are accepted before promotion (see [`enterprise-scanner-matrix.md`](enterprise-scanner-matrix.md)).

`ai_review_findings` remains advisory even in regulated unless the project explicitly opts
in (§6); do not assume regulated turns it on.

---

## 5. Demotion / rollback

Promotion is reversible. If a freshly promoted tier exposes a gate that is not yet ready to
block (e.g. a flaky experimental scanner), the correct response is a **scoped, justified
override** (§6) that loosens *that one gate* with a tracking note — **not** lowering the
whole `gates.mode`. Lowering the mode silently drops every gate the tier added. Prefer a
per-gate override with an expiry/tracking issue over a tier demotion.

---

## 6. Per-gate override examples

Any key under `gates.fail_on` overrides the mode default and is **reported explicitly** by
the resolver (overrides are never hidden — they print to stderr and into the resolved
JSON/markdown). Use overrides to *tighten* a gate ahead of its tier, or to *temporarily
loosen* an immature gate while the promotion settles — always with a justification comment
and, for a loosen, a tracking reference. Full format: [`gate-resolution.md`](gate-resolution.md)
and [`templates/profile.yaml`](../templates/profile.yaml).

### 6a. Strict, tightening a gate ahead of its tier

```yaml
# .sentinel-shield/profile.yaml
gates:
  mode: strict
  fail_on:
    # Tighten: block DAST findings now even though strict leaves it advisory by
    # default. Our app is internet-facing; security owner approved the DAST
    # allowlist on 2026-05-30 (see docs/dast-policy.md). Tracking: SEC-4821.
    dast_findings: true
    # Tighten: opt AI review into gating for this high-criticality service.
    # Reviewed false-positive rate < 5% over 30 days. Tracking: SEC-4822.
    ai_review_findings: true
```

### 6b. Strict, temporarily loosening an immature gate

```yaml
gates:
  mode: strict
  fail_on:
    # Loosen: container-image scanner (Dockle/Trivy image) is still being tuned
    # for this base image; run advisory until baseline noise is triaged.
    # Expires 2026-07-15; remove this override then. Tracking: SEC-4830.
    container_image_violations: false
```

### 6c. Regulated, loosening with justification + expiry

```yaml
gates:
  mode: regulated
  fail_on:
    # Loosen: repo-health (Scorecard) flags a branch-protection check we are
    # mid-migration on; accepted risk approved by platform-team, expires
    # 2026-08-01. Do NOT extend without re-approval. Tracking: SEC-4905.
    repository_health_warnings: false
    # Tighten (belt-and-suspenders): keep third-party obfuscation hard-blocking
    # even though it is already the regulated default — documents intent so a
    # later mode demotion does not silently drop it.
    third_party_obfuscation: true
```

> **Policy on loosening:** a `false` override on a gate the tier would otherwise block is an
> **accepted risk** and must be treated like one — justification, owner, expiry, tracking
> reference. It is not a way to ship the promotion and forget. The resolver prints every
> override (`Override: <key>=<value> (default <d>)`), so loosens are auditable in CI logs.

---

## Regenerating the matrix

```sh
for m in report-only baseline strict regulated; do
  sh scripts/resolve-gates.sh --mode "$m" --format json --output-dir "/tmp/ss-$m" >/dev/null 2>&1
done
# Per-gate, per-mode booleans (compare against §2):
paste -d'\t' \
  <(jq -r '.fail_on | keys_unsorted[]' /tmp/ss-report-only/sentinel-shield-gates.json) \
  <(jq -r '.fail_on[]' /tmp/ss-report-only/sentinel-shield-gates.json) \
  <(jq -r '.fail_on[]' /tmp/ss-baseline/sentinel-shield-gates.json) \
  <(jq -r '.fail_on[]' /tmp/ss-strict/sentinel-shield-gates.json) \
  <(jq -r '.fail_on[]' /tmp/ss-regulated/sentinel-shield-gates.json)
```

If `resolve-gates.sh`'s `default_for()` changes, regenerate and update §2 in the same
change — the matrix must never drift from the resolver.

---

## See also

- [`strict-mode-readiness.md`](strict-mode-readiness.md) — strict pre-flight checklist.
- [`regulated-mode-readiness.md`](regulated-mode-readiness.md) — regulated pre-flight checklist.
- [`gate-resolution.md`](gate-resolution.md) — how the resolver computes `fail_on`.
- [`severity-policy.md`](severity-policy.md) — severity → gate mapping.
- [`dast-policy.md`](dast-policy.md), [`ai-review-policy.md`](ai-review-policy.md) — DAST / AI gates.
- [`accepted-risk-suppression.md`](accepted-risk-suppression.md), [`exception-policy.md`](exception-policy.md) — overrides / accepted risk governance.
- [`tests/fixtures/modes/README.md`](../tests/fixtures/modes/README.md) — fixtures that pin the promotion boundaries.
