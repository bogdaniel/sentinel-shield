# Supply-Chain Reproducibility (v0.1.23)

Reproducibility is the property that a Sentinel Shield gate run can be reconstructed
byte-for-byte: the same scanner images, the same pinned GitHub Actions, and the same
deterministic SBOM inputs produce the same findings. This document consolidates the
**verification**, **rollback**, and **version-update** procedures for the supply chain, and
records the **honest verification state** of the three live-validated scanner images.

It builds on — and does not duplicate — the digest tables and rollback narrative in
[`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) and the Action SHA tables in
[`pinned-tool-references.md`](pinned-tool-references.md). Where those docs are authoritative, this
one references them rather than re-stating digests (single source of truth: the digest tables in
`scanner-image-digest-pinning.md`).

> Honesty rule: digests in this repo are **resolved with Docker, never invented**. We do not pin a
> digest for an image we have not validated, and we never recommend `latest` for production.

---

## 1. Verification state of the three pinned scanner images (Task 91)

`docker` **was available** in this environment (`Docker version 29.4.0`), so the three digests
documented in [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) were
**re-verified live on 2026-06-10** with `docker buildx imagetools inspect <image>:<tag>
--format '{{.Manifest.Digest}}'`. Raw command outputs:

| Image | Tag | Expected digest (in `scanner-image-digest-pinning.md`) | Resolved 2026-06-10 | Match |
|---|---|---|---|---|
| `semgrep/semgrep` | `1.165.0` | `sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b` | `sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b` | ✅ match |
| `anchore/grype` | `v0.114.0` | `sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28` | `sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28` | ✅ match |
| `goodwithtech/dockle` | `v0.4.15` | `sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9` | `sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9` | ✅ match |

**Result:** all three tags still resolve to their pinned manifest-list digests — no tag has been
re-pushed since 2026-06-10. The pinned baselines remain trustworthy.

> If `docker` is **unavailable** in your environment, do not guess: mark the result
> "verification deferred — commands documented" and run the commands in §2 once Docker is present.

---

## 2. Digest verification commands (Task 92)

Two independent checks. The first confirms the tag still points at the pinned image; the second
confirms the pinned image, run **by digest**, reports the expected version. (Full narrative in
[`scanner-image-digest-pinning.md` §"How to verify a digest still matches"](scanner-image-digest-pinning.md).)

```sh
# (a) Tag → digest: the readable tag must still resolve to the pinned manifest-list digest.
docker buildx imagetools inspect semgrep/semgrep:1.165.0      --format '{{.Manifest.Digest}}'
#   -> must equal sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b
docker buildx imagetools inspect anchore/grype:v0.114.0       --format '{{.Manifest.Digest}}'
#   -> must equal sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28
docker buildx imagetools inspect goodwithtech/dockle:v0.4.15  --format '{{.Manifest.Digest}}'
#   -> must equal sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9

# (b) Digest → version: run the pinned digest and confirm the version string.
docker run --rm semgrep/semgrep@sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b semgrep --version   # -> 1.165.0
docker run --rm anchore/grype@sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28 version | grep -i 0.114.0
docker run --rm goodwithtech/dockle@sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9 --version
```

If check (a) mismatches, the tag was re-pushed to a **different** image — do **not** silently adopt
the new digest. Treat it as a version update (§7) and re-validate before trusting it.

---

## 3. Digest rollback (Task 93)

Container image digests are **immutable**: an `@sha256:…` reference always resolves to the exact
same bytes, even after the human tag has moved on. That makes rollback deterministic — you can
always retrieve the previously validated image. The authoritative rollback steps are in
[`scanner-image-digest-pinning.md` §"Rollback process"](scanner-image-digest-pinning.md); summary:

1. Revert the affected `SENTINEL_SHIELD_*_IMAGE` override to the **previous known-good digest** from
   the digest table in `scanner-image-digest-pinning.md` (those rows are the validated baselines).
2. Re-run the gate; confirm green.
3. File the regression upstream; keep the old digest pinned until the upstream fix is validated.
4. Because the old digest is immutable, the exact validated image is always retrievable by its
   `@sha256:` reference — rollback is byte-for-byte reproducible, not best-effort.

---

## 4. Template examples — digest-pinned scanner images (Task 94)

Consuming projects pin by **digest** in their workflow `env:`, keeping the readable tag as a
trailing comment. The Sentinel Shield wrappers consume these overrides transparently.

```yaml
env:
  # Production-grade: pin by digest (@sha256:…); readable tag kept as a comment.
  SENTINEL_SHIELD_SEMGREP_IMAGE: semgrep/semgrep@sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b   # 1.165.0
  SENTINEL_SHIELD_GRYPE_IMAGE:   anchore/grype@sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28      # v0.114.0
  SENTINEL_SHIELD_DOCKLE_IMAGE:  goodwithtech/dockle@sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9 # v0.4.15
```

The upstream Sentinel Shield templates ship the **readable tag** form (`semgrep/semgrep:1.165.0`)
with the digest in a `# or …@sha256:…` comment — readability for the template, digest-pinning as a
consumer-side production decision. Do not replace the readable tag in the upstream templates with a
digest.

---

## 5. Check: templates expose digest-override env vars (Task 95)

**Expectation** (the captain will add the executable self-test; this documents what it must assert):
every container-scanner template must expose the `SENTINEL_SHIELD_*_IMAGE` override so a consumer can
swap the readable tag for a digest **without editing the template**. Observed coverage on 2026-06-10:

| Template | Override env var(s) present |
|---|---|
| `templates/workflows/sentinel-shield.yml` | `SENTINEL_SHIELD_SEMGREP_IMAGE` (with `@sha256:…` comment) |
| `templates/workflows/sentinel-shield-main.yml` | `SENTINEL_SHIELD_GRYPE_IMAGE` (with `@sha256:…` comment) |
| `templates/workflows/sentinel-shield-pr-fast.yml` | `SENTINEL_SHIELD_SEMGREP_IMAGE` (with `@sha256:…` comment) |
| `templates/workflows/sentinel-shield-scheduled.yml` | `SENTINEL_SHIELD_GRYPE_IMAGE`, `SENTINEL_SHIELD_DOCKLE_IMAGE` (with `@sha256:…` comments) |

The wrappers honour the override transparently: `${SENTINEL_SHIELD_SEMGREP_IMAGE:-semgrep/semgrep:1.165.0}`.
Self-test assertion (expected form): for each template above, the named `SENTINEL_SHIELD_*_IMAGE`
key is present and its value (or trailing comment) carries the matching readable tag.

---

## 6. Check: production docs do NOT recommend `latest` (Task 96)

Production guidance never recommends a mutable `latest` tag — it defeats reproducibility and is a
supply-chain risk. The pinned scanner images (Semgrep/Grype/Dockle) are all tag- or digest-pinned.

**One allowed exception:** OWASP Dependency-Check. It appears as `owasp/dependency-check:latest` in
`templates/workflows/sentinel-shield-dependency-check.yml` and
`templates/workflows/sentinel-shield-scheduled.yml` **only as a not-yet-validated placeholder**, with
an explicit pin-before-prod comment in the template:

```yaml
# No validated Dependency-Check digest yet — readable tag; pin by digest before production.
SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE: owasp/dependency-check:latest
```

This is honest: Dependency-Check is *attempted, not live-validated* (see
[`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md)), so we deliberately do
**not** invent a digest for it. The `latest` tag here is a placeholder, and **must be pinned by
digest before any production use** — resolve and pin it only once a nightly run produces a real
artifact, then move it into the digest table in `scanner-image-digest-pinning.md`. No other
production doc or template recommends `latest`. Self-test assertion (expected form): no `:latest`
appears in any template **except** this one Dependency-Check placeholder, which must retain its
pin-before-prod comment.

---

## 7. Scanner version update process (Task 100)

When bumping a scanner to a new version, follow this order so the digest tables and evidence never
drift from reality (mirrors [`scanner-image-digest-pinning.md` §"How to update safely"](scanner-image-digest-pinning.md)):

1. **Bump the tag** — pick the new version tag (e.g. `anchore/grype:v0.115.0`).
2. **Resolve the new digest** — `docker buildx imagetools inspect <image>:<newtag> --format '{{.Manifest.Digest}}'`.
   Never hand-write a digest; copy it from the command output.
3. **Re-validate** the new digest with a real run:
   - Semgrep: `sh scripts/verify-semgrep-image.sh tests/fixtures/semgrep/php-modern reports/raw/semgrep-image-verify.json` (expect **0 parser errors**).
   - Grype / Dockle: run on a consumer and confirm the collector parses the produced artifact.
4. **Update the digest tables** in `scanner-image-digest-pinning.md` **and** `pinned-tool-references.md`
   (digest + date), and refresh the override examples in the workflow templates (tag stays readable;
   digest in the trailing comment).
5. **Update CHANGELOG** with the version bump and the new digest.
6. **Record the validation run** in [`main-gate-live-evidence.md`](main-gate-live-evidence.md)
   (run ID + result), so the digest is backed by a citable live run.

Only after steps 3–6 is the new digest a "validated baseline" eligible for rollback in §3.

---

## 8. Supply-chain reproducibility checklist (Task 97)

- [ ] All production scanner images pinned by **digest** (`@sha256:…`), not a mutable tag.
- [ ] Each pinned digest **re-verified** with `docker buildx imagetools inspect` (§2a) and the
      digest still equals the table in `scanner-image-digest-pinning.md`.
- [ ] Each pinned digest, run by `@sha256:`, reports the **expected version** (§2b).
- [ ] No digest was hand-written/invented — every one traces to a `docker` command output.
- [ ] No production doc or template recommends `latest` (the Dependency-Check placeholder is the one
      documented exception and carries a pin-before-prod comment — §6).
- [ ] `SENTINEL_SHIELD_*_IMAGE` override env vars present in the relevant templates (§5).
- [ ] GitHub Actions pinned to full-length commit SHAs (§9).
- [ ] SBOM inputs deterministic; Grype scans SBOM-first (§10).
- [ ] Digest tables, CHANGELOG, and `main-gate-live-evidence.md` agree after any update (§7).

---

## 9. Action pinning checklist (Task 98)

GitHub Actions are pinned to **full 40-char commit SHAs**, not tags — a tag like `@v4` is mutable.
The authoritative SHA table (action → version → SHA → status) lives in
[`pinned-tool-references.md`](pinned-tool-references.md); see also
[`github-actions-security.md`](github-actions-security.md).

- [ ] Every `uses:` references a **full-length commit SHA**, with the version as a trailing comment
      (e.g. `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2`).
- [ ] Each SHA resolved from upstream via `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha`.
- [ ] First-party actions (`actions/checkout` v4.2.2, `actions/upload-artifact` v4.6.2) — pinned and
      validated in `ci-self-test.yml`.
- [ ] Security actions (codeql-action v3.29.0, trivy-action v0.36.0, sbom-action v0.20.7,
      gitleaks-action v2.3.9, osv-scanner-action v1.9.0) — pinned SHAs documented and exercised in
      the consumer's live validation (per `pinned-tool-references.md`).
- [ ] On any action bump: resolve the new SHA, update `pinned-tool-references.md`, keep the readable
      version as the trailing comment.

---

## 10. SBOM reproducibility notes (Task 99)

Sentinel Shield's container-vulnerability path is **SBOM-first**: Syft produces the SBOM, and Grype
scans that SBOM rather than re-walking the image. Reproducibility properties:

- **Deterministic inputs.** The same digest-pinned image fed to the same pinned Syft version yields
  the same SBOM (same package set + versions), so Grype's vulnerability output over that SBOM is
  reproducible. Pin the **image by digest** (not tag) to keep the SBOM input fixed.
- **Decoupled, auditable artifact.** The SBOM is an inspectable artifact between "what's in the
  image" and "what's vulnerable", so a finding can be traced to a specific package@version rather
  than an opaque image scan — and re-scanned later with an updated Grype DB without rebuilding.
- **Pinned producers.** Syft / Grype run as pinned, verified images (Grype `v0.114.0` digest
  `sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28`; the `anchore/sbom-action`
  and `anchore/scan-action` SHAs are in `pinned-tool-references.md`). Updating either follows the
  version-update process in §7 so the SBOM toolchain stays reproducible.
- **Note on DB freshness.** Grype's vulnerability *database* updates over time, so the **package set**
  is reproducible but the **match set** can change as new CVEs are published against the same
  packages. That is expected and desirable; it does not change the SBOM input, only the matching.

---

## References

- [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) — authoritative digest table,
  verify / update / rollback narrative.
- [`pinned-tool-references.md`](pinned-tool-references.md) — Action SHA table + image digests.
- [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md) — why
  Dependency-Check is attempted, not validated (the `latest` exception).
- [`main-gate-live-evidence.md`](main-gate-live-evidence.md) — citable live validation runs.
- [`github-actions-security.md`](github-actions-security.md) — Action pinning rationale.
