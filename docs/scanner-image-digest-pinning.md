# Scanner Image Digest Pinning (v0.1.21)

Validated Sentinel Shield scanner images are **tag-pinned** in the templates for readability, but a
tag is mutable — the same `:v0.114.0` can point at a different image tomorrow. For supply-chain
integrity, consuming projects should pin scanner images by **digest** (`@sha256:…`). This doc gives
the real, resolved digests for the three live-validated/validated scanner images and the procedure
to verify, update, and roll them back.

> Digests below were **resolved with Docker, not invented** — `docker buildx imagetools inspect`
> on **2026-06-10**. They are the multi-arch **manifest-list** digests (what you pin); Docker
> resolves the right per-arch image at pull time.

## Resolved digests (2026-06-10)

| Image | Tag (validation) | Resolved digest | Validated in |
|---|---|---|---|
| `semgrep/semgrep` | `1.165.0` | `sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b` | consumer-verified, zenchron run 27239206382 (0 parser errors) |
| `anchore/grype` | `v0.114.0` | `sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28` | live-validated (SBOM-first), zenchron run 27239206382 |
| `goodwithtech/dockle` | `v0.4.15` | `sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9` | live-validated (built image), zenchron run 27239206382 |

Digest-pinned forms (paste these into your workflow env):

```yaml
env:
  SENTINEL_SHIELD_SEMGREP_IMAGE: semgrep/semgrep@sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b   # 1.165.0
  SENTINEL_SHIELD_GRYPE_IMAGE:   anchore/grype@sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28      # v0.114.0
  SENTINEL_SHIELD_DOCKLE_IMAGE:  goodwithtech/dockle@sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9 # v0.4.15
```

> OWASP Dependency-Check is intentionally **not** listed here — it is *attempted, not
> live-validated* (see [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md)).
> We do not pin a digest for an image we have not validated. Resolve and pin it only once a nightly
> run produces a real artifact.

## Digest resolution command

```sh
docker buildx imagetools inspect semgrep/semgrep:1.165.0
docker buildx imagetools inspect anchore/grype:v0.114.0
docker buildx imagetools inspect goodwithtech/dockle:v0.4.15
# digest only:
docker buildx imagetools inspect semgrep/semgrep:1.165.0 --format '{{.Manifest.Digest}}'
```

## How to verify a digest still matches the expected version

A digest must always resolve back to the **same version** you validated. To confirm before trusting
a pinned digest:

```sh
# 1. The tag must still resolve to the pinned digest (tag has not been re-pushed to a new image):
docker buildx imagetools inspect anchore/grype:v0.114.0 --format '{{.Manifest.Digest}}'
#    -> must equal sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28

# 2. The image, run by digest, must report the expected version:
docker run --rm anchore/grype@sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28 version | grep -i '0.114.0'
docker run --rm goodwithtech/dockle@sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9 --version
docker run --rm semgrep/semgrep@sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b semgrep --version   # -> 1.165.0
```

If step 1 mismatches, the tag was re-pushed — **do not** silently adopt the new digest; treat it as
an update (below) and re-validate.

## How to update safely

1. Pick the new version tag; resolve its digest with `docker buildx imagetools inspect <image>:<tag>`.
2. Run the verify steps above against the **new** digest (confirm version output).
3. Re-run the relevant validation:
   - Semgrep: `sh scripts/verify-semgrep-image.sh tests/fixtures/semgrep/php-modern reports/raw/semgrep-image-verify.json` (expect 0 parser errors).
   - Grype/Dockle: run on a consumer and confirm the collector parses the artifact.
4. Update the digest + date in this file **and** in [`pinned-tool-references.md`](pinned-tool-references.md).
5. Update the override examples in the workflow templates (tags stay readable; digest in the comment).
6. Record the new validation run in [`main-gate-live-evidence.md`](main-gate-live-evidence.md).

## How consuming projects should pin

- Override the scanner image env var with the **digest** form (`<image>@sha256:…`), keeping the
  human tag as a trailing `# comment` for readability.
- Pin once, in the workflow `env:` (or a repo/org variable) so every job inherits it.
- The Sentinel Shield wrappers accept the override transparently: `SENTINEL_SHIELD_SEMGREP_IMAGE`,
  `SENTINEL_SHIELD_GRYPE_IMAGE`, `SENTINEL_SHIELD_DOCKLE_IMAGE`.
- Do **not** replace the readable tag in the upstream Sentinel Shield templates with a digest — the
  digest is a consumer-side production decision; templates stay readable + overridable.

## Rollback process

If a newly-pinned digest misbehaves (false positives, crashes, version drift):

1. Revert the env override to the **previous known-good digest** from the table above (these are the
   validated baselines).
2. Re-run the gate; confirm green.
3. File the regression against the scanner upstream; keep the old digest pinned until fixed.
4. Because the old digests are immutable, rollback is deterministic — the exact validated image is
   always retrievable by its `@sha256:` reference even if the tag has moved on.

## v0.1.27 — digest re-verification (all MATCH)

Re-resolved with Docker on **2026-06-15**; every digest **matches** the prior recorded value
(reproducible across releases — not invented):

| Image | Tag | Digest | Verdict |
|---|---|---|---|
| `owasp/dependency-check` | `latest` | `sha256:ad169904106250816059f113d374d63a49a7cb0fd2c5e476d05c4fb814cc77b9` | **MATCH** (v0.1.26) |
| `semgrep/semgrep` | `1.165.0` | `sha256:f4791a54…bfed1b` | **MATCH** (v0.1.21) |
| `anchore/grype` | `v0.114.0` | `sha256:7a9fc7f8…01dd28` | **MATCH** (v0.1.21) |
| `goodwithtech/dockle` | `v0.4.15` | `sha256:eade932f…7abe6b9` | **MATCH** (v0.1.21) |

**Production recommendation.** Templates ship **readable tags** for legibility; consumers SHOULD pin
each scanner to its `@sha256:` digest before production via the documented override env vars.
Dependency-Check is the one image referenced as `:latest` (it tracks the NVD analyzers); for a
reproducible consumer gate, pin it to `owasp/dependency-check@sha256:ad169904…cc77b9` (the digest
behind the v0.1.27 consumer run). **Default templates remain tag-based by design**; moving them to
digest-pinned-by-default is a separate v1.0 item (`v1-readiness.md` §6). Rollback and digest-mismatch
guidance: see the section above (immutable digests → deterministic rollback).

## v0.1.28 — pinning policy (decided)

Digests re-verified again 2026-06-15 — DC/Semgrep/Grype/Dockle all **MATCH**. The pinning policy is
now an explicit, documented decision:

| Context | Form | Why |
|---|---|---|
| **development / onboarding** | **readable tags** (`owasp/dependency-check:latest`, `anchore/grype:v0.114.0`, …) | legible, easy to bump, low-friction adoption |
| **production / hardened** | **digest-pinned overrides** (`@sha256:…` via the documented env vars) | reproducible, tamper-evident, deterministic rollback |

- **Default templates stay tag-based by design** (legibility) — this is a deliberate stance, not an
  open gap. Consumers harden by pinning before production.
- **Hardened reference:** [`examples/hardened/sentinel-shield-hardened.snippet.yml`](../examples/hardened/sentinel-shield-hardened.snippet.yml)
  pins every scanner image + Action by digest/SHA. **Do not use `:latest` in production** — pin
  Dependency-Check too (to `owasp/dependency-check@sha256:ad169904…cc77b9`).
- **Rollback:** keep the prior `@sha256:` — immutable, always retrievable. **Drift:** a mismatch at
  pull time fails the gate closed; investigate before bumping.
