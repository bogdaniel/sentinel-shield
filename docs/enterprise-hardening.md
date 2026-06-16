# Enterprise Hardening

> Advanced/enterprise doc (v1.2.0) — additive guidance, no behavior change.

This guide is a **map**, not a re-statement. It explains how the existing hardening
levers fit together for an enterprise/regulated rollout and links to the canonical doc for
each topic. **Default Sentinel Shield is deliberately readable and tag-based** — the
hardened profile here is **opt-in**. Nothing below changes a default; adopting it is a
consumer-side production decision.

When a fact has a home elsewhere, this doc points there instead of copying it:

| Topic | Canonical doc |
|---|---|
| Scanner image digests (resolve/verify/update/rollback) | [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) |
| Action / image pinned references (resolved SHAs) | [`pinned-tool-references.md`](pinned-tool-references.md) |
| Secrets, NVD key rotation, artifact retention, .gitignore | [`security-hygiene.md`](security-hygiene.md) |
| Minimal token permissions, no `pull_request_target`, SHA pinning | [`github-actions-security.md`](github-actions-security.md) |
| Strict-mode pre-flight | [`strict-mode-readiness.md`](strict-mode-readiness.md) |
| Regulated-mode pre-flight | [`regulated-mode-readiness.md`](regulated-mode-readiness.md) |
| DAST (ZAP/Nuclei) manual/fail-closed posture | [`dast-policy.md`](dast-policy.md) |
| AI review (non-gating) posture | [`ai-review-policy.md`](ai-review-policy.md) |
| Hardened reference snippet (all pinned) | [`../examples/hardened/sentinel-shield-hardened.snippet.yml`](../examples/hardened/sentinel-shield-hardened.snippet.yml) |

---

## 1. The hardened profile — purpose (opt-in, not forced)

The **hardened profile** is the production-form configuration: every scanner image and
every GitHub Action is pinned by immutable reference, permissions are minimal, secrets are
provided out-of-band, and the gate is wired as a required status check. It exists so that
an enterprise consumer can make their pipeline **reproducible and tamper-evident** without
forking the templates.

It is **not** the default. The shipped templates use **readable tags** by design
(legibility, low-friction onboarding, easy bumps). You harden by **overriding**, not by
editing upstream templates. See the policy table in
[`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) §v0.1.28:

| Context | Form |
|---|---|
| development / onboarding | readable tags |
| production / hardened | digest-pinned overrides (`SENTINEL_SHIELD_*_IMAGE` env vars) |

---

## 2. Readable tags vs digest-pinned production overrides

A tag is **mutable** — `:v0.114.0` can point at a different image tomorrow. For production
you pin by **digest** (`@sha256:…`), which is immutable. Override the documented env vars in
your consumer workflow `env:` (or a repo/org variable so every job inherits):

- `SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE`
- `SENTINEL_SHIELD_SEMGREP_IMAGE`
- `SENTINEL_SHIELD_GRYPE_IMAGE`
- `SENTINEL_SHIELD_DOCKLE_IMAGE`

Do **not** replace the readable tag inside the upstream templates — the digest is a
consumer-side decision; templates stay readable + overridable. The resolved, validated
digests and the verify/update/rollback procedure live in
[`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md); the worked hardened
form (including the v1.1.0 transitive Dependency-Check knobs
`SENTINEL_SHIELD_DEPENDENCY_CHECK_INSTALL_PHP` / `_INSTALL_NODE`, default OFF) is in
[`../examples/hardened/sentinel-shield-hardened.snippet.yml`](../examples/hardened/sentinel-shield-hardened.snippet.yml).

> **No floating `:latest` in production** — pin Dependency-Check too. On a digest **mismatch
> at pull time the gate fails closed** — investigate before bumping.

---

## 3. SHA-pinned Actions

GitHub Actions are pinned by **full 40-char commit SHA** (with the human-readable version as
a trailing comment), because a tag can be re-pointed to malicious code after you trusted it.
The resolved SHAs are catalogued in [`pinned-tool-references.md`](pinned-tool-references.md);
the rules and enforcement (`scripts/audit-github-actions-pins.sh`, actionlint, zizmor,
Scorecard, OPA) are in [`github-actions-security.md`](github-actions-security.md).

The blocking self-gate `ci-self-test.yml` is already pinned; other templates stay
tag-readable and **must be pinned before production**. The hardened snippet shows the pinned
form for `checkout`, `upload-artifact`, `osv-scanner-action`, `trivy-action`, and
`sbom-action`.

---

## 4. Minimal workflow permissions

Workflow templates default the top-level token to `permissions: contents: read`, granting
`security-events: write` **only** where CodeQL must upload SARIF. There is **no
`pull_request_target`** anywhere (it is a known secret-exfiltration vector and is denied by
policy). `write-all` is denied. Per-job scope is the narrowest needed; deploy/secret-bearing
steps are gated on trusted events or a protected environment. Details and enforcement:
[`github-actions-security.md`](github-actions-security.md) §1, §2, §6.

---

## 5. Artifact retention & audit-evidence retention

- Workflow artifacts upload with `retention-days: 30` and `if: always()` so raw reports
  survive a scanner failure or a finding-induced gate failure.
- Raw reports live under `reports/` which is **gitignored** — they are CI artifacts, not
  committed. Cite aggregate counts, never raw private consumer artifacts, in this public repo.
- The NVD cache lives under `.sentinel-shield/cache/` (gitignored); it contains **NVD data,
  never the key**.

For audit/evidence runs, use a dedicated **evidence branch** on the consumer (kept off the
default branch), cite the run ID + artifacts, then delete the branch — run history and
artifacts persist. Lower `retention-days` for sensitive consumers if your retention policy
requires it. Full hygiene + cleanup commands: [`security-hygiene.md`](security-hygiene.md).

---

## 6. Branch-protection expectations

The hardened posture treats the Sentinel Shield gate as a **required status check** on the
protected branch:

- [ ] Protect the default branch (`main`/`master`): no force-push, no deletion.
- [ ] Require the gate job as a **required status check** before merge. The gate job is
      `main-gate` (template `sentinel-shield-main.yml`) or `gate` (template
      `ci-release-gate.yml`) — use the name your consumer actually runs.
- [ ] Require branches to be **up to date** before merging.
- [ ] Require **pull-request review** before merge; dismiss stale approvals on new commits.
- [ ] Use a **protected GitHub Environment** with required reviewers for any
      deploy/secret-bearing job.
- [ ] (Regulated) Require signed commits / linear history per your compliance baseline.

These are repository settings the consumer applies — Sentinel Shield does not (and should
not) mutate your branch protection.

---

## 7. Secret management expectations

- Secrets are **consumer-provided GitHub secrets**, never committed and never echoed (even
  masked) into logs.
- Forked-PR workflows must not have access to secrets; gate secret-bearing steps on trusted
  events or an approved environment.
- **Never print, log, commit, or paste a secret value** anywhere — including this repo's
  docs and any shared chat/log.

### NVD API key handling + rotation

The Dependency-Check NVD key is a consumer-provided secret,
`SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY`. The wrapper passes it **only** via an
ephemeral, container-readable **propertyfile** (removed on exit) — **never** on the command
line / process list, in logs, in the report, or in commits.

- [ ] Store the key as a repo/org GitHub secret (set via `gh secret set`, value piped from a
      `0600` file or interactive prompt — never echoed).
- [ ] Rotate on suspected exposure or on a periodic cadence.
- [ ] After rotation, re-run Dependency-Check; confirm it authenticates (no HTTP 429).
- [ ] Verify no key was ever committed (UUID-shaped scan) — **report the location, never the
      value**.

Step-by-step rotation, the safe `gh secret set` form, and the commit-scan command are in
[`security-hygiene.md`](security-hygiene.md). Do **not** reproduce a key value anywhere.

---

## 8. Strict vs regulated (both opt-in)

Both tiers are **opt-in** — neither is forced.

- **Strict** adds, as hard blockers over baseline: medium-severity findings, SBOM presence,
  style, IaC, container-image, and the higher-confidence third-party supply-chain signals.
- **Regulated** adds, over strict: release/audit evidence (mandatory), the noisier
  third-party signals, repo-health (Scorecard), and DAST findings (only when a target +
  allowlist + approval are configured). Everything blocks **except AI review**.

Read the pre-flight gates before flipping: [`strict-mode-readiness.md`](strict-mode-readiness.md)
then [`regulated-mode-readiness.md`](regulated-mode-readiness.md). Maturity claims defer to
`product-status.md` (canonical).

---

## 9. DAST / Nuclei — manual, allowlisted, fail-closed

DAST (OWASP ZAP baseline/full, Nuclei) is **manual / controlled** — never a PR check, never
run by default, and gated only in `regulated` (and only when configured). Safety rules
(enforced by `scripts/runners/dast-guard.sh`):

- **No target → no scan** (skip, exit 0).
- **Allowlist required, fail closed** — host mismatch or missing allowlist fails closed (no
  scan). `http/https` only. Never scan production without written approval; use staging you
  control.

**AI review is assistive and NON-gating by default — even in regulated** (non-reproducible
output must not silently block/pass a release). See [`dast-policy.md`](dast-policy.md) and
[`ai-review-policy.md`](ai-review-policy.md).

---

## 10. Enterprise rollout checklist

- [ ] Onboard on **readable tags** first; get a green baseline gate.
- [ ] Pin scanner images by **digest** (DC/Semgrep/Grype/Dockle) via the override env vars
      (§2); resolve digests per [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md).
- [ ] Pin all third-party Actions by **commit SHA** (§3); run the pin audit.
- [ ] Confirm `permissions: contents: read` top-level; no `pull_request_target`; no
      `write-all` (§4).
- [ ] Provide secrets as GitHub secrets; configure the NVD key; verify nothing is committed
      (§7).
- [ ] Set `retention-days` per your policy; confirm `reports/`, `.sentinel-shield/`,
      `.claude/`, `graphify-out/` are gitignored (§5).
- [ ] Protect `main`; require the gate (`main-gate`/`gate`) as a status check; protected
      environment for deploys (§6).
- [ ] Decide tier: leave baseline, or opt into **strict** / **regulated** after the
      pre-flight (§8).
- [ ] Keep DAST manual + allowlisted; keep AI review non-gating (§9).
- [ ] Record the validation run ID + artifacts on a dedicated evidence branch; clean up
      after (§5).

---

## 11. Hardened-profile migration guide (tags → digests, with rollback)

Migrate one consumer at a time; keep a known-good baseline you can revert to.

1. **Capture the baseline.** Note the current readable tags and the last green gate run.
2. **Resolve digests** for each scanner image you run:
   ```sh
   docker buildx imagetools inspect <image>:<tag> --format '{{.Manifest.Digest}}'
   ```
   Verify each digest reports the expected version (procedure in
   [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md)).
3. **Pin in the consumer `env:`** (not the upstream template) using the override vars:
   ```yaml
   env:
     SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE: owasp/dependency-check@sha256:<digest>  # latest
     SENTINEL_SHIELD_SEMGREP_IMAGE:          semgrep/semgrep@sha256:<digest>         # 1.165.0
     SENTINEL_SHIELD_GRYPE_IMAGE:            anchore/grype@sha256:<digest>           # v0.114.0
     SENTINEL_SHIELD_DOCKLE_IMAGE:           goodwithtech/dockle@sha256:<digest>     # v0.4.15
   ```
   (The validated digests + the matching hardened snippet are linked above — do not invent
   digests; resolve them.)
4. **Pin Actions by SHA** in the same workflow (§3); run the pin audit.
5. **Re-run the gate** on an evidence branch; confirm green.
6. **Promote** the pinned workflow to the protected branch only after green.

**Rollback** (deterministic, because digests are immutable):

- [ ] Revert the env override to the **previous known-good `@sha256:`** digest (kept from
      step 1 / the validated baseline table).
- [ ] Re-run the gate; confirm green.
- [ ] If a tag was re-pushed (digest mismatch), treat it as an **update** — re-validate
      before adopting; do not silently accept the new digest.

Because the prior `@sha256:` is immutable, the exact validated image is always retrievable
even if the tag has moved on — rollback is a one-line revert, not a rebuild.
